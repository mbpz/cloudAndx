#!/usr/bin/env python3
"""Allowlisted HTTP bridge for an Android Emulator reachable through ADB."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ADB = os.environ.get("ADB_PATH", "/opt/platform-tools/adb")
ADB_SERIAL = os.environ.get("ADB_SERIAL", "emulator:5555")


def _load_token() -> str:
    path = os.environ.get("BRIDGE_TOKEN_FILE", "")
    if path:
        try:
            return Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            return ""
    return os.environ.get("BRIDGE_TOKEN", "").strip()


AUTH_TOKEN = _load_token()
MAX_JSON_BYTES = 64 * 1024
MAX_APK_BYTES = 256 * 1024 * 1024
PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")
PHONE_RE = re.compile(r"^[+0-9*#]{1,32}$")
SESSION_HEALTH_RE = re.compile(r"^/sessions/(ses_[a-f0-9]{32})/healthz$")
MIN_ANDROID_API_LEVEL = 37
EXPECTED_ANDROID_ABI = "arm64-v8a"
EXPECTED_PAGE_SIZE_BYTES = 16384
REQUIRED_GOOGLE_PACKAGES = (
    "com.android.vending",
    "com.google.android.gms",
)
RUNTIME_HEALTH_TTL_SECONDS = max(
    1,
    int(os.environ.get("RUNTIME_HEALTH_TTL_SECONDS", "60")),
)
_RUNTIME_HEALTH_LOCK = threading.Lock()
_RUNTIME_HEALTH_CACHE: tuple[
    float,
    str,
    tuple[bool, str, dict[str, Any]],
] | None = None


class AdbError(RuntimeError):
    pass


class Adb:
    def __init__(self, executable: str = ADB, serial: str = ADB_SERIAL) -> None:
        self.executable = executable
        self.serial = serial
        self._last_connect = 0.0

    def _raw(self, args: list[str], timeout: int = 30, input_bytes: bytes | None = None) -> bytes:
        try:
            result = subprocess.run(
                [self.executable, *args],
                input=input_bytes,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise AdbError(str(exc)) from exc
        if result.returncode != 0:
            message = result.stderr.decode("utf-8", "replace").strip()
            raise AdbError(message or f"adb exited {result.returncode}")
        return result.stdout

    def connect(self, force: bool = False) -> None:
        now = time.monotonic()
        if force or now - self._last_connect > 5:
            self._raw(["connect", self.serial], timeout=3)
            self._last_connect = now

    def run(self, args: list[str], timeout: int = 30) -> bytes:
        self.connect()
        return self._raw(["-s", self.serial, *args], timeout=timeout)

    def text(self, args: list[str], timeout: int = 30) -> str:
        return self.run(args, timeout).decode("utf-8", "replace").strip()

    def shell(self, *args: str, timeout: int = 30) -> str:
        return self.text(["shell", *args], timeout=timeout)

    def emu(self, *args: str) -> str:
        return self.text(["emu", *args], timeout=15)


ADB_CLIENT = Adb()


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def _bounded_int(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer in [{minimum}, {maximum}]")
    return value


def _bounded_float(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not minimum <= float(value) <= maximum:
        raise ValueError(f"{name} must be a number in [{minimum}, {maximum}]")
    return float(value)


def _assess_runtime_health(observed: dict[str, Any]) -> tuple[bool, str]:
    reasons: list[str] = []
    state = str(observed.get("state", ""))
    properties = observed.get("properties", {})
    packages = observed.get("packages", {})
    package_errors = observed.get("package_errors", {})

    if state != "device":
        reasons.append(f"ADB state is {state!r}; expected 'device'")

    boot_completed = str(properties.get("boot_completed", ""))
    if boot_completed != "1":
        reasons.append(f"sys.boot_completed is {boot_completed!r}; expected '1'")

    api_text = str(properties.get("api_level", ""))
    try:
        api_level = int(api_text)
    except ValueError:
        reasons.append(f"API level is not an integer: {api_text!r}")
    else:
        if api_level < MIN_ANDROID_API_LEVEL:
            reasons.append(f"API level {api_level} is below required {MIN_ANDROID_API_LEVEL}")

    abi = str(properties.get("abi", ""))
    if abi != EXPECTED_ANDROID_ABI:
        reasons.append(
            f"ro.product.cpu.abi is {abi!r}; expected {EXPECTED_ANDROID_ABI!r}"
        )

    page_size_text = str(properties.get("page_size_bytes", ""))
    try:
        page_size_bytes = int(page_size_text)
    except ValueError:
        reasons.append(f"PAGE_SIZE is not an integer: {page_size_text!r}")
    else:
        if page_size_bytes != EXPECTED_PAGE_SIZE_BYTES:
            reasons.append(
                f"PAGE_SIZE is {page_size_bytes} bytes; "
                f"expected {EXPECTED_PAGE_SIZE_BYTES}"
            )

    for package in REQUIRED_GOOGLE_PACKAGES:
        if packages.get(package) is True:
            continue
        if package in package_errors:
            reasons.append(f"could not verify required package {package}: {package_errors[package]}")
        else:
            reasons.append(f"required package {package} is not installed")

    return not reasons, "ready" if not reasons else "; ".join(reasons)


class Handler(BaseHTTPRequestHandler):
    server_version = "android-device-bridge/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"bridge: {self.address_string()} {fmt % args}", flush=True)

    def _send(self, status: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _json(self, status: int, value: Any) -> None:
        self._send(status, _json_bytes(value))

    def _error(self, status: int, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})

    def _require_auth(self) -> bool:
        if not AUTH_TOKEN:
            self._error(HTTPStatus.SERVICE_UNAVAILABLE, "AUTH_NOT_CONFIGURED", "BRIDGE_TOKEN is required")
            return False
        if self.headers.get("Authorization") != f"Bearer {AUTH_TOKEN}":
            self._error(HTTPStatus.UNAUTHORIZED, "UNAUTHORIZED", "valid bearer token required")
            return False
        return True

    def _read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length <= 0 or length > MAX_JSON_BYTES:
            raise ValueError(f"JSON body must be 1..{MAX_JSON_BYTES} bytes")
        value = json.loads(self.rfile.read(length))
        if not isinstance(value, dict):
            raise ValueError("JSON body must be an object")
        return value

    def _device_summary(self) -> dict[str, Any]:
        state = ADB_CLIENT.text(["get-state"], timeout=10)
        props = {
            "boot_completed": ADB_CLIENT.shell("getprop", "sys.boot_completed"),
            "android_version": ADB_CLIENT.shell("getprop", "ro.build.version.release"),
            "api_level": ADB_CLIENT.shell("getprop", "ro.build.version.sdk"),
            "security_patch": ADB_CLIENT.shell("getprop", "ro.build.version.security_patch"),
            "fingerprint": ADB_CLIENT.shell("getprop", "ro.build.fingerprint"),
            "product": ADB_CLIENT.shell("getprop", "ro.product.name"),
            "abi": ADB_CLIENT.shell("getprop", "ro.product.cpu.abi"),
            "page_size_bytes": ADB_CLIENT.shell("getconf", "PAGE_SIZE"),
        }
        return {"serial": ADB_SERIAL, "state": state, "properties": props}

    def _runtime_health(self) -> tuple[bool, str, dict[str, Any]]:
        observed = self._device_summary()
        packages: dict[str, bool | None] = {}
        package_errors: dict[str, str] = {}
        for package in REQUIRED_GOOGLE_PACKAGES:
            try:
                output = ADB_CLIENT.shell("pm", "path", package, timeout=10)
                packages[package] = any(line.startswith("package:") for line in output.splitlines())
            except AdbError as exc:
                packages[package] = None
                package_errors[package] = str(exc)
        observed["packages"] = packages
        if package_errors:
            observed["package_errors"] = package_errors
        ready, reason = _assess_runtime_health(observed)
        return ready, reason, observed

    def _cached_runtime_health(self) -> tuple[bool, str, dict[str, Any]]:
        global _RUNTIME_HEALTH_CACHE

        now = time.monotonic()
        cached = _RUNTIME_HEALTH_CACHE
        if cached is not None and now - cached[0] < RUNTIME_HEALTH_TTL_SECONDS:
            return cached[2]

        with _RUNTIME_HEALTH_LOCK:
            now = time.monotonic()
            cached = _RUNTIME_HEALTH_CACHE
            if cached is not None and now - cached[0] < RUNTIME_HEALTH_TTL_SECONDS:
                return cached[2]
            try:
                result = self._runtime_health()
            except (AdbError, ValueError) as exc:
                result = (
                    False,
                    f"device evidence unavailable: {exc}",
                    {"serial": ADB_SERIAL},
                )
            observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            _RUNTIME_HEALTH_CACHE = (time.monotonic(), observed_at, result)
            return result

    def _session_health(self, session_id: str) -> None:
        ready, reason, observed = self._cached_runtime_health()
        cached = _RUNTIME_HEALTH_CACHE
        observed_at = (
            cached[1]
            if cached is not None
            else datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        )

        payload: dict[str, Any] = {
            "session_id": session_id,
            "healthy": ready,
            "observed_at": observed_at,
        }
        if not ready:
            payload.update({"reason": reason, "observed": observed})
        self._json(HTTPStatus.OK if ready else HTTPStatus.SERVICE_UNAVAILABLE, payload)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        try:
            session_match = SESSION_HEALTH_RE.fullmatch(parsed.path)
            if session_match:
                self._session_health(session_match.group(1))
            elif parsed.path == "/livez":
                self._json(HTTPStatus.OK, {"alive": True})
            elif parsed.path == "/healthz":
                ready, reason, observed = self._cached_runtime_health()
                self._json(
                    HTTPStatus.OK if ready else HTTPStatus.SERVICE_UNAVAILABLE,
                    {"ready": ready, "reason": reason, **observed},
                )
            elif parsed.path == "/v1/device":
                self._json(HTTPStatus.OK, self._device_summary())
            elif parsed.path == "/v1/screenshot.png":
                image = ADB_CLIENT.run(["exec-out", "screencap", "-p"], timeout=30)
                self._send(HTTPStatus.OK, image, "image/png")
            elif parsed.path == "/v1/apps":
                packages = [line.removeprefix("package:") for line in ADB_CLIENT.shell("pm", "list", "packages", "-3").splitlines()]
                self._json(HTTPStatus.OK, {"packages": packages})
            elif parsed.path == "/v1/logcat":
                query = urllib.parse.parse_qs(parsed.query)
                lines = _bounded_int(int(query.get("lines", ["200"])[0]), "lines", 1, 2000)
                self._json(HTTPStatus.OK, {"lines": ADB_CLIENT.text(["logcat", "-d", "-t", str(lines)]).splitlines()})
            else:
                self._error(HTTPStatus.NOT_FOUND, "NOT_FOUND", "unknown endpoint")
        except (AdbError, ValueError) as exc:
            self._error(HTTPStatus.SERVICE_UNAVAILABLE, "DEVICE_UNAVAILABLE", str(exc))

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._require_auth():
            return
        prefix = "/v1/apps/"
        if not self.path.startswith(prefix):
            self._error(HTTPStatus.NOT_FOUND, "NOT_FOUND", "unknown endpoint")
            return
        package = urllib.parse.unquote(self.path[len(prefix):])
        if not PACKAGE_RE.fullmatch(package):
            self._error(HTTPStatus.BAD_REQUEST, "INVALID_PACKAGE", "invalid package name")
            return
        try:
            self._json(HTTPStatus.OK, {"result": ADB_CLIENT.text(["uninstall", package], timeout=90)})
        except AdbError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, "ADB_FAILED", str(exc))

    def do_POST(self) -> None:  # noqa: N802
        if not self._require_auth():
            return
        try:
            if self.path == "/v1/apk":
                self._install_apk()
                return
            body = self._read_json()
            result = self._mutation(self.path, body)
            self._json(HTTPStatus.OK, {"result": result})
        except ValueError as exc:
            self._error(HTTPStatus.BAD_REQUEST, "INVALID_REQUEST", str(exc))
        except AdbError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, "ADB_FAILED", str(exc))

    def _mutation(self, path: str, body: dict[str, Any]) -> str:
        if path == "/v1/input/tap":
            x = _bounded_int(body.get("x"), "x", 0, 16384)
            y = _bounded_int(body.get("y"), "y", 0, 16384)
            return ADB_CLIENT.shell("input", "tap", str(x), str(y))
        if path == "/v1/input/swipe":
            values = [_bounded_int(body.get(k), k, 0, 16384) for k in ("x1", "y1", "x2", "y2")]
            duration = _bounded_int(body.get("duration_ms", 300), "duration_ms", 1, 10000)
            return ADB_CLIENT.shell("input", "swipe", *(str(v) for v in values), str(duration))
        if path == "/v1/input/text":
            text = body.get("text")
            if not isinstance(text, str) or not 1 <= len(text) <= 1000 or not re.fullmatch(r"[A-Za-z0-9 .,?!_@:+-]+", text):
                raise ValueError("text contains characters unsafe for the emulator input command")
            return ADB_CLIENT.shell("input", "text", text.replace(" ", "%s"))
        if path == "/v1/input/keyevent":
            keycode = _bounded_int(body.get("keycode"), "keycode", 0, 288)
            return ADB_CLIENT.shell("input", "keyevent", str(keycode))
        if path == "/v1/location":
            lon = _bounded_float(body.get("longitude"), "longitude", -180, 180)
            lat = _bounded_float(body.get("latitude"), "latitude", -90, 90)
            altitude = _bounded_float(body.get("altitude", 0), "altitude", -500, 100000)
            return ADB_CLIENT.emu("geo", "fix", str(lon), str(lat), str(altitude))
        if path == "/v1/sms":
            sender = str(body.get("from", ""))
            text = body.get("text")
            if not PHONE_RE.fullmatch(sender) or not isinstance(text, str) or not 1 <= len(text) <= 500:
                raise ValueError("from or text is invalid")
            return ADB_CLIENT.emu("sms", "send", sender, text)
        if path == "/v1/call":
            action = body.get("action")
            number = str(body.get("number", ""))
            if action not in {"call", "accept", "cancel", "hold"} or not PHONE_RE.fullmatch(number):
                raise ValueError("action or number is invalid")
            return ADB_CLIENT.emu("gsm", action, number)
        if path == "/v1/network":
            speed = body.get("speed", "full")
            delay = body.get("delay", "none")
            if speed not in {"gsm", "hscsd", "gprs", "edge", "umts", "hsdpa", "lte", "full"}:
                raise ValueError("unsupported network speed")
            if delay not in {"none", "gprs", "edge", "umts"}:
                raise ValueError("unsupported network delay")
            return f"{ADB_CLIENT.emu('network', 'speed', speed)}; {ADB_CLIENT.emu('network', 'delay', delay)}"
        if path == "/v1/battery":
            level = _bounded_int(body.get("level"), "level", 0, 100)
            return ADB_CLIENT.emu("power", "capacity", str(level))
        if path == "/v1/rotation":
            rotation = _bounded_int(body.get("rotation"), "rotation", 0, 3)
            ADB_CLIENT.shell("settings", "put", "system", "accelerometer_rotation", "0")
            return ADB_CLIENT.shell("settings", "put", "system", "user_rotation", str(rotation))
        if path == "/v1/reboot":
            return ADB_CLIENT.text(["reboot"], timeout=10)
        raise ValueError("unknown mutation endpoint")

    def _install_apk(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length <= 0 or length > MAX_APK_BYTES:
            raise ValueError(f"APK body must be 1..{MAX_APK_BYTES} bytes")
        name = Path(self.headers.get("X-Filename", "upload.apk")).name
        if not name.endswith(".apk") or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", name):
            raise ValueError("X-Filename must be a safe .apk name")
        with tempfile.TemporaryDirectory(prefix="apk-") as directory:
            apk = Path(directory) / name
            remaining = length
            with apk.open("wb") as handle:
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError("unexpected end of APK body")
                    handle.write(chunk)
                    remaining -= len(chunk)
            output = ADB_CLIENT.text(["install", "-r", str(apk)], timeout=180)
            self._json(HTTPStatus.OK, {"result": output})


def main() -> None:
    host = os.environ.get("LISTEN_HOST", "0.0.0.0")
    port = int(os.environ.get("LISTEN_PORT", "8090"))
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"bridge: listening on {host}:{port}, adb={ADB_SERIAL}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

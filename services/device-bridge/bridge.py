#!/usr/bin/env python3
"""Allowlisted HTTP bridge for an Android Emulator via ADB and Console."""

from __future__ import annotations

import json
import math
import os
import re
import socket
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


def _bounded_env_int(name: str, fallback: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(fallback))
    try:
        value = int(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be in [{minimum}, {maximum}]")
    return value


def _load_token() -> str:
    path = os.environ.get("BRIDGE_TOKEN_FILE", "")
    if path:
        try:
            return Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            return ""
    return os.environ.get("BRIDGE_TOKEN", "").strip()


def _validated_console_socket_path(value: str) -> str:
    if (
        not isinstance(value, str)
        or not value.startswith("/")
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
        or len(os.fsencode(value)) > 107
    ):
        raise RuntimeError(
            "EMULATOR_CONSOLE_SOCKET must be an absolute, control-free Unix socket path"
        )
    return value


AUTH_TOKEN = _load_token()
EMULATOR_CONSOLE_SOCKET = _validated_console_socket_path(
    os.environ.get(
        "EMULATOR_CONSOLE_SOCKET", "/run/emulator-console/console.sock"
    )
)
EMULATOR_CONSOLE_TIMEOUT_SECONDS = _bounded_env_int(
    "EMULATOR_CONSOLE_TIMEOUT_SECONDS", 15, 1, 60
)
MAX_JSON_BYTES = 64 * 1024
MAX_APK_BYTES = 256 * 1024 * 1024
MAX_CONSOLE_COMMAND_BYTES = 4096
MAX_CONSOLE_RESPONSE_BYTES = 64 * 1024
MAX_CONSOLE_LINE_BYTES = 4096
PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")
PHONE_RE = re.compile(r"^[+0-9*#]{1,32}$")
CONSOLE_TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
MIN_ANDROID_API_LEVEL = _bounded_env_int("MIN_ANDROID_API_LEVEL", 37, 1, 100)
EXPECTED_ANDROID_ABI = os.environ.get("EXPECTED_ANDROID_ABI", "arm64-v8a")
EXPECTED_PAGE_SIZE_BYTES = _bounded_env_int(
    "EXPECTED_PAGE_SIZE_BYTES", 16384, 4096, 65536
)
EXPECTED_AVD_NAME = os.environ.get(
    "EXPECTED_AVD_NAME", "Pixel_9_Android_17_Play_ARM64"
)
if any(
    ord(character) < 32 or ord(character) == 127 for character in EXPECTED_AVD_NAME
):
    raise RuntimeError("EXPECTED_AVD_NAME must not contain control characters")
REQUIRED_GOOGLE_PACKAGES = tuple(
    package
    for package in os.environ.get(
        "REQUIRED_ANDROID_PACKAGES", "com.android.vending,com.google.android.gms"
    ).split(",")
    if package
)
CONSOLE_ENABLED = os.environ.get("EMULATOR_CONSOLE_ENABLED", "true").lower() in {
    "1",
    "true",
    "yes",
}
ADB_READ_TIMEOUT_SECONDS = _bounded_env_int(
    "ADB_READ_TIMEOUT_SECONDS", 180, 30, 300
)
RUNTIME_HEALTH_TTL_SECONDS = _bounded_env_int(
    "RUNTIME_HEALTH_TTL_SECONDS", 60, 1, 300
)
RUNTIME_HEALTH_BUDGET_SECONDS = _bounded_env_int(
    "RUNTIME_HEALTH_BUDGET_SECONDS", 180, 30, 900
)
RuntimeHealthResult = tuple[bool, str, dict[str, Any]]
_RUNTIME_HEALTH_LOCK = threading.Lock()
_RUNTIME_HEALTH_CACHE: tuple[
    float,
    str,
    RuntimeHealthResult,
] | None = None


class AdbError(RuntimeError):
    pass


class ConsoleError(RuntimeError):
    pass


def _safe_sms_text(value: Any) -> bool:
    if not isinstance(value, str) or not value or not value.isprintable():
        return False
    return len(value.encode("utf-8")) < MAX_CONSOLE_COMMAND_BYTES


def _runtime_health_timeout(deadline: float | None) -> float:
    if deadline is None:
        return float(ADB_READ_TIMEOUT_SECONDS)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise AdbError(
            "runtime health probe exhausted its "
            f"{RUNTIME_HEALTH_BUDGET_SECONDS}-second aggregate budget"
        )
    return min(float(ADB_READ_TIMEOUT_SECONDS), remaining)


class Adb:
    def __init__(self, executable: str = ADB, serial: str = ADB_SERIAL) -> None:
        self.executable = executable
        self.serial = serial
        self._last_connect = 0.0

    def _raw(
        self,
        args: list[str],
        timeout: float = 30,
        input_bytes: bytes | None = None,
    ) -> bytes:
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

    def connect(self, force: bool = False, timeout: float = 3) -> None:
        now = time.monotonic()
        if force or now - self._last_connect > 5:
            self._raw(["connect", self.serial], timeout=min(3.0, timeout))
            self._last_connect = time.monotonic()

    def run(self, args: list[str], timeout: float = 30) -> bytes:
        started_at = time.monotonic()
        self.connect(timeout=timeout)
        remaining = timeout - (time.monotonic() - started_at)
        if remaining <= 0:
            raise AdbError(f"adb operation exhausted its {timeout:g}-second timeout")
        return self._raw(["-s", self.serial, *args], timeout=remaining)

    def text(self, args: list[str], timeout: float = 30) -> str:
        return self.run(args, timeout).decode("utf-8", "replace").strip()

    def shell(self, *args: str, timeout: float = 30) -> str:
        return self.text(["shell", *args], timeout=timeout)


class _ConsoleProtocol:
    def __init__(self, connection: socket.socket, deadline: float) -> None:
        self.connection = connection
        self.deadline = deadline
        self.buffer = b""
        self.received_bytes = 0

    def _remaining(self) -> float:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ConsoleError("emulator console operation timed out")
        return remaining

    def send_line(self, line: str) -> None:
        encoded = line.encode("utf-8") + b"\r\n"
        self.connection.settimeout(self._remaining())
        self.connection.sendall(encoded)

    def read_reply(self) -> tuple[list[str], str]:
        payload: list[str] = []
        while True:
            line = self._read_line()
            if line == "OK":
                return payload, "OK"
            if line == "KO" or line.startswith("KO:"):
                return payload, "KO"
            payload.append(line)

    def _read_line(self) -> str:
        while b"\n" not in self.buffer:
            self.connection.settimeout(self._remaining())
            chunk = self.connection.recv(4096)
            if not chunk:
                raise ConsoleError("emulator console closed before a status line")
            self.received_bytes += len(chunk)
            if self.received_bytes > MAX_CONSOLE_RESPONSE_BYTES:
                raise ConsoleError("emulator console response exceeded its limit")
            self.buffer += chunk
            if len(self.buffer) > MAX_CONSOLE_LINE_BYTES and b"\n" not in self.buffer:
                raise ConsoleError("emulator console line exceeded its limit")
        raw_line, self.buffer = self.buffer.split(b"\n", 1)
        raw_line = raw_line.removesuffix(b"\r")
        if len(raw_line) > MAX_CONSOLE_LINE_BYTES:
            raise ConsoleError("emulator console line exceeded its limit")
        try:
            line = raw_line.decode("utf-8")
        except UnicodeDecodeError:
            raise ConsoleError("emulator console returned invalid text") from None
        if any(ord(character) < 32 or ord(character) == 127 for character in line):
            raise ConsoleError("emulator console returned invalid text")
        return line

    def best_effort_quit(self) -> None:
        try:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                return
            self.connection.settimeout(min(0.25, remaining))
            self.connection.sendall(b"quit\r\n")
        except (OSError, ConsoleError):
            return


class EmulatorConsole:
    def __init__(
        self,
        socket_path: str = EMULATOR_CONSOLE_SOCKET,
        token: str = AUTH_TOKEN,
        timeout: float = EMULATOR_CONSOLE_TIMEOUT_SECONDS,
    ) -> None:
        self.socket_path = _validated_console_socket_path(socket_path)
        self.token = token
        self.timeout = float(timeout)

    def command(self, *parts: str, timeout: float | None = None) -> str:
        command_line = self._command_line(parts)
        if not self._token_is_safe():
            raise ConsoleError("emulator console authentication is unavailable")
        effective_timeout = (
            self.timeout if timeout is None else min(self.timeout, float(timeout))
        )
        if not math.isfinite(effective_timeout) or effective_timeout <= 0:
            raise ConsoleError("emulator console operation timed out")
        deadline = time.monotonic() + effective_timeout
        connection: socket.socket | None = None
        protocol: _ConsoleProtocol | None = None
        connected = False
        try:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            protocol = _ConsoleProtocol(connection, deadline)
            connection.settimeout(protocol._remaining())
            connection.connect(self.socket_path)
            connected = True
            banner, status = protocol.read_reply()
            if status != "OK":
                raise ConsoleError("emulator console rejected the connection")
            required_auth_banner = {
                "Android Console: Authentication required",
                "Android Console: type 'auth <auth_token>' to authenticate",
            }
            if not required_auth_banner.issubset(banner):
                raise ConsoleError(
                    "emulator console did not require authenticated access"
                )
            protocol.send_line(f"auth {self.token}")
            _, auth_status = protocol.read_reply()
            if auth_status != "OK":
                raise ConsoleError("emulator console authentication failed")
            protocol.send_line(command_line)
            payload, command_status = protocol.read_reply()
            if command_status != "OK":
                raise ConsoleError("emulator console rejected the command")
            result = "\n".join(payload) or "OK"
            if self.token and self.token in result:
                raise ConsoleError("emulator console returned an unsafe response")
            return result
        except ConsoleError:
            raise
        except (OSError, TimeoutError, UnicodeError, ValueError):
            raise ConsoleError("emulator console transport failed") from None
        finally:
            if connected and protocol is not None:
                protocol.best_effort_quit()
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass

    def _token_is_safe(self) -> bool:
        return isinstance(self.token, str) and bool(
            CONSOLE_TOKEN_RE.fullmatch(self.token)
        )

    @staticmethod
    def _command_line(parts: tuple[str, ...]) -> str:
        if not parts or any(
            not isinstance(part, str)
            or not part
            or any(ord(character) < 32 or ord(character) == 127 for character in part)
            for part in parts
        ):
            raise ConsoleError("emulator console command is not allowlisted")

        allowed = False
        if parts == ("avd", "name"):
            allowed = True
        elif len(parts) == 5 and parts[:2] == ("geo", "fix"):
            try:
                longitude, latitude, altitude = (float(value) for value in parts[2:])
            except ValueError:
                allowed = False
            else:
                allowed = (
                    math.isfinite(longitude)
                    and math.isfinite(latitude)
                    and math.isfinite(altitude)
                    and -180 <= longitude <= 180
                    and -90 <= latitude <= 90
                    and -500 <= altitude <= 100000
                )
        elif len(parts) == 4 and parts[:2] == ("sms", "send"):
            allowed = bool(
                PHONE_RE.fullmatch(parts[2]) and _safe_sms_text(parts[3])
            )
        elif len(parts) == 3 and parts[0] == "gsm":
            allowed = parts[1] in {"call", "accept", "cancel", "hold"} and bool(
                PHONE_RE.fullmatch(parts[2])
            )
        elif len(parts) == 3 and parts[:2] == ("network", "speed"):
            allowed = parts[2] in {
                "gsm", "hscsd", "gprs", "edge", "umts", "hsdpa", "lte", "full"
            }
        elif len(parts) == 3 and parts[:2] == ("network", "delay"):
            allowed = parts[2] in {"none", "gprs", "edge", "umts"}
        elif len(parts) == 3 and parts[:2] == ("power", "capacity"):
            allowed = parts[2].isdigit() and 0 <= int(parts[2]) <= 100

        command_line = " ".join(parts)
        encoded_command = command_line.encode("utf-8")
        if (
            not allowed
            or len(encoded_command) + len(b"\r\n") > MAX_CONSOLE_COMMAND_BYTES
            or (parts[:2] != ("sms", "send") and not command_line.isascii())
        ):
            raise ConsoleError("emulator console command is not allowlisted")
        return command_line


ADB_CLIENT = Adb()
CONSOLE_CLIENT = EmulatorConsole()


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
    console = observed.get("console", {})

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

    if CONSOLE_ENABLED:
        avd_name = str(console.get("avd_name", ""))
        if console.get("available") is not True:
            console_error = str(console.get("error", "unavailable"))
            reasons.append(f"emulator console is unavailable: {console_error}")
        elif avd_name != EXPECTED_AVD_NAME:
            reasons.append(
                f"emulator console AVD name is {avd_name!r}; expected {EXPECTED_AVD_NAME!r}"
            )

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

    def _device_summary(self, deadline: float | None = None) -> dict[str, Any]:
        state = ADB_CLIENT.text(
            ["get-state"], timeout=_runtime_health_timeout(deadline)
        )
        props = {
            "boot_completed": ADB_CLIENT.shell(
                "getprop",
                "sys.boot_completed",
                timeout=_runtime_health_timeout(deadline),
            ),
            "android_version": ADB_CLIENT.shell(
                "getprop",
                "ro.build.version.release",
                timeout=_runtime_health_timeout(deadline),
            ),
            "api_level": ADB_CLIENT.shell(
                "getprop",
                "ro.build.version.sdk",
                timeout=_runtime_health_timeout(deadline),
            ),
            "security_patch": ADB_CLIENT.shell(
                "getprop",
                "ro.build.version.security_patch",
                timeout=_runtime_health_timeout(deadline),
            ),
            "fingerprint": ADB_CLIENT.shell(
                "getprop",
                "ro.build.fingerprint",
                timeout=_runtime_health_timeout(deadline),
            ),
            "product": ADB_CLIENT.shell(
                "getprop",
                "ro.product.name",
                timeout=_runtime_health_timeout(deadline),
            ),
            "abi": ADB_CLIENT.shell(
                "getprop",
                "ro.product.cpu.abi",
                timeout=_runtime_health_timeout(deadline),
            ),
            "page_size_bytes": ADB_CLIENT.shell(
                "getconf", "PAGE_SIZE", timeout=_runtime_health_timeout(deadline)
            ),
        }
        return {"serial": ADB_SERIAL, "state": state, "properties": props}

    def _runtime_health(self) -> RuntimeHealthResult:
        deadline = time.monotonic() + RUNTIME_HEALTH_BUDGET_SECONDS
        observed = self._device_summary(deadline)
        packages: dict[str, bool | None] = {}
        package_errors: dict[str, str] = {}
        for package in REQUIRED_GOOGLE_PACKAGES:
            try:
                output = ADB_CLIENT.shell(
                    "pm", "path", package, timeout=_runtime_health_timeout(deadline)
                )
                packages[package] = any(line.startswith("package:") for line in output.splitlines())
            except AdbError as exc:
                packages[package] = None
                package_errors[package] = str(exc)
        observed["packages"] = packages
        if package_errors:
            observed["package_errors"] = package_errors
        if CONSOLE_ENABLED:
            try:
                avd_name = CONSOLE_CLIENT.command(
                    "avd", "name", timeout=_runtime_health_timeout(deadline)
                )
                observed["console"] = {"available": True, "avd_name": avd_name}
            except ConsoleError as exc:
                observed["console"] = {"available": False, "error": str(exc)}
        ready, reason = _assess_runtime_health(observed)
        return ready, reason, observed

    def _cached_runtime_health(self) -> tuple[RuntimeHealthResult, str]:
        global _RUNTIME_HEALTH_CACHE

        with _RUNTIME_HEALTH_LOCK:
            now = time.monotonic()
            cached = _RUNTIME_HEALTH_CACHE
            if cached is not None and now - cached[0] < RUNTIME_HEALTH_TTL_SECONDS:
                return cached[2], cached[1]
            try:
                result = self._runtime_health()
            except (AdbError, ConsoleError, ValueError) as exc:
                result = (
                    False,
                    f"device evidence unavailable: {exc}",
                    {"serial": ADB_SERIAL},
                )
            observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            _RUNTIME_HEALTH_CACHE = (time.monotonic(), observed_at, result)
            return result, observed_at

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        try:
            if parsed.path == "/livez":
                self._json(HTTPStatus.OK, {"alive": True})
            elif parsed.path == "/healthz":
                (ready, reason, observed), _ = self._cached_runtime_health()
                self._json(
                    HTTPStatus.OK if ready else HTTPStatus.SERVICE_UNAVAILABLE,
                    {"ready": ready, "reason": reason, **observed},
                )
            elif parsed.path == "/v1/device":
                self._json(HTTPStatus.OK, self._device_summary())
            elif parsed.path == "/v1/screenshot.png":
                image = ADB_CLIENT.run(
                    ["exec-out", "screencap", "-p"],
                    timeout=ADB_READ_TIMEOUT_SECONDS,
                )
                self._send(HTTPStatus.OK, image, "image/png")
            elif parsed.path == "/v1/apps":
                packages = [
                    line.removeprefix("package:")
                    for line in ADB_CLIENT.shell(
                        "pm", "list", "packages", "-3",
                        timeout=ADB_READ_TIMEOUT_SECONDS,
                    ).splitlines()
                ]
                self._json(HTTPStatus.OK, {"packages": packages})
            elif parsed.path == "/v1/logcat":
                query = urllib.parse.parse_qs(parsed.query)
                lines = _bounded_int(int(query.get("lines", ["200"])[0]), "lines", 1, 2000)
                self._json(
                    HTTPStatus.OK,
                    {
                        "lines": ADB_CLIENT.text(
                            ["logcat", "-d", "-t", str(lines)],
                            timeout=ADB_READ_TIMEOUT_SECONDS,
                        ).splitlines()
                    },
                )
            else:
                self._error(HTTPStatus.NOT_FOUND, "NOT_FOUND", "unknown endpoint")
        except (AdbError, ConsoleError, ValueError) as exc:
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
        except ConsoleError as exc:
            self._error(HTTPStatus.BAD_GATEWAY, "CONSOLE_FAILED", str(exc))

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
            return CONSOLE_CLIENT.command("geo", "fix", str(lon), str(lat), str(altitude))
        if path == "/v1/sms":
            sender = str(body.get("from", ""))
            text = body.get("text")
            if (
                not PHONE_RE.fullmatch(sender)
                or not _safe_sms_text(text)
            ):
                raise ValueError("from or text is invalid")
            return CONSOLE_CLIENT.command("sms", "send", sender, text)
        if path == "/v1/call":
            action = body.get("action")
            number = str(body.get("number", ""))
            if action not in {"call", "accept", "cancel", "hold"} or not PHONE_RE.fullmatch(number):
                raise ValueError("action or number is invalid")
            return CONSOLE_CLIENT.command("gsm", action, number)
        if path == "/v1/network":
            speed = body.get("speed", "full")
            delay = body.get("delay", "none")
            if speed not in {"gsm", "hscsd", "gprs", "edge", "umts", "hsdpa", "lte", "full"}:
                raise ValueError("unsupported network speed")
            if delay not in {"none", "gprs", "edge", "umts"}:
                raise ValueError("unsupported network delay")
            return f"{CONSOLE_CLIENT.command('network', 'speed', speed)}; {CONSOLE_CLIENT.command('network', 'delay', delay)}"
        if path == "/v1/battery":
            level = _bounded_int(body.get("level"), "level", 0, 100)
            return CONSOLE_CLIENT.command("power", "capacity", str(level))
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

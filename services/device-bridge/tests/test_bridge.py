import importlib.util
import io
import json
import os
import socket
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import Mock, call, patch


os.environ.setdefault("BRIDGE_TOKEN", "test-token")
MODULE_PATH = Path(__file__).parents[1] / "bridge.py"
SPEC = importlib.util.spec_from_file_location("bridge", MODULE_PATH)
bridge = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(bridge)


class ValidationTests(unittest.TestCase):
    def test_bounded_env_int_rejects_non_integer_and_out_of_range_values(self):
        with patch.dict(os.environ, {"TEST_SECONDS": "slow"}):
            with self.assertRaises(RuntimeError):
                bridge._bounded_env_int("TEST_SECONDS", 30, 1, 300)
        with patch.dict(os.environ, {"TEST_SECONDS": "301"}):
            with self.assertRaises(RuntimeError):
                bridge._bounded_env_int("TEST_SECONDS", 30, 1, 300)

    def test_bounded_int_rejects_bool_and_range(self):
        with self.assertRaises(ValueError):
            bridge._bounded_int(True, "x", 0, 10)
        with self.assertRaises(ValueError):
            bridge._bounded_int(11, "x", 0, 10)

    def test_bounded_float_accepts_number(self):
        self.assertEqual(bridge._bounded_float(1.5, "x", -2, 2), 1.5)

    def test_package_pattern_is_strict(self):
        self.assertRegex("com.example.app", bridge.PACKAGE_RE)
        self.assertNotRegex("com.example;rm", bridge.PACKAGE_RE)

    def test_console_socket_path_is_absolute_control_free_and_unix_only(self):
        self.assertEqual(
            bridge.EMULATOR_CONSOLE_SOCKET,
            "/run/emulator-console/console.sock",
        )
        for value in (
            "emulator-console/console.sock",
            "/run/emulator-console/console.sock\n",
            "/" + "x" * 108,
        ):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                bridge._validated_console_socket_path(value)
        self.assertFalse(hasattr(bridge, "EMULATOR_CONSOLE_HOST"))
        self.assertFalse(hasattr(bridge, "EMULATOR_CONSOLE_PORT"))

    def test_session_health_path_is_strict(self):
        session_id = "ses_" + "a" * 32
        match = bridge.SESSION_HEALTH_RE.fullmatch(f"/sessions/{session_id}/healthz")
        self.assertEqual(match.group(1), session_id)
        self.assertIsNone(bridge.SESSION_HEALTH_RE.fullmatch(f"/sessions/{session_id}/healthz/extra"))
        self.assertIsNone(bridge.SESSION_HEALTH_RE.fullmatch("/sessions/not-a-session/healthz"))


class FakeAdb:
    def __init__(self):
        self.calls = []

    def shell(self, *args, **kwargs):
        self.calls.append(("shell", args))
        return "ok"

    def emu(self, *args):
        raise AssertionError(f"emulator mutation unexpectedly used adb emu: {args}")

    def text(self, args, timeout=30):
        self.calls.append(("text", tuple(args)))
        return "ok"


class FakeConsole:
    def __init__(self, result="Pixel_9_Android_17_Play_ARM64", error=None):
        self.result = result
        self.error = error
        self.calls = []

    def command(self, *parts, **kwargs):
        self.calls.append((parts, kwargs))
        if self.error is not None:
            raise self.error
        return self.result


class FakeSocket:
    def __init__(self, replies, connect_error=None):
        self.replies = list(replies)
        self.connect_error = connect_error
        self.sent = []
        self.connects = []
        self.timeouts = []
        self.closed = False

    def settimeout(self, timeout):
        self.timeouts.append(timeout)

    def sendall(self, data):
        self.sent.append(data)

    def connect(self, address):
        self.connects.append(address)
        if self.connect_error is not None:
            raise self.connect_error

    def recv(self, maximum):
        if not self.replies:
            return b""
        reply = self.replies.pop(0)
        if isinstance(reply, BaseException):
            raise reply
        if len(reply) > maximum:
            self.replies.insert(0, reply[maximum:])
            return reply[:maximum]
        return reply

    def close(self):
        self.closed = True


class RuntimeAdb:
    def __init__(self, installed_packages=None, page_size="16384"):
        if installed_packages is None:
            installed_packages = bridge.REQUIRED_GOOGLE_PACKAGES
        self.installed_packages = set(installed_packages)
        self.page_size = page_size
        self.shell_calls = []
        self.shell_timeouts = {}
        self.text_timeouts = {}
        self.timeout_calls = []
        self.properties = {
            "sys.boot_completed": "1",
            "ro.build.version.release": "17",
            "ro.build.version.sdk": "37",
            "ro.build.version.security_patch": "2026-07-01",
            "ro.build.fingerprint": "google/sdk_gphone64_arm64/test",
            "ro.product.name": "sdk_gphone64_arm64",
            "ro.product.cpu.abi": "arm64-v8a",
        }

    def text(self, args, timeout=30):
        self.text_timeouts[tuple(args)] = timeout
        self.timeout_calls.append(timeout)
        if args == ["get-state"]:
            return "device"
        raise AssertionError(f"unexpected text call: {args}")

    def shell(self, *args, **kwargs):
        self.shell_calls.append(args)
        self.shell_timeouts[args] = kwargs.get("timeout")
        self.timeout_calls.append(kwargs.get("timeout"))
        if args[:1] == ("getprop",):
            return self.properties[args[1]]
        if args == ("getconf", "PAGE_SIZE"):
            return self.page_size
        if args[:2] == ("pm", "path"):
            package = args[2]
            return f"package:/system/{package}.apk" if package in self.installed_packages else ""
        raise AssertionError(f"unexpected shell call: {args}")


def healthy_observation():
    return {
        "serial": "emulator:5555",
        "state": "device",
        "properties": {
            "boot_completed": "1",
            "api_level": "37",
            "abi": "arm64-v8a",
            "page_size_bytes": "16384",
        },
        "packages": {
            "com.android.vending": True,
            "com.google.android.gms": True,
        },
        "console": {
            "available": True,
            "avd_name": "Pixel_9_Android_17_Play_ARM64",
        },
    }


class AdbTimeoutTests(unittest.TestCase):
    def test_adb_command_timeout_includes_reconnect_time(self):
        client = bridge.Adb(serial="emulator:5555")
        raw = Mock(return_value=b"device\n")

        with (
            patch.object(client, "_raw", raw),
            patch.object(
                bridge.time,
                "monotonic",
                side_effect=[100.0, 100.0, 102.0, 102.0],
            ),
        ):
            result = client.run(["get-state"], timeout=10)

        self.assertEqual(result, b"device\n")
        self.assertEqual(
            raw.call_args_list,
            [
                call(["connect", "emulator:5555"], timeout=3.0),
                call(["-s", "emulator:5555", "get-state"], timeout=8.0),
            ],
        )


class ConsoleClientTests(unittest.TestCase):
    TOKEN = "a" * 64
    AUTH_BANNER = (
        b"Android Console: Authentication required\r\n"
        b"Android Console: type 'auth <auth_token>' to authenticate\r\n"
        b"OK\r\n"
    )
    READY_BANNER = b"Android Console: type 'help' for a list of commands\r\nOK\r\n"

    def test_console_uses_loaded_bridge_token(self):
        self.assertEqual(bridge.CONSOLE_CLIENT.token, bridge.AUTH_TOKEN)

    def test_authenticated_line_protocol_returns_payload_and_quits(self):
        token = self.TOKEN
        connection = FakeSocket(
            [
                self.AUTH_BANNER[:24],
                self.AUTH_BANNER[24:],
                self.READY_BANNER,
                b"Pixel_9_Android_17_Play_ARM64\r\nOK\r\n",
            ]
        )
        socket_path = "/run/emulator-console/console.sock"
        client = bridge.EmulatorConsole(
            socket_path=socket_path, token=token, timeout=15
        )

        with patch.object(bridge.socket, "socket", return_value=connection) as factory:
            result = client.command("avd", "name")

        self.assertEqual(result, "Pixel_9_Android_17_Play_ARM64")
        factory.assert_called_once_with(socket.AF_UNIX, socket.SOCK_STREAM)
        self.assertEqual(connection.connects, [socket_path])
        self.assertEqual(
            connection.sent,
            [
                f"auth {token}\r\n".encode(),
                b"avd name\r\n",
                b"quit\r\n",
            ],
        )
        self.assertTrue(connection.closed)
        self.assertTrue(all(0 < timeout <= 15 for timeout in connection.timeouts))

    def test_console_fails_closed_when_banner_does_not_require_auth(self):
        connection = FakeSocket([self.READY_BANNER])
        client = bridge.EmulatorConsole(token=self.TOKEN)

        with (
            patch.object(bridge.socket, "socket", return_value=connection),
            self.assertRaisesRegex(
                bridge.ConsoleError, "did not require authenticated access"
            ),
        ):
            client.command("power", "capacity", "50")

        self.assertEqual(connection.sent, [b"quit\r\n"])

    def test_authentication_and_command_errors_never_expose_token(self):
        token = "b" * 64
        cases = [
            [self.AUTH_BANNER, f"KO: bad token {token}\r\n".encode()],
            [
                self.AUTH_BANNER,
                self.READY_BANNER,
                f"KO: rejected {token}\r\n".encode(),
            ],
        ]
        for replies in cases:
            with self.subTest(replies=len(replies)):
                connection = FakeSocket(replies)
                client = bridge.EmulatorConsole(token=token)
                stdout = io.StringIO()
                stderr = io.StringIO()
                with (
                    patch.object(bridge.socket, "socket", return_value=connection),
                    redirect_stdout(stdout),
                    redirect_stderr(stderr),
                    self.assertRaises(bridge.ConsoleError) as raised,
                ):
                    client.command("avd", "name")
                exposed = str(raised.exception) + stdout.getvalue() + stderr.getvalue()
                self.assertNotIn(token, exposed)

    def test_console_requires_exact_lowercase_hex_token(self):
        invalid_tokens = [
            "",
            "a" * 63,
            "a" * 65,
            "A" * 64,
            "g" * 64,
            "a" * 63 + "\n",
            "a" * 63 + "\x00",
            "a" * 63 + "\x7f",
        ]
        for token in invalid_tokens:
            with self.subTest(token_length=len(token)):
                client = bridge.EmulatorConsole(token=token)
                with (
                    patch.object(bridge.socket, "socket") as socket_factory,
                    self.assertRaisesRegex(
                        bridge.ConsoleError, "authentication is unavailable"
                    ),
                ):
                    client.command("avd", "name")
                socket_factory.assert_not_called()

    def test_console_requires_both_exact_auth_banner_lines(self):
        banners = [
            b"Android Console: Authentication required\r\nOK\r\n",
            (
                b"Android Console: type 'auth <auth_token>' to authenticate\r\n"
                b"OK\r\n"
            ),
            (
                b"android console: authentication required\r\n"
                b"Android Console: type 'auth <auth_token>' to authenticate\r\n"
                b"OK\r\n"
            ),
            self.READY_BANNER,
        ]
        for banner in banners:
            with self.subTest(banner=banner):
                connection = FakeSocket([banner])
                client = bridge.EmulatorConsole(token=self.TOKEN)
                with (
                    patch.object(bridge.socket, "socket", return_value=connection),
                    self.assertRaisesRegex(
                        bridge.ConsoleError, "did not require authenticated access"
                    ),
                ):
                    client.command("avd", "name")
                self.assertEqual(connection.sent, [b"quit\r\n"])

    def test_console_sends_printable_utf8_sms_as_one_line(self):
        text = "你好；Android 17 ✅; still one line"
        connection = FakeSocket(
            [self.AUTH_BANNER, self.READY_BANNER, b"OK\r\n"]
        )
        client = bridge.EmulatorConsole(token=self.TOKEN)

        with patch.object(bridge.socket, "socket", return_value=connection):
            result = client.command("sms", "send", "+15551234567", text)

        self.assertEqual(result, "OK")
        self.assertEqual(
            connection.sent,
            [
                f"auth {self.TOKEN}\r\n".encode(),
                f"sms send +15551234567 {text}\r\n".encode("utf-8"),
                b"quit\r\n",
            ],
        )

    def test_console_command_limit_includes_crlf(self):
        prefix = "sms send +1 "
        text_at_limit = "x" * (
            bridge.MAX_CONSOLE_COMMAND_BYTES
            - len(prefix.encode("utf-8"))
            - len(b"\r\n")
        )

        command = bridge.EmulatorConsole._command_line(
            ("sms", "send", "+1", text_at_limit)
        )

        self.assertEqual(
            len(command.encode("utf-8")) + len(b"\r\n"),
            bridge.MAX_CONSOLE_COMMAND_BYTES,
        )
        with self.assertRaises(bridge.ConsoleError):
            bridge.EmulatorConsole._command_line(
                ("sms", "send", "+1", text_at_limit + "x")
            )

    def test_console_rejects_control_injection_and_non_allowlisted_commands(self):
        client = bridge.EmulatorConsole(token=self.TOKEN)
        invalid_commands = [
            ("sms", "send", "+15551234", "hello\r\nquit"),
            ("sms", "send", "+15551234", "hello\x00quit"),
            ("sms", "send", "+15551234", "hello\tquit"),
            ("avd", "stop"),
            ("auth", "token"),
        ]
        with patch.object(bridge.socket, "socket") as socket_factory:
            for command in invalid_commands:
                with self.subTest(command=command):
                    with self.assertRaises(bridge.ConsoleError):
                        client.command(*command)
        socket_factory.assert_not_called()

    def test_console_timeout_and_response_limits_fail_closed(self):
        cases = [
            ([socket.timeout("slow")], "transport failed"),
            ([b"x" * (bridge.MAX_CONSOLE_LINE_BYTES + 1)], "line exceeded"),
            ([], "closed before a status line"),
            ([b"\xff\n"], "invalid text"),
            ([b"unsafe\x00text\r\n"], "invalid text"),
            ([b"OK: not-a-terminal-status\r\n"], "closed before a status line"),
            ([b"KO\r\n"], "rejected the connection"),
            (
                [(b"x" * 1000 + b"\r\n") * 66],
                "response exceeded its limit",
            ),
        ]
        for replies, expected in cases:
            with self.subTest(expected=expected):
                connection = FakeSocket(replies)
                client = bridge.EmulatorConsole(token=self.TOKEN, timeout=15)
                with (
                    patch.object(bridge.socket, "socket", return_value=connection),
                    self.assertRaisesRegex(bridge.ConsoleError, expected),
                ):
                    client.command("avd", "name")
                self.assertTrue(connection.closed)
                self.assertTrue(all(0 < timeout <= 15 for timeout in connection.timeouts))

    def test_console_uses_one_deadline_for_connect_auth_and_command(self):
        connection = FakeSocket(
            [
                self.AUTH_BANNER,
                self.READY_BANNER,
                b"Pixel_9_Android_17_Play_ARM64\r\nOK\r\n",
            ]
        )
        client = bridge.EmulatorConsole(token=self.TOKEN, timeout=15)

        with (
            patch.object(bridge.socket, "socket", return_value=connection),
            patch.object(
                bridge.time,
                "monotonic",
                side_effect=[100.0, 101.0, 102.0, 103.0, 104.0, 105.0, 106.0, 107.0],
            ),
        ):
            client.command("avd", "name")

        self.assertEqual(
            connection.timeouts[:-1], [14.0, 13.0, 12.0, 11.0, 10.0, 9.0]
        )
        self.assertEqual(connection.timeouts[-1], 0.25)

    def test_console_deadline_exhaustion_stops_before_auth_send(self):
        connection = FakeSocket([self.AUTH_BANNER])
        client = bridge.EmulatorConsole(token=self.TOKEN, timeout=15)

        with (
            patch.object(bridge.socket, "socket", return_value=connection),
            patch.object(
                bridge.time,
                "monotonic",
                side_effect=[100.0, 101.0, 102.0, 116.0, 117.0],
            ),
            self.assertRaisesRegex(bridge.ConsoleError, "timed out"),
        ):
            client.command("avd", "name")

        self.assertEqual(connection.sent, [])

    def test_console_success_payload_cannot_echo_auth_token(self):
        connection = FakeSocket(
            [
                self.AUTH_BANNER,
                self.READY_BANNER,
                f"{self.TOKEN}\r\nOK\r\n".encode(),
            ]
        )
        client = bridge.EmulatorConsole(token=self.TOKEN)

        with (
            patch.object(bridge.socket, "socket", return_value=connection),
            self.assertRaises(bridge.ConsoleError) as raised,
        ):
            client.command("avd", "name")

        self.assertNotIn(self.TOKEN, str(raised.exception))


class RuntimeHealthTests(unittest.TestCase):
    def setUp(self):
        bridge._RUNTIME_HEALTH_CACHE = None
        self.console = FakeConsole()
        self.console_patch = patch.object(bridge, "CONSOLE_CLIENT", self.console)
        self.console_patch.start()
        self.addCleanup(self.console_patch.stop)

    def test_liveness_does_not_touch_adb_runtime_health(self):
        handler = object.__new__(bridge.Handler)
        handler.path = "/livez"
        handler._json = Mock()
        handler._runtime_health = Mock(side_effect=AssertionError("deep probe must not run"))

        handler.do_GET()

        handler._runtime_health.assert_not_called()
        handler._json.assert_called_once_with(200, {"alive": True})

    def test_runtime_probe_collects_required_package_evidence(self):
        handler = object.__new__(bridge.Handler)
        adb = RuntimeAdb()
        with patch.object(bridge, "ADB_CLIENT", adb):
            healthy, reason, observed = handler._runtime_health()

        self.assertTrue(healthy)
        self.assertEqual(reason, "ready")
        self.assertEqual(observed["properties"]["api_level"], "37")
        self.assertEqual(observed["properties"]["abi"], "arm64-v8a")
        self.assertEqual(observed["properties"]["page_size_bytes"], "16384")
        self.assertEqual(
            observed["console"]["avd_name"], "Pixel_9_Android_17_Play_ARM64"
        )
        self.assertIn(("getconf", "PAGE_SIZE"), adb.shell_calls)
        self.assertEqual(len(adb.timeout_calls), 11)
        self.assertTrue(
            all(
                0 < timeout <= bridge.ADB_READ_TIMEOUT_SECONDS
                for timeout in adb.timeout_calls
            )
        )
        self.assertEqual(
            observed["packages"],
            {
                "com.android.vending": True,
                "com.google.android.gms": True,
            },
        )
        self.assertEqual(self.console.calls[0][0], ("avd", "name"))

    def test_runtime_probe_caps_each_command_by_remaining_aggregate_budget(self):
        handler = object.__new__(bridge.Handler)
        adb = RuntimeAdb()
        ticks = [100.0, *(100.0 + offset for offset in range(12))]

        with (
            patch.object(bridge, "ADB_CLIENT", adb),
            patch.object(bridge, "RUNTIME_HEALTH_BUDGET_SECONDS", 20),
            patch.object(bridge, "ADB_READ_TIMEOUT_SECONDS", 180),
            patch.object(bridge.time, "monotonic", side_effect=ticks),
        ):
            healthy, reason, _ = handler._runtime_health()

        self.assertTrue(healthy)
        self.assertEqual(reason, "ready")
        self.assertEqual(adb.timeout_calls, list(range(20, 9, -1)))
        self.assertEqual(self.console.calls[0][1]["timeout"], 9)

    def test_runtime_probe_stops_before_command_after_budget_exhaustion(self):
        handler = object.__new__(bridge.Handler)
        adb = RuntimeAdb()

        with (
            patch.object(bridge, "ADB_CLIENT", adb),
            patch.object(bridge, "RUNTIME_HEALTH_BUDGET_SECONDS", 5),
            patch.object(
                bridge.time,
                "monotonic",
                side_effect=[100.0, 100.0, 105.0],
            ),
        ):
            with self.assertRaisesRegex(bridge.AdbError, "aggregate budget"):
                handler._runtime_health()

        self.assertEqual(adb.timeout_calls, [5.0])
        self.assertEqual(adb.shell_calls, [])

    def test_runtime_probe_rejects_a_missing_google_package(self):
        handler = object.__new__(bridge.Handler)
        adb = RuntimeAdb(installed_packages={"com.google.android.gms"})
        with patch.object(bridge, "ADB_CLIENT", adb):
            healthy, reason, observed = handler._runtime_health()

        self.assertFalse(healthy)
        self.assertFalse(observed["packages"]["com.android.vending"])
        self.assertIn("com.android.vending is not installed", reason)

    def test_runtime_probe_fails_closed_when_console_is_unavailable(self):
        handler = object.__new__(bridge.Handler)
        adb = RuntimeAdb()
        self.console.error = bridge.ConsoleError("console transport failed")
        with patch.object(bridge, "ADB_CLIENT", adb):
            healthy, reason, observed = handler._runtime_health()

        self.assertFalse(healthy)
        self.assertFalse(observed["console"]["available"])
        self.assertIn("emulator console is unavailable", reason)

    def test_health_endpoint_returns_503_when_console_is_unavailable(self):
        handler = object.__new__(bridge.Handler)
        handler.path = "/healthz"
        handler._json = Mock()
        adb = RuntimeAdb()
        self.console.error = bridge.ConsoleError("emulator console transport failed")

        with patch.object(bridge, "ADB_CLIENT", adb):
            handler.do_GET()

        status, payload = handler._json.call_args.args
        self.assertEqual(status, 503)
        self.assertFalse(payload["ready"])
        self.assertIn("emulator console is unavailable", payload["reason"])

    def test_deep_health_cache_reuses_one_probe_within_ttl(self):
        handler = object.__new__(bridge.Handler)
        expected = (True, "ready", healthy_observation())
        handler._runtime_health = Mock(return_value=expected)

        first, first_observed_at = handler._cached_runtime_health()
        second, second_observed_at = handler._cached_runtime_health()

        self.assertEqual(first, expected)
        self.assertEqual(second, expected)
        self.assertEqual(first_observed_at, second_observed_at)
        handler._runtime_health.assert_called_once_with()

    def test_deep_health_cache_throttles_adb_failures(self):
        handler = object.__new__(bridge.Handler)
        handler._runtime_health = Mock(side_effect=bridge.AdbError("transport offline"))

        first, first_observed_at = handler._cached_runtime_health()
        second, second_observed_at = handler._cached_runtime_health()

        self.assertFalse(first[0])
        self.assertEqual(first, second)
        self.assertEqual(first_observed_at, second_observed_at)
        self.assertIn("transport offline", first[1])
        handler._runtime_health.assert_called_once_with()

    def test_concurrent_first_cache_miss_runs_one_probe(self):
        handler = object.__new__(bridge.Handler)
        expected = (True, "ready", healthy_observation())
        probe_started = threading.Event()
        second_started = threading.Event()
        release_probe = threading.Event()
        results = []
        errors = []

        def probe():
            probe_started.set()
            if not release_probe.wait(timeout=5):
                raise RuntimeError("test did not release runtime probe")
            return expected

        def read_cache(started=None):
            if started is not None:
                started.set()
            try:
                results.append(handler._cached_runtime_health())
            except BaseException as exc:  # surface thread failures in the test
                errors.append(exc)

        handler._runtime_health = Mock(side_effect=probe)
        first = threading.Thread(target=read_cache)
        second = threading.Thread(target=read_cache, args=(second_started,))
        first.start()
        try:
            self.assertTrue(probe_started.wait(timeout=2))
            second.start()
            self.assertTrue(second_started.wait(timeout=2))
        finally:
            release_probe.set()
            first.join(timeout=2)
            if second.ident is not None:
                second.join(timeout=2)

        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0], results[1])
        handler._runtime_health.assert_called_once_with()

    def test_session_health_uses_timestamp_paired_with_cached_result(self):
        handler = object.__new__(bridge.Handler)
        observed_at = "2026-07-19T12:34:56Z"
        handler._cached_runtime_health = Mock(
            return_value=((True, "ready", healthy_observation()), observed_at)
        )
        handler._json = Mock()
        bridge._RUNTIME_HEALTH_CACHE = (
            0.0,
            "wrong-timestamp",
            (False, "wrong-result", {"serial": bridge.ADB_SERIAL}),
        )

        handler._session_health("ses_" + "d" * 32)

        _, payload = handler._json.call_args.args
        self.assertTrue(payload["healthy"])
        self.assertEqual(payload["observed_at"], observed_at)

    def test_all_required_evidence_is_healthy(self):
        healthy, reason = bridge._assess_runtime_health(healthy_observation())
        self.assertTrue(healthy)
        self.assertEqual(reason, "ready")

    def test_console_avd_name_must_match_exactly(self):
        for wrong_name in (
            "Pixel_8_Android_17_Play_ARM64",
            " Pixel_9_Android_17_Play_ARM64",
            "Pixel_9_Android_17_Play_ARM64 ",
        ):
            with self.subTest(wrong_name=wrong_name):
                observed = healthy_observation()
                observed["console"]["avd_name"] = wrong_name

                healthy, reason = bridge._assess_runtime_health(observed)

                self.assertFalse(healthy)
                self.assertIn("emulator console AVD name", reason)

    def test_x86_64_guest_abi_is_unhealthy(self):
        observed = healthy_observation()
        observed["properties"]["abi"] = "x86_64"

        healthy, reason = bridge._assess_runtime_health(observed)

        self.assertFalse(healthy)
        self.assertIn("ro.product.cpu.abi is 'x86_64'; expected 'arm64-v8a'", reason)

    def test_4k_guest_page_size_is_unhealthy(self):
        observed = healthy_observation()
        observed["properties"]["page_size_bytes"] = "4096"

        healthy, reason = bridge._assess_runtime_health(observed)

        self.assertFalse(healthy)
        self.assertIn("PAGE_SIZE is 4096 bytes; expected 16384", reason)

    def test_missing_or_malformed_architecture_evidence_is_unhealthy(self):
        cases = {
            "missing ABI": ("abi", None, "ro.product.cpu.abi is ''; expected 'arm64-v8a'"),
            "missing page size": ("page_size_bytes", None, "PAGE_SIZE is not an integer: ''"),
            "malformed page size": (
                "page_size_bytes",
                "unknown",
                "PAGE_SIZE is not an integer: 'unknown'",
            ),
        }
        for name, (field, value, expected_reason) in cases.items():
            with self.subTest(name=name):
                observed = healthy_observation()
                if value is None:
                    observed["properties"].pop(field)
                else:
                    observed["properties"][field] = value

                healthy, reason = bridge._assess_runtime_health(observed)

                self.assertFalse(healthy)
                self.assertIn(expected_reason, reason)

    def test_each_required_evidence_failure_is_unhealthy(self):
        cases = {
            "adb state": (lambda observed: observed.update(state="offline"), "ADB state"),
            "boot complete": (
                lambda observed: observed["properties"].update(boot_completed="0"),
                "sys.boot_completed",
            ),
            "minimum API": (
                lambda observed: observed["properties"].update(api_level="36"),
                "below required 37",
            ),
            "Play Store": (
                lambda observed: observed["packages"].update({"com.android.vending": False}),
                "com.android.vending is not installed",
            ),
            "Google Play services": (
                lambda observed: observed["packages"].update({"com.google.android.gms": False}),
                "com.google.android.gms is not installed",
            ),
        }
        for name, (mutate, expected_reason) in cases.items():
            with self.subTest(name=name):
                observed = healthy_observation()
                mutate(observed)
                healthy, reason = bridge._assess_runtime_health(observed)
                self.assertFalse(healthy)
                self.assertIn(expected_reason, reason)

    def test_malformed_api_and_package_probe_error_are_unhealthy(self):
        observed = healthy_observation()
        observed["properties"]["api_level"] = "unknown"
        observed["packages"]["com.google.android.gms"] = None
        observed["package_errors"] = {"com.google.android.gms": "package manager unavailable"}

        healthy, reason = bridge._assess_runtime_health(observed)

        self.assertFalse(healthy)
        self.assertIn("API level is not an integer", reason)
        self.assertIn("could not verify required package com.google.android.gms", reason)

    def test_healthy_session_envelope_remains_controller_compatible(self):
        handler = object.__new__(bridge.Handler)
        handler._runtime_health = Mock(return_value=(True, "ready", healthy_observation()))
        handler._json = Mock()
        session_id = "ses_" + "a" * 32

        handler._session_health(session_id)

        status, payload = handler._json.call_args.args
        self.assertEqual(status, 200)
        self.assertEqual(set(payload), {"session_id", "healthy", "observed_at"})
        self.assertEqual(payload["session_id"], session_id)
        self.assertTrue(payload["healthy"])

    def test_screenshot_uses_tcg_safe_read_timeout(self):
        handler = object.__new__(bridge.Handler)
        handler.path = "/v1/screenshot.png"
        handler._send = Mock()
        adb = Mock()
        adb.run.return_value = b"\x89PNG\r\n\x1a\nimage"

        with patch.object(bridge, "ADB_CLIENT", adb):
            handler.do_GET()

        adb.run.assert_called_once_with(
            ["exec-out", "screencap", "-p"],
            timeout=bridge.ADB_READ_TIMEOUT_SECONDS,
        )
        handler._send.assert_called_once_with(
            200, b"\x89PNG\r\n\x1a\nimage", "image/png"
        )

    def test_unhealthy_session_exposes_reason_and_observations(self):
        handler = object.__new__(bridge.Handler)
        observed = healthy_observation()
        observed["packages"]["com.android.vending"] = False
        handler._runtime_health = Mock(return_value=(False, "Play Store missing", observed))
        handler._json = Mock()

        handler._session_health("ses_" + "b" * 32)

        status, payload = handler._json.call_args.args
        self.assertEqual(status, 503)
        self.assertFalse(payload["healthy"])
        self.assertEqual(payload["reason"], "Play Store missing")
        self.assertEqual(payload["observed"], observed)

    def test_adb_failure_cannot_produce_healthy_session_evidence(self):
        handler = object.__new__(bridge.Handler)
        handler._runtime_health = Mock(side_effect=bridge.AdbError("transport offline"))
        handler._json = Mock()

        handler._session_health("ses_" + "c" * 32)

        status, payload = handler._json.call_args.args
        self.assertEqual(status, 503)
        self.assertFalse(payload["healthy"])
        self.assertIn("transport offline", payload["reason"])


class MutationTests(unittest.TestCase):
    def setUp(self):
        self.handler = object.__new__(bridge.Handler)
        self.adb = FakeAdb()
        self.console = FakeConsole(result="ok")
        self.adb_patch = patch.object(bridge, "ADB_CLIENT", self.adb)
        self.console_patch = patch.object(bridge, "CONSOLE_CLIENT", self.console)
        self.adb_patch.start()
        self.console_patch.start()

    def tearDown(self):
        self.console_patch.stop()
        self.adb_patch.stop()

    def test_location_preserves_longitude_latitude_order(self):
        self.handler._mutation("/v1/location", {"longitude": 121.4, "latitude": 31.2})
        self.assertEqual(
            self.console.calls[-1][0],
            ("geo", "fix", "121.4", "31.2", "0.0"),
        )
        self.assertEqual(self.adb.calls, [])

    def test_network_is_allowlisted(self):
        self.handler._mutation("/v1/network", {"speed": "lte", "delay": "none"})
        self.assertEqual(
            [parts for parts, _ in self.console.calls],
            [("network", "speed", "lte"), ("network", "delay", "none")],
        )
        self.assertEqual(self.adb.calls, [])
        with self.assertRaises(ValueError):
            self.handler._mutation("/v1/network", {"speed": "arbitrary", "delay": "none"})

    def test_unknown_mutation_is_rejected(self):
        with self.assertRaises(ValueError):
            self.handler._mutation("/v1/shell", {"command": "id"})

    def test_sms_routes_safe_text_to_console_and_rejects_raw_controls(self):
        text = "你好；Android 17 ✅; still one line"
        self.handler._mutation(
            "/v1/sms", {"from": "+15551234567", "text": text}
        )
        self.assertEqual(
            self.console.calls[-1][0],
            ("sms", "send", "+15551234567", text),
        )
        invalid = [
            {"from": "1;id", "text": "hello"},
            {"from": "+15551234567", "text": "hello\rquit"},
            {"from": "+15551234567", "text": "hello\nquit"},
            {"from": "+15551234567", "text": "hello\x00quit"},
            {"from": "+15551234567", "text": "hello\x7fquit"},
            {"from": "+15551234567", "text": "hello\tquit"},
            {"from": "+15551234567", "text": "hello\u0085quit"},
        ]
        for body in invalid:
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.handler._mutation("/v1/sms", body)

    def test_gsm_hold_retains_remote_number_and_uses_console(self):
        self.handler._mutation(
            "/v1/call", {"action": "hold", "number": "+15551234567"}
        )

        self.assertEqual(
            self.console.calls[-1][0],
            ("gsm", "hold", "+15551234567"),
        )
        self.assertEqual(self.adb.calls, [])

    def test_battery_uses_console_while_input_and_rotation_remain_adb_shell(self):
        self.handler._mutation("/v1/battery", {"level": 85})
        self.handler._mutation("/v1/input/tap", {"x": 10, "y": 20})
        self.handler._mutation("/v1/rotation", {"rotation": 2})

        self.assertEqual(self.console.calls[0][0], ("power", "capacity", "85"))
        self.assertEqual(
            self.adb.calls,
            [
                ("shell", ("input", "tap", "10", "20")),
                (
                    "shell",
                    ("settings", "put", "system", "accelerometer_rotation", "0"),
                ),
                (
                    "shell",
                    ("settings", "put", "system", "user_rotation", "2"),
                ),
            ],
        )

    def test_console_mutation_failure_is_reported_as_bad_gateway(self):
        self.handler.path = "/v1/battery"
        self.handler._require_auth = Mock(return_value=True)
        self.handler._read_json = Mock(return_value={"level": 50})
        self.handler._json = Mock()
        self.handler._error = Mock()
        self.console.error = bridge.ConsoleError("emulator console transport failed")

        self.handler.do_POST()

        self.handler._error.assert_called_once_with(
            502, "CONSOLE_FAILED", "emulator console transport failed"
        )
        self.handler._json.assert_not_called()

    def test_input_text_rejects_shell_metacharacters(self):
        with self.assertRaises(ValueError):
            self.handler._mutation("/v1/input/text", {"text": "hello; id"})


if __name__ == "__main__":
    unittest.main()

import importlib.util
import io
import json
import os
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


os.environ.setdefault("BRIDGE_TOKEN", "test-token")
MODULE_PATH = Path(__file__).parents[1] / "bridge.py"
SPEC = importlib.util.spec_from_file_location("bridge", MODULE_PATH)
bridge = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(bridge)


class ValidationTests(unittest.TestCase):
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
        self.calls.append(("emu", args))
        return "ok"

    def text(self, args, timeout=30):
        self.calls.append(("text", tuple(args)))
        return "ok"


class RuntimeAdb:
    def __init__(self, installed_packages=None, page_size="16384"):
        if installed_packages is None:
            installed_packages = bridge.REQUIRED_GOOGLE_PACKAGES
        self.installed_packages = set(installed_packages)
        self.page_size = page_size
        self.shell_calls = []
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
        if args == ["get-state"]:
            return "device"
        raise AssertionError(f"unexpected text call: {args}")

    def shell(self, *args, **kwargs):
        self.shell_calls.append(args)
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
    }


class RuntimeHealthTests(unittest.TestCase):
    def setUp(self):
        bridge._RUNTIME_HEALTH_CACHE = None

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
        self.assertIn(("getconf", "PAGE_SIZE"), adb.shell_calls)
        self.assertEqual(
            observed["packages"],
            {
                "com.android.vending": True,
                "com.google.android.gms": True,
            },
        )

    def test_runtime_probe_rejects_a_missing_google_package(self):
        handler = object.__new__(bridge.Handler)
        adb = RuntimeAdb(installed_packages={"com.google.android.gms"})
        with patch.object(bridge, "ADB_CLIENT", adb):
            healthy, reason, observed = handler._runtime_health()

        self.assertFalse(healthy)
        self.assertFalse(observed["packages"]["com.android.vending"])
        self.assertIn("com.android.vending is not installed", reason)

    def test_deep_health_cache_reuses_one_probe_within_ttl(self):
        handler = object.__new__(bridge.Handler)
        expected = (True, "ready", healthy_observation())
        handler._runtime_health = Mock(return_value=expected)

        first = handler._cached_runtime_health()
        second = handler._cached_runtime_health()

        self.assertEqual(first, expected)
        self.assertEqual(second, expected)
        handler._runtime_health.assert_called_once_with()

    def test_deep_health_cache_throttles_adb_failures(self):
        handler = object.__new__(bridge.Handler)
        handler._runtime_health = Mock(side_effect=bridge.AdbError("transport offline"))

        first = handler._cached_runtime_health()
        second = handler._cached_runtime_health()

        self.assertFalse(first[0])
        self.assertEqual(first, second)
        self.assertIn("transport offline", first[1])
        handler._runtime_health.assert_called_once_with()

    def test_all_required_evidence_is_healthy(self):
        healthy, reason = bridge._assess_runtime_health(healthy_observation())
        self.assertTrue(healthy)
        self.assertEqual(reason, "ready")

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
        self.patch = patch.object(bridge, "ADB_CLIENT", self.adb)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def test_location_preserves_longitude_latitude_order(self):
        self.handler._mutation("/v1/location", {"longitude": 121.4, "latitude": 31.2})
        self.assertEqual(self.adb.calls[-1], ("emu", ("geo", "fix", "121.4", "31.2", "0.0")))

    def test_network_is_allowlisted(self):
        self.handler._mutation("/v1/network", {"speed": "lte", "delay": "none"})
        self.assertEqual(len(self.adb.calls), 2)
        with self.assertRaises(ValueError):
            self.handler._mutation("/v1/network", {"speed": "arbitrary", "delay": "none"})

    def test_unknown_mutation_is_rejected(self):
        with self.assertRaises(ValueError):
            self.handler._mutation("/v1/shell", {"command": "id"})

    def test_sms_validates_sender(self):
        with self.assertRaises(ValueError):
            self.handler._mutation("/v1/sms", {"from": "1;id", "text": "hello"})

    def test_input_text_rejects_shell_metacharacters(self):
        with self.assertRaises(ValueError):
            self.handler._mutation("/v1/input/text", {"text": "hello; id"})


if __name__ == "__main__":
    unittest.main()

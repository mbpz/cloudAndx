import importlib.util
import io
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch


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

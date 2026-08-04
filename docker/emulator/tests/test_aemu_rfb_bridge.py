import importlib.util
import io
import pathlib
import sys
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "bin" / "aemu-rfb-bridge.py"
SPEC = importlib.util.spec_from_file_location("aemu_rfb_bridge", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class BridgeTests(unittest.TestCase):
    def test_decodes_concatenated_grpcurl_json(self):
        stream = io.BytesIO(b'{"seq":1}\n{\n"seq": 3\n}\n')
        self.assertEqual([1, 3], [item["seq"] for item in MODULE.decode_json_stream(stream)])

    def test_preserves_aemu_top_down_rows_when_converting_to_rfb_bgrx(self):
        # Top source row is blue; bottom source row is red.
        rgb = bytes([0, 0, 255, 255, 0, 0])
        self.assertEqual(
            bytes([255, 0, 0, 0, 0, 0, 255, 0]),
            MODULE.rgb_to_bgrx(rgb, 1, 2),
        )

    def test_rejects_wrong_frame_size(self):
        with self.assertRaisesRegex(ValueError, "expected 12"):
            MODULE.rgb_to_bgrx(b"short", 2, 2)

    def test_grpcurl_command_is_plaintext_and_proto_locked(self):
        command = MODULE.Grpcurl("/grpcurl", "/proto", "127.0.0.1:8556").command(
            "{}", "streamScreenshot"
        )
        self.assertEqual("/grpcurl", command[0])
        self.assertIn("-plaintext", command)
        self.assertIn("emulator_controller.proto", command)
        self.assertEqual(
            "android.emulation.control.EmulatorController/streamScreenshot", command[-1]
        )


if __name__ == "__main__":
    unittest.main()

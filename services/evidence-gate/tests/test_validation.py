from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from evidence_gate.validation import validate_instance, validate_schema_file


class ValidationTests(unittest.TestCase):
    def test_draft_2020_12_schema_and_instance_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schema = root / "schema.json"
            valid = root / "valid.json"
            invalid = root / "invalid.json"
            schema.write_text(
                json.dumps(
                    {
                        "$schema": "https://json-schema.org/draft/2020-12/schema",
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["uri"],
                        "properties": {"uri": {"type": "string", "format": "uri"}},
                    }
                ),
                encoding="utf-8",
            )
            valid.write_text('{"uri":"urn:test:valid"}', encoding="utf-8")
            invalid.write_text('{"uri":"not a uri","extra":true}', encoding="utf-8")

            self.assertEqual("PASS", validate_schema_file(schema)["status"])
            self.assertEqual("PASS", validate_instance(valid, schema, "test")["status"])
            report = validate_instance(invalid, schema, "test")
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(2, len(report["errors"]))

    def test_missing_schema_fails_closed(self) -> None:
        report = validate_schema_file(Path("/does/not/exist.json"))
        self.assertEqual("FAIL", report["status"])


if __name__ == "__main__":
    unittest.main()

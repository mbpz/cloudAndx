from __future__ import annotations

from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError

from .io_utils import read_json, sha256_bytes, utc_now


FORMAT_CHECKER = FormatChecker()


@FORMAT_CHECKER.checks("uri")
def _absolute_uri(value: object) -> bool:
    if not isinstance(value, str) or not value or any(character.isspace() for character in value):
        return False
    parsed = urlparse(value)
    if not parsed.scheme:
        return False
    if parsed.scheme in {"http", "https"} and not parsed.netloc:
        return False
    return True


def _json_path(parts: list[object]) -> str:
    value = "$"
    for part in parts:
        if isinstance(part, int):
            value += f"[{part}]"
        else:
            value += f".{part}"
    return value


def validate_schema_file(schema_path: Path) -> dict[str, Any]:
    try:
        schema, raw_schema = read_json(schema_path)
        Draft202012Validator.check_schema(schema)
        return {
            "status": "PASS",
            "schema_path": str(schema_path),
            "schema_id": schema.get("$id"),
            "schema_digest": sha256_bytes(raw_schema),
        }
    except (OSError, ValueError, SchemaError) as error:
        return {
            "status": "FAIL",
            "schema_path": str(schema_path),
            "error": str(error),
        }


def validate_instance(instance_path: Path, schema_path: Path, kind: str) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schema_version": "1.0.0",
        "kind": kind,
        "validated_at": utc_now(),
        "instance_path": str(instance_path),
        "schema_path": str(schema_path),
        "fail_closed": True,
    }
    try:
        schema, raw_schema = read_json(schema_path)
        instance, raw_instance = read_json(instance_path)
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FORMAT_CHECKER)
        errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.absolute_path))
        report.update(
            {
                "schema_id": schema.get("$id"),
                "schema_digest": sha256_bytes(raw_schema),
                "instance_digest": sha256_bytes(raw_instance),
                "errors": [
                    {
                        "instance_path": _json_path(list(error.absolute_path)),
                        "schema_path": _json_path(list(error.absolute_schema_path)),
                        "validator": error.validator,
                        "message": error.message,
                    }
                    for error in errors
                ],
            }
        )
        report["status"] = "PASS" if not errors else "FAIL"
    except (OSError, ValueError, SchemaError) as error:
        report.update({"status": "FAIL", "errors": [{"message": str(error)}]})
    return report

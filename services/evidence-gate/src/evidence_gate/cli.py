from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .io_utils import write_json_atomic
from .preflight import CAPABILITY_SCHEMA, IMAGE_SCHEMA, PreflightSettings, run_preflight
from .validation import validate_instance


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="evidence-gate")
    subcommands = parser.add_subparsers(dest="command", required=True)

    preflight = subcommands.add_parser("preflight", help="run architecture, KVM, contract, and Google metadata checks")
    preflight.add_argument("--output", type=Path, help="override PREFLIGHT_OUTPUT")

    for name, schema_name, kind in (
        ("validate-image", IMAGE_SCHEMA, "image_manifest"),
        ("validate-capabilities", CAPABILITY_SCHEMA, "capability_evidence"),
    ):
        command = subcommands.add_parser(name, help=f"validate a {kind} JSON instance")
        command.add_argument("instance", type=Path)
        command.add_argument("--contracts-dir", type=Path, default=Path("/contracts"))
        command.add_argument("--output", type=Path)
        command.set_defaults(schema_name=schema_name, kind=kind)
    return parser


def _print(report: dict[str, object]) -> None:
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    if arguments.command == "preflight":
        try:
            settings = PreflightSettings.from_env(arguments.output)
            report = run_preflight(settings)
        except (OSError, ValueError) as error:
            report = {
                "schema_version": "1.0.0",
                "state": "BLOCKED",
                "ready": False,
                "fail_closed": True,
                "blockers": [str(error)],
            }
            output = arguments.output or Path("/evidence/preflight.json")
            try:
                write_json_atomic(output, report)
            except OSError:
                pass
        _print(report)
        return 0 if report.get("ready") is True else 2

    report = validate_instance(
        arguments.instance,
        arguments.contracts_dir / arguments.schema_name,
        arguments.kind,
    )
    if arguments.output:
        write_json_atomic(arguments.output, report)
    _print(report)
    return 0 if report["status"] == "PASS" else 2

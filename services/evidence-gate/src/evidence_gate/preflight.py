from __future__ import annotations

import os
import platform
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .google_repo import (
    ANDROID_API_LEVEL,
    ANDROID_RELEASE_STATUS,
    ANDROID_VERSION,
    GOOGLE_PLAY_ABI,
    GOOGLE_PLAY_ARCHIVE_URL,
    GOOGLE_PLAY_CHANNEL,
    GOOGLE_PLAY_CHANNEL_ID,
    GOOGLE_PLAY_CHECKSUM,
    GOOGLE_PLAY_PACKAGE_PATH,
    GOOGLE_PLAY_REVISION,
    GOOGLE_PLAY_TAG,
    RepositoryError,
    RepositoryExpectation,
    fetch_repository_xml,
    verify_google_play_package,
)
from .io_utils import utc_now, write_json_atomic
from .validation import validate_instance, validate_schema_file


IMAGE_SCHEMA = "android-image-manifest.schema.json"
CAPABILITY_SCHEMA = "android-capability-evidence.schema.json"
NATIVE_RUNTIME_IMPLEMENTATION = "native"
HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION = "hybrid-aemu-arm64"
RUNTIME_IMPLEMENTATIONS = (
    NATIVE_RUNTIME_IMPLEMENTATION,
    HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
)


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def _integer_env(name: str, default: int) -> int:
    value = os.environ.get(name)
    try:
        return int(value) if value is not None else default
    except ValueError as error:
        raise ValueError(f"{name} must be an integer") from error


def _runtime_implementation_env() -> str:
    implementation = os.environ.get(
        "ANDROID_RUNTIME_IMPLEMENTATION", NATIVE_RUNTIME_IMPLEMENTATION
    ).strip()
    if implementation not in RUNTIME_IMPLEMENTATIONS:
        allowed = ", ".join(RUNTIME_IMPLEMENTATIONS)
        raise ValueError(f"ANDROID_RUNTIME_IMPLEMENTATION must be one of: {allowed}")
    return implementation


@dataclass(frozen=True)
class PreflightSettings:
    contracts_dir: Path
    evidence_path: Path
    repository_urls: tuple[str, ...]
    android_version: int
    api_level: int
    google_play_tag: str
    google_play_package_path: str
    google_play_abi: str
    expected_channel: str
    expected_channel_id: str
    expected_revision: str | None
    expected_url: str | None
    expected_checksum: str | None
    fetch_timeout_seconds: float
    allow_software_emulation_only: bool
    runtime_implementation: str
    image_manifest_path: Path | None
    capability_evidence_path: Path | None
    kvm_path: Path

    @classmethod
    def from_env(cls, output_override: Path | None = None) -> "PreflightSettings":
        repository_urls = tuple(
            url.strip()
            for url in os.environ.get("GOOGLE_REPOSITORY_URLS", "").split(",")
            if url.strip()
        )
        timeout_text = os.environ.get("GOOGLE_REPOSITORY_TIMEOUT_SECONDS", "20")
        try:
            timeout = float(timeout_text)
        except ValueError as error:
            raise ValueError("GOOGLE_REPOSITORY_TIMEOUT_SECONDS must be numeric") from error
        if timeout <= 0 or timeout > 120:
            raise ValueError("GOOGLE_REPOSITORY_TIMEOUT_SECONDS must be in (0, 120]")
        image_path = os.environ.get("IMAGE_MANIFEST_PATH")
        capability_path = os.environ.get("CAPABILITY_EVIDENCE_PATH")
        return cls(
            contracts_dir=Path(os.environ.get("CONTRACTS_DIR", "/contracts")),
            evidence_path=output_override or Path(os.environ.get("PREFLIGHT_OUTPUT", "/evidence/preflight.json")),
            repository_urls=repository_urls,
            android_version=_integer_env("ANDROID_VERSION", ANDROID_VERSION),
            api_level=_integer_env("ANDROID_API_LEVEL", ANDROID_API_LEVEL),
            google_play_tag=os.environ.get("GOOGLE_PLAY_TAG", GOOGLE_PLAY_TAG),
            google_play_package_path=os.environ.get("GOOGLE_PLAY_PACKAGE_PATH", GOOGLE_PLAY_PACKAGE_PATH),
            google_play_abi=os.environ.get("GOOGLE_PLAY_ABI", GOOGLE_PLAY_ABI),
            expected_channel=os.environ.get(
                "GOOGLE_PLAY_EXPECTED_CHANNEL", GOOGLE_PLAY_CHANNEL
            ),
            expected_channel_id=os.environ.get(
                "GOOGLE_PLAY_EXPECTED_CHANNEL_ID", GOOGLE_PLAY_CHANNEL_ID
            ),
            expected_revision=os.environ.get("GOOGLE_PLAY_EXPECTED_REVISION", GOOGLE_PLAY_REVISION),
            expected_url=os.environ.get("GOOGLE_PLAY_EXPECTED_URL", GOOGLE_PLAY_ARCHIVE_URL),
            expected_checksum=os.environ.get("GOOGLE_PLAY_EXPECTED_CHECKSUM", GOOGLE_PLAY_CHECKSUM),
            fetch_timeout_seconds=timeout,
            allow_software_emulation_only=_truthy(os.environ.get("ALLOW_SOFTWARE_EMULATION_ONLY")),
            runtime_implementation=_runtime_implementation_env(),
            image_manifest_path=Path(image_path) if image_path else None,
            capability_evidence_path=Path(capability_path) if capability_path else None,
            kvm_path=Path(os.environ.get("KVM_PATH", "/dev/kvm")),
        )


def detect_architecture(machine: str | None = None) -> dict[str, Any]:
    raw = (machine or platform.machine()).lower()
    aliases = {
        "x86_64": ("x86_64", "x86_64"),
        "amd64": ("x86_64", "x86_64"),
        "aarch64": ("arm64", "arm64-v8a"),
        "arm64": ("arm64", "arm64-v8a"),
    }
    normalized, sdk_abi = aliases.get(raw, (raw, None))
    return {
        "raw": raw,
        "normalized": normalized,
        "supported": sdk_abi is not None,
        "google_play_abi": sdk_abi,
    }


def inspect_kvm(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {
        "path": str(path),
        "exists": path.exists(),
        "character_device": False,
        "readable": False,
        "writable": False,
        "openable": False,
        "usable": False,
    }
    try:
        metadata = path.stat()
        result["character_device"] = stat.S_ISCHR(metadata.st_mode)
        result["readable"] = os.access(path, os.R_OK)
        result["writable"] = os.access(path, os.W_OK)
        descriptor = os.open(path, os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        os.close(descriptor)
        result["openable"] = True
    except OSError as error:
        result["error"] = f"{error.__class__.__name__}: {error}"
    result["usable"] = bool(
        result["exists"]
        and result["character_device"]
        and result["readable"]
        and result["writable"]
        and result["openable"]
    )
    return result


def native_kvm_compatible(host_architecture: str, guest_abi: str) -> bool:
    return (host_architecture, guest_abi) == ("arm64", "arm64-v8a")


def evaluate_runtime_compatibility(
    implementation: str, host_architecture: str, guest_abi: str
) -> dict[str, Any]:
    implementation_supported = implementation in RUNTIME_IMPLEMENTATIONS
    native_compatible = native_kvm_compatible(host_architecture, guest_abi)
    hybrid_compatible = (
        implementation == HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION
        and host_architecture == "arm64"
        and guest_abi == "arm64-v8a"
    )
    if implementation == NATIVE_RUNTIME_IMPLEMENTATION:
        execution_mode = "native-virtualization"
        runtime_compatible = native_compatible and host_architecture != "x86_64"
    elif implementation == HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION:
        execution_mode = "hybrid-software-emulation"
        runtime_compatible = hybrid_compatible
    else:
        execution_mode = "unsupported"
        runtime_compatible = False
    return {
        "implementation": implementation,
        "implementation_supported": implementation_supported,
        "execution_mode": execution_mode,
        "host_architecture": host_architecture,
        "guest_abi": guest_abi,
        "native_virtualization_compatible": native_compatible,
        "hybrid_software_emulation_compatible": hybrid_compatible,
        "runtime_compatible": runtime_compatible,
        "kvm_readiness_eligible": bool(
            implementation == NATIVE_RUNTIME_IMPLEMENTATION
            and native_compatible
            and host_architecture != "x86_64"
        ),
    }


def run_preflight(
    settings: PreflightSettings,
    fetcher: Callable[[str, float], tuple[str, bytes]] = fetch_repository_xml,
    architecture: dict[str, Any] | None = None,
    kvm: dict[str, Any] | None = None,
) -> dict[str, Any]:
    architecture = architecture or detect_architecture()
    kvm = kvm or inspect_kvm(settings.kvm_path)
    checks: list[dict[str, Any]] = []
    blockers: list[str] = []

    runtime = evaluate_runtime_compatibility(
        settings.runtime_implementation,
        str(architecture["normalized"]),
        settings.google_play_abi,
    )

    architecture_status = "PASS" if architecture["supported"] else "FAIL"
    checks.append({"check_id": "architecture", "status": architecture_status, "details": architecture})
    if architecture_status == "FAIL":
        blockers.append(f"unsupported host architecture: {architecture['raw']}")

    runtime_status = "PASS" if runtime["runtime_compatible"] else "FAIL"
    checks.append(
        {
            "check_id": "runtime_implementation",
            "status": runtime_status,
            "details": runtime,
        }
    )
    if not runtime["implementation_supported"]:
        allowed = ", ".join(RUNTIME_IMPLEMENTATIONS)
        blockers.append(
            f"unsupported Android runtime implementation {settings.runtime_implementation!r}; "
            f"expected one of: {allowed}"
        )
    elif not runtime["runtime_compatible"]:
        if settings.runtime_implementation == NATIVE_RUNTIME_IMPLEMENTATION:
            if architecture["normalized"] == "x86_64":
                blockers.append(
                    "x86_64 host runtime is deferred until it is built and verified on "
                    "x86_64 hardware"
                )
            else:
                blockers.append(
                    f"host architecture {architecture['normalized']} cannot run the selected "
                    f"{settings.google_play_abi} Google Android Emulator natively"
                )
        else:
            blockers.append(
                f"runtime implementation {settings.runtime_implementation} requires an arm64 "
                "host and the selected arm64-v8a Google Play guest"
            )

    schema_reports = [
        validate_schema_file(settings.contracts_dir / IMAGE_SCHEMA),
        validate_schema_file(settings.contracts_dir / CAPABILITY_SCHEMA),
    ]
    schema_status = "PASS" if all(report["status"] == "PASS" for report in schema_reports) else "FAIL"
    checks.append({"check_id": "contract_schemas", "status": schema_status, "details": schema_reports})
    if schema_status == "FAIL":
        blockers.append("one or more mounted contract schemas are missing or invalid")

    for check_id, instance_path, schema_name, kind in (
        ("image_manifest_instance", settings.image_manifest_path, IMAGE_SCHEMA, "image_manifest"),
        (
            "capability_evidence_instance",
            settings.capability_evidence_path,
            CAPABILITY_SCHEMA,
            "capability_evidence",
        ),
    ):
        if instance_path is None:
            checks.append({"check_id": check_id, "status": "SKIP", "details": "path not configured"})
            continue
        instance_report = validate_instance(instance_path, settings.contracts_dir / schema_name, kind)
        checks.append({"check_id": check_id, "status": instance_report["status"], "details": instance_report})
        if instance_report["status"] != "PASS":
            blockers.append(f"{kind} instance failed schema validation")

    repository_report: dict[str, Any] | None = None
    if not settings.repository_urls:
        checks.append(
            {
                "check_id": "google_play_repository",
                "status": "SKIP",
                "details": "GOOGLE_REPOSITORY_URLS is not configured",
            }
        )
    elif architecture["supported"]:
        try:
            documents = [fetcher(url, settings.fetch_timeout_seconds) for url in settings.repository_urls]
            expectation = RepositoryExpectation(
                android_version=settings.android_version,
                api_level=settings.api_level,
                package_path=settings.google_play_package_path,
                tag=settings.google_play_tag,
                abi=settings.google_play_abi,
                channel=settings.expected_channel,
                channel_id=settings.expected_channel_id,
                revision=settings.expected_revision,
                archive_url=settings.expected_url,
                checksum=settings.expected_checksum,
            )
            repository_report = verify_google_play_package(documents, expectation)
            checks.append({"check_id": "google_play_repository", "status": "PASS", "details": repository_report})
        except (RepositoryError, OSError, ValueError) as error:
            blockers.append(str(error))
            checks.append(
                {
                    "check_id": "google_play_repository",
                    "status": "FAIL",
                    "details": {"error": str(error)},
                }
            )

    if not runtime["kvm_readiness_eligible"]:
        kvm_status = "SKIP"
    elif kvm["usable"]:
        kvm_status = "PASS"
    else:
        kvm_status = "WARN"
    checks.append(
        {
            "check_id": "kvm",
            "status": kvm_status,
            "details": {
                **kvm,
                "native_runtime_only": True,
                "readiness_eligible": runtime["kvm_readiness_eligible"],
            },
        }
    )

    if settings.runtime_implementation != NATIVE_RUNTIME_IMPLEMENTATION:
        native_compatibility_status = "SKIP"
    elif runtime["native_virtualization_compatible"]:
        native_compatibility_status = "PASS"
    else:
        native_compatibility_status = "FAIL"
    checks.append(
        {
            "check_id": "native_kvm_compatibility",
            "status": native_compatibility_status,
            "details": {
                "host_architecture": architecture["normalized"],
                "guest_abi": settings.google_play_abi,
                "runtime_implementation": settings.runtime_implementation,
                "native_virtualization_compatible": runtime[
                    "native_virtualization_compatible"
                ],
                "kvm_readiness_eligible": runtime["kvm_readiness_eligible"],
            },
        }
    )

    if blockers:
        state = "BLOCKED"
    elif not settings.repository_urls:
        state = "DESIGN_READY"
    elif kvm["usable"] and runtime["kvm_readiness_eligible"]:
        state = "KVM_READY"
    else:
        state = "SOFTWARE_EMULATION_ONLY"
    ready = state == "KVM_READY" or (
        state == "SOFTWARE_EMULATION_ONLY" and settings.allow_software_emulation_only
    )
    report = {
        "schema_version": "1.0.0",
        "generated_at": utc_now(),
        "state": state,
        "ready": ready,
        "fail_closed": True,
        "policy": {
            "allow_software_emulation_only": settings.allow_software_emulation_only,
            "runtime": runtime,
            "android_version": settings.android_version,
            "android_release_status": ANDROID_RELEASE_STATUS,
            "api_level": settings.api_level,
            "google_play_tag": settings.google_play_tag,
            "google_play_package_path": settings.google_play_package_path,
            "google_play_abi": settings.google_play_abi,
            "expected_channel": settings.expected_channel,
            "expected_channel_id": settings.expected_channel_id,
        },
        "architecture": architecture,
        "runtime": runtime,
        "kvm": kvm,
        "google_play_repository": repository_report,
        "checks": checks,
        "blockers": blockers,
    }
    write_json_atomic(settings.evidence_path, report)
    return report

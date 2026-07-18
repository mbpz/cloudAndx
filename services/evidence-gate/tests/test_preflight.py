from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from evidence_gate.preflight import (
    HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
    NATIVE_RUNTIME_IMPLEMENTATION,
    PreflightSettings,
    detect_architecture,
    run_preflight,
)


FIXTURE = Path(__file__).parent / "fixtures" / "repository-stable.xml"
SOURCE_URL = "https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-4.xml"


def x86_architecture(supported: bool = True) -> dict[str, object]:
    return {
        "raw": "x86_64" if supported else "mips64",
        "normalized": "x86_64" if supported else "mips64",
        "supported": supported,
        "google_play_abi": "x86_64" if supported else None,
    }


def arm_architecture(raw: str = "aarch64") -> dict[str, object]:
    return {
        "raw": raw,
        "normalized": "arm64",
        "supported": True,
        "google_play_abi": "arm64-v8a",
    }


def kvm(usable: bool) -> dict[str, object]:
    return {
        "path": "/dev/kvm",
        "exists": usable,
        "character_device": usable,
        "readable": usable,
        "writable": usable,
        "openable": usable,
        "usable": usable,
    }


class PreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.contracts = self.root / "contracts"
        self.contracts.mkdir()
        schema = {"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object"}
        for name in ("android-image-manifest.schema.json", "android-capability-evidence.schema.json"):
            (self.contracts / name).write_text(json.dumps(schema), encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def settings(
        self,
        urls: tuple[str, ...],
        allow_software: bool = False,
        runtime_implementation: str = NATIVE_RUNTIME_IMPLEMENTATION,
        guest_abi: str = "arm64-v8a",
    ) -> PreflightSettings:
        if guest_abi == "x86_64":
            package_path = "system-images;android-37.0;google_apis_playstore_ps16k;x86_64"
            expected_url = "https://dl.google.com/android/repository/sys-img/google_apis_playstore/x86_64-playstore-ps16k-37.0_r06.zip"
            expected_checksum = "sha1:8eaeeceb77452c018c3f6b589913cdc45222a87f"
        else:
            package_path = "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a"
            expected_url = "https://dl.google.com/android/repository/sys-img/google_apis_playstore/arm64-v8a-playstore-ps16k-37.0_r06.zip"
            expected_checksum = "sha1:ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4"
        return PreflightSettings(
            contracts_dir=self.contracts,
            evidence_path=self.root / "evidence" / "preflight.json",
            repository_urls=urls,
            android_version=17,
            api_level=37,
            google_play_tag="google_apis_playstore",
            google_play_package_path=package_path,
            google_play_abi=guest_abi,
            expected_channel="stable",
            expected_channel_id="channel-0",
            expected_revision="6",
            expected_url=expected_url,
            expected_checksum=expected_checksum,
            fetch_timeout_seconds=1,
            allow_software_emulation_only=allow_software,
            runtime_implementation=runtime_implementation,
            image_manifest_path=None,
            capability_evidence_path=None,
            kvm_path=Path("/dev/kvm"),
        )

    def test_runtime_implementation_defaults_to_native(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            settings = PreflightSettings.from_env(self.root / "preflight.json")

        self.assertEqual(NATIVE_RUNTIME_IMPLEMENTATION, settings.runtime_implementation)
        self.assertEqual("arm64-v8a", settings.google_play_abi)
        self.assertEqual(
            "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a",
            settings.google_play_package_path,
        )
        self.assertEqual("channel-0", settings.expected_channel_id)

    def test_arm64_machine_aliases_normalize_to_hybrid_host_architecture(self) -> None:
        for machine in ("arm64", "aarch64"):
            with self.subTest(machine=machine):
                detected = detect_architecture(machine)
                self.assertTrue(detected["supported"])
                self.assertEqual("arm64", detected["normalized"])

    def test_hybrid_runtime_implementation_is_allowlisted(self) -> None:
        with patch.dict(
            os.environ,
            {"ANDROID_RUNTIME_IMPLEMENTATION": HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION},
            clear=True,
        ):
            settings = PreflightSettings.from_env(self.root / "preflight.json")

        self.assertEqual(
            HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
            settings.runtime_implementation,
        )

    def test_unknown_runtime_implementation_is_rejected(self) -> None:
        with patch.dict(
            os.environ,
            {"ANDROID_RUNTIME_IMPLEMENTATION": "qemu-user"},
            clear=True,
        ):
            with self.assertRaisesRegex(
                ValueError,
                "ANDROID_RUNTIME_IMPLEMENTATION must be one of: native, hybrid-aemu-arm64",
            ):
                PreflightSettings.from_env(self.root / "preflight.json")

    @staticmethod
    def fetcher(url: str, timeout: float) -> tuple[str, bytes]:
        del timeout
        return url, FIXTURE.read_bytes()

    def test_kvm_ready_is_successful(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,)),
            fetcher=self.fetcher,
            architecture=arm_architecture(),
            kvm=kvm(True),
        )
        self.assertEqual("KVM_READY", report["state"])
        self.assertTrue(report["ready"])
        self.assertEqual("stable", report["policy"]["android_release_status"])
        written = json.loads((self.root / "evidence" / "preflight.json").read_text())
        self.assertEqual("KVM_READY", written["state"])

    def test_native_x86_64_runtime_is_deferred_and_blocked(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,), guest_abi="x86_64"),
            fetcher=self.fetcher,
            architecture=x86_architecture(),
            kvm=kvm(True),
        )

        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])
        self.assertEqual("x86_64", report["runtime"]["guest_abi"])
        self.assertFalse(report["runtime"]["native_virtualization_compatible"])
        self.assertFalse(report["runtime"]["runtime_compatible"])
        self.assertIn(
            "x86_64 host runtime is deferred until it is built and verified on x86_64 hardware",
            report["blockers"],
        )

    def test_missing_kvm_is_software_only_and_fails_by_default(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,)),
            fetcher=self.fetcher,
            architecture=arm_architecture(),
            kvm=kvm(False),
        )
        self.assertEqual("SOFTWARE_EMULATION_ONLY", report["state"])
        self.assertFalse(report["ready"])

    def test_software_only_can_be_explicitly_allowed(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,), allow_software=True),
            fetcher=self.fetcher,
            architecture=arm_architecture(),
            kvm=kvm(False),
        )
        self.assertEqual("SOFTWARE_EMULATION_ONLY", report["state"])
        self.assertTrue(report["ready"])

    def test_no_repository_urls_is_design_ready_but_not_runtime_ready(self) -> None:
        report = run_preflight(
            self.settings(()), architecture=arm_architecture(), kvm=kvm(True)
        )
        self.assertEqual("DESIGN_READY", report["state"])
        self.assertFalse(report["ready"])

    def test_invalid_architecture_is_blocked(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,)),
            fetcher=self.fetcher,
            architecture=x86_architecture(False),
            kvm=kvm(True),
        )
        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])

    def test_arm_host_with_x86_64_guest_is_blocked_even_when_software_is_allowed(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,), allow_software=True, guest_abi="x86_64"),
            fetcher=self.fetcher,
            architecture=arm_architecture(),
            kvm=kvm(True),
        )
        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])
        self.assertIn(
            "host architecture arm64 cannot run the selected x86_64 Google Android Emulator natively",
            report["blockers"],
        )
        compatibility = next(
            check for check in report["checks"] if check["check_id"] == "native_kvm_compatibility"
        )
        self.assertEqual("FAIL", compatibility["status"])
        self.assertFalse(compatibility["details"]["native_virtualization_compatible"])

    def test_declared_hybrid_arm_runtime_is_software_only_and_fails_by_default(self) -> None:
        report = run_preflight(
            self.settings(
                (SOURCE_URL,),
                runtime_implementation=HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
            ),
            fetcher=self.fetcher,
            architecture=arm_architecture(),
            kvm=kvm(True),
        )

        self.assertEqual("SOFTWARE_EMULATION_ONLY", report["state"])
        self.assertFalse(report["ready"])
        self.assertEqual(
            HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
            report["policy"]["runtime"]["implementation"],
        )
        self.assertEqual("arm64", report["policy"]["runtime"]["host_architecture"])
        self.assertEqual("arm64-v8a", report["policy"]["runtime"]["guest_abi"])
        self.assertFalse(report["policy"]["runtime"]["kvm_readiness_eligible"])

    def test_declared_hybrid_arm_runtime_requires_explicit_software_policy(self) -> None:
        report = run_preflight(
            self.settings(
                (SOURCE_URL,),
                allow_software=True,
                runtime_implementation=HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
            ),
            fetcher=self.fetcher,
            architecture=arm_architecture("arm64"),
            kvm=kvm(True),
        )

        self.assertEqual("SOFTWARE_EMULATION_ONLY", report["state"])
        self.assertTrue(report["ready"])
        runtime_check = next(
            check for check in report["checks"] if check["check_id"] == "runtime_implementation"
        )
        self.assertEqual("PASS", runtime_check["status"])
        self.assertTrue(runtime_check["details"]["hybrid_software_emulation_compatible"])
        kvm_check = next(
            check for check in report["checks"] if check["check_id"] == "kvm"
        )
        native_compatibility_check = next(
            check
            for check in report["checks"]
            if check["check_id"] == "native_kvm_compatibility"
        )
        self.assertEqual("SKIP", kvm_check["status"])
        self.assertEqual("SKIP", native_compatibility_check["status"])

    def test_hybrid_runtime_is_blocked_on_x86_64_host(self) -> None:
        report = run_preflight(
            self.settings(
                (SOURCE_URL,),
                allow_software=True,
                runtime_implementation=HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
            ),
            fetcher=self.fetcher,
            architecture=x86_architecture(),
            kvm=kvm(False),
        )

        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])
        self.assertIn(
            "runtime implementation hybrid-aemu-arm64 requires an arm64 host and the selected "
            "arm64-v8a Google Play guest",
            report["blockers"],
        )

    def test_hybrid_runtime_blocks_x86_64_guest_fallback(self) -> None:
        report = run_preflight(
            self.settings(
                (SOURCE_URL,),
                allow_software=True,
                runtime_implementation=HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
                guest_abi="x86_64",
            ),
            fetcher=self.fetcher,
            architecture=arm_architecture(),
            kvm=kvm(False),
        )

        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])
        self.assertEqual("x86_64", report["runtime"]["guest_abi"])
        self.assertFalse(report["runtime"]["hybrid_software_emulation_compatible"])

    def test_hybrid_runtime_is_blocked_for_unsupported_guest(self) -> None:
        report = run_preflight(
            self.settings(
                (),
                allow_software=True,
                runtime_implementation=HYBRID_AEMU_ARM64_RUNTIME_IMPLEMENTATION,
                guest_abi="riscv64",
            ),
            architecture=arm_architecture(),
            kvm=kvm(False),
        )

        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])

    def test_unallowlisted_runtime_is_blocked_when_settings_are_constructed_directly(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,), allow_software=True, runtime_implementation="qemu-user"),
            fetcher=self.fetcher,
            architecture=arm_architecture(),
            kvm=kvm(False),
        )

        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])
        self.assertIn(
            "unsupported Android runtime implementation 'qemu-user'; expected one of: "
            "native, hybrid-aemu-arm64",
            report["blockers"],
        )


if __name__ == "__main__":
    unittest.main()

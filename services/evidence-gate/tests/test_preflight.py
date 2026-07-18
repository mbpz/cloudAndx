from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from evidence_gate.preflight import PreflightSettings, run_preflight


FIXTURE = Path(__file__).parent / "fixtures" / "repository-stable.xml"
SOURCE_URL = "https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-4.xml"


def architecture(supported: bool = True) -> dict[str, object]:
    return {
        "raw": "x86_64" if supported else "mips64",
        "normalized": "x86_64" if supported else "mips64",
        "supported": supported,
        "google_play_abi": "x86_64" if supported else None,
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

    def settings(self, urls: tuple[str, ...], allow_software: bool = False) -> PreflightSettings:
        return PreflightSettings(
            contracts_dir=self.contracts,
            evidence_path=self.root / "evidence" / "preflight.json",
            repository_urls=urls,
            android_version=17,
            api_level=37,
            google_play_tag="google_apis_playstore",
            google_play_package_path="system-images;android-37.0;google_apis_playstore_ps16k;x86_64",
            google_play_abi="x86_64",
            expected_channel="stable",
            expected_revision="6",
            expected_url="https://dl.google.com/android/repository/sys-img/google_apis_playstore/x86_64-playstore-ps16k-37.0_r06.zip",
            expected_checksum="sha1:8eaeeceb77452c018c3f6b589913cdc45222a87f",
            fetch_timeout_seconds=1,
            allow_software_emulation_only=allow_software,
            image_manifest_path=None,
            capability_evidence_path=None,
            kvm_path=Path("/dev/kvm"),
        )

    @staticmethod
    def fetcher(url: str, timeout: float) -> tuple[str, bytes]:
        del timeout
        return url, FIXTURE.read_bytes()

    def test_kvm_ready_is_successful(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,)),
            fetcher=self.fetcher,
            architecture=architecture(),
            kvm=kvm(True),
        )
        self.assertEqual("KVM_READY", report["state"])
        self.assertTrue(report["ready"])
        written = json.loads((self.root / "evidence" / "preflight.json").read_text())
        self.assertEqual("KVM_READY", written["state"])

    def test_missing_kvm_is_software_only_and_fails_by_default(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,)),
            fetcher=self.fetcher,
            architecture=architecture(),
            kvm=kvm(False),
        )
        self.assertEqual("SOFTWARE_EMULATION_ONLY", report["state"])
        self.assertFalse(report["ready"])

    def test_software_only_can_be_explicitly_allowed(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,), allow_software=True),
            fetcher=self.fetcher,
            architecture=architecture(),
            kvm=kvm(False),
        )
        self.assertEqual("SOFTWARE_EMULATION_ONLY", report["state"])
        self.assertTrue(report["ready"])

    def test_no_repository_urls_is_design_ready_but_not_runtime_ready(self) -> None:
        report = run_preflight(
            self.settings(()), architecture=architecture(), kvm=kvm(True)
        )
        self.assertEqual("DESIGN_READY", report["state"])
        self.assertFalse(report["ready"])

    def test_invalid_architecture_is_blocked(self) -> None:
        report = run_preflight(
            self.settings((SOURCE_URL,)),
            fetcher=self.fetcher,
            architecture=architecture(False),
            kvm=kvm(True),
        )
        self.assertEqual("BLOCKED", report["state"])
        self.assertFalse(report["ready"])

    def test_arm_host_with_x86_64_guest_is_blocked_even_when_software_is_allowed(self) -> None:
        arm_architecture = {
            "raw": "arm64",
            "normalized": "arm64",
            "supported": True,
            "google_play_abi": "arm64-v8a",
        }
        report = run_preflight(
            self.settings((SOURCE_URL,), allow_software=True),
            fetcher=self.fetcher,
            architecture=arm_architecture,
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


if __name__ == "__main__":
    unittest.main()

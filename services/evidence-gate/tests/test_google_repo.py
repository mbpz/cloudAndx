from __future__ import annotations

import unittest
from pathlib import Path

from evidence_gate.google_repo import (
    RepositoryError,
    RepositoryExpectation,
    parse_repository_xml,
    verify_google_play_package,
)


FIXTURES = Path(__file__).parent / "fixtures"
SOURCE_URL = "https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-4.xml"


class GoogleRepositoryTests(unittest.TestCase):
    def fixture(self, name: str) -> bytes:
        return (FIXTURES / name).read_bytes()

    def test_selects_channel_0_android_17_arm64_google_play_package(self) -> None:
        report = verify_google_play_package(
            [(SOURCE_URL, self.fixture("repository-stable.xml"))],
            RepositoryExpectation(),
        )

        selected = report["selected_package"]
        self.assertEqual("PASS", report["status"])
        self.assertEqual(37, selected["api_level"])
        self.assertEqual(
            "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a",
            selected["path"],
        )
        self.assertEqual("arm64-v8a", selected["abi"])
        self.assertEqual("6", selected["revision"])
        self.assertEqual("stable", selected["channel"])
        self.assertEqual("channel-0", selected["channel_id"])
        self.assertEqual(
            "https://dl.google.com/android/repository/sys-img/google_apis_playstore/arm64-v8a-playstore-ps16k-37.0_r06.zip",
            selected["archive_url"],
        )
        self.assertEqual("sha1", selected["checksum_algorithm"])
        self.assertEqual("ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4", selected["checksum"])
        self.assertEqual("stable", report["android_release_status"])

    def test_explicit_x86_64_fallback_metadata_remains_compatible(self) -> None:
        report = verify_google_play_package(
            [(SOURCE_URL, self.fixture("repository-stable.xml"))],
            RepositoryExpectation(
                package_path="system-images;android-37.0;google_apis_playstore_ps16k;x86_64",
                abi="x86_64",
                archive_url="https://dl.google.com/android/repository/sys-img/google_apis_playstore/x86_64-playstore-ps16k-37.0_r06.zip",
                checksum="sha1:8eaeeceb77452c018c3f6b589913cdc45222a87f",
            ),
        )

        selected = report["selected_package"]
        self.assertEqual("x86_64", selected["abi"])
        self.assertEqual("channel-0", selected["channel_id"])

    def test_expected_revision_url_and_checksum_are_all_enforced(self) -> None:
        expectation = RepositoryExpectation(
            revision="6",
            archive_url="https://dl.google.com/android/repository/sys-img/google_apis_playstore/arm64-v8a-playstore-ps16k-37.0_r06.zip",
            checksum="sha1:ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4",
        )
        report = verify_google_play_package(
            [(SOURCE_URL, self.fixture("repository-stable.xml"))], expectation
        )
        self.assertEqual("6", report["selected_package"]["revision"])

        with self.assertRaisesRegex(RepositoryError, "SDK repository channel"):
            verify_google_play_package(
                [(SOURCE_URL, self.fixture("repository-stable.xml"))],
                RepositoryExpectation(revision="5"),
            )

    def test_preview_channel_is_not_accepted(self) -> None:
        with self.assertRaisesRegex(RepositoryError, "SDK repository channel"):
            verify_google_play_package(
                [(SOURCE_URL, self.fixture("repository-preview-only.xml"))],
                RepositoryExpectation(),
            )

    def test_stable_label_on_non_channel_0_is_not_accepted(self) -> None:
        non_channel_0 = self.fixture("repository-stable.xml").replace(
            b"channel-0", b"channel-7"
        )
        with self.assertRaisesRegex(RepositoryError, "channel-0"):
            verify_google_play_package(
                [(SOURCE_URL, non_channel_0)],
                RepositoryExpectation(),
            )

    def test_malformed_checksum_fails_closed(self) -> None:
        with self.assertRaisesRegex(RepositoryError, "malformed sha256 checksum"):
            parse_repository_xml(self.fixture("repository-bad-checksum.xml"), SOURCE_URL)

    def test_non_google_source_is_rejected(self) -> None:
        with self.assertRaisesRegex(RepositoryError, "not an allowlisted Google"):
            parse_repository_xml(
                self.fixture("repository-stable.xml"),
                "https://example.invalid/repository.xml",
            )

    def test_gate_is_pinned_to_android_17_api_37(self) -> None:
        with self.assertRaisesRegex(RepositoryError, "pinned to Android 17 / API 37"):
            verify_google_play_package(
                [(SOURCE_URL, self.fixture("repository-stable.xml"))],
                RepositoryExpectation(android_version=16, api_level=36),
            )


if __name__ == "__main__":
    unittest.main()

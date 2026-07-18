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

    def test_selects_stable_android_17_api_37_google_play_package(self) -> None:
        report = verify_google_play_package(
            [(SOURCE_URL, self.fixture("repository-stable.xml"))],
            RepositoryExpectation(abi="x86_64"),
        )

        selected = report["selected_package"]
        self.assertEqual("PASS", report["status"])
        self.assertEqual(37, selected["api_level"])
        self.assertEqual(
            "system-images;android-37.0;google_apis_playstore_ps16k;x86_64",
            selected["path"],
        )
        self.assertEqual("6", selected["revision"])
        self.assertEqual("stable", selected["channel"])
        self.assertEqual(
            "https://dl.google.com/android/repository/sys-img/google_apis_playstore/x86_64-playstore-ps16k-37.0_r06.zip",
            selected["archive_url"],
        )
        self.assertEqual("sha1", selected["checksum_algorithm"])
        self.assertEqual("8eaeeceb77452c018c3f6b589913cdc45222a87f", selected["checksum"])

    def test_expected_revision_url_and_checksum_are_all_enforced(self) -> None:
        expectation = RepositoryExpectation(
            abi="x86_64",
            revision="6",
            archive_url="https://dl.google.com/android/repository/sys-img/google_apis_playstore/x86_64-playstore-ps16k-37.0_r06.zip",
            checksum="sha1:8eaeeceb77452c018c3f6b589913cdc45222a87f",
        )
        report = verify_google_play_package(
            [(SOURCE_URL, self.fixture("repository-stable.xml"))], expectation
        )
        self.assertEqual("6", report["selected_package"]["revision"])

        with self.assertRaisesRegex(RepositoryError, "no stable Android 17"):
            verify_google_play_package(
                [(SOURCE_URL, self.fixture("repository-stable.xml"))],
                RepositoryExpectation(abi="x86_64", revision="5"),
            )

    def test_preview_channel_is_not_accepted(self) -> None:
        with self.assertRaisesRegex(RepositoryError, "no stable Android 17"):
            verify_google_play_package(
                [(SOURCE_URL, self.fixture("repository-preview-only.xml"))],
                RepositoryExpectation(abi="x86_64"),
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
                RepositoryExpectation(android_version=16, api_level=36, abi="x86_64"),
            )


if __name__ == "__main__":
    unittest.main()

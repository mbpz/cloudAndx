from __future__ import annotations

import hashlib
import re
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Iterable

from .io_utils import sha256_bytes, utc_now


ANDROID_VERSION = 17
ANDROID_API_LEVEL = 37
ANDROID_RELEASE_STATUS = "stable"
GOOGLE_PLAY_PACKAGE_PATH = "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a"
GOOGLE_PLAY_TAG = "google_apis_playstore"
GOOGLE_PLAY_ABI = "arm64-v8a"
GOOGLE_PLAY_CHANNEL = "stable"
GOOGLE_PLAY_CHANNEL_ID = "channel-0"
GOOGLE_PLAY_REVISION = "6"
GOOGLE_PLAY_ARCHIVE_URL = (
    "https://dl.google.com/android/repository/sys-img/google_apis_playstore/"
    "arm64-v8a-playstore-ps16k-37.0_r06.zip"
)
GOOGLE_PLAY_CHECKSUM = "sha1:ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4"
OFFICIAL_HOSTS = frozenset(
    {
        "dl.google.com",
        "redirector.gvt1.com",
        "storage.googleapis.com",
    }
)
MAX_XML_BYTES = 16 * 1024 * 1024


class RepositoryError(ValueError):
    """Repository metadata is missing, ambiguous, or not trusted."""


@dataclass(frozen=True)
class PackageRecord:
    path: str
    api_level: int
    tag: str
    abi: str
    revision: str
    revision_key: tuple[int, ...]
    channel: str
    channel_id: str
    archive_url: str
    checksum_algorithm: str
    checksum: str
    source_url: str

    def to_dict(self) -> dict[str, object]:
        return {
            "path": self.path,
            "api_level": self.api_level,
            "tag": self.tag,
            "abi": self.abi,
            "revision": self.revision,
            "channel": self.channel,
            "channel_id": self.channel_id,
            "archive_url": self.archive_url,
            "checksum_algorithm": self.checksum_algorithm,
            "checksum": self.checksum,
            "source_url": self.source_url,
        }


@dataclass(frozen=True)
class RepositoryExpectation:
    android_version: int = ANDROID_VERSION
    api_level: int = ANDROID_API_LEVEL
    package_path: str = GOOGLE_PLAY_PACKAGE_PATH
    tag: str = GOOGLE_PLAY_TAG
    abi: str = GOOGLE_PLAY_ABI
    channel: str = GOOGLE_PLAY_CHANNEL
    channel_id: str = GOOGLE_PLAY_CHANNEL_ID
    revision: str | None = GOOGLE_PLAY_REVISION
    archive_url: str | None = GOOGLE_PLAY_ARCHIVE_URL
    checksum: str | None = GOOGLE_PLAY_CHECKSUM

    def assert_supported_target(self) -> None:
        if self.android_version != ANDROID_VERSION or self.api_level != ANDROID_API_LEVEL:
            raise RepositoryError(
                "this gate is pinned to Android 17 / API 37; "
                f"received Android {self.android_version} / API {self.api_level}"
            )
        if self.tag != GOOGLE_PLAY_TAG:
            if not self.tag:
                raise RepositoryError("Google Play tag cannot be empty")
        if (
            self.channel.lower() != GOOGLE_PLAY_CHANNEL
            or self.channel_id != GOOGLE_PLAY_CHANNEL_ID
        ):
            raise RepositoryError(
                "only SDK repository channel stable (channel-0) is promotable; "
                "product release status and repository channel are independent evidence"
            )


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _first_descendant_text(element: ET.Element, local_name: str) -> str | None:
    for child in element.iter():
        if _local_name(child.tag) == local_name and child.text and child.text.strip():
            return child.text.strip()
    return None


def _direct_child(element: ET.Element, local_name: str) -> ET.Element | None:
    for child in element:
        if _local_name(child.tag) == local_name:
            return child
    return None


def _channel_map(root: ET.Element) -> dict[str, str]:
    channels: dict[str, str] = {}
    for element in root.iter():
        if _local_name(element.tag) != "channel":
            continue
        channel_id = element.attrib.get("id")
        value = (element.text or "").strip().lower()
        if channel_id and value:
            channels[channel_id] = value
    return channels


def _revision(remote_package: ET.Element) -> tuple[str, tuple[int, ...]]:
    revision_element = _direct_child(remote_package, "revision")
    if revision_element is None:
        raise RepositoryError("remotePackage is missing revision")
    components: list[int] = []
    for name in ("major", "minor", "micro", "preview"):
        child = _direct_child(revision_element, name)
        if child is None:
            continue
        text = (child.text or "").strip()
        if not text.isdigit():
            raise RepositoryError(f"invalid revision {name}: {text!r}")
        components.append(int(text))
    if not components:
        raise RepositoryError("remotePackage revision has no numeric components")
    return ".".join(str(component) for component in components), tuple(components)


def _checksum(complete: ET.Element) -> tuple[str, str]:
    checksum_element = _direct_child(complete, "checksum")
    if checksum_element is None:
        raise RepositoryError("archive is missing checksum")
    algorithm = (
        checksum_element.attrib.get("type")
        or checksum_element.attrib.get("algorithm")
        or ""
    ).strip().lower().replace("-", "")
    checksum = (checksum_element.text or "").strip().lower()
    expected_lengths = {"sha1": 40, "sha256": 64}
    if algorithm not in expected_lengths:
        raise RepositoryError(f"unsupported repository checksum algorithm: {algorithm!r}")
    if not re.fullmatch(r"[a-f0-9]+", checksum) or len(checksum) != expected_lengths[algorithm]:
        raise RepositoryError(f"malformed {algorithm} checksum")
    return algorithm, checksum


def is_official_google_url(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    return parsed.scheme == "https" and (parsed.hostname or "").lower() in OFFICIAL_HOSTS


def parse_repository_xml(xml_bytes: bytes, source_url: str) -> list[PackageRecord]:
    if not is_official_google_url(source_url):
        raise RepositoryError(f"repository URL is not an allowlisted Google HTTPS endpoint: {source_url}")
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as error:
        raise RepositoryError(f"invalid repository XML: {error}") from error

    channels = _channel_map(root)
    packages: list[PackageRecord] = []
    for remote_package in root.iter():
        if _local_name(remote_package.tag) != "remotePackage":
            continue
        path = remote_package.attrib.get("path", "").strip()
        parts = path.split(";")
        if len(parts) < 4 or parts[0] != "system-images":
            continue

        type_details = _direct_child(remote_package, "type-details")
        api_text = _first_descendant_text(type_details, "api-level") if type_details is not None else None
        tag_element = None
        if type_details is not None:
            for descendant in type_details.iter():
                if _local_name(descendant.tag) == "tag":
                    tag_element = descendant
                    break
        tag = _first_descendant_text(tag_element, "id") if tag_element is not None else None
        abi = _first_descendant_text(type_details, "abi") if type_details is not None else None
        if api_text is None and parts[1].startswith("android-"):
            api_text = parts[1].removeprefix("android-")
        tag = tag or parts[2]
        abi = abi or parts[3]
        if api_text is None or re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", api_text) is None:
            # Extension-style packages such as android-36-ext19 are outside this
            # gate's exact Android 17 path. Skip them; if the requested package
            # is malformed it remains absent and verification still fails closed.
            continue

        channel_ref = _direct_child(remote_package, "channelRef")
        if channel_ref is None or not channel_ref.attrib.get("ref"):
            raise RepositoryError(f"package {path!r} is missing channelRef")
        channel_id = channel_ref.attrib["ref"]
        channel = channels.get(channel_id)
        if channel is None:
            raise RepositoryError(f"package {path!r} references unknown channel {channel_id!r}")

        revision, revision_key = _revision(remote_package)
        archives = _direct_child(remote_package, "archives")
        complete = None
        if archives is not None:
            for descendant in archives.iter():
                if _local_name(descendant.tag) == "complete":
                    complete = descendant
                    break
        if complete is None:
            raise RepositoryError(f"package {path!r} has no complete archive")
        url_text = _first_descendant_text(complete, "url")
        if not url_text:
            raise RepositoryError(f"package {path!r} archive is missing URL")
        archive_url = urllib.parse.urljoin(source_url, url_text)
        if not is_official_google_url(archive_url):
            raise RepositoryError(f"package {path!r} archive URL is not allowlisted: {archive_url}")
        checksum_algorithm, checksum = _checksum(complete)
        packages.append(
            PackageRecord(
                path=path,
                api_level=int(api_text.split(".", 1)[0]),
                tag=tag,
                abi=abi,
                revision=revision,
                revision_key=revision_key,
                channel=channel,
                channel_id=channel_id,
                archive_url=archive_url,
                checksum_algorithm=checksum_algorithm,
                checksum=checksum,
                source_url=source_url,
            )
        )
    return packages


def fetch_repository_xml(url: str, timeout_seconds: float = 20.0) -> tuple[str, bytes]:
    if not is_official_google_url(url):
        raise RepositoryError(f"repository URL is not an allowlisted Google HTTPS endpoint: {url}")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "cloudandx-evidence-gate/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            resolved_url = response.geturl()
            if not is_official_google_url(resolved_url):
                raise RepositoryError(f"repository redirect left the Google allowlist: {resolved_url}")
            content_length = response.headers.get("Content-Length")
            if content_length and int(content_length) > MAX_XML_BYTES:
                raise RepositoryError("repository XML exceeds the configured maximum size")
            payload = response.read(MAX_XML_BYTES + 1)
            if len(payload) > MAX_XML_BYTES:
                raise RepositoryError("repository XML exceeds the configured maximum size")
            return resolved_url, payload
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        if isinstance(error, RepositoryError):
            raise
        raise RepositoryError(f"failed to fetch {url}: {error}") from error


def verify_google_play_package(
    documents: Iterable[tuple[str, bytes]],
    expectation: RepositoryExpectation,
) -> dict[str, object]:
    expectation.assert_supported_target()
    candidates: list[PackageRecord] = []
    source_records: list[dict[str, object]] = []
    document_count = 0
    for source_url, xml_bytes in documents:
        document_count += 1
        parsed = parse_repository_xml(xml_bytes, source_url)
        source_records.append(
            {
                "url": source_url,
                "digest": sha256_bytes(xml_bytes),
                "bytes": len(xml_bytes),
            }
        )
        candidates.extend(
            package
            for package in parsed
            if package.api_level == expectation.api_level
            and package.path == expectation.package_path
            and package.tag == expectation.tag
            and package.abi == expectation.abi
            and package.channel == expectation.channel.lower()
            and package.channel_id == expectation.channel_id
        )
    if document_count == 0:
        raise RepositoryError("no Google repository XML documents were supplied")
    if expectation.revision is not None:
        candidates = [package for package in candidates if package.revision == expectation.revision]
    if expectation.archive_url is not None:
        candidates = [package for package in candidates if package.archive_url == expectation.archive_url]
    if expectation.checksum is not None:
        wanted = expectation.checksum.lower().removeprefix("sha1:").removeprefix("sha256:")
        candidates = [package for package in candidates if package.checksum == wanted]
    if not candidates:
        raise RepositoryError(
            "no Android 17 / API 37 Google Play system image on SDK repository channel "
            f"{expectation.channel!r} ({expectation.channel_id}) matched "
            f"package {expectation.package_path!r}, ABI {expectation.abi!r}, and the configured "
            "revision/URL/checksum constraints"
        )

    candidates.sort(key=lambda package: package.revision_key, reverse=True)
    selected = candidates[0]
    same_revision = [package for package in candidates if package.revision_key == selected.revision_key]
    identities = {
        (
            package.path,
            package.channel_id,
            package.archive_url,
            package.checksum_algorithm,
            package.checksum,
        )
        for package in same_revision
    }
    if len(identities) != 1:
        raise RepositoryError("highest matching Google Play revision is ambiguous across repository documents")

    return {
        "status": "PASS",
        "verified_at": utc_now(),
        "android_version": expectation.android_version,
        "android_release_status": ANDROID_RELEASE_STATUS,
        "api_level": expectation.api_level,
        "selected_package": selected.to_dict(),
        "repository_sources": source_records,
    }

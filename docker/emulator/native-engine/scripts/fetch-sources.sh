#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
LOCK_FILE=${LOCK_FILE:-${ENGINE_DIR}/sources.lock.json}
WORKSPACE=${WORKSPACE:-/workspace}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(jq -r '.source_date_epoch' "${LOCK_FILE}")}

die() {
  printf 'fetch-sources: %s\n' "$*" >&2
  exit 1
}

safe_relative_path() {
  local value=$1
  [[ -n "${value}" ]] || return 1
  [[ "${value}" != /* ]] || return 1
  [[ "/${value}/" != *'/../'* ]] || return 1
  [[ "/${value}/" != *'/./'* ]] || return 1
  [[ "${value}" != *//* ]] || return 1
}

validate_archive_members() {
  local archive=$1 member

  while IFS= read -r member; do
    [[ -n "${member}" ]] || continue
    member=${member#./}
    safe_relative_path "${member%/}" || die "unsafe archive member: ${member}"
  done < <(tar -tzf "${archive}")
}

verify_git_tree() {
  local source_dir=$1 expected_tree=$2 actual_tree

  git -C "${source_dir}" init -q
  git -C "${source_dir}" -c core.autocrlf=false -c core.filemode=true \
    -c core.excludesfile=/dev/null add -A -f
  actual_tree=$(git -C "${source_dir}" write-tree)
  rm -rf -- "${source_dir}/.git"
  [[ "${actual_tree}" == "${expected_tree}" ]] \
    || die "tree mismatch: expected ${expected_tree}, got ${actual_tree}"
}

verify_blobs() {
  local source_dir=$1 source_json=$2 path expected actual

  while IFS=$'\t' read -r path expected; do
    [[ -n "${path}" ]] || continue
    [[ -f "${source_dir}/${path}" || -L "${source_dir}/${path}" ]] \
      || die "locked blob is missing: ${path}"
    actual=$(git hash-object --no-filters "${source_dir}/${path}")
    [[ "${actual}" == "${expected}" ]] \
      || die "blob mismatch for ${path}: expected ${expected}, got ${actual}"
  done < <(jq -r '.blob_checks[]? | [.path, .sha1] | @tsv' <<<"${source_json}")
}

normalize_mtimes() {
  local source_dir=$1
  find "${source_dir}" -depth -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
}

fetch_locked_files() {
  local source_json=$1 repository=$2 commit=$3 temp_dir=$4 extract_dir=$5
  local source_path relative_destination expected url encoded output actual

  while IFS=$'\t' read -r source_path relative_destination expected; do
    [[ -n "${source_path}" ]] || continue
    safe_relative_path "${source_path}" \
      || die "unsafe locked file path: ${source_path}"
    [[ "${source_path}" =~ ^[A-Za-z0-9._/-]+$ ]] \
      || die "locked file path cannot be encoded safely: ${source_path}"
    safe_relative_path "${relative_destination}" \
      || die "unsafe locked file destination: ${relative_destination}"
    [[ "${expected}" =~ ^[0-9a-f]{40}$ ]] \
      || die "locked file blob is not a full SHA-1: ${source_path}"

    url="${repository}/+/${commit}/${source_path}?format=TEXT"
    encoded=${temp_dir}/encoded-blob
    output=${extract_dir}/${relative_destination}
    mkdir -p "$(dirname -- "${output}")"
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 5 --retry-all-errors --connect-timeout 30 \
      --output "${encoded}" "${url}"
    base64 --decode "${encoded}" >"${output}"
    actual=$(git hash-object --no-filters "${output}")
    [[ "${actual}" == "${expected}" ]] \
      || die "blob mismatch for ${source_path}: expected ${expected}, got ${actual}"
  done < <(jq -r '.files[] | [.path, .destination, .sha1] | @tsv' \
    <<<"${source_json}")
}

fetch_one() {
  local source_json=$1 id repository commit subtree destination git_tree verify_tree file_count
  local url temp_dir archive extract_dir target

  id=$(jq -r '.id' <<<"${source_json}")
  repository=$(jq -r '.repository' <<<"${source_json}")
  commit=$(jq -r '.commit' <<<"${source_json}")
  subtree=$(jq -r '.subtree' <<<"${source_json}")
  destination=$(jq -r '.destination' <<<"${source_json}")
  git_tree=$(jq -r '.git_tree // empty' <<<"${source_json}")
  verify_tree=$(jq -r '.verify_tree' <<<"${source_json}")
  file_count=$(jq -r '.files // [] | length' <<<"${source_json}")

  [[ "${repository}" =~ ^https://android\.googlesource\.com/[A-Za-z0-9._/-]+$ ]] \
    || die "${id}: repository is outside the official allow-list"
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || die "${id}: commit is not a full SHA-1"
  safe_relative_path "${destination}" || die "${id}: unsafe destination"
  temp_dir=$(mktemp -d)
  archive=${temp_dir}/source.tar.gz
  extract_dir=${temp_dir}/source
  mkdir -p "${extract_dir}"
  printf 'fetch-sources: %s\n' "${id}"

  if (( file_count > 0 )); then
    [[ -z "${subtree}" ]] || die "${id}: locked files cannot also use a subtree"
    [[ "${verify_tree}" == false ]] \
      || die "${id}: a partial locked file set cannot verify a whole tree"
    fetch_locked_files "${source_json}" "${repository}" "${commit}" \
      "${temp_dir}" "${extract_dir}"
  else
    if [[ -n "${subtree}" ]]; then
      safe_relative_path "${subtree}" || die "${id}: unsafe subtree"
      url="${repository}/+archive/${commit}/${subtree}.tar.gz"
    else
      url="${repository}/+archive/${commit}.tar.gz"
    fi
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 5 --retry-all-errors --connect-timeout 30 \
      --output "${archive}" "${url}"
    validate_archive_members "${archive}"
    tar --extract --gzip --file "${archive}" --directory "${extract_dir}" \
      --no-same-owner --no-same-permissions

    if [[ "${verify_tree}" == true ]]; then
      [[ "${git_tree}" =~ ^[0-9a-f]{40}$ ]] \
        || die "${id}: verified tree is not pinned"
      verify_git_tree "${extract_dir}" "${git_tree}"
    fi
    verify_blobs "${extract_dir}" "${source_json}"
  fi
  normalize_mtimes "${extract_dir}"

  target=${WORKSPACE}/${destination}
  mkdir -p "$(dirname -- "${target}")"
  rm -rf -- "${target}"
  mv -- "${extract_dir}" "${target}"
  rm -rf -- "${temp_dir}"
}

[[ -f "${LOCK_FILE}" ]] || die "lock file not found: ${LOCK_FILE}"
mkdir -p "${WORKSPACE}"

while IFS= read -r source_json; do
  fetch_one "${source_json}"
done < <(jq -c '.sources[]' "${LOCK_FILE}")

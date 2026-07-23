#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
RUNTIME_DIR=${ROOT}/.runtime/scrcpy-4.1-arm-tcg
SOURCE_ARCHIVE=${RUNTIME_DIR}/scrcpy-v4.1.tar.gz
SOURCE_DIR=${RUNTIME_DIR}/src
BUILD_DIR=${RUNTIME_DIR}/build
VENV_DIR=${RUNTIME_DIR}/venv
SCRCPY_URL=https://github.com/Genymobile/scrcpy/archive/refs/tags/v4.1.tar.gz
SCRCPY_SHA256=537b2ade623cb94b6edddfa5c61bf0b0af21484aa8365ea2531b686ea573249a
SERVER_JAR=/opt/homebrew/Cellar/scrcpy/4.1/share/scrcpy/scrcpy-server

mkdir -p "${RUNTIME_DIR}"
if [ ! -s "${SOURCE_ARCHIVE}" ]; then
  curl --fail --location --retry 5 --retry-all-errors --output "${SOURCE_ARCHIVE}" "${SCRCPY_URL}"
fi
printf '%s  %s\n' "${SCRCPY_SHA256}" "${SOURCE_ARCHIVE}" | shasum -a 256 -c -
test -s "${SERVER_JAR}" || {
  echo >&2 "scrcpy 4.1 server is missing: ${SERVER_JAR}"
  exit 1
}

rm -rf "${SOURCE_DIR}" "${BUILD_DIR}"
mkdir -p "${SOURCE_DIR}" "${BUILD_DIR}"
tar -xzf "${SOURCE_ARCHIVE}" -C "${SOURCE_DIR}" --strip-components=1
patch -d "${SOURCE_DIR}" -p1 <"${ROOT}/patches/scrcpy-4.1-arm-tcg-connect-timeout.patch"

python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --disable-pip-version-check 'meson==1.8.3' 'ninja==1.13.0'
PATH=${VENV_DIR}/bin:${PATH}
export PATH
PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg/lib/pkgconfig:/opt/homebrew/opt/sdl3/lib/pkgconfig:/opt/homebrew/opt/libusb/lib/pkgconfig \
  "${VENV_DIR}/bin/meson" setup "${BUILD_DIR}" "${SOURCE_DIR}" \
    -Dprebuilt_server="${SERVER_JAR}" -Db_lto=true --buildtype=release
"${VENV_DIR}/bin/meson" compile -C "${BUILD_DIR}"
test -x "${BUILD_DIR}/app/scrcpy"
printf '%s\n' "built ${BUILD_DIR}/app/scrcpy"

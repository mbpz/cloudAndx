#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

WORKSPACE=${WORKSPACE:-/workspace}
BUILD_DIR=${BUILD_DIR:-/out/build}

cmake \
  -S "${WORKSPACE}/external/qemu" \
  -B "${BUILD_DIR}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="${WORKSPACE}/external/qemu/android/build/cmake/toolchain-linux-aarch64.cmake" \
  -DPython_EXECUTABLE=/usr/bin/python3 \
  -DOPTION_BAZEL=FALSE \
  -DOPTION_CRASHUPLOAD=NONE \
  -DOPTION_MINBUILD=TRUE \
  -DOPTION_HEADLESS_ENGINE_ONLY=TRUE \
  -DOPTION_SYSTEM_HOST_TOOLCHAIN=TRUE \
  -DOPTION_X86_64_GUEST_ON_AARCH64=TRUE \
  -DOPTION_SDK_TOOLS_BUILD_NUMBER=cloudandx-hybrid \
  -DOPTION_SDK_TOOLS_REVISION=37.1.7 \
  -DQTWEBENGINE=FALSE \
  -DWEBRTC=FALSE

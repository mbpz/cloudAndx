#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

BUILD_DIR=${BUILD_DIR:-/out/build}
BUILD_JOBS=${BUILD_JOBS:-$(nproc)}

cmake --build "${BUILD_DIR}" \
  --target qemu-system-x86_64-headless \
  --parallel "${BUILD_JOBS}"

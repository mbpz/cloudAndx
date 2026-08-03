#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

BUILD_DIR=${BUILD_DIR:-/out/build}
BUILD_JOBS=${BUILD_JOBS:-$(nproc)}

cmake --build "${BUILD_DIR}" \
  --target \
    qemu-system-aarch64-headless \
    gfxstream_backend \
    crashpad_handler \
    qemu-img \
    nimble_bridge \
  --parallel "${BUILD_JOBS}"

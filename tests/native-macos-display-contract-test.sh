#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
SEAM=${ROOT}/client/macos/Sources/CloudAndxClientCore/ScrcpyDisplaySeam.swift
VIEW=${ROOT}/client/macos/Sources/CloudAndxClient/FixtureDisplayView.swift

grep -Fq '2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0' "${SEAM}"
grep -Fq 'send_device_meta=false' "${SEAM}" || { echo 'FAIL: documented stream profile must disable device metadata' >&2; exit 1; }
grep -Fq 'VTDecompressionSessionCreate' "${SEAM}"
grep -Fq 'VTDecompressionSessionDecodeFrame' "${SEAM}"
grep -Fq 'VTDecompressionSessionFinishDelayedFrames' "${SEAM}"
grep -Fq 'ScrcpyPresentationGeometry' "${SEAM}"
grep -Fq 'readAvailable' "${SEAM}"
grep -Fq 'sendControl' "${SEAM}"
grep -Fq 'maxBufferedBytes' "${SEAM}"
grep -Fq 'MTKView' "${VIEW}"
grep -Fq 'present(pixelBuffer: pixelBuffer)' "${VIEW}"
grep -Fq 'Fixture demo — not live Android' "${VIEW}"
grep -Fq 'CIContext(mtlDevice:' "${SEAM}"
grep -Fq 'CIImage(color: .black)' "${SEAM}"
grep -Fq 'ScrcpyPresentationGeometry' "${SEAM}"
if rg -n 'Process\(|/bin/sh|socket\(|URLSession|CLOUDANDX_' "${SEAM}" "${VIEW}" >/dev/null; then
  echo 'FAIL: display seam must not create runtime/network/process authority' >&2
  exit 1
fi
printf '%s\n' 'PASS: native macOS fixture display contract'

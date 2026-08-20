#!/bin/sh
set -eu
cd "$(CDPATH= cd "$(dirname "$0")/../client/macos" && pwd)"
./scripts/swift-toolchain.sh build --product CloudAndxDisplaySeamTests >/dev/null
"$(./scripts/swift-toolchain.sh bin-path)/CloudAndxDisplaySeamTests"

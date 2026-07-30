#!/bin/sh
set -eu

# Host preparation is intentionally provider-neutral.  Linux kernel modules
# and mounts belong to the selected Docker engine/VM; this entry point only
# performs the fail-closed capability check used by Compose and CI.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "${ROOT}/scripts/check-redroid-host.sh" "$@"

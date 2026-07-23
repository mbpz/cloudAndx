#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

"${SCRIPT_DIR}/check-runtime-arch.sh"
python3 -m evidence_gate preflight
exec "${SCRIPT_DIR}/entrypoint.sh" "$@"

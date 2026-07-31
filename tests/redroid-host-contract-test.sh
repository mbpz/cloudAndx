#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check=${ROOT}/scripts/check-redroid-host.sh
setup=${ROOT}/scripts/setup-redroid-host.sh
constraints=${ROOT}/AGENTS.md
compose=${ROOT}/compose.yaml

test -x "${check}"
test -x "${setup}"
test ! -e "${ROOT}/scripts/setup-redroid-colima.sh"
test ! -e "${ROOT}/tests/redroid-colima-contract-test.sh"
grep -Fq '项目只使用 Docker Engine/CLI 与 Docker Compose 作为运行时入口' "${constraints}"
grep -Fq 'PROBE_IMAGE=${REDROID_HOST_PROBE_IMAGE:-debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd}' "${check}"
grep -Fq "'{{.OSType}} {{.Architecture}} {{.KernelVersion}}'" "${check}"
grep -Fq '${DOCKER_BIN} run --rm --interactive --privileged --platform linux/arm64' "${check}"
grep -Fq -- '--entrypoint /bin/sh "${PROBE_IMAGE}" -s "${PAGE_SIZE}"' "${check}"
grep -Fq 'expected_page_size=$1' "${check}"
grep -Fq '/cloudandx-host-dev/ashmem' "${check}"
grep -Fq '/cloudandx-host-dev/dma_heap/system' "${check}"
grep -Fq '/cloudandx-host-dev/binderfs/binder' "${check}"
grep -Fq '/cloudandx-host-dev/binderfs/hwbinder' "${check}"
grep -Fq '/cloudandx-host-dev/binderfs/vndbinder' "${check}"
grep -Fq 'IPv6 is disabled' "${check}"
! grep -Eiq 'colima|orb(o|s)stack|orbctl|(^|[[:space:]])orb([[:space:]]|$)' "${check}" "${setup}" "${compose}"

printf '%s\n' 'PASS: Docker-only ReDroid host contract'

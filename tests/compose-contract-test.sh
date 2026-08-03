#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "${ROOT}"

compose_file=${ROOT}/compose.yaml
dockerfile=${ROOT}/docker/redroid/Dockerfile
entrypoint=${ROOT}/docker/redroid/bin/container-entrypoint.sh
supervisor=${ROOT}/docker/redroid/bin/ui-supervisor.sh
healthcheck=${ROOT}/docker/redroid/bin/healthcheck.sh
runtime_smoke=${ROOT}/tests/redroid-runtime-smoke-test.sh

runtime_services=$(docker compose config --services)
[ "${runtime_services}" = android ] || {
  printf 'FAIL: expected only android runtime service, got: %s\n' "${runtime_services}" >&2
  exit 1
}
[ "$(docker compose config --images)" = 'cloudandx/android16-redroid:16-r1' ]

grep -Fq 'platform: linux/arm64' "${compose_file}"
grep -Fq 'privileged: true' "${compose_file}"
grep -Fq 'dockerfile: docker/redroid/Dockerfile' "${compose_file}"
grep -Fq '/dev/binderfs/binder' "${compose_file}"
grep -Fq '/dev/binderfs/hwbinder' "${compose_file}"
grep -Fq '/dev/binderfs/vndbinder' "${compose_file}"
grep -Fq '/dev/ashmem:/dev/ashmem' "${compose_file}"
grep -Fq '/dev/dma_heap/system:/dev/dma_heap/system' "${compose_file}"
grep -Fq 'androidboot.redroid_gpu_mode=guest' "${compose_file}"
grep -Fq '127.0.0.1:${ANDROID_ADB_PORT:-5555}:5555/tcp' "${compose_file}"
grep -Fq '127.0.0.1:${ANDROID_NOVNC_PORT:-6080}:6080/tcp' "${compose_file}"
grep -Fq '127.0.0.1:${DEVICE_BRIDGE_PORT:-8090}:8090/tcp' "${compose_file}"
if grep -Eq '0\.0\.0\.0:|:5900:|docker\.sock' "${compose_file}"; then
  echo 'FAIL: forbidden external control surface in Compose' >&2
  exit 1
fi

grep -Fq 'redroid/redroid@sha256:7b1e389bd15f37af3bcd06138f5b2ffa7cfba4332bd5ef54c53e99c2f160a15b' "${dockerfile}"
grep -Fq 'ARG SCRCPY_VERSION=4.1' "${dockerfile}"
grep -Fq 'ARG NOVNC_VERSION=1.7.0' "${dockerfile}"
grep -Fq 'ARG WEBSOCKIFY_VERSION=0.13.0' "${dockerfile}"
grep -Fq 'ARG GITHUB_MIRROR=https://github.com' "${dockerfile}"
grep -Fq 'GITHUB_MIRROR: ${CLOUDANDX_GITHUB_MIRROR:-https://github.com}' "${compose_file}"
grep -Fq 'COPY --from=ui-toolchain /etc/alternatives/' "${dockerfile}"
grep -Fq 'COPY services/device-bridge/bridge.py /opt/cloudandx/device-bridge/bridge.py' "${dockerfile}"
grep -Fq 'blas/libblas.so.3.12.1' "${dockerfile}"
grep -Fq '/opt/cloudandx/scrcpy/scrcpy --version' "${dockerfile}"
grep -Fq 'COPY docker/redroid/novnc/mandatory.json' "${dockerfile}"
grep -Fq 'COPY docker/redroid/novnc/cloudandx.css' "${dockerfile}"
grep -Fq 'COPY docker/redroid/novnc/cloudandx-touch.js' "${dockerfile}"
grep -Fq 'ENTRYPOINT ["/usr/bin/dash", "/opt/cloudandx/bin/container-entrypoint.sh"]' "${dockerfile}"

grep -Fq 'exec /init qemu=1 androidboot.hardware=redroid "$@"' "${entrypoint}"
grep -Fq 'getconf PAGESIZE' "${entrypoint}"
grep -Fq '/proc/sys/net/ipv6/conf/all/disable_ipv6' "${entrypoint}"
for device in /dev/ashmem /dev/dma_heap/system /dev/binder /dev/hwbinder /dev/vndbinder; do
  grep -Fq "${device}" "${entrypoint}"
done
grep -Fq 'required character device is missing' "${entrypoint}"
grep -Fq 'runtime preflight passed' "${entrypoint}"
preflight_line=$(grep -n 'runtime preflight passed' "${entrypoint}" | cut -d: -f1)
token_line=$(grep -n '/usr/bin/openssl rand -hex 32' "${entrypoint}" | cut -d: -f1)
[ "${preflight_line}" -lt "${token_line}" ]
grep -Fq 'SCRCPY_SERVER_PATH=/opt/cloudandx/scrcpy/scrcpy-server' "${supervisor}"
grep -Fq '/usr/bin/stdbuf -oL -eL /opt/cloudandx/scrcpy/scrcpy' "${supervisor}"
grep -Fq -- '--mouse=sdk --keyboard=sdk' "${supervisor}"
grep -Fq '/usr/bin/openbox --sm-disable' "${supervisor}"
grep -Fq -- '--config-file /opt/cloudandx/openbox/rc.xml' "${supervisor}"
grep -Fq -- '--always-on-top --window-title=' "${supervisor}"
grep -Fq -- '--ssl-only' "${supervisor}"
grep -Fq -- '-localhost' "${supervisor}"
grep -Fq 'EMULATOR_CONSOLE_ENABLED=false' "${supervisor}"
if grep -Eq 'kill .* 1' "${supervisor}"; then
  echo 'FAIL: a container process cannot reliably terminate Android init PID 1' >&2
  exit 1
fi
grep -Fq "kill -0 \"\${BRIDGE_PID}\"" "${supervisor}"
grep -Fq '[ -f "${ready}" ]' "${healthcheck}"
grep -Fq 'http://127.0.0.1:8090/livez' "${healthcheck}"

grep -Fq '"view_only": false' docker/redroid/novnc/mandatory.json
grep -Fq '"resize": "scale"' docker/redroid/novnc/mandatory.json
grep -Fq '"compression": 0' docker/redroid/novnc/mandatory.json
grep -Fq -- '-wait 1 -defer 1 -nonap -noxdamage -nowait_bog' "${supervisor}"
! grep -Fq -- '-threads' "${supervisor}"
grep -Fq "addEventListener('wheel'" docker/redroid/novnc/cloudandx-touch.js
grep -Fq "addEventListener('mousedown'" docker/redroid/novnc/cloudandx-touch.js
grep -Fq 'stopImmediatePropagation' docker/redroid/novnc/cloudandx-touch.js
grep -Fq "curl --noproxy '*'" "${runtime_smoke}"
grep -Fq 'FAIL: noVNC accepted plaintext HTTP' "${runtime_smoke}"

for retired_path in \
  compose.kvm.yaml \
  contracts \
  docker/emulator \
  services/evidence-gate; do
  [ ! -e "${retired_path}" ] || {
    printf 'FAIL: retired runtime path still exists: %s\n' "${retired_path}" >&2
    exit 1
  }
done

if grep -R -n -E 'docker/emulator|services/evidence-gate|compose\.kvm|native-engine' \
  --exclude=compose-contract-test.sh \
  README.md compose.yaml docker/redroid docs scripts services tests; then
  echo 'FAIL: supported runtime still references a retired implementation' >&2
  exit 1
fi

echo 'compose/redroid single-container contract: PASS'

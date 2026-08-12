#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
compose_file=${ROOT}/compose.yaml
readme=${ROOT}/README.md
emulator_readme=${ROOT}/docker/emulator/README.md
history=${ROOT}/docs/remote-android-lessons-and-next-steps.md
acceptance=${ROOT}/docs/dual-remote-ui-acceptance.md
feasibility=${ROOT}/docs/orbstack-redroid-feasibility-2026-08-11.md
scrcpy_script=${ROOT}/scripts/scrcpy-android17.sh
bridge_readme=${ROOT}/services/device-bridge/README.md
client_architecture=${ROOT}/docs/native-macos-client-architecture.md
client_package=${ROOT}/client/macos/Package.swift

grep -Fq 'profiles: ["docker-compat"]' "${compose_file}"
grep -Fq 'scripts/native-android17.sh start' "${readme}"
grep -Fq 'docker compose --profile docker-compat up -d --build' "${readme}"
grep -Fq '显式 `docker-compat` profile 锁定' "${readme}"
grep -Fq '`docker-compat` profile 中的 ARM64 guest/AEMU 软件执行兼容路径' "${readme}"
if grep -Fq 'docker compose up -d --build' "${readme}"; then
  echo 'FAIL: README must not present bare Docker startup as the default' >&2
  exit 1
fi
grep -Fq 'docker compose --profile docker-compat up -d --build' "${emulator_readme}"
grep -Fq 'explicit `docker-compat` evidence path' "${emulator_readme}"
grep -Fq 'This command only prebuilds `native-engine`' "${emulator_readme}"
grep -Fq 'the subsequent' "${emulator_readme}"
grep -Fq 'builds the main runtime image' "${emulator_readme}"
if grep -Fq 'docker compose up -d --build' "${emulator_readme}"; then
  echo 'FAIL: emulator README must not present bare Docker startup' >&2
  exit 1
fi
if grep -Eq '(^|[^-])docker compose (exec|run|down|logs|ps) ' "${emulator_readme}"; then
  echo 'FAIL: emulator README Docker runtime commands must select docker-compat' >&2
  exit 1
fi

grep -Fq '均是原实验时点的' "${history}"
grep -Fq '该判断已被' "${history}"
grep -Fq '历史环境的默认 Compose 仅 `android`' "${acceptance}"
for stale_claim in \
  '这条路线已迁入默认 Compose' \
  'ReDroid 16 仍是满足宿主内核设备后的长期运行路线' \
  '默认 Compose 已切换到 ReDroid 16'; do
  if grep -Fq "${stale_claim}" "${history}" "${acceptance}"; then
    printf 'FAIL: historical document retains current ReDroid claim: %s\n' "${stale_claim}" >&2
    exit 1
  fi
done

grep -Fq 'sha256:0a611199ba2e0b5d60af39b3327a517f6407231f4352114ed3bd3cbfe2be69aa' "${feasibility}"
grep -Fq 'sha256:b51bde9cef80f7bd7581148192f2b2f4d41f23c6344cfe88eceeb8ddd67490ee' "${feasibility}"

grep -Fq -- '--profile docker-compat cp' "${scrcpy_script}"
grep -Fq 'android:/data/runtime/adb/adbkey' "${scrcpy_script}"
if grep -Fq 'emulator:/data/runtime/adb/adbkey' "${scrcpy_script}"; then
  echo 'FAIL: scrcpy key export must target the android compatibility service' >&2
  exit 1
fi

for runtime_doc in "${emulator_readme}" "${bridge_readme}"; do
  grep -Fq '/data/runtime/console/console.sock' "${runtime_doc}"
  grep -Fq '/data/runtime/secrets/token' "${runtime_doc}"
  if grep -Eq '/run/(emulator-console/console\.sock|bridge-secrets/token)' "${runtime_doc}"; then
    printf 'FAIL: stale multi-container runtime path remains: %s\n' "${runtime_doc}" >&2
    exit 1
  fi
done
grep -Fq 'same fail-closed entrypoint in the single `android` container' "${bridge_readme}"
grep -Fq 'there is no sidecar or shared socket volume' "${emulator_readme}"
if grep -Fq '| 单最终镜像/单容器 | 通过 | 默认 Compose' "${acceptance}"; then
  echo 'FAIL: acceptance table must label its Compose topology as historical' >&2
  exit 1
fi

for obsolete in \
  docker/redroid/Dockerfile \
  docker/redroid/bin/container-entrypoint.sh \
  docker/redroid/bin/healthcheck.sh \
  docker/redroid/bin/ui-supervisor.sh \
  docker/redroid/openbox/rc.xml \
  scripts/check-redroid-host.sh \
  scripts/setup-redroid-host.sh \
  tests/redroid-host-contract-test.sh \
  tests/redroid-runtime-smoke-test.sh; do
  if [ -e "${ROOT}/${obsolete}" ]; then
    printf 'FAIL: obsolete ReDroid implementation remains: %s\n' "${obsolete}" >&2
    exit 1
  fi
done

grep -Fq 'Hypervisor.Framework' "${ROOT}/scripts/native-android17.sh"
grep -Fq -- '-gpu host' "${ROOT}/scripts/native-android17.sh"
grep -Fq 'EXPECTED_SCRCPY_VERSION=4.1' "${ROOT}/scripts/native-android17.sh"
grep -Fq '127.0.0.1:${ADB_PORT}' "${ROOT}/scripts/native-android17.sh"

test -f "${client_package}"
grep -Fq 'client/macos' "${readme}"
grep -Fq 'Hypervisor.Framework' "${client_architecture}"
grep -Fq 'Virtualization.framework + AOSP' "${client_architecture}"
grep -Fq 'Physical Pixel' "${client_architecture}"
grep -Fq 'P95 ≤ 35 ms' "${client_architecture}"

printf '%s\n' 'PASS: native-default and Docker-compat contracts'

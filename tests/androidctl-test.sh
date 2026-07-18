#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT INT TERM

mkdir -p "${tmp}/bin"
cat >"${tmp}/bin/docker" <<'EOF'
#!/bin/sh
set -eu

printf 'runtime_implementation=%s args=%s\n' "${ANDROID_RUNTIME_IMPLEMENTATION-}" "$*" >>"${FAKE_DOCKER_LOG}"

if [ "${1-}" = info ] && [ "${2-}" = --format ]; then
  case ${3-} in
    *OSType*) printf '%s\n' linux ;;
    *Architecture*) printf '%s\n' "${FAKE_DOCKER_ARCH}" ;;
    *) printf '%s\n' unknown ;;
  esac
fi
exit 0
EOF
chmod 0755 "${tmp}/bin/docker"

ANDROID_RUNTIME_IMPLEMENTATION=native \
  sh "${ROOT}/docker/bootstrap/check-runtime-arch.sh" x86_64 >"${tmp}/runtime-x86.out"
grep -q 'supported' "${tmp}/runtime-x86.out"
ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 \
  sh "${ROOT}/docker/bootstrap/check-runtime-arch.sh" arm64 >"${tmp}/runtime-arm.out"
grep -q 'engine=native-aemu-arm64' "${tmp}/runtime-arm.out"
if ANDROID_RUNTIME_IMPLEMENTATION=native \
  sh "${ROOT}/docker/bootstrap/check-runtime-arch.sh" arm64 >"${tmp}/runtime-arm-native.out" 2>&1; then
  printf '%s\n' 'FAIL: Compose runtime architecture gate accepted ARM64 without the hybrid declaration.' >&2
  exit 1
fi
grep -q 'hybrid-aemu-arm64' "${tmp}/runtime-arm-native.out"
if sh "${ROOT}/docker/bootstrap/check-runtime-arch.sh" >"${tmp}/runtime-missing.out" 2>&1; then
  printf '%s\n' 'FAIL: Compose runtime architecture gate accepted a missing engine fact.' >&2
  exit 1
fi
grep -q 'was not supplied by androidctl' "${tmp}/runtime-missing.out"

run_ctl() {
  env \
    FAKE_DOCKER_ARCH="$1" \
    FAKE_DOCKER_LOG="${tmp}/docker.log" \
    PATH="${tmp}/bin:${PATH}" \
    sh "${ROOT}/androidctl" "$2"
}

: >"${tmp}/docker.log"
env FAKE_DOCKER_ARCH=arm64 FAKE_DOCKER_LOG="${tmp}/docker.log" \
  PATH="${tmp}/bin:${PATH}" sh "${ROOT}/docker/emulator/preflight.sh" \
  >"${tmp}/standalone-preflight-arm.out" 2>&1
grep -q 'required.arm64-child-platform=linux/arm64' "${tmp}/standalone-preflight-arm.out"
grep -q 'required.host-mutations=none' "${tmp}/standalone-preflight-arm.out"

env FAKE_DOCKER_ARCH=x86_64 FAKE_DOCKER_LOG="${tmp}/docker.log" \
  PATH="${tmp}/bin:${PATH}" sh "${ROOT}/docker/emulator/preflight.sh" \
  >"${tmp}/standalone-preflight-x86.out" 2>&1

: >"${tmp}/docker.log"
run_ctl arm64 up >"${tmp}/arm.out" 2>&1
grep -q 'build --platform linux/amd64 --target bundle --tag cloudandx/aemu-native-engine:37.1.7' "${tmp}/docker.log"
grep -q 'compose .* up -d --build' "${tmp}/docker.log"
grep -q 'runtime_implementation=hybrid-aemu-arm64' "${tmp}/docker.log"

: >"${tmp}/docker.log"
if run_ctl aarch64 up-kvm >"${tmp}/arm-kvm.out" 2>&1; then
  printf '%s\n' 'FAIL: ARM64 KVM-mode startup unexpectedly succeeded.' >&2
  exit 1
fi
if grep -q -- '--device /dev/kvm' "${tmp}/docker.log"; then
  printf '%s\n' 'FAIL: ARM64 guard ran after probing /dev/kvm.' >&2
  exit 1
fi

: >"${tmp}/docker.log"
if run_ctl arm64 preflight-kvm >"${tmp}/arm-preflight-kvm.out" 2>&1; then
  printf '%s\n' 'FAIL: ARM64 KVM preflight unexpectedly succeeded.' >&2
  exit 1
fi
if grep -q -- '--device /dev/kvm' "${tmp}/docker.log"; then
  printf '%s\n' 'FAIL: ARM64 KVM preflight probed /dev/kvm before the architecture guard.' >&2
  exit 1
fi

: >"${tmp}/docker.log"
run_ctl amd64 up >"${tmp}/amd64.out" 2>&1
grep -q 'compose .* up -d --build' "${tmp}/docker.log"

: >"${tmp}/docker.log"
run_ctl x86_64 up >"${tmp}/x86-64.out" 2>&1
grep -q 'compose .* up -d --build' "${tmp}/docker.log"

: >"${tmp}/docker.log"
if run_ctl riscv64 up >"${tmp}/unknown.out" 2>&1; then
  printf '%s\n' 'FAIL: unknown Docker Engine architecture unexpectedly succeeded.' >&2
  exit 1
fi
if grep -q 'compose .* up' "${tmp}/docker.log"; then
  printf '%s\n' 'FAIL: unknown architecture guard ran after Compose startup.' >&2
  exit 1
fi

printf '%s\n' 'PASS: androidctl architecture guard'

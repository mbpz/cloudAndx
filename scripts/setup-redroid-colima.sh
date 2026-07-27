#!/bin/sh
set -eu

PROFILE=${COLIMA_PROFILE:-cloudandx}
CACHE_DIR=${CLOUDANDX_COLIMA_CACHE_DIR:-${HOME}/.cache/cloudandx-colima}
JAMMY_IMAGE=${CACHE_DIR}/ubuntu-22.04-server-cloudimg-arm64.img
JAMMY_IMAGE_URL=https://cloud-images.ubuntu.com/releases/server/jammy/release/ubuntu-22.04-server-cloudimg-arm64.img
JAMMY_IMAGE_SHA256=8f61e558498ba262da5b5d13f75b2921136b737a1492415150f33b3d0e46a281
PROXY_URL=${CLOUDANDX_PROXY_URL:-}

log() { printf '%s\n' "cloudandx-colima: $*"; }
die() { printf '%s\n' "cloudandx-colima: ERROR: $*" >&2; exit 1; }

command -v colima >/dev/null 2>&1 || die 'colima is required'
command -v curl >/dev/null 2>&1 || die 'curl is required'

mkdir -p "${CACHE_DIR}"
if [ ! -s "${JAMMY_IMAGE}" ]; then
  log 'downloading the pinned Ubuntu 22.04 ARM64 cloud image'
  if [ -n "${PROXY_URL}" ]; then
    curl --fail --location --retry 4 --continue-at - --proxy "${PROXY_URL}" \
      --output "${JAMMY_IMAGE}" "${JAMMY_IMAGE_URL}"
  else
    curl --fail --location --retry 4 --continue-at - \
      --output "${JAMMY_IMAGE}" "${JAMMY_IMAGE_URL}"
  fi
fi
printf '%s  %s\n' "${JAMMY_IMAGE_SHA256}" "${JAMMY_IMAGE}" | shasum -a 256 -c -

if ! colima list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -Fxq "${PROFILE}"; then
  log "creating Colima profile ${PROFILE}"
  # The stock cloud image has no Docker installation. Its first Colima start
  # may stop at Docker provisioning, but SSH must be ready for the next step.
  if [ -n "${PROXY_URL}" ]; then
    HTTP_PROXY=${PROXY_URL} HTTPS_PROXY=${PROXY_URL} \
      colima start "${PROFILE}" --cpu 8 --memory 8 --disk 30 --root-disk 12 \
        --arch aarch64 --vm-type vz --mount-type virtiofs \
        --disk-image "${JAMMY_IMAGE}" --force-disk-image || true
  else
    colima start "${PROFILE}" --cpu 8 --memory 8 --disk 30 --root-disk 12 \
      --arch aarch64 --vm-type vz --mount-type virtiofs \
      --disk-image "${JAMMY_IMAGE}" --force-disk-image || true
  fi
fi

colima ssh -p "${PROFILE}" -- true >/dev/null 2>&1 \
  || die "profile ${PROFILE} is not reachable over SSH"

kernel=$(colima ssh -p "${PROFILE}" -- uname -r)
case ${kernel} in
  5.15.*) ;;
  *) die "profile ${PROFILE} uses ${kernel}; expected the validated 5.15 kernel" ;;
esac

log 'installing Docker and the Ubuntu extra kernel modules'
colima ssh -p "${PROFILE}" -- sh -lc \
  'sudo env DEBIAN_FRONTEND=noninteractive apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing docker.io linux-modules-extra-$(uname -r)'
colima ssh -p "${PROFILE}" -- sh -lc \
  'sudo mkdir -p /etc/containerd /etc/systemd/system/docker.service.d; test -s /etc/containerd/config.toml || containerd config default | sudo tee /etc/containerd/config.toml >/dev/null'

if [ -n "${PROXY_URL}" ]; then
  guest_proxy=$(printf '%s\n' "${PROXY_URL}" | sed 's/127\.0\.0\.1/192.168.5.2/g; s/localhost/192.168.5.2/g')
  colima ssh -p "${PROFILE}" -- sudo tee /etc/systemd/system/docker.service.d/cloudandx-proxy.conf >/dev/null <<EOF
[Service]
Environment=HTTP_PROXY=${guest_proxy}
Environment=HTTPS_PROXY=${guest_proxy}
Environment=NO_PROXY=127.0.0.1,localhost
EOF
fi

colima ssh -p "${PROFILE}" -- sudo tee /etc/systemd/system/cloudandx-redroid-devices.service >/dev/null <<'EOF'
[Unit]
Description=CloudAndx ReDroid kernel devices
Before=docker.service

[Service]
Type=oneshot
ExecStart=/sbin/modprobe ashmem_linux
ExecStart=/sbin/modprobe binder_linux devices=binder,hwbinder,vndbinder
ExecStart=/usr/bin/mkdir -p /dev/binderfs
ExecStart=/bin/sh -c 'mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs'
ExecStart=/bin/chmod 0666 /dev/ashmem /dev/dma_heap/system /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

colima ssh -p "${PROFILE}" -- sh -lc \
  'sudo systemctl daemon-reload; sudo systemctl enable cloudandx-redroid-devices.service; sudo systemctl restart cloudandx-redroid-devices.service; sudo systemctl restart containerd docker'

# A mandatory restart catches broken module ordering and ephemeral binderfs
# configuration before any Android container is started.
log 'restarting the profile to verify persistent kernel-device setup'
colima stop "${PROFILE}"
colima start "${PROFILE}"

colima ssh -p "${PROFILE}" -- sh -lc '
  set -eu
  test "$(getconf PAGESIZE)" = 4096
  grep -q "^CONFIG_IPV6=y$" /boot/config-$(uname -r)
  grep -q "^CONFIG_DMABUF_HEAPS=y$" /boot/config-$(uname -r)
  grep -q "^CONFIG_ASHMEM=m$" /boot/config-$(uname -r)
  grep -q "^CONFIG_ANDROID_BINDERFS=m$" /boot/config-$(uname -r)
  test "$(systemctl is-active cloudandx-redroid-devices.service)" = active
  test "$(systemctl is-active docker.service)" = active
  mountpoint -q /dev/binderfs
  test -c /dev/ashmem
  test -c /dev/dma_heap/system
  test -c /dev/binderfs/binder
  test -c /dev/binderfs/hwbinder
  test -c /dev/binderfs/vndbinder
'

log "profile ${PROFILE} is ready for ReDroid 16"

#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
setup=${ROOT}/scripts/setup-redroid-colima.sh

test -x "${setup}"
grep -Fq 'JAMMY_IMAGE_SHA256=8f61e558498ba262da5b5d13f75b2921136b737a1492415150f33b3d0e46a281' "${setup}"
grep -Fq 'case ${kernel} in' "${setup}"
grep -Fq '5.15.*)' "${setup}"
grep -Fq 'linux-modules-extra-$(uname -r)' "${setup}"
grep -Fq 'ExecStart=/sbin/modprobe ashmem_linux' "${setup}"
grep -Fq 'ExecStart=/sbin/modprobe binder_linux devices=binder,hwbinder,vndbinder' "${setup}"
grep -Fq "mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs" "${setup}"
grep -Fq 'CONFIG_DMABUF_HEAPS=y' "${setup}"
grep -Fq 'getconf PAGESIZE' "${setup}"
grep -Fq 'colima stop "${PROFILE}"' "${setup}"
grep -Fq 'colima start "${PROFILE}"' "${setup}"

printf '%s\n' 'PASS: ReDroid Colima host contract'

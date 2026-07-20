#!/bin/sh
set -eu

install -d -m 0750 /volumes/controller /volumes/evidence /volumes/bridge-secrets /volumes/emulator /volumes/adb-keys
install -d -m 0700 /volumes/emulator-console
chown 65532:65532 /volumes/controller /volumes/evidence
chown 10001:10001 /volumes/bridge-secrets /volumes/emulator /volumes/adb-keys /volumes/emulator-console
chmod 0700 /volumes/emulator-console

token=/volumes/bridge-secrets/token
if [ ! -s "${token}" ]; then
  umask 077
  temporary=${token}.tmp.$$
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"${temporary}"
  mv "${temporary}" "${token}"
fi
chown 10001:10001 "${token}"
chmod 0400 "${token}"

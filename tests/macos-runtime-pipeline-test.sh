#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
PIPELINE=${ROOT}/runtime/macos-arm64/runtime_pipeline.py
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cloudandx-runtime-pipeline.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT HUP INT TERM

fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
expect_fail() { "$@" >/dev/null 2>&1 && fail "expected rejection: $*" || :; }
expect_fail_contains() {
  task_log=${WORK}/expected-failure.log
  if "$@" >"${task_log}" 2>&1; then fail "expected rejection: $*"; fi
  grep -Fq "${EXPECT}" "${task_log}" || { cat "${task_log}" >&2; fail "missing diagnostic ${EXPECT}: $*"; }
}
assemble_with() {
  "${PIPELINE}" assemble --attestation "${TASK_ATTESTATION:-${WORK}/attestation.json}" --signature "${TASK_SIGNATURE:-${WORK}/attestation.sig}" --public-key "${WORK}/pub.pem" --policy "${WORK}/policy.json" --source-lock "${LOCK}" --source-evidence "${TASK_INPUT:-${INPUT}}/provenance/source-evidence.json" --toolchain-evidence "${TASK_INPUT:-${INPUT}}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "$1" --input-root "${TASK_INPUT:-${INPUT}}" --destination "$2"
}
attest_with() {
  task_decl=$1
  task_name=$2
  task_input=${TASK_INPUT:-${INPUT}}
  "${PIPELINE}" create-attestation --source-lock "${LOCK}" --source-evidence "${task_input}/provenance/source-evidence.json" --toolchain-evidence "${task_input}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${task_decl}" --input-root "${task_input}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --environment "${WORK}/environment.json" --build-command 'fixture build only' --default-template templates/default.avd.tar --output "${WORK}/${task_name}.json"
  openssl dgst -sha256 -sign "${WORK}/key.pem" -out "${WORK}/${task_name}.sig" "${WORK}/${task_name}.json"
}

INPUT=${WORK}/input
TOOLCHAIN=${WORK}/toolchain
mkdir -p "${INPUT}/provenance" "${INPUT}/licenses" "${INPUT}/templates" "${INPUT}/tools"
mkdir -p "${TOOLCHAIN}/tools"
LOCK=${ROOT}/runtime/macos-arm64/production-source-lock.json
cp "${LOCK}" "${INPUT}/provenance/source-lock.json"
cat >"${INPUT}/provenance/source-evidence.json" <<EOF
{"aemuRevision":"98f7f6ffcc4e6ce513a8b978323c3b961dc58143","aemuSubmodules":[],"aemuTree":"aeeb57688c7eac123fd2c9728f721da45e60a39a","aospManifestCommit":"5bc9a7ce1cd78dd53613bbfd0ebf506e1e4adb0f","aospManifestResolved":"<manifest><project path=\"build/make\" revision=\"5bc9a7ce1cd78dd53613bbfd0ebf506e1e4adb0f\"/><project path=\"packages/modules/adb\" revision=\"9084198a2d4b0f6a0f174260fb42da33485b684d\"/></manifest>","aospManifestResolvedSha256":"$(printf '<manifest><project path="build/make" revision="5bc9a7ce1cd78dd53613bbfd0ebf506e1e4adb0f"/><project path="packages/modules/adb" revision="9084198a2d4b0f6a0f174260fb42da33485b684d"/></manifest>' | shasum -a 256 | awk '{print $1}')","offline":true,"repoToolSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repoToolSize":1,"schemaVersion":1,"scrcpyRevision":"2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0","sourceLockSha256":"$(shasum -a 256 "${LOCK}" | awk '{print $1}')"}
EOF
printf x >"${TOOLCHAIN}/tools/fixture-clang"
tool_hash=$(shasum -a 256 "${TOOLCHAIN}/tools/fixture-clang" | awk '{print $1}')
printf '{"schemaVersion":1,"tools":[{"path":"tools/fixture-clang","version":"offline","sha256":"%s","size":1,"architecture":"host-tool"}]}\n' "${tool_hash}" >"${INPUT}/provenance/toolchain.json"
printf '%s\n' '{"spdxVersion":"SPDX-2.3"}' >"${INPUT}/provenance/sbom.json"
printf '%s\n' '{"licenses":["Apache-2.0"]}' >"${INPUT}/licenses/licenses.json"
printf '%s\n' 'fixture NOTICE' >"${INPUT}/licenses/NOTICE"
printf '%s\n' 'synthetic template' >"${INPUT}/templates/default.avd.tar"

# A genuine arm64 Mach-O exercises `otool -L`, LC_RPATH, and the same
# non-system payload closure checked by production verification.
if command -v clang >/dev/null 2>&1 && printf 'int answer(void){return 42;}' | clang -target arm64-apple-macos11 -dynamiclib -x c - -install_name @rpath/libfixture.dylib -o "${INPUT}/tools/libfixture.dylib" >/dev/null 2>&1 && printf 'extern int answer(void); int main(void){return answer()!=42;}' | clang -target arm64-apple-macos11 -x c - -L"${INPUT}/tools" -lfixture -Wl,-rpath,@loader_path -o "${INPUT}/tools/runtime-tool" >/dev/null 2>&1; then
  chmod 0755 "${INPUT}/tools/runtime-tool"
  TOOL_ARCH='"arm64"'
  TOOL_EXEC=true
  DYLIB=true
else
  printf '%s\n' 'not an executable on this host' >"${INPUT}/tools/runtime-tool"
  TOOL_ARCH='null'
  TOOL_EXEC=false
  DYLIB=false
fi

cat >"${WORK}/declaration.json" <<EOF
{"schemaVersion":1,"references":{"sourceLock":"provenance/source-lock.json","sourceEvidence":"provenance/source-evidence.json","toolchainEvidence":"provenance/toolchain.json","sbom":"provenance/sbom.json","licenses":"licenses/licenses.json","notice":"licenses/NOTICE"},"artifacts":[
{"input":"provenance/source-lock.json","path":"provenance/source-lock.json","role":"source-lock","executable":false,"requiredArchitecture":null,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"},
{"input":"provenance/source-evidence.json","path":"provenance/source-evidence.json","role":"source-evidence","executable":false,"requiredArchitecture":null,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"},
{"input":"provenance/toolchain.json","path":"provenance/toolchain.json","role":"toolchain","executable":false,"requiredArchitecture":null,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"},
{"input":"provenance/sbom.json","path":"provenance/sbom.json","role":"sbom","executable":false,"requiredArchitecture":null,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"},
{"input":"licenses/licenses.json","path":"licenses/licenses.json","role":"license","executable":false,"requiredArchitecture":null,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"},
{"input":"licenses/NOTICE","path":"licenses/NOTICE","role":"notice","executable":false,"requiredArchitecture":null,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"},
{"input":"templates/default.avd.tar","path":"templates/default.avd.tar","role":"template","executable":false,"requiredArchitecture":null,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"},
{"input":"tools/runtime-tool","path":"tools/runtime-tool","role":"tool","executable":${TOOL_EXEC},"requiredArchitecture":${TOOL_ARCH},"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"}]}
EOF
if [ "${DYLIB}" = true ]; then
  python3 - "${WORK}/declaration.json" <<'PY'
import json, sys
p=sys.argv[1]; o=json.load(open(p)); o['artifacts'].append({"input":"tools/libfixture.dylib","path":"tools/libfixture.dylib","role":"dylib","executable":True,"requiredArchitecture":"arm64","sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"}); open(p,'w').write(json.dumps(o))
PY
fi

openssl genrsa -out "${WORK}/key.pem" 2048 >/dev/null 2>&1
openssl rsa -in "${WORK}/key.pem" -pubout -out "${WORK}/pub.pem" >/dev/null 2>&1
key_hash=$(openssl pkey -pubin -in "${WORK}/pub.pem" -outform DER | shasum -a 256 | awk '{print $1}')
printf '{"algorithm":"rsa-sha256","schemaVersion":1,"trustedPublicKeyDerSha256":["%s"]}\n' "${key_hash}" >"${WORK}/policy.json"
printf '%s\n' '{"SOURCE_DATE_EPOCH":"0"}' >"${WORK}/environment.json"
"${PIPELINE}" create-attestation --source-lock "${LOCK}" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --environment "${WORK}/environment.json" --build-command 'fixture build only' --default-template templates/default.avd.tar --output "${WORK}/attestation.json"
openssl dgst -sha256 -sign "${WORK}/key.pem" -out "${WORK}/attestation.sig" "${WORK}/attestation.json"
"${PIPELINE}" assemble --attestation "${WORK}/attestation.json" --signature "${WORK}/attestation.sig" --public-key "${WORK}/pub.pem" --policy "${WORK}/policy.json" --source-lock "${LOCK}" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --destination "${WORK}/AndroidRuntime"
"${PIPELINE}" verify-payload --payload "${WORK}/AndroidRuntime" --policy "${WORK}/policy.json"
VERIFIER=$(cd "${ROOT}/client/macos" && ./scripts/swift-toolchain.sh build --product CloudAndxRuntimeVerifier >/dev/null && ./scripts/swift-toolchain.sh bin-path)/CloudAndxRuntimeVerifier
"${PIPELINE}" verify-payload --payload "${WORK}/AndroidRuntime" --policy "${WORK}/policy.json" --swift-verifier "${VERIFIER}"

# Negative gates: signature/key policy, evidence, closure, classification,
# version binding, architecture/Mach-O and tamper/atomic destination behavior.
cp "${WORK}/policy.json" "${WORK}/untrusted-policy.json"
sed 's/[0-9a-f]/0/' "${WORK}/untrusted-policy.json" >"${WORK}/bad-policy.json"
expect_fail "${PIPELINE}" verify-payload --payload "${WORK}/AndroidRuntime" --policy "${WORK}/bad-policy.json"
printf '{"schemaVersion":1,"schemaVersion":1}\n' >"${WORK}/duplicate.json"
EXPECT='duplicate JSON key' expect_fail_contains "${PIPELINE}" create-attestation --source-lock "${WORK}/duplicate.json" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --default-template templates/default.avd.tar --output "${WORK}/bad.json"
cp "${INPUT}/provenance/source-evidence.json" "${WORK}/adb-mismatch-evidence.json"
python3 - "${WORK}/adb-mismatch-evidence.json" <<'PY'
import json,sys
p=sys.argv[1]; o=json.load(open(p)); o['aospManifestResolved']=o['aospManifestResolved'].replace('9084198a2d4b0f6a0f174260fb42da33485b684d','0'*40); import hashlib; o['aospManifestResolvedSha256']=hashlib.sha256(o['aospManifestResolved'].encode()).hexdigest(); open(p,'w').write(json.dumps(o))
PY
EXPECT='unlocked adb revision' expect_fail_contains "${PIPELINE}" create-attestation --source-lock "${LOCK}" --source-evidence "${WORK}/adb-mismatch-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --default-template templates/default.avd.tar --output "${WORK}/bad.json"
cp "${INPUT}/provenance/toolchain.json" "${WORK}/fake-toolchain.json"
sed 's/"sha256":"[0-9a-f]*/"sha256":"0000000000000000000000000000000000000000000000000000000000000000/' "${WORK}/fake-toolchain.json" >"${WORK}/fake-toolchain-hash.json"
EXPECT='toolchain hash/size drift' expect_fail_contains "${PIPELINE}" create-attestation --source-lock "${LOCK}" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${WORK}/fake-toolchain-hash.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --default-template templates/default.avd.tar --output "${WORK}/bad.json"
printf dirty >"${INPUT}/undeclared.txt"
expect_fail "${PIPELINE}" create-attestation --source-lock "${LOCK}" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --default-template templates/default.avd.tar --output "${WORK}/bad.json"
rm "${INPUT}/undeclared.txt"
ln -s NOTICE "${INPUT}/licenses/link"
expect_fail "${PIPELINE}" create-attestation --source-lock "${LOCK}" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --default-template templates/default.avd.tar --output "${WORK}/bad.json"
rm "${INPUT}/licenses/link"
cp -R "${WORK}/AndroidRuntime" "${WORK}/tampered"
printf drift >>"${WORK}/tampered/templates/default.avd.tar"
expect_fail "${PIPELINE}" verify-payload --payload "${WORK}/tampered" --policy "${WORK}/policy.json"
cp -R "${WORK}/AndroidRuntime" "${WORK}/traversal"
python3 - "${WORK}/traversal/manifest.json" <<'PY'
import json, sys
p=sys.argv[1]
o=json.load(open(p))
o["buildAttestationReference"]="../attestation.json"
open(p,"w").write(json.dumps(o))
PY
expect_fail "${PIPELINE}" verify-payload --payload "${WORK}/traversal" --policy "${WORK}/policy.json"
cp -R "${WORK}/AndroidRuntime" "${WORK}/substitution"
python3 - "${WORK}/substitution/manifest.json" <<'PY'
import json, sys
p=sys.argv[1]
o=json.load(open(p))
o["artifacts"][0]["sourceReference"]="licenses/NOTICE"
open(p,"w").write(json.dumps(o))
PY
expect_fail "${PIPELINE}" verify-payload --payload "${WORK}/substitution" --policy "${WORK}/policy.json"
cp -R "${WORK}/AndroidRuntime" "${WORK}/template-substitution"
python3 - "${WORK}/template-substitution/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; o=json.load(open(p)); a=next(x for x in o['artifacts'] if x['path']=='tools/runtime-tool'); o['defaultTemplateArtifact']=a['path']; o['defaultTemplateDigest']=a['sha256']; open(p,'w').write(json.dumps(o))
PY
EXPECT='default template does not match signed attestation' expect_fail_contains "${PIPELINE}" verify-payload --payload "${WORK}/template-substitution" --policy "${WORK}/policy.json"
python3 - "${WORK}/attestation.json" "${WORK}/swapped-envelope.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); o['envelope']['signature']='provenance/builder-public-key.pem'; o['envelope']['publicKey']='provenance/build-attestation.sig'; open(sys.argv[2],'w').write(json.dumps(o))
PY
openssl dgst -sha256 -sign "${WORK}/key.pem" -out "${WORK}/swapped-envelope.sig" "${WORK}/swapped-envelope.json"
EXPECT='signed envelope paths are not fixed' TASK_ATTESTATION="${WORK}/swapped-envelope.json" TASK_SIGNATURE="${WORK}/swapped-envelope.sig" expect_fail_contains assemble_with "${WORK}/declaration.json" "${WORK}/swapped-envelope"
cp -R "${WORK}/AndroidRuntime" "${WORK}/policy-substitution"
printf '%s\n' '{"schemaVersion":1,"algorithm":"rsa-sha256","trustedPublicKeyDerSha256":[]}' >"${WORK}/policy-substitution/provenance/trusted-builders-policy.json"
expect_fail "${PIPELINE}" verify-payload --payload "${WORK}/policy-substitution" --policy "${WORK}/policy.json"
cp -R "${WORK}/AndroidRuntime" "${WORK}/mixed-scrcpy"
python3 - "${WORK}/mixed-scrcpy/provenance/build-attestation.json" <<'PY'
import json,sys
p=sys.argv[1]; o=json.load(open(p)); o['scrcpyServerRevision']='0'*40; open(p,'w').write(json.dumps(o))
PY
expect_fail "${PIPELINE}" verify-payload --payload "${WORK}/mixed-scrcpy" --policy "${WORK}/policy.json"
cp -R "${WORK}/AndroidRuntime" "${WORK}/generated-metadata"
python3 - "${WORK}/generated-metadata/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; o=json.load(open(p)); a=next(x for x in o['artifacts'] if x['path']=='provenance/build-attestation.sig'); a['size']+=1; open(p,'w').write(json.dumps(o))
PY
expect_fail "${PIPELINE}" verify-payload --payload "${WORK}/generated-metadata" --policy "${WORK}/policy.json"
python3 - "${WORK}/declaration.json" "${WORK}/google-classification.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); next(x for x in o['artifacts'] if x['path']=='tools/runtime-tool')['role']='Google Play tool'; open(sys.argv[2],'w').write(json.dumps(o))
PY
expect_fail "${PIPELINE}" create-attestation --source-lock "${LOCK}" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/google-classification.json" --input-root "${INPUT}" --runtime-id fixture-runtime --policy "${WORK}/policy.json" --default-template templates/default.avd.tar --output "${WORK}/bad.json"
if [ "${DYLIB}" = true ]; then
  # Deliberately omit the referenced dylib from the declared input closure;
  # assembly reaches Mach-O dependency validation rather than manifest closure.
  cp "${WORK}/declaration.json" "${WORK}/missing-macho-closure.json"
  python3 - "${WORK}/missing-macho-closure.json" <<'PY'
import json,sys
p=sys.argv[1]; o=json.load(open(p)); o['artifacts']=[a for a in o['artifacts'] if a['path']!='tools/libfixture.dylib']; open(p,'w').write(json.dumps(o))
PY
  cp -R "${INPUT}" "${WORK}/missing-macho-input"
  rm "${WORK}/missing-macho-input/tools/libfixture.dylib"
  TASK_INPUT="${WORK}/missing-macho-input" attest_with "${WORK}/missing-macho-closure.json" missing-macho-attestation
  EXPECT='missing or escaping Mach-O dependency closure' TASK_INPUT="${WORK}/missing-macho-input" TASK_ATTESTATION="${WORK}/missing-macho-attestation.json" TASK_SIGNATURE="${WORK}/missing-macho-attestation.sig" expect_fail_contains assemble_with "${WORK}/missing-macho-closure.json" "${WORK}/missing-macho-closure"
  cp "${INPUT}/tools/runtime-tool" "${INPUT}/tools/non-arm64"
  python3 - "${WORK}/declaration.json" "${WORK}/non-arm64.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); a=next(x for x in o['artifacts'] if x['path']=='tools/runtime-tool').copy(); a['input']='tools/non-arm64'; a['path']='tools/non-arm64'; o['artifacts'].append(a); open(sys.argv[2],'w').write(json.dumps(o))
PY
  # Corrupt the Mach-O magic so the arm64-required declaration fails closed.
  printf 'NOPE' | dd of="${INPUT}/tools/non-arm64" bs=1 count=4 conv=notrunc >/dev/null 2>&1
  TASK_INPUT="${INPUT}" attest_with "${WORK}/non-arm64.json" non-arm64-attestation
  EXPECT='required arm64 artifact is not a Mach-O' TASK_ATTESTATION="${WORK}/non-arm64-attestation.json" TASK_SIGNATURE="${WORK}/non-arm64-attestation.sig" expect_fail_contains assemble_with "${WORK}/non-arm64.json" "${WORK}/non-arm64"
  rm "${INPUT}/tools/non-arm64"
  cp "${INPUT}/tools/runtime-tool" "${INPUT}/tools/unsafe-rpath"
  install_name_tool -add_rpath /tmp "${INPUT}/tools/unsafe-rpath"
  python3 - "${WORK}/declaration.json" "${WORK}/unsafe-rpath.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); a=next(x for x in o['artifacts'] if x['path']=='tools/runtime-tool').copy(); a['input']='tools/unsafe-rpath'; a['path']='tools/unsafe-rpath'; o['artifacts'].append(a); open(sys.argv[2],'w').write(json.dumps(o))
PY
  TASK_INPUT="${INPUT}" attest_with "${WORK}/unsafe-rpath.json" unsafe-rpath-attestation
  EXPECT='unsafe Mach-O RPATH' TASK_ATTESTATION="${WORK}/unsafe-rpath-attestation.json" TASK_SIGNATURE="${WORK}/unsafe-rpath-attestation.sig" expect_fail_contains assemble_with "${WORK}/unsafe-rpath.json" "${WORK}/unsafe-rpath"
  rm "${INPUT}/tools/unsafe-rpath"
  # This is intentionally declared data (not executable/no architecture):
  # byte-level Mach-O detection must still reach the RPATH validator.
  cp "${INPUT}/tools/runtime-tool" "${INPUT}/tools/unlabelled-unsafe-rpath"
  install_name_tool -add_rpath /tmp "${INPUT}/tools/unlabelled-unsafe-rpath"
  python3 - "${WORK}/declaration.json" "${WORK}/unlabelled-macho.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); a=next(x for x in o['artifacts'] if x['path']=='tools/runtime-tool').copy(); a.update(input='tools/unlabelled-unsafe-rpath', path='tools/unlabelled-unsafe-rpath', executable=False, requiredArchitecture=None); o['artifacts'].append(a); open(sys.argv[2],'w').write(json.dumps(o))
PY
  TASK_INPUT="${INPUT}" attest_with "${WORK}/unlabelled-macho.json" unlabelled-macho-attestation
  EXPECT='unsafe Mach-O RPATH' TASK_ATTESTATION="${WORK}/unlabelled-macho-attestation.json" TASK_SIGNATURE="${WORK}/unlabelled-macho-attestation.sig" expect_fail_contains assemble_with "${WORK}/unlabelled-macho.json" "${WORK}/unlabelled-macho"
  rm "${INPUT}/tools/unlabelled-unsafe-rpath"
  printf 'int main(void){return 0;}' | clang -target x86_64-apple-macos11 -x c - -o "${INPUT}/tools/unlabelled-x86"
  python3 - "${WORK}/declaration.json" "${WORK}/unlabelled-x86.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); a=next(x for x in o['artifacts'] if x['path']=='tools/runtime-tool').copy(); a.update(input='tools/unlabelled-x86', path='tools/unlabelled-x86', executable=False, requiredArchitecture=None); o['artifacts'].append(a); open(sys.argv[2],'w').write(json.dumps(o))
PY
  TASK_INPUT="${INPUT}" attest_with "${WORK}/unlabelled-x86.json" unlabelled-x86-attestation
  EXPECT='artifact is not arm64' TASK_ATTESTATION="${WORK}/unlabelled-x86-attestation.json" TASK_SIGNATURE="${WORK}/unlabelled-x86-attestation.sig" expect_fail_contains assemble_with "${WORK}/unlabelled-x86.json" "${WORK}/unlabelled-x86"
  rm "${INPUT}/tools/unlabelled-x86"
  printf 'int id(void){return 0;}' | clang -target arm64-apple-macos11 -dynamiclib -x c - -install_name /tmp/unsafe.dylib -o "${INPUT}/tools/unsafe-id.dylib"
  python3 - "${WORK}/declaration.json" "${WORK}/unsafe-id.json" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])); a=next(x for x in o['artifacts'] if x['path']=='tools/libfixture.dylib').copy(); a['input']='tools/unsafe-id.dylib'; a['path']='tools/unsafe-id.dylib'; o['artifacts'].append(a); open(sys.argv[2],'w').write(json.dumps(o))
PY
  TASK_INPUT="${INPUT}" attest_with "${WORK}/unsafe-id.json" unsafe-id-attestation
  EXPECT='unsafe Mach-O install name' TASK_ATTESTATION="${WORK}/unsafe-id-attestation.json" TASK_SIGNATURE="${WORK}/unsafe-id-attestation.sig" expect_fail_contains assemble_with "${WORK}/unsafe-id.json" "${WORK}/unsafe-id"
  # A system-looking prefix cannot hide a traversal component in LC_ID_DYLIB.
  install_name_tool -id /usr/lib/../tmp/unsafe.dylib "${INPUT}/tools/unsafe-id.dylib"
  TASK_INPUT="${INPUT}" attest_with "${WORK}/unsafe-id.json" unsafe-id-escape-attestation
  EXPECT='unsafe Mach-O install name escape' TASK_ATTESTATION="${WORK}/unsafe-id-escape-attestation.json" TASK_SIGNATURE="${WORK}/unsafe-id-escape-attestation.sig" expect_fail_contains assemble_with "${WORK}/unsafe-id.json" "${WORK}/unsafe-id-escape"
  rm "${INPUT}/tools/unsafe-id.dylib"
fi
expect_fail "${PIPELINE}" assemble --attestation "${WORK}/attestation.json" --signature "${WORK}/attestation.sig" --public-key "${WORK}/pub.pem" --policy "${WORK}/policy.json" --source-lock "${LOCK}" --source-evidence "${INPUT}/provenance/source-evidence.json" --toolchain-evidence "${INPUT}/provenance/toolchain.json" --toolchain-root "${TOOLCHAIN}" --artifact-declaration "${WORK}/declaration.json" --input-root "${INPUT}" --destination "${WORK}/AndroidRuntime"
test -f "${WORK}/AndroidRuntime/manifest.json" || fail 'atomic destination changed'
# The attestation is signed before this pathname substitution. Assembly must
# reject it and leave the new destination absent rather than publish stale data.
cp "${INPUT}/templates/default.avd.tar" "${WORK}/template-before-substitution"
printf substituted >"${INPUT}/templates/default.avd.tar"
EXPECT='source substitution before copy' TASK_ATTESTATION="${WORK}/attestation.json" TASK_SIGNATURE="${WORK}/attestation.sig" TASK_INPUT="${INPUT}" expect_fail_contains assemble_with "${WORK}/declaration.json" "${WORK}/substitution-destination"
test ! -e "${WORK}/substitution-destination" || fail 'source substitution published a destination'
mv "${WORK}/template-before-substitution" "${INPUT}/templates/default.avd.tar"
printf '%s\n' 'PASS: macOS runtime pipeline positive assembly and signature, source/closure/symlink/tamper/atomic negative gates'

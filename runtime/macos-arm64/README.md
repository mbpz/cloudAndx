# Phase 2C offline runtime supply chain

`runtime_pipeline.py` is the offline, fail-closed assembly gate for a future
source-built `AndroidRuntime` payload.  It uses Python's standard library plus
local `git`, `openssl`, `lipo`, and `otool`; it never downloads, builds, starts,
or executes a runtime.

Production source identities are locked in `production-source-lock.json`.
`production-trusted-builders.json` deliberately has no keys, so production
release assembly and release verification fail closed until a reviewed key is
added.  Fixture policies may be supplied to the CLI, but `build-app.sh` always
uses the fixed production policy.

The AOSP `repo` Python tool has no independently evidenced immutable release
digest in this repository. `preflight-sources` therefore requires an explicit,
reviewable caller-supplied `{path, sha256, size}` lock record for the local
`.repo/repo/repo` tool before executing it. This only checks consistency with
an external build-lane approval; it does not make the caller-supplied record
independently trustworthy. Production remains blocked by the zero-key builder
policy until a real reviewed build lane supplies the record and builder key.

`preflight-sources` requires `--repo-tool-lock` for the local repo launcher.
`create-attestation` and `assemble` require `--toolchain-root`, whose exact
regular-file closure is recomputed against toolchain evidence. The commands are `preflight-sources`, `create-attestation`, `assemble`, and
`verify-payload`.  JSON is emitted canonically (sorted keys and compact UTF-8)
so detached RSA-SHA256 signatures are stable.  See the fixture test for an
offline, synthetic invocation.

This proves a controlled input/assembly process, not that redistributable
macOS AEMU, gfxstream, adb, or their legal/license closure has been built or
approved.

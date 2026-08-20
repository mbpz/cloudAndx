#!/usr/bin/env python3
"""Offline, fail-closed assembler for the schema-1 CloudAndx macOS runtime."""
import argparse, errno, hashlib, json, os, re, shutil, stat, subprocess, sys, tempfile, unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath

MAX_FILE = 8 * 1024 * 1024 * 1024
MAX_JSON = 32 * 1024 * 1024
HEX64 = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN = ("google play", "google_apis", "google apis", "android sdk", "android studio")
PIN = {
    "aospManifestTag": "android-17.0.0_r1", "aospManifestCommit": "5bc9a7ce1cd78dd53613bbfd0ebf506e1e4adb0f",
    "aospProduct": "sdk_phone16k_arm64", "aemuRevision": "98f7f6ffcc4e6ce513a8b978323c3b961dc58143",
    "aemuTree": "aeeb57688c7eac123fd2c9728f721da45e60a39a", "adbRevision": "9084198a2d4b0f6a0f174260fb42da33485b684d",
    "scrcpyRevision": "2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0", "scrcpyVersion": "4.1",
}
ENVELOPE_PATHS={"attestation":"provenance/build-attestation.json","signature":"provenance/build-attestation.sig","publicKey":"provenance/builder-public-key.pem","policy":"provenance/trusted-builders-policy.json","declaration":"provenance/artifact-declaration.json"}

class GateError(Exception): pass
def die(msg): raise GateError(msg)
def canonical(value): return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
def load_json(path):
    def no_duplicates(pairs):
        result={}
        for key,value in pairs:
            if key in result: raise ValueError("duplicate JSON key: %s" % key)
            result[key]=value
        return result
    try:
        p=Path(path)
        if p.is_symlink() or not p.is_file(): die("JSON input is not a regular non-symlink file: %s" % path)
        if p.stat().st_size > MAX_JSON: die("JSON input exceeds byte limit: %s" % path)
        with open(p, "rb") as f: return json.load(f, object_pairs_hook=no_duplicates)
    except (OSError, ValueError) as e: die("invalid JSON %s: %s" % (path, e))
def write_canonical(path, obj): Path(path).write_bytes(canonical(obj) + b"\n")
def digest_bytes(data): return hashlib.sha256(data).hexdigest()
def digest(path):
    h=hashlib.sha256()
    try:
        with open(path,"rb") as f:
            while True:
                b=f.read(1024*1024)
                if not b: return h.hexdigest()
                h.update(b)
    except OSError as e: die("cannot hash %s: %s" % (path,e))
def run(args, cwd=None):
    try: return subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except (OSError, subprocess.CalledProcessError) as e:
        detail = getattr(e, "stderr", "").strip()
        die("command failed (%s): %s" % (" ".join(args), detail or e))
def path_ok(value):
    if not isinstance(value,str) or not value or value != unicodedata.normalize("NFC", value): return False
    if value.startswith(("/","~")) or "\\" in value or any(ord(c)<32 or ord(c)==127 for c in value): return False
    parts=value.split("/")
    return all(p and p not in (".","..") for p in parts)
def safe_rel(value):
    if not path_ok(value): die("unsafe relative path: %r" % value)
    return PurePosixPath(value)
def tree_no_symlinks(root):
    root=Path(root)
    if root.is_symlink(): die("symlink is forbidden: .")
    if not root.is_dir(): die("not a directory: %s" % root)
    files=[]
    for base, dirs, names in os.walk(root, followlinks=False):
        for n in dirs + names:
            p=Path(base,n)
            try: mode=os.lstat(p).st_mode
            except OSError as e: die("cannot inspect payload node %s: %s" % (p,e))
            relative=p.relative_to(root)
            if stat.S_ISLNK(mode): die("symlink is forbidden: %s" % relative)
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)): die("special filesystem node is forbidden: %s" % relative)
        for n in names:
            p=Path(base,n)
            if p.is_file(): files.append(p)
    return files
def file_info(path):
    p=Path(path); st=p.stat()
    if p.is_symlink() or not p.is_file(): die("not a regular file: %s" % p)
    if st.st_size > MAX_FILE: die("file exceeds byte limit: %s" % p)
    return {"sha256":digest(p), "size":st.st_size, "mode":stat.S_IMODE(st.st_mode)}
def copy_verified_file(source, destination, expected, label):
    """Copy from one O_NOFOLLOW descriptor and prove the staged bytes match."""
    source=Path(source); destination=Path(destination)
    try:
        source_fd=os.open(source, os.O_RDONLY | getattr(os,"O_NOFOLLOW",0))
    except OSError as e: die("cannot securely open %s: %s" % (label,e))
    try:
        source_stat=os.fstat(source_fd)
        if not stat.S_ISREG(source_stat.st_mode): die("%s is not a regular file" % label)
        source_info={"size":source_stat.st_size,"mode":stat.S_IMODE(source_stat.st_mode)}
        if source_info["size"] != expected["size"] or source_info["mode"] != expected["mode"]: die("source substitution before copy: %s" % label)
        destination_fd=os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os,"O_NOFOLLOW",0), source_info["mode"])
        try:
            digestor=hashlib.sha256()
            while True:
                chunk=os.read(source_fd, 1024*1024)
                if not chunk: break
                digestor.update(chunk)
                offset=0
                while offset < len(chunk):
                    written=os.write(destination_fd,chunk[offset:])
                    if written <= 0: die("short write while copying %s" % label)
                    offset += written
            os.fsync(destination_fd)
        finally: os.close(destination_fd)
        if digestor.hexdigest() != expected["sha256"]: die("stage-copy drift for %s" % label)
    finally: os.close(source_fd)
    staged=file_info(destination)
    if any(staged[k] != expected[k] for k in ("sha256","size","mode")): die("stage-copy drift for %s" % label)
def regular_input(path, label):
    p=Path(path)
    if p.is_symlink() or not p.is_file(): die("%s is not a regular non-symlink file: %s" % (label,p))
    if p.stat().st_size > MAX_FILE: die("%s exceeds byte limit: %s" % (label,p))
    return p
def no_forbidden(value, label):
    lower=str(value).lower()
    if any(x in lower for x in FORBIDDEN): die("forbidden Google/SDK classification in %s" % label)
def case_unique(paths):
    seen=set()
    for p in paths:
        n=unicodedata.normalize("NFC",p).casefold()
        if n in seen: die("case-colliding path: %s" % p)
        seen.add(n)
def exact_keys(value, keys, label):
    if not isinstance(value,dict) or set(value) != set(keys): die("invalid exact schema for %s" % label)
def unique_paths(paths, label):
    if len(paths) != len(set(paths)): die("duplicate %s path" % label)
    case_unique(paths)
def assert_lock(lock):
    exact_keys(lock,{"schemaVersion","target","aosp","aemu","adb","scrcpy","repoTool"},"production source lock")
    if lock.get("schemaVersion") != 1: die("unsupported production source lock schema")
    exact_keys(lock.get("aosp"),{"manifestTag","manifestCommit","product","classification"},"AOSP source lock")
    exact_keys(lock.get("aemu"),{"version","commit","tree"},"AEMU source lock")
    exact_keys(lock.get("adb"),{"revision"},"adb source lock")
    exact_keys(lock.get("scrcpy"),{"version","commit"},"scrcpy source lock")
    exact_keys(lock.get("repoTool"),{"callerLockedRecordRequired"},"repo tool source lock")
    a=lock.get("aosp",{}); e=lock.get("aemu",{}); adb=lock.get("adb",{}); s=lock.get("scrcpy",{})
    values=(a.get("manifestTag"),a.get("manifestCommit"),a.get("product"),a.get("classification"),e.get("version"),e.get("commit"),e.get("tree"),adb.get("revision"),s.get("version"),s.get("commit"))
    expected=(PIN["aospManifestTag"],PIN["aospManifestCommit"],PIN["aospProduct"],"aosp-only","37.1.7",PIN["aemuRevision"],PIN["aemuTree"],PIN["adbRevision"],PIN["scrcpyVersion"],PIN["scrcpyRevision"])
    if values != expected or lock.get("target") != "macos/arm64" or lock["repoTool"]["callerLockedRecordRequired"] is not True: die("source lock does not match production Android 17 macos/arm64 identities")
def git_value(root, *args): return run(["git","-C",str(root),*args]).stdout.strip()
def git_clean(root):
    if git_value(root,"status","--porcelain=v1","--untracked-files=all"): die("dirty source checkout: %s" % root)
def preflight(args):
    lock=load_json(args.source_lock); assert_lock(lock)
    roots={"aosp":Path(args.aosp),"aemu":Path(args.aemu),"scrcpy":Path(args.scrcpy)}
    # repo workspaces intentionally contain linkfiles/symlinks; inspect their
    # declared Git projects instead of recursively treating the workspace root
    # as a standalone checkout.
    for key in ("aemu","scrcpy"):
        tree_no_symlinks(roots[key]); git_clean(roots[key])
    if git_value(roots["aemu"],"rev-parse","HEAD") != PIN["aemuRevision"]: die("AEMU commit is unlocked")
    if git_value(roots["aemu"],"rev-parse","HEAD^{tree}") != PIN["aemuTree"]: die("AEMU tree is unlocked")
    sub=git_value(roots["aemu"],"submodule","status","--recursive")
    if any(line.startswith(("-","+","U")) for line in sub.splitlines()): die("AEMU recursive submodule is uninitialized or dirty")
    if git_value(roots["scrcpy"],"rev-parse","HEAD") != PIN["scrcpyRevision"]: die("scrcpy commit is unlocked")
    repo=roots["aosp"] / ".repo" / "repo" / "repo"
    regular_input(repo,"fixed AOSP repo tool")
    repo_lock=load_json(args.repo_tool_lock)
    exact_keys(repo_lock,{"path","sha256","size"},"caller repo tool lock")
    if repo_lock["path"] != ".repo/repo/repo" or repo_lock["sha256"] != digest(repo) or repo_lock["size"] != repo.stat().st_size: die("fixed AOSP repo tool does not match caller locked record")
    manifest_checkout=roots["aosp"] / ".repo" / "manifests"
    git_clean(manifest_checkout)
    if git_value(manifest_checkout, "rev-parse","HEAD") != PIN["aospManifestCommit"]: die("AOSP manifest commit is unlocked")
    manifest=run([str(repo),"manifest","-r"],cwd=roots["aosp"]).stdout
    if not manifest.strip(): die("AOSP repo manifest -r is empty")
    if len(manifest.encode()) > MAX_JSON: die("resolved AOSP manifest exceeds evidence byte limit")
    try:
        doc=ET.fromstring(manifest)
        projects=[]
        for node in doc.findall(".//project"):
            project_path=node.get("path") or node.get("name")
            revision=node.get("revision")
            if project_path and revision: projects.append((project_path,revision))
    except ET.ParseError as e: die("resolved AOSP manifest is invalid XML: %s" % e)
    if not projects: die("resolved AOSP manifest has no pinned projects")
    unique_paths([p for p,_ in projects],"AOSP project")
    adb_projects=[r for p,r in projects if p == "packages/modules/adb"]
    if adb_projects != [PIN["adbRevision"]]: die("resolved AOSP manifest does not pin packages/modules/adb")
    for project_path, revision in projects:
        safe_rel(project_path)
        if not re.match(r"^[0-9a-f]{40}$",revision): die("resolved AOSP project has unpinned revision: %s" % project_path)
        checkout=roots["aosp"] / project_path
        if checkout.is_symlink() or not checkout.is_dir(): die("resolved AOSP project is missing or symlinked: %s" % project_path)
        git_clean(checkout)
        if git_value(checkout,"rev-parse","HEAD") != revision: die("AOSP project is not pinned to resolved manifest: %s" % project_path)
    evidence={"schemaVersion":1,"offline":True,"sourceLockSha256":digest(args.source_lock),"aospManifestCommit":PIN["aospManifestCommit"],"aospManifestResolved":manifest,"aospManifestResolvedSha256":digest_bytes(manifest.encode()),"repoToolSha256":digest(repo),"repoToolSize":repo.stat().st_size,"aemuRevision":PIN["aemuRevision"],"aemuTree":PIN["aemuTree"],"aemuSubmodules":sub.splitlines(),"scrcpyRevision":PIN["scrcpyRevision"]}
    write_canonical(args.output,evidence)
def require_evidence(evidence, lock_hash):
    exact_keys(evidence,{"schemaVersion","offline","sourceLockSha256","aospManifestCommit","aospManifestResolved","aospManifestResolvedSha256","repoToolSha256","repoToolSize","aemuRevision","aemuTree","aemuSubmodules","scrcpyRevision"},"source evidence")
    if evidence.get("schemaVersion") != 1 or evidence.get("offline") is not True or evidence.get("sourceLockSha256") != lock_hash: die("source evidence is dirty, unlocked, or does not bind source lock")
    for key in ("aospManifestCommit","aemuRevision","aemuTree","scrcpyRevision"):
        expected=PIN[{"aospManifestCommit":"aospManifestCommit","aemuRevision":"aemuRevision","aemuTree":"aemuTree","scrcpyRevision":"scrcpyRevision"}[key]]
        if evidence.get(key) != expected: die("source evidence has unlocked %s" % key)
    resolved=evidence.get("aospManifestResolved")
    if not isinstance(resolved,str) or not resolved or len(resolved.encode()) > MAX_JSON or evidence.get("aospManifestResolvedSha256") != digest_bytes(resolved.encode()): die("source evidence lacks bound recursive AOSP manifest")
    try:
        projects=[]
        for node in ET.fromstring(resolved).findall(".//project"):
            path=node.get("path") or node.get("name"); revision=node.get("revision")
            if not path or not revision or not re.match(r"^[0-9a-f]{40}$",revision): die("source evidence has unpinned AOSP project")
            safe_rel(path); projects.append(path)
        if not projects: die("source evidence has no resolved AOSP projects")
        unique_paths(projects,"source evidence AOSP project")
        if projects.count("packages/modules/adb") != 1: die("source evidence lacks unique packages/modules/adb project")
        adb_node=next(node for node in ET.fromstring(resolved).findall(".//project") if (node.get("path") or node.get("name")) == "packages/modules/adb")
        if adb_node.get("revision") != PIN["adbRevision"]: die("source evidence has unlocked adb revision")
    except ET.ParseError as e: die("source evidence has malformed resolved AOSP manifest: %s" % e)
    subs=evidence.get("aemuSubmodules")
    sub_paths=[]
    if not isinstance(subs,list): die("source evidence lacks exact recursive AEMU submodule revisions")
    for line in subs:
        if not isinstance(line,str) or not re.match(r"^ [0-9a-f]{40} [^ ]+( \(.+\))?$",line): die("source evidence has uninitialized or drifting AEMU submodule")
        sub_paths.append(line.split()[1])
    unique_paths(sub_paths,"AEMU submodule")
    if not isinstance(evidence.get("repoToolSha256"),str) or not HEX64.match(evidence["repoToolSha256"]) or not isinstance(evidence.get("repoToolSize"),int) or evidence["repoToolSize"] < 1: die("source evidence lacks fixed repo tool identity")
def declarations(args):
    dec=load_json(args.artifact_declaration)
    exact_keys(dec,{"schemaVersion","references","artifacts"},"artifact declaration")
    if dec.get("schemaVersion") != 1 or not isinstance(dec.get("artifacts"),list) or not isinstance(dec.get("references"),dict): die("invalid artifact declaration schema")
    refs=dec["references"]
    exact_keys(refs,{"sourceLock","sourceEvidence","toolchainEvidence","sbom","licenses","notice"},"artifact declaration references")
    for n in ("sourceLock","sourceEvidence","toolchainEvidence","sbom","licenses","notice"):
        safe_rel(refs.get(n,""))
    paths=[]
    input_paths=[]
    for a in dec["artifacts"]:
        exact_keys(a,{"input","path","role","executable","requiredArchitecture","sourceReference","licenseReference","noticeReference"},"artifact declaration entry")
        for key in ("input","path","role","sourceReference","licenseReference","noticeReference"):
            safe_rel(a.get(key,""))
        if not isinstance(a.get("role"),str) or not a["role"] or not isinstance(a.get("executable"),bool): die("artifact role/executable is invalid")
        if a.get("requiredArchitecture") not in (None,"arm64"): die("artifact architecture must be arm64")
        no_forbidden(" ".join(map(str,a.values())),a["path"]); paths.append(a["path"]); input_paths.append(a["input"])
    unique_paths(paths,"declaration output")
    unique_paths(input_paths,"declaration input")
    if set(refs.values()) - set(paths): die("provenance/SBOM/license references must be declared artifacts")
    return dec
def exact_declared_inputs(root, dec):
    actual={str(p.relative_to(root)) for p in tree_no_symlinks(root)}
    expected={a["input"] for a in dec["artifacts"]}
    if actual != expected: die("input closure contains undeclared or missing regular files")
def toolchain_evidence(path, root=None):
    tool=load_json(path)
    exact_keys(tool,{"schemaVersion","tools"},"toolchain evidence")
    if tool.get("schemaVersion") != 1 or not isinstance(tool["tools"],list) or not tool["tools"]: die("invalid toolchain evidence")
    names=[]
    for entry in tool["tools"]:
        exact_keys(entry,{"path","version","sha256","size","architecture"},"toolchain evidence entry")
        if not isinstance(entry["path"],str) or not entry["path"] or not isinstance(entry["version"],str) or not entry["version"] or not isinstance(entry["sha256"],str) or not HEX64.match(entry["sha256"]) or not isinstance(entry["size"],int) or entry["size"] < 0 or entry["architecture"] not in ("arm64","universal","host-tool"): die("invalid toolchain evidence entry")
        safe_rel(entry["path"]); names.append(entry["path"])
    unique_paths(names,"toolchain")
    if root is not None:
        actual={str(p.relative_to(root)) for p in tree_no_symlinks(root)}
        if actual != set(names): die("toolchain closure contains undeclared or missing regular files")
        for entry in tool["tools"]:
            info=file_info(Path(root)/entry["path"])
            if info["sha256"] != entry["sha256"] or info["size"] != entry["size"]: die("toolchain hash/size drift: %s" % entry["path"])
            if entry["architecture"] in ("arm64","universal"): macho_check(Path(root)/entry["path"],True)
    return tool
def create_attestation(args):
    lock=load_json(args.source_lock); assert_lock(lock); lock_hash=digest(args.source_lock)
    evidence=load_json(args.source_evidence); require_evidence(evidence,lock_hash)
    toolchain_evidence(args.toolchain_evidence,args.toolchain_root)
    dec=declarations(args); root=Path(args.input_root); exact_declared_inputs(root,dec)
    claims=[]
    for a in dec["artifacts"]:
        source=root / safe_rel(a["input"])
        info=file_info(source)
        claims.append({**a,**info})
    env=load_json(args.environment) if args.environment else {}
    if not isinstance(env,dict) or any(k not in ("SOURCE_DATE_EPOCH","DEVELOPER_DIR","SDKROOT","MACOSX_DEPLOYMENT_TARGET","PATH") for k in env) or any(not isinstance(v,str) or re.search(r"(token|secret|password|proxy)",k,re.I) for k,v in env.items()): die("environment is not a strict build allowlist")
    commands=args.build_command or []
    if not all(isinstance(x,str) and x and "\x00" not in x for x in commands): die("invalid build command record")
    regular_input(args.policy,"trusted-builders policy")
    template_claim=next((x for x in claims if x["path"] == args.default_template),None)
    if not template_claim: die("default template is not a declared artifact")
    att={"schemaVersion":1,"runtimeID":args.runtime_id,"targetPlatform":"macos","targetArchitecture":"arm64","aospProduct":PIN["aospProduct"],"sourceLockSha256":lock_hash,"sourceEvidenceSha256":digest(args.source_evidence),"toolchainEvidenceSha256":digest(args.toolchain_evidence),"artifactDeclarationSha256":digest(args.artifact_declaration),"trustedBuildersPolicySha256":digest(args.policy),"aospRevision":PIN["aospManifestCommit"],"aemuRevision":PIN["aemuRevision"],"adbRevision":PIN["adbRevision"],"scrcpyRevision":PIN["scrcpyRevision"],"scrcpyClientRevision":PIN["scrcpyRevision"],"scrcpyServerRevision":PIN["scrcpyRevision"],"defaultTemplateArtifact":args.default_template,"defaultTemplateDigest":template_claim["sha256"],"buildCommands":commands,"environment":env,"references":dec["references"],"envelope":ENVELOPE_PATHS,"artifacts":claims}
    if not re.match(r"^[A-Za-z0-9._-]{1,96}$",args.runtime_id): die("unsafe runtime ID")
    write_canonical(args.output,att)
def public_key_digest(path):
    # subprocess text mode is unsuitable for arbitrary DER; retrieve bytes separately.
    p=subprocess.run(["openssl","pkey","-pubin","-in",str(path),"-outform","DER"],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode: die("invalid public key: %s" % p.stderr.decode(errors="replace").strip())
    text=run(["openssl","rsa","-pubin","-in",str(path),"-text","-noout"]).stdout
    m=re.search(r"Public-Key:\s*\((\d+) bit\)",text)
    if not m or int(m.group(1)) < 2048: die("trusted builder key must be RSA-2048 or stronger")
    if "MODULUS:" not in text.upper() or "EXPONENT:" not in text.upper(): die("trusted builder key must be RSA")
    return digest_bytes(p.stdout)
def verify_signature(attestation, signature, public_key, policy):
    regular_input(attestation,"attestation")
    regular_input(signature,"signature")
    regular_input(public_key,"public key")
    pol=load_json(policy)
    exact_keys(pol,{"schemaVersion","algorithm","trustedPublicKeyDerSha256"},"trusted-builders policy")
    if pol.get("schemaVersion") != 1 or pol.get("algorithm") != "rsa-sha256" or not isinstance(pol.get("trustedPublicKeyDerSha256"),list) or len(pol["trustedPublicKeyDerSha256"]) != len(set(pol["trustedPublicKeyDerSha256"])) or any(not isinstance(x,str) or not HEX64.match(x) for x in pol["trustedPublicKeyDerSha256"]): die("invalid trusted-builders policy")
    key_hash=public_key_digest(public_key)
    if key_hash not in pol["trustedPublicKeyDerSha256"]: die("no trusted production builder key matches the attestation public key")
    run(["openssl","dgst","-sha256","-verify",str(public_key),"-signature",str(signature),str(attestation)])
    return key_hash
def verify_attestation(att, lock, lock_path, evidence_path, toolchain_path, toolchain_root=None):
    assert_lock(lock)
    require_evidence(load_json(evidence_path), digest(lock_path))
    toolchain_evidence(toolchain_path,toolchain_root)
    if att.get("schemaVersion") != 1 or att.get("targetPlatform") != "macos" or att.get("targetArchitecture") != "arm64" or att.get("aospProduct") != PIN["aospProduct"]: die("attestation target/product mismatch")
    if att.get("sourceLockSha256") != digest(lock_path) or att.get("sourceEvidenceSha256") != digest(evidence_path) or att.get("toolchainEvidenceSha256") != digest(toolchain_path): die("attestation source/toolchain digest drift")
    for k,v in (("aospRevision",PIN["aospManifestCommit"]),("aemuRevision",PIN["aemuRevision"]),("adbRevision",PIN["adbRevision"]),("scrcpyRevision",PIN["scrcpyRevision"]),("scrcpyClientRevision",PIN["scrcpyRevision"]),("scrcpyServerRevision",PIN["scrcpyRevision"])):
        if att.get(k)!=v: die("attestation revision mismatch: %s"%k)
    if att.get("scrcpyClientRevision") != att.get("scrcpyServerRevision"): die("mixed scrcpy client/server revisions")
    required={"schemaVersion","runtimeID","targetPlatform","targetArchitecture","aospProduct","sourceLockSha256","sourceEvidenceSha256","toolchainEvidenceSha256","artifactDeclarationSha256","trustedBuildersPolicySha256","aospRevision","aemuRevision","adbRevision","scrcpyRevision","scrcpyClientRevision","scrcpyServerRevision","defaultTemplateArtifact","defaultTemplateDigest","buildCommands","environment","references","envelope","artifacts"}
    exact_keys(att,required,"signed attestation")
    if not isinstance(att.get("artifacts"),list) or not isinstance(att.get("references"),dict): die("invalid signed artifact claims")
    exact_keys(att["references"],{"sourceLock","sourceEvidence","toolchainEvidence","sbom","licenses","notice"},"signed references")
    for ref in att["references"].values(): safe_rel(ref)
    claim_paths=[]
    artifact_keys={"input","path","role","executable","requiredArchitecture","sourceReference","licenseReference","noticeReference","sha256","size","mode"}
    if not isinstance(att["buildCommands"],list) or not all(isinstance(x,str) and x and "\x00" not in x for x in att["buildCommands"]): die("invalid signed build commands")
    if not isinstance(att["environment"],dict) or any(k not in ("SOURCE_DATE_EPOCH","DEVELOPER_DIR","SDKROOT","MACOSX_DEPLOYMENT_TARGET","PATH") or not isinstance(v,str) for k,v in att["environment"].items()): die("invalid signed environment")
    for claim in att["artifacts"]:
        exact_keys(claim,artifact_keys,"signed artifact claim")
        for key in ("input","path","sourceReference","licenseReference","noticeReference"): safe_rel(claim[key])
        if not isinstance(claim["role"],str) or not claim["role"] or not isinstance(claim["executable"],bool) or claim["requiredArchitecture"] not in (None,"arm64") or not isinstance(claim["sha256"],str) or not HEX64.match(claim["sha256"]) or not isinstance(claim["size"],int) or claim["size"] < 0 or not isinstance(claim["mode"],int) or claim["mode"] < 0 or claim["mode"] > 0o7777: die("invalid signed artifact claim fields")
        claim_paths.append(claim["path"])
    unique_paths(claim_paths,"signed claim")
    safe_rel(att["defaultTemplateArtifact"])
    if not isinstance(att["defaultTemplateDigest"],str) or not HEX64.match(att["defaultTemplateDigest"]): die("invalid signed default template digest")
    default_claim=next((x for x in att["artifacts"] if x["path"] == att["defaultTemplateArtifact"]),None)
    if not default_claim or default_claim["sha256"] != att["defaultTemplateDigest"]: die("signed default template is not an exact signed artifact")
    if not re.match(r"^[A-Za-z0-9._-]{1,96}$",str(att.get("runtimeID",""))): die("unsafe signed runtime ID")
    envelope=att.get("envelope")
    exact_keys(envelope,set(ENVELOPE_PATHS),"signed envelope")
    if envelope != ENVELOPE_PATHS: die("signed envelope paths are not fixed")
def is_macho(path):
    regular_input(path,"Mach-O input")
    with open(path,"rb") as f: magic=f.read(4)
    return magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca")
def macho_check(path, required, payload_root=None, declared=None):
    p=Path(path)
    if not required and not is_macho(p): return
    try: archs=run(["lipo","-archs",str(p)]).stdout.split()
    except GateError: die("required arm64 artifact is not a Mach-O: %s" % p)
    if "arm64" not in archs: die("artifact is not arm64: %s" % p)
    ident=run(["otool","-D",str(p)]).stdout.splitlines()[1:]
    install_ids={value.strip() for value in ident if value.strip()}
    output=run(["otool","-L",str(p)]).stdout.splitlines()[1:]
    for line in output:
        dep=line.strip().split(" ",1)[0]
        if dep in install_ids: continue
        if dep.startswith(("/usr/lib/","/System/Library/")):
            if ".." in PurePosixPath(dep).parts: die("unsafe Mach-O dependency escape: %s" % dep)
            continue
        if dep.startswith(("@rpath/","@loader_path/","@executable_path/")):
            if payload_root is None or declared is None: continue
            suffix=dep.split("/",1)[1]
            if ".." in PurePosixPath(suffix).parts: die("unsafe Mach-O dependency escape: %s" % dep)
            candidates=[]
            if dep.startswith("@loader_path/"): candidates=[p.parent / suffix]
            elif dep.startswith("@executable_path/"): candidates=[Path(payload_root) / suffix, Path(payload_root) / "tools" / suffix]
            else:
                load=run(["otool","-l",str(p)]).stdout
                rpaths=re.findall(r"path (.+?) \(offset",load)
                for r in rpaths:
                    if r.startswith("/") or ".." in PurePosixPath(r).parts: continue
                    if r == "@loader_path":
                        candidates.append(p.parent / suffix)
                    elif r.startswith("@loader_path/"):
                        candidates.append(p.parent / r.split("/",1)[1] / suffix)
                    elif r == "@executable_path":
                        candidates.append(Path(payload_root) / suffix)
                    elif r.startswith("@executable_path/"):
                        candidates.append(Path(payload_root) / r.split("/",1)[1] / suffix)
                    else:
                        # Bare relative rpaths are ambiguous and permit the
                        # process working directory to affect resolution.
                        die("unsafe Mach-O RPATH: %s" % r)
            if not any(c.is_file() and str(c.relative_to(payload_root)) in declared for c in candidates): die("missing or escaping Mach-O dependency closure: %s (candidates=%s)" % (dep, candidates))
            continue
        die("unsafe Mach-O dependency: %s" % dep)
    load=run(["otool","-l",str(p)]).stdout
    for value in re.findall(r"path (.+?) \(offset",load):
        if value.startswith("/") or ".." in PurePosixPath(value).parts or value not in ("@loader_path","@executable_path") and not value.startswith(("@loader_path/","@executable_path/")): die("unsafe Mach-O RPATH: %s" % value)
    # LC_ID_DYLIB is part of the dependency contract and may not introduce an
    # absolute non-system install name.
    for value in ident:
        value=value.strip()
        if ".." in PurePosixPath(value).parts:
            die("unsafe Mach-O install name escape: %s" % value)
        if value and not value.startswith(("@rpath/","@loader_path/","@executable_path/","/usr/lib/","/System/Library/")): die("unsafe Mach-O install name: %s" % value)
def add_generated(root, manifest_artifacts, rel, source_ref="provenance/source-lock.json"):
    p=root/rel; i=file_info(p); manifest_artifacts.append({"path":rel,**i,"role":"provenance","executable":False,"requiredArchitecture":None,"sourceReference":source_ref,"licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"})
def generated_record(root, rel):
    i=file_info(root/rel)
    return {"path":rel,"sha256":i["sha256"],"size":i["size"],"role":"provenance","executable":False,"requiredArchitecture":None,"sourceReference":"provenance/source-lock.json","licenseReference":"licenses/licenses.json","noticeReference":"licenses/NOTICE"}
def assemble(args):
    att_path=Path(args.attestation); verify_signature(att_path,args.signature,args.public_key,args.policy)
    att=load_json(att_path); lock=load_json(args.source_lock); verify_attestation(att,lock,args.source_lock,args.source_evidence,args.toolchain_evidence,args.toolchain_root)
    dec=declarations(argparse.Namespace(artifact_declaration=args.artifact_declaration)); root=Path(args.input_root); exact_declared_inputs(root,dec)
    if att.get("artifactDeclarationSha256") != digest(args.artifact_declaration): die("signed artifact declaration digest drift")
    if att.get("trustedBuildersPolicySha256") != digest(args.policy): die("signed trusted-builders policy digest drift")
    dest=Path(args.destination)
    if dest.exists() or dest.is_symlink(): die("destination already exists; atomic create-new required")
    parent=dest.parent; parent.mkdir(parents=True,exist_ok=True)
    if parent.is_symlink() or not parent.is_dir(): die("destination parent is not a real directory")
    stage=Path(tempfile.mkdtemp(prefix=".AndroidRuntime-stage-",dir=parent))
    os.chmod(stage, 0o700)
    try:
        claims={a["path"]:a for a in att["artifacts"]}; artifacts=[]
        if set(claims) != {a["path"] for a in dec["artifacts"]}: die("signed claims do not exactly match declaration")
        for declared in dec["artifacts"]:
            claim=claims[declared["path"]]; src=regular_input(root/safe_rel(declared["input"]),"declared artifact")
            if any(claim.get(k) != declared.get(k) for k in ("input","path","role","executable","requiredArchitecture","sourceReference","licenseReference","noticeReference")): die("signed artifact metadata does not match declaration: %s" % declared["path"])
            out=stage/safe_rel(declared["path"]); out.parent.mkdir(parents=True,exist_ok=True); copy_verified_file(src,out,claim,"declared artifact: %s" % declared["path"])
            artifact={k:claim[k] for k in ("path","sha256","size","role","executable","requiredArchitecture","sourceReference","licenseReference","noticeReference")}; artifacts.append(artifact)
        # Dependency closure can reference an artifact declared later, so only
        # inspect after the complete declared set has been copied into staging.
        for artifact in artifacts:
            out=stage/artifact["path"]
            macho_check(out, artifact["executable"] or artifact["requiredArchitecture"] == "arm64" or is_macho(out), stage, set(claims))
        generated={"provenance/build-attestation.json":att_path,"provenance/build-attestation.sig":Path(args.signature),"provenance/builder-public-key.pem":Path(args.public_key),"provenance/trusted-builders-policy.json":Path(args.policy),"provenance/artifact-declaration.json":Path(args.artifact_declaration)}
        if att["envelope"] != ENVELOPE_PATHS or generated != {path: {"provenance/build-attestation.json":att_path,"provenance/build-attestation.sig":Path(args.signature),"provenance/builder-public-key.pem":Path(args.public_key),"provenance/trusted-builders-policy.json":Path(args.policy),"provenance/artifact-declaration.json":Path(args.artifact_declaration)}[path] for path in ENVELOPE_PATHS.values()}: die("signed envelope paths are not exact")
        if att["references"] != dec["references"]: die("signed references do not exactly match declaration")
        for rel,src in generated.items():
            regular_input(src,"generated envelope input")
            out=stage/rel; out.parent.mkdir(parents=True,exist_ok=True)
            generated_expected=file_info(src)
            copy_verified_file(src,out,generated_expected,"generated envelope: %s" % rel)
        for rel in generated: artifacts.append(generated_record(stage,rel))
        refs=att["references"]
        manifest={"schemaVersion":1,"runtimeID":att["runtimeID"],"targetPlatform":"macos","targetArchitecture":"arm64","sourceBuilt":True,"immutableRoot":"AndroidRuntime","artifacts":sorted(artifacts,key=lambda x:x["path"]),"defaultTemplateArtifact":att["defaultTemplateArtifact"],"defaultTemplateDigest":att["defaultTemplateDigest"],"aemuRevision":PIN["aemuRevision"],"aospRevision":PIN["aospManifestCommit"],"adbRevision":PIN["adbRevision"],"scrcpyRevision":PIN["scrcpyRevision"],"buildAttestationReference":"provenance/build-attestation.json","toolchainAttestationReference":refs["toolchainEvidence"],"sbomReference":refs["sbom"],"licensesReference":refs["licenses"],"noticeReference":refs["notice"]}
        no_forbidden(canonical(manifest).decode(),"manifest")
        write_canonical(stage/"manifest.json",manifest); tree_no_symlinks(stage)
        # Re-verify the complete staged closure under the same supplied policy
        # before the atomic publication step.
        verify_payload(argparse.Namespace(payload=stage, policy=args.policy, swift_verifier=None))
        os.rename(stage,dest)
    except Exception:
        shutil.rmtree(stage,ignore_errors=True); raise
def verify_payload(args):
    root=Path(args.payload); files=tree_no_symlinks(root); manifest=load_json(root/"manifest.json")
    manifest_top={"schemaVersion","runtimeID","targetPlatform","targetArchitecture","sourceBuilt","immutableRoot","artifacts","defaultTemplateArtifact","defaultTemplateDigest","aemuRevision","aospRevision","adbRevision","scrcpyRevision","buildAttestationReference","toolchainAttestationReference","sbomReference","licensesReference","noticeReference"}
    exact_keys(manifest,manifest_top,"RuntimeManifest")
    if manifest.get("schemaVersion") != 1 or manifest.get("immutableRoot") != "AndroidRuntime" or manifest.get("targetPlatform")!="macos" or manifest.get("targetArchitecture")!="arm64" or manifest.get("sourceBuilt") is not True: die("invalid manifest identity")
    no_forbidden(canonical(manifest).decode(),"manifest")
    for field in ("defaultTemplateArtifact","buildAttestationReference","toolchainAttestationReference","sbomReference","licensesReference","noticeReference"):
        safe_rel(manifest.get(field,""))
    att=root/safe_rel(manifest["buildAttestationReference"]); sig=regular_input(root/"provenance/build-attestation.sig","signature"); pub=regular_input(root/"provenance/builder-public-key.pem","public key")
    verify_signature(att,sig,pub,args.policy)
    lock_ref=next((x.get("path") for x in manifest.get("artifacts",[]) if x.get("path") == "provenance/source-lock.json"),None)
    if not lock_ref: die("manifest lacks source lock artifact")
    lock=load_json(root/lock_ref)
    evidence_ref=next((x.get("path") for x in manifest["artifacts"] if x.get("path") == "provenance/source-evidence.json"),None)
    tool_ref=manifest.get("toolchainAttestationReference")
    if not evidence_ref or not tool_ref: die("manifest lacks source/toolchain evidence")
    att_obj=load_json(att); verify_attestation(att_obj,lock,root/lock_ref,root/evidence_ref,root/tool_ref)
    envelope=att_obj["envelope"]
    if att_obj.get("trustedBuildersPolicySha256") != digest(args.policy): die("signed trusted-builders policy digest drift")
    if digest(root/envelope["policy"]) != digest(args.policy): die("embedded trusted-builders policy drift")
    if att_obj.get("artifactDeclarationSha256") != digest(root/envelope["declaration"]): die("embedded artifact declaration drift")
    embedded_declaration=declarations(argparse.Namespace(artifact_declaration=root/envelope["declaration"]))
    if att_obj["references"] != embedded_declaration["references"]: die("embedded declaration references do not match signed attestation")
    if manifest["runtimeID"] != att_obj["runtimeID"]: die("manifest runtime ID does not match signed attestation")
    for field, signed in (("aospRevision","aospRevision"),("aemuRevision","aemuRevision"),("adbRevision","adbRevision"),("scrcpyRevision","scrcpyRevision")):
        if manifest[field] != att_obj[signed]: die("manifest revision does not match signed attestation: %s" % field)
    for field, signed in (("toolchainAttestationReference","toolchainEvidence"),("sbomReference","sbom"),("licensesReference","licenses"),("noticeReference","notice")):
        if manifest[field] != att_obj["references"][signed]: die("manifest reference does not match signed attestation: %s" % field)
    if manifest["buildAttestationReference"] != envelope["attestation"]: die("manifest attestation reference does not match signed envelope")
    if manifest["defaultTemplateArtifact"] != att_obj["defaultTemplateArtifact"] or manifest["defaultTemplateDigest"] != att_obj["defaultTemplateDigest"]: die("manifest default template does not match signed attestation")
    if not re.match(r"^[A-Za-z0-9._-]{1,96}$",str(manifest.get("runtimeID",""))): die("unsafe manifest runtime ID")
    artifacts=manifest.get("artifacts",[]); paths=[]
    manifest_keys={"path","sha256","size","role","executable","requiredArchitecture","sourceReference","licenseReference","noticeReference"}
    for a in artifacts:
        exact_keys(a,manifest_keys,"manifest artifact")
        for k in ("path","sourceReference","licenseReference","noticeReference"): safe_rel(a.get(k,""))
        if not isinstance(a["sha256"],str) or not HEX64.match(a["sha256"]) or not isinstance(a["size"],int) or a["size"] < 0 or not isinstance(a["role"],str) or not a["role"] or not isinstance(a["executable"],bool) or a["requiredArchitecture"] not in (None,"arm64"): die("invalid manifest artifact fields")
        paths.append(a["path"]); no_forbidden(" ".join(map(str,a.values())),a["path"])
    unique_paths(paths,"manifest artifact")
    actual={str(p.relative_to(root)) for p in files}; expected=set(paths)|{"manifest.json"}
    if actual != expected: die("manifest closure mismatch (missing or undeclared file)")
    by={a["path"]:a for a in artifacts}
    for ref in (manifest.get("defaultTemplateArtifact"),manifest.get("buildAttestationReference"),manifest.get("toolchainAttestationReference"),manifest.get("sbomReference"),manifest.get("licensesReference"),manifest.get("noticeReference")):
        if ref not in by: die("manifest reference is not declared: %s" % ref)
    for a in artifacts:
        info=file_info(root/a["path"])
        if info["sha256"] != a.get("sha256") or info["size"] != a.get("size"): die("artifact hash/size drift: %s"%a["path"])
        if bool(info["mode"] & 0o111) != a.get("executable"): die("artifact executable mode drift: %s"%a["path"])
        macho_check(root/a["path"],a.get("executable") or a.get("requiredArchitecture")=="arm64" or is_macho(root/a["path"]),root,set(paths))
    signed={a["path"]:a for a in att_obj["artifacts"]}
    generated={envelope["attestation"],envelope["signature"],envelope["publicKey"],envelope["policy"],envelope["declaration"]}
    for path, record in by.items():
        if path in signed:
            claim=signed[path]
            if file_info(root/path)["mode"] != claim.get("mode"): die("manifest artifact mode does not match signed claim: %s" % path)
            for key in ("path","sha256","size","role","executable","requiredArchitecture","sourceReference","licenseReference","noticeReference"):
                if record.get(key) != claim.get(key): die("manifest artifact does not match signed claim: %s" % path)
        elif path not in generated:
            die("manifest artifact is not cryptographically bound by signed claims: %s" % path)
        else:
            # Envelope bytes have a separate cryptographic relationship: the
            # signature verifies the attestation; the signed attestation pins
            # the public-key policy/declaration and fixed envelope paths.
            if path not in envelope.values(): die("undeclared generated envelope artifact")
            if record != generated_record(root,path): die("generated manifest metadata does not equal recomputed envelope record: %s" % path)
    for a in artifacts:
        for ref in (a["sourceReference"],a["licenseReference"],a["noticeReference"]):
            if ref not in by: die("artifact reference is not a declared payload artifact: %s" % ref)
    template=by.get(manifest.get("defaultTemplateArtifact"))
    if not template or template["sha256"] != manifest.get("defaultTemplateDigest"): die("default template hash drift")
    if args.swift_verifier: run([args.swift_verifier,str(root)])
def parser():
    p=argparse.ArgumentParser(description=__doc__); q=p.add_subparsers(dest="command",required=True)
    s=q.add_parser("preflight-sources",help="offline inspect pinned source roots"); s.add_argument("--source-lock",required=True); s.add_argument("--repo-tool-lock",required=True); s.add_argument("--aosp",required=True); s.add_argument("--aemu",required=True); s.add_argument("--scrcpy",required=True); s.add_argument("--output",required=True); s.set_defaults(func=preflight)
    s=q.add_parser("create-attestation",help="canonical unsigned claims from declared inputs");
    for n in ("source-lock","source-evidence","toolchain-evidence","toolchain-root","artifact-declaration","input-root","output","runtime-id","policy","default-template"): s.add_argument("--"+n,required=True)
    s.add_argument("--environment"); s.add_argument("--build-command",action="append"); s.set_defaults(func=create_attestation)
    s=q.add_parser("assemble",help="authenticate and atomically assemble AndroidRuntime");
    for n in ("attestation","signature","public-key","policy","source-lock","source-evidence","toolchain-evidence","toolchain-root","artifact-declaration","input-root","destination"): s.add_argument("--"+n,required=True)
    s.set_defaults(func=assemble)
    s=q.add_parser("verify-payload",help="independently reverify payload provenance and closure"); s.add_argument("--payload",required=True); s.add_argument("--policy",required=True); s.add_argument("--swift-verifier"); s.set_defaults(func=verify_payload)
    return p
def main():
    try:
        args=parser().parse_args()
        args.func(args)
    except GateError as e: print("runtime-pipeline: ERROR: %s"%e,file=sys.stderr); return 1
    except KeyboardInterrupt: return 130
    return 0
if __name__ == "__main__": sys.exit(main())

import CloudAndxClientCore
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: CloudAndxRuntimeVerifier <AndroidRuntime-root>\n", stderr)
    exit(64)
}
do {
    let identity = try RuntimeManifestVerifier.loadAndVerify(at: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("runtime_id=\(identity.runtimeID)")
    print("manifest_digest=\(identity.manifestDigest)")
    print("template_digest=\(identity.templateDigest)")
} catch {
    fputs("CloudAndx runtime verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CloudAndxClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CloudAndxClientCore", targets: ["CloudAndxClientCore"]),
        .executable(name: "CloudAndxClient", targets: ["CloudAndxClient"]),
        .executable(name: "CloudAndxCapabilityAgent", targets: ["CloudAndxCapabilityAgent"]),
        .executable(name: "CloudAndxDisplaySeamTests", targets: ["CloudAndxDisplaySeamTests"]),
    ],
    targets: [
        .target(name: "CloudAndxClientCore"),
        .executableTarget(
            name: "CloudAndxClient",
            dependencies: ["CloudAndxClientCore"]
        ),
        .executableTarget(
            name: "CloudAndxCapabilityAgent",
            dependencies: ["CloudAndxClientCore"],
            path: "Sources/CloudAndxCapabilityAgent"
        ),
        .executableTarget(
            name: "CloudAndxClientCoreTests",
            dependencies: ["CloudAndxClientCore"],
            path: "Tests/CloudAndxClientCoreTests"
        ),
        .executableTarget(
            name: "CloudAndxDisplaySeamTests",
            dependencies: ["CloudAndxClientCore"],
            path: "Tests/CloudAndxDisplaySeamTests"
        ),
        .executableTarget(
            name: "CloudAndxRuntimeVerifier",
            dependencies: ["CloudAndxClientCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

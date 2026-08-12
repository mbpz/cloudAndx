// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CloudAndxClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CloudAndxClientCore", targets: ["CloudAndxClientCore"]),
        .executable(name: "CloudAndxClient", targets: ["CloudAndxClient"]),
    ],
    targets: [
        .target(name: "CloudAndxClientCore"),
        .executableTarget(
            name: "CloudAndxClient",
            dependencies: ["CloudAndxClientCore"]
        ),
        .executableTarget(
            name: "CloudAndxClientCoreTests",
            dependencies: ["CloudAndxClientCore"],
            path: "Tests/CloudAndxClientCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)

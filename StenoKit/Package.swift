// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StenoKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "StenoKit",
            targets: ["StenoKit"]
        ),
        .executable(
            name: "StenoBenchmarkCLI",
            targets: ["StenoBenchmarkCLI"]
        ),
    ],
    targets: [
        .target(
            name: "StenoKit"
        ),
        .target(
            name: "StenoBenchmarkCore",
            dependencies: ["StenoKit"]
        ),
        .executableTarget(
            name: "StenoBenchmarkCLI",
            dependencies: ["StenoBenchmarkCore"]
        ),
        .testTarget(
            name: "StenoKitTests",
            dependencies: ["StenoKit"]
        ),
        .testTarget(
            name: "StenoBenchmarkCoreTests",
            dependencies: ["StenoBenchmarkCore"]
        ),
    ]
)

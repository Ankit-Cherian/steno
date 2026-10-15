// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StenoKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "StenoKit",
            targets: ["StenoKit"]
        ),
        .library(
            name: "StenoKitTestSupport",
            targets: ["StenoKitTestSupport"]
        ),
        .library(
            name: "StenoBenchmarkCore",
            targets: ["StenoBenchmarkCore"]
        ),
        .executable(
            name: "StenoBenchmarkCLI",
            targets: ["StenoBenchmarkCLI"]
        ),
        .executable(
            name: "StenoIconRenderer",
            targets: ["StenoIconRenderer"]
        ),
    ],
    targets: [
        .target(
            name: "StenoKit",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "StenoBenchmarkCore",
            dependencies: ["StenoKit"]
        ),
        .target(
            name: "StenoKitTestSupport",
            dependencies: ["StenoKit"]
        ),
        .executableTarget(
            name: "StenoBenchmarkCLI",
            dependencies: ["StenoBenchmarkCore"]
        ),
        .executableTarget(
            name: "StenoIconRenderer",
            dependencies: ["StenoKit"]
        ),
        .testTarget(
            name: "StenoKitTests",
            dependencies: ["StenoKit", "StenoKitTestSupport"]
        ),
        .testTarget(
            name: "StenoBenchmarkCoreTests",
            dependencies: ["StenoBenchmarkCore"]
        ),
        .testTarget(
            name: "StenoBenchmarkCLITests",
            dependencies: ["StenoBenchmarkCLI"]
        ),
    ]
)

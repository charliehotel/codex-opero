// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "codex-opero",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexOperoCore",
            targets: ["QuotaCore"]
        ),
        .executable(
            name: "codex-opero",
            targets: ["QuotaPeekMenu"]
        ),
        .executable(
            name: "codex-opero-cli",
            targets: ["QuotaPeekCLI"]
        ),
    ],
    targets: [
        .target(
            name: "QuotaCore"
        ),
        .executableTarget(
            name: "QuotaPeekMenu",
            dependencies: ["QuotaCore"]
        ),
        .executableTarget(
            name: "QuotaPeekCLI",
            dependencies: ["QuotaCore"]
        ),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore"]
        ),
    ]
)

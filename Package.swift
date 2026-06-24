// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTokenMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TokenUsageCore",
            targets: ["TokenUsageCore"]
        ),
        .executable(
            name: "CodexTokenMenuBar",
            targets: ["TokenUsageMenuBar"]
        ),
        .executable(
            name: "TokenUsageCoreTestRunner",
            targets: ["TokenUsageCoreTestRunner"]
        )
    ],
    targets: [
        .target(
            name: "TokenUsageCore"
        ),
        .executableTarget(
            name: "TokenUsageMenuBar",
            dependencies: ["TokenUsageCore"]
        ),
        .executableTarget(
            name: "TokenUsageCoreTestRunner",
            dependencies: ["TokenUsageCore"]
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPTUsageTracker",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "GPTUsageTracker",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/GPTSessionPinger",
            linkerSettings: []
        ),
        .testTarget(
            name: "GPTUsageTrackerTests",
            dependencies: ["GPTUsageTracker"],
            path: "Tests/GPTSessionPingerTests"
        )
    ]
)

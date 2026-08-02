// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPTUsageTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GPTUsageTracker",
            path: "Sources/GPTSessionPinger",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "GPTUsageTrackerTests",
            dependencies: ["GPTUsageTracker"],
            path: "Tests/GPTSessionPingerTests"
        )
    ]
)

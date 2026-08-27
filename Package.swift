// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CombinedSessionTracker",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0")
    ],
    targets: [
        .target(
            name: "TrackerDesignSystem",
            path: "Sources/TrackerDesignSystem"
        ),
        .target(
            name: "GPTTrackerFeature",
            dependencies: ["TrackerDesignSystem"],
            path: "Sources/GPTSessionPinger",
            exclude: ["App.swift"]
        ),
        .executableTarget(
            name: "CombinedSessionTracker",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                "TrackerDesignSystem",
                "GPTTrackerFeature"
            ],
            path: "Sources/ClaudeSessionPinger",
            linkerSettings: []
        ),
        .executableTarget(
            name: "SessionPingerWakeHelper",
            path: "Sources/SessionPingerWakeHelper",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "CombinedSessionTrackerTests",
            dependencies: ["CombinedSessionTracker"],
            path: "Tests/ClaudeSessionPingerTests"
        ),
        .testTarget(
            name: "GPTTrackerFeatureTests",
            dependencies: ["GPTTrackerFeature"],
            path: "Tests/GPTSessionPingerTests"
        )
    ]
)

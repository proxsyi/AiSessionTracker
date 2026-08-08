// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSessionPinger",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSessionPinger",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
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
            name: "ClaudeSessionPingerTests",
            dependencies: ["ClaudeSessionPinger"],
            path: "Tests/ClaudeSessionPingerTests"
        )
    ]
)

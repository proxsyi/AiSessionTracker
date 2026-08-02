// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPTSessionPinger",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GPTSessionPinger",
            path: "Sources/GPTSessionPinger",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
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
            name: "GPTSessionPingerTests",
            dependencies: ["GPTSessionPinger"],
            path: "Tests/GPTSessionPingerTests"
        )
    ]
)

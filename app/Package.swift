// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MiragePlay",
    platforms: [.macOS("15.0")],
    products: [
        .executable(
            name: "MiragePlay",
            targets: ["AppShell"]
        )
    ],
    targets: [
        .target(name: "SharedTypes", path: "Sources/SharedTypes"),
        .target(name: "Localization", path: "Sources/Localization"),
        .executableTarget(
            name: "AppShell",
            dependencies: [
                "ContainerKit", "ReceiverKit", "ConfigEngine",
                "SleepGuard", "SessionNotifier", "SettingsUI",
                "core-bridge", "Localization"
            ],
            path: "Sources/AppShell"
        ),
        .target(
            name: "ContainerKit",
            dependencies: ["ReceiverKit", "ConfigEngine", "SharedTypes"],
            path: "Sources/ContainerKit"
        ),
        .target(
            name: "ReceiverKit",
            dependencies: ["SharedTypes"],
            path: "Sources/ReceiverKit"
        ),
        .target(
            name: "ConfigEngine",
            dependencies: ["SharedTypes"],
            path: "Sources/ConfigEngine"
        ),
        .target(name: "SleepGuard", path: "Sources/SleepGuard"),
        .target(
            name: "SessionNotifier",
            dependencies: ["ReceiverKit", "Localization"],
            path: "Sources/SessionNotifier"
        ),
        .target(
            name: "core-bridge",
            dependencies: ["ReceiverKit", "ConfigEngine", "SharedTypes"],
            path: "Sources/core-bridge"
        ),
        .target(
            name: "SettingsUI",
            dependencies: ["ConfigEngine", "SharedTypes", "ReceiverKit", "Localization"],
            path: "Sources/SettingsUI"
        ),
        .executableTarget(
            name: "ConfigEngineSelfTest",
            dependencies: ["ConfigEngine", "SharedTypes"],
            path: "Tests/ConfigEngineSelfTest"
        ),
        .executableTarget(
            name: "LocalizationSelfTest",
            dependencies: ["Localization"],
            path: "Tests/LocalizationSelfTest"
        ),
    ]
)

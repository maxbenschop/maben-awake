// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sleepwalker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Sleepwalker",
            path: "Sources/Sleepwalker",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "SleepwalkerHook",
            path: "Sources/SleepwalkerHook"
        ),
        .executableTarget(
            name: "SleepwalkerFailsafe",
            path: "Sources/SleepwalkerFailsafe",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
    ]
)

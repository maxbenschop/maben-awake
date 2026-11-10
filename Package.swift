// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MabenAwake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MabenAwake",
            path: "Sources/MabenAwake",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "MabenAwakeHook",
            path: "Sources/MabenAwakeHook"
        ),
        .executableTarget(
            name: "MabenAwakeFailsafe",
            path: "Sources/MabenAwakeFailsafe",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
    ]
)

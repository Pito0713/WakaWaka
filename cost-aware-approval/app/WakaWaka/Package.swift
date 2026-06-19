// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WakaWaka",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WakaWaka",
            path: "Sources/WakaWaka",
            swiftSettings: [
                // MVP: relax strict concurrency to focus on functionality
                .unsafeFlags(["-strict-concurrency=minimal"])
            ],
            linkerSettings: [
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)

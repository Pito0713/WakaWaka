// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CostNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CostNotch",
            path: "Sources/CostNotch",
            swiftSettings: [
                // MVP: relax strict concurrency to focus on functionality
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        )
    ]
)

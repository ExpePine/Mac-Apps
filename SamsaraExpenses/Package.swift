// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SamsaraExpenses",
    platforms: [.macOS(.v13)],
    targets: [
        // CSV parsing, models and analytics. No UI, so it is unit-tested on CI.
        .target(
            name: "SamsaraCore",
            path: "Sources/SamsaraCore"
        ),
        // The SwiftUI app: auto-download from the Samsara page, dashboard, insights.
        .executableTarget(
            name: "SamsaraExpenses",
            dependencies: ["SamsaraCore"],
            path: "Sources/SamsaraExpenses"
        ),
        .testTarget(
            name: "SamsaraCoreTests",
            dependencies: ["SamsaraCore"],
            path: "Tests/SamsaraCoreTests"
        )
    ]
)

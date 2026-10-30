// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAlerts",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "agentalerts", targets: ["AgentAlertsCLI"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0")
    ],
    targets: [
        .target(name: "AgentAlertsCore"),
        .executableTarget(
            name: "AgentAlertsCLI",
            dependencies: ["AgentAlertsCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "AgentAlertsCoreTests", dependencies: ["AgentAlertsCore"])
    ]
)

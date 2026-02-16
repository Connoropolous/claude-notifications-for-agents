// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeWebhooks",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeWebhooks",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources"
        ),
    ]
)

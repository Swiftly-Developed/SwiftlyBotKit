// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickStart",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "QuickStart",
            dependencies: [
                .product(name: "SwiftlyBotKit", package: "SwiftlyBotKit"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
            ]
        ),
    ]
)

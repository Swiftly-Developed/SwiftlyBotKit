// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftlyBotKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftlyBotKit",
            targets: ["SwiftlyBotKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.48.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.28.0"),
        .package(url: "https://github.com/elementary-swift/elementary.git", from: "0.6.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "SwiftlyBotKit",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "Elementary", package: "elementary"),
            ]
        ),
        .testTarget(
            name: "SwiftlyBotKitTests",
            dependencies: [
                "SwiftlyBotKit",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)

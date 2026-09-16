// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "kbbs",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "VersionGenTool"
        ),
        .plugin(
            name: "VersionGenPlugin",
            capability: .buildTool(),
            dependencies: [
                "VersionGenTool",
            ]
        ),
        .executableTarget(
            name: "kbbs",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            plugins: [
                .plugin(name: "VersionGenPlugin"),
            ]
        ),
        .testTarget(
            name: "kbbsTests",
            dependencies: ["kbbs"]
        ),
    ]
)

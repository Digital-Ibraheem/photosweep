// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoSweep",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "photosweep", targets: ["PhotoSweepCLI"]),
        .library(name: "PhotoSweepCore", targets: ["PhotoSweepCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "PhotoSweepCore"),
        .executableTarget(
            name: "PhotoSweepCLI",
            dependencies: [
                "PhotoSweepCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PhotoSweepCoreTests", dependencies: ["PhotoSweepCore"]),
    ]
)

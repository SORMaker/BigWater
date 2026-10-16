// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BigWater",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BigWater", targets: ["BigWater"]),
        .executable(name: "BigWaterArtwork", targets: ["BigWaterArtwork"]),
        .executable(name: "BigWaterChecks", targets: ["BigWaterChecks"]),
        .executable(name: "BigWaterSessionChecks", targets: ["BigWaterSessionChecks"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "BigWaterCore"),
        .target(name: "BigWaterArt", dependencies: ["BigWaterCore"]),
        // Menu bar, settings, storage and desktop windows. A library so the
        // session checks can drive the real app classes.
        .target(name: "BigWaterApp", dependencies: [
            "BigWaterCore", "BigWaterArt", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]),
        .executableTarget(name: "BigWater", dependencies: ["BigWaterApp"]),
        .executableTarget(name: "BigWaterArtwork", dependencies: ["BigWaterCore", "BigWaterArt"]),
        // Standalone check runners also work with Command Line Tools, where
        // XCTest and Swift Testing are not installed.
        .executableTarget(name: "BigWaterChecks", dependencies: ["BigWaterCore", "BigWaterArt"],
                          path: "Tests/BigWaterCoreTests"),
        // Uses `@testable import BigWaterApp`, so it builds in debug only.
        .executableTarget(name: "BigWaterSessionChecks",
                          dependencies: ["BigWaterCore", "BigWaterArt", "BigWaterApp"],
                          path: "Tests/BigWaterSessionChecks")
    ]
)

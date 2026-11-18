// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BigWater",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BigWater", targets: ["BigWater"]),
        .executable(name: "BigWaterArtwork", targets: ["BigWaterArtwork"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // Rules and state: time, hours, the countdown, the drink log, the
        // reminder's own life cycle and where its parts sit. No AppKit.
        .target(name: "BigWaterCore"),
        // Turns what the core describes into pixels.
        .target(name: "BigWaterArt", dependencies: ["BigWaterCore"]),
        // The menu bar app. A library so the tests can drive the real model.
        .target(name: "BigWaterApp", dependencies: [
            "BigWaterCore", "BigWaterArt", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]),
        .executableTarget(name: "BigWater", dependencies: ["BigWaterApp"]),
        .executableTarget(name: "BigWaterArtwork", dependencies: ["BigWaterCore", "BigWaterArt"]),
        // A plain executable rather than a test target: it runs with only the
        // Command Line Tools installed, where XCTest and Swift Testing are
        // not available. It uses `@testable import`, so it builds in debug only.
        .executableTarget(name: "BigWaterTests", dependencies: ["BigWaterCore", "BigWaterArt", "BigWaterApp"],
                          path: "Tests/BigWaterTests")
    ]
)

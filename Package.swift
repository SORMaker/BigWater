// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BigWater",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BigWater", targets: ["BigWater"]),
        .executable(name: "BigWaterArtwork", targets: ["BigWaterArtwork"]),
        .executable(name: "BigWaterChecks", targets: ["BigWaterChecks"])
    ],
    targets: [
        .target(name: "BigWaterCore"),
        .target(name: "BigWaterArt", dependencies: ["BigWaterCore"]),
        .executableTarget(name: "BigWater", dependencies: ["BigWaterCore", "BigWaterArt"]),
        .executableTarget(name: "BigWaterArtwork", dependencies: ["BigWaterCore", "BigWaterArt"]),
        // A standalone check runner also works with Command Line Tools, where
        // XCTest and Swift Testing are not installed.
        .executableTarget(name: "BigWaterChecks", dependencies: ["BigWaterCore", "BigWaterArt"], path: "Tests/BigWaterCoreTests")
    ]
)

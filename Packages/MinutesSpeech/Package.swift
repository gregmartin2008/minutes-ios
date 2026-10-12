// swift-tools-version: 5.9
import PackageDescription

// On-device transcription and speaker separation for Minutes, built on FluidAudio's Core ML models.
// Apple platforms only. `minutes-bench` runs the same code path on a Mac to measure accuracy.
let package = Package(
    name: "MinutesSpeech",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MinutesSpeech", targets: ["MinutesSpeech"]),
        .executable(name: "minutes-bench", targets: ["minutes-bench"]),
    ],
    dependencies: [
        .package(path: "../MinutesCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .target(
            name: "MinutesSpeech",
            dependencies: [
                .product(name: "MinutesCore", package: "MinutesCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MinutesSpeech"
        ),
        .executableTarget(
            name: "minutes-bench",
            dependencies: [
                "MinutesSpeech", .product(name: "MinutesCore", package: "MinutesCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/minutes-bench"
        ),
    ],
    swiftLanguageVersions: [.v5]
)

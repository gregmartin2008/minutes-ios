// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift logic for Minutes: transcript assembly, voice matching, notes orchestration,
// email (MIME + SMTP), storage. Nothing here needs an Apple-only framework except the
// optional Network transport, so the tests run on any platform.
let package = Package(
    name: "MinutesCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MinutesCore", targets: ["MinutesCore"])
    ],
    targets: [
        .target(name: "MinutesCore", path: "Sources/MinutesCore"),
        .testTarget(
            name: "MinutesCoreTests",
            dependencies: ["MinutesCore"],
            path: "Tests/MinutesCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)

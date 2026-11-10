// swift-tools-version: 5.9
// Re-assembles published benchmark results from their words and speaker turns, so a change to
// how words are given to speakers can be scored in minutes on any machine with Swift, without
// running the speech models again. See the README, "Benchmark".
import PackageDescription

let package = Package(
    name: "reassemble",
    dependencies: [.package(path: "../../../Packages/MinutesCore")],
    targets: [
        .executableTarget(
            name: "reassemble", dependencies: [.product(name: "MinutesCore", package: "MinutesCore")], path: "Sources/reassemble")
    ]
)

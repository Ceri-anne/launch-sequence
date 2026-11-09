// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "launch-sequence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "launchseq", targets: ["launchseq"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "launchseq",
            dependencies: [
                "LaunchSequenceCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "LaunchSequenceCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .testTarget(
            name: "LaunchSequenceCoreTests",
            dependencies: ["LaunchSequenceCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

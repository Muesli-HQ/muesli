// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MuesliCoreAIBenchmark",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(
            url: "https://github.com/apple/coreai-models",
            revision: "25af63c68837b3a9da911302b9089b6ab0d50927"
        ),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.3"),
    ],
    targets: [
        .executableTarget(
            name: "CoreAIBenchmark",
            dependencies: [
                .product(name: "CoreAISpeech", package: "coreai-models"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)

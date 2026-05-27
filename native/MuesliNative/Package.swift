// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MuesliNative",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .library(name: "MuesliCore", targets: ["MuesliCore"]),
        .executable(name: "MuesliNativeApp", targets: ["MuesliNativeApp"]),
        .executable(name: "muesli-cli", targets: ["MuesliCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", "0.12.6"..<"0.13.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", branch: "main"), // TODO: pin to tagged release once one ships post-PR #455 (swift-transformers removal)
        // Ghost Pepper uses this LLM.swift fork for local Qwen cleanup. Before production, replace it with upstream
        // eastriverlee/LLM.swift once explicit Qwen/ChatML template behavior is validated against our GGUF models.
        .package(url: "https://github.com/obra/LLM.swift.git", revision: "f1e1e11982dbc59662be191b8bed408dfb48e9df"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
        .package(url: "https://github.com/MimicScribe/dtln-aec-coreml.git", from: "0.4.0-beta"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "MuesliCore",
            dependencies: [],
            path: "Sources/MuesliCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "MuesliNativeApp",
            dependencies: [
                "MuesliCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "LLM", package: "LLM.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "DTLNAecCoreML", package: "dtln-aec-coreml"),
                .product(name: "DTLNAec512", package: "dtln-aec-coreml"),
                "LocalVQEBridge",
            ],
            path: "Sources/MuesliNativeApp",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "MuesliCLI",
            dependencies: [
                "MuesliCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MuesliCLI"
        ),
        .target(
            name: "LocalVQEBridge",
            path: "Sources/LocalVQEBridge",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "MuesliTests",
            dependencies: ["MuesliNativeApp", "MuesliCore", "MuesliCLI", "LocalVQEBridge"],
            path: "Tests/MuesliTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

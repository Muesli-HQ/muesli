// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Opt-in optimized benchmark suite; unrelated tests require DEBUG-only hooks.
let cleanupEvaluationOnly = ProcessInfo.processInfo.environment["MUESLI_CLEANUP_EVALUATION_ONLY"] == "1"

let package = Package(
    name: "MuesliNative",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .library(name: "MuesliCore", targets: ["MuesliCore"]),
        .library(name: "MuesliNativeAppCore", targets: ["MuesliNativeApp"]),
        .executable(name: "MuesliNativeApp", targets: ["MuesliNativeAppShell"]),
        .executable(name: "muesli-cli", targets: ["MuesliCLI"]),
    ],
    dependencies: [
        .package(path: "../AIElementsSwift"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.2"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.3"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", branch: "main"), // TODO: pin to tagged release once one ships post-PR #455 (swift-transformers removal)
        // Ghost Pepper uses this LLM.swift fork for local Qwen cleanup. Before production, replace it with upstream
        // eastriverlee/LLM.swift once explicit Qwen/ChatML template behavior is validated against our GGUF models.
        .package(url: "https://github.com/obra/LLM.swift.git", revision: "f1e1e11982dbc59662be191b8bed408dfb48e9df"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
        .package(url: "https://github.com/MimicScribe/dtln-aec-coreml.git", from: "0.4.0-beta"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // Local source patch of the pinned wrapper; reuse its existing runtime and macros.
        .target(
            name: "MuesliLLM",
            dependencies: [.product(name: "LLM", package: "LLM.swift")],
            path: "Sources/MuesliLLM",
            exclude: ["README.md", "generation-limit.patch"],
            resources: [.copy("LICENSE")]
        ),

        .target(
            name: "MuesliCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/MuesliCore",
            resources: [.copy("Resources/ZIPFoundation-LICENSE.txt")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "MuesliNativeApp",
            dependencies: [
                "MuesliCore",
                "GemmaAudioEvaluation",
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "AIElementsSwift", package: "AIElementsSwift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "MuesliLLM",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "DTLNAecCoreML", package: "dtln-aec-coreml"),
                .product(name: "DTLNAec512", package: "dtln-aec-coreml"),
                "AudioGraphExceptionBridge",
                "LocalVQEBridge",
            ],
            path: "Sources/MuesliNativeApp",
            resources: [.copy("Resources/Licenses"), .copy("Resources/muesli-export-logo.png"), .copy("Resources/granola-export-guide.png"), .copy("Resources/recording-announcement.aiff")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Contacts"),
                .linkedFramework("ContactsUI"),
            ]
        ),
        // Thin executable shell: main.swift + App Intents. Kept separate from
        // the existing MuesliNativeApp module so a genuine Xcode Application
        // target (see xcodegen project used for release builds) can wrap it
        // and get App Intents metadata extraction, which only runs for real
        // Application-type targets, not SwiftPM executables or libraries.
        .executableTarget(
            name: "MuesliNativeAppShell",
            dependencies: [
                "MuesliNativeApp",
            ],
            path: "Sources/MuesliNativeAppShell",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .executableTarget(
            name: "MuesliCLI",
            dependencies: [
                "MuesliCore",
                "MuesliNativeApp",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MuesliCLI",
            // The shared app runtimes add framework dependencies. Xcode app
            // packaging places them beside Resources, rather than the CLI.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(
            name: "AudioGraphExceptionBridge",
            path: "Sources/AudioGraphExceptionBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
            ]
        ),
        .target(
            name: "LocalVQEBridge",
            path: "Sources/LocalVQEBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AudioGraphTestSupport",
            path: "Tests/AudioGraphTestSupport",
            publicHeadersPath: "include"
        ),
        // Native E-series audio encoder, with separate opt-in reference-parity tests.
        .target(name: "GemmaAudioEvaluation",
                dependencies: [.product(name: "MLX", package: "mlx-swift")],
                path: "Sources/GemmaAudioEvaluation", exclude: ["README.md"], resources: [.copy("LICENSE")]),
        .testTarget(name: "GemmaAudioEvaluationTests", dependencies: ["GemmaAudioEvaluation"],
                    path: "Tests/GemmaAudioEvaluationTests"),
        .testTarget(
            name: "MuesliTests",
            dependencies: ["GemmaAudioEvaluation", .product(name: "MLXNN", package: "mlx-swift"), "MuesliNativeApp", "MuesliLLM", "MuesliCore", "MuesliCLI", "AudioGraphExceptionBridge", "AudioGraphTestSupport", "LocalVQEBridge", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Tests/MuesliTests",
            sources: cleanupEvaluationOnly ? ["BackendTests.swift", "MuesliCleanupV2Tests.swift", "QuilTransformationTests.swift", "ComputerUseLocalPlannerBenchmarkTests.swift", "CleanupMLXEvaluationTests.swift", "GemmaAudioEndToEndTests.swift", "GemmaNativeAudioTests.swift", "BodhanBackendTests.swift", "BodhanArtifactValidationTests.swift", "BodhanLifecycleTests.swift", "CotypistModelComparisonTests.swift"] : nil,
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

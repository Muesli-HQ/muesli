// swift-tools-version: 5.9
import PackageDescription

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
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
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
        .target(
            name: "MuesliCore",
            dependencies: [],
            path: "Sources/MuesliCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "MuesliNativeApp",
            dependencies: [
                "MuesliCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "LLM", package: "LLM.swift"),
                .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MuesliCLI"
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
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.13.1/CLiteRTLM_mac.xcframework.zip",
            checksum: "ec9ffe230dc39117a7fc8933b1cc15910454027fee6d3041534ab7cf17313981"
        ),
        .testTarget(
            name: "MuesliTests",
            dependencies: ["MuesliNativeApp", "MuesliCore", "MuesliCLI", "AudioGraphExceptionBridge", "LocalVQEBridge"],
            path: "Tests/MuesliTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

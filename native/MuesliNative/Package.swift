// swift-tools-version: 5.9
import PackageDescription

// MARK: - Platform-conditional manifest
//
// The macOS app and its macOS-only dependencies (MLX, FluidAudio, WhisperKit,
// Sparkle, CoreML packages, the macOS LiteRT binary artifact, LocalVQE, ...)
// are declared only when the manifest is evaluated on macOS. On Windows the
// manifest exposes just the portable `MuesliCore` library and its tests, so
// `swift build --target MuesliCore` never resolves or downloads macOS-only
// packages or binary artifacts.

#if os(Windows)
let windowsVcpkgRoot = Context.environment["VCPKG_ROOT"]
    ?? Context.environment["MUESLI_VCPKG_ROOT"]
    ?? Context.environment["VCPKG_INSTALLATION_ROOT"]
let windowsVcpkgInstalled = windowsVcpkgRoot.map { "\($0)/installed/x64-windows" }

// Native headers/libraries come from the developer environment (vcpkg), not
// from a machine-specific path baked into the package.
let coreSwiftSettings: [SwiftSetting] = windowsVcpkgInstalled.map {
    [.unsafeFlags(["-Xcc", "-I\($0)/include"])]
} ?? []
let coreLinkerSettings: [LinkerSetting] = windowsVcpkgInstalled.map {
    [.unsafeFlags(["-L\($0)/lib"])]
} ?? []

let package = Package(
    name: "MuesliNative",
    // Declared for parity with the macOS manifest; ignored when building on Windows.
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .library(name: "MuesliCore", targets: ["MuesliCore"]),
        // Stable Swift↔C ABI consumed by the Windows app. Dynamic so the C#
        // adapter can load it beside the packaged application.
        .library(name: "MuesliCoreABI", type: .dynamic, targets: ["MuesliCoreABI"]),
    ],
    dependencies: [
        // Exact pins keep the Windows dependency graph reproducible. The macOS graph is
        // unaffected because this branch is only evaluated on Windows, and the Windows build
        // resolves against Package.resolved.windows (staged as Package.resolved in an isolated
        // build copy) rather than the macOS Package.resolved.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1"),
    ],
    targets: [
        // Portable Clang module maps resolving through the vcpkg include path.
        .systemLibrary(name: "SQLite3", path: "Sources/CSQLite"),
        .systemLibrary(name: "CLZFSE", path: "Sources/CLZFSE"),

        .target(
            name: "MuesliCore",
            dependencies: [
                "SQLite3",
                "CLZFSE",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/MuesliCore",
            exclude: [
                // CoreML-backed Qwen3 backend is macOS-only; the portable parts of
                // the Qwen3ASR directory (config, RoPE, mel spectrogram) still build.
                "Qwen3ASR/Qwen3AsrManager.swift",
                "Qwen3ASR/Qwen3AsrModels.swift",
                "Qwen3ASR/Qwen3StreamingManager.swift",
                "Qwen3ASR/LICENSE-Apache-2.0",
            ],
            swiftSettings: coreSwiftSettings,
            linkerSettings: coreLinkerSettings + [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("lzfse"),
            ]
        ),

        .target(
            name: "MuesliCoreABI",
            dependencies: ["MuesliCore"],
            path: "Sources/MuesliCoreABI",
            swiftSettings: coreSwiftSettings,
            linkerSettings: coreLinkerSettings
        ),

        .testTarget(
            name: "MuesliCoreTests",
            dependencies: ["MuesliCore"],
            path: "Tests/MuesliCoreTests",
            swiftSettings: coreSwiftSettings,
            linkerSettings: coreLinkerSettings
        ),
        .testTarget(
            name: "MuesliCoreABITests",
            dependencies: ["MuesliCoreABI", "MuesliCore"],
            path: "Tests/MuesliCoreABITests",
            swiftSettings: coreSwiftSettings,
            linkerSettings: coreLinkerSettings
        ),
    ],
    cxxLanguageStandard: .cxx17
)
#else
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
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
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
            exclude: [
                "Qwen3ASR/LICENSE-Apache-2.0",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        // Cross-platform C ABI bridge around MuesliCore. The Windows manifest
        // also publishes it as a dynamic library; declaring the target here keeps
        // the Apple branch compiling it for CI coverage.
        .target(
            name: "MuesliCoreABI",
            dependencies: ["MuesliCore"],
            path: "Sources/MuesliCoreABI"
        ),
        // Portable cross-platform tests for MuesliCore (run on macOS CI and Windows).
        .testTarget(
            name: "MuesliCoreTests",
            dependencies: ["MuesliCore"],
            path: "Tests/MuesliCoreTests"
        ),
        .testTarget(
            name: "MuesliCoreABITests",
            dependencies: ["MuesliCoreABI", "MuesliCore"],
            path: "Tests/MuesliCoreABITests"
        ),
        .target(
            name: "MuesliNativeApp",
            dependencies: [
                "MuesliCore",
                .product(name: "MLX", package: "mlx-swift"),
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
#endif

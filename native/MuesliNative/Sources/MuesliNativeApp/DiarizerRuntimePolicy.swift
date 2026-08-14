import CoreML
import Darwin
import FluidAudio
import Foundation
import TelemetryDeck

enum DiarizerComputePolicy: String, Sendable, Equatable {
    case all
    case cpuAndNeuralEngine = "cpu_and_neural_engine"

    var computeUnits: MLComputeUnits {
        switch self {
        case .all:
            return .all
        case .cpuAndNeuralEngine:
            return .cpuAndNeuralEngine
        }
    }
}

enum DiarizerPreloadFailure: Error {
    case operationTimedOut
}

struct DiarizerRuntimeEnvironment: Sendable {
    let cpuBrand: String?
    let hardwareModel: String?
    let operatingSystemVersion: OperatingSystemVersion

    static func current(processInfo: ProcessInfo = .processInfo) -> DiarizerRuntimeEnvironment {
        DiarizerRuntimeEnvironment(
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            hardwareModel: sysctlString("hw.model"),
            operatingSystemVersion: processInfo.operatingSystemVersion
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(validatingCString: value)
    }
}

struct DiarizerRuntimePolicy: Sendable, Equatable {
    static let defaultCompatibilityRule = "default_v1"
    static let m1MacOS151CompatibilityRule = "m1_macos_15_1_gpu_avoidance_v1"

    // Fallback identifiers are used only if the CPU brand sysctl is unavailable.
    // The CPU brand remains the primary signal because it covers M1, M1 Pro, M1 Max,
    // and M1 Ultra without trying to infer the chip from every Mac product identifier.
    private static let m1HardwareModels: Set<String> = [
        "MacBookAir10,1",
        "MacBookPro17,1",
        "MacBookPro18,1",
        "MacBookPro18,2",
        "MacBookPro18,3",
        "MacBookPro18,4",
        "Macmini9,1",
        "iMac21,1",
        "iMac21,2",
        "Mac13,1",
        "Mac13,2",
    ]

    let computePolicy: DiarizerComputePolicy
    let compatibilityRule: String

    static func resolve(for environment: DiarizerRuntimeEnvironment) -> DiarizerRuntimePolicy {
        let version = environment.operatingSystemVersion
        let isMacOS151 = version.majorVersion == 15 && version.minorVersion == 1
        let isM1Family = environment.cpuBrand.map(isM1CPUBrand)
            ?? environment.hardwareModel.map(m1HardwareModels.contains)
            ?? false

        // Issue #344's crash stack enters MPSGraph/Metal while FluidAudio loads
        // the diarizer on M1 + macOS 15.1.x. Excluding GPU here leaves CoreML free
        // to use CPU/ANE fallbacks without slowing unaffected hardware and OSes.
        if isMacOS151, isM1Family {
            return DiarizerRuntimePolicy(
                computePolicy: .cpuAndNeuralEngine,
                compatibilityRule: m1MacOS151CompatibilityRule
            )
        }

        return DiarizerRuntimePolicy(
            computePolicy: .all,
            compatibilityRule: defaultCompatibilityRule
        )
    }

    var modelConfiguration: MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computePolicy.computeUnits
        return configuration
    }

    private static func isM1CPUBrand(_ value: String) -> Bool {
        let brand = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return brand == "Apple M1" || brand.hasPrefix("Apple M1 ")
    }
}

enum DiarizerPreloadTrigger: String, Sendable {
    case appLaunch = "app_launch"
    case audioImport = "audio_import"
    case backendChange = "backend_change"
    case meetingStart = "meeting_start"
    case modelLibrary = "model_library"
    case onboarding
    case retranscription
    case unspecified
}

enum DiarizerModelCacheState: String, Sendable {
    case absent
    case partial
    case complete

    static func resolve(
        directory: URL = DiarizerModels.defaultModelsDirectory(),
        requiredModelNames: Set<String> = DiarizerModels.requiredModelNames,
        fileManager: FileManager = .default
    ) -> DiarizerModelCacheState {
        let presentCount = requiredModelNames.reduce(into: 0) { count, modelName in
            if fileManager.fileExists(atPath: directory.appendingPathComponent(modelName).path) {
                count += 1
            }
        }

        if presentCount == 0 { return .absent }
        if presentCount == requiredModelNames.count { return .complete }
        return .partial
    }
}

struct DiarizerPreloadContext: Sendable {
    static let telemetrySchemaVersion = "1"
    // Keep synchronized with the exact FluidAudio pin in Package.swift.
    static let fluidAudioVersion = "0.15.1"

    let trigger: DiarizerPreloadTrigger
    let policy: DiarizerRuntimePolicy
    let cacheState: DiarizerModelCacheState

    var telemetryParameters: [String: String] {
        [
            "schema_version": Self.telemetrySchemaVersion,
            "trigger": trigger.rawValue,
            "compute_policy": policy.computePolicy.rawValue,
            "compatibility_rule": policy.compatibilityRule,
            "cache_state": cacheState.rawValue,
            "model_set": "pyannote_streaming",
            "fluid_audio_version": Self.fluidAudioVersion,
        ]
    }
}

struct DiarizerPreloadDiagnostics {
    typealias SignalSink = (_ event: String, _ parameters: [String: String]) -> Void

    private struct PendingAttempt: Codable {
        let startedAt: TimeInterval
        let parameters: [String: String]
    }

    static let pendingAttemptKey = "diarizerPreload.pendingAttempt.v1"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let signalSink: SignalSink

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        signalSink: @escaping SignalSink = { event, parameters in
            TelemetryDeck.signal(event, parameters: parameters)
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.signalSink = signalSink
    }

    func reportInterruptedAttemptIfNeeded() {
        guard let data = defaults.data(forKey: Self.pendingAttemptKey),
              let pending = try? JSONDecoder().decode(PendingAttempt.self, from: data) else {
            clearPendingAttempt()
            return
        }

        clearPendingAttempt()
        var parameters = pending.parameters
        parameters["duration_bucket"] = Self.durationBucket(
            now().timeIntervalSince1970 - pending.startedAt
        )
        signalSink("diarizer.preload.interrupted", parameters)
    }

    @discardableResult
    func begin(_ context: DiarizerPreloadContext) -> Date {
        let startedAt = now()
        let pending = PendingAttempt(
            startedAt: startedAt.timeIntervalSince1970,
            parameters: context.telemetryParameters
        )
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: Self.pendingAttemptKey)
            // This marker must outlive an immediate SIGABRT during CoreML loading.
            // Preloads are rare enough that forcing this tiny preferences write is acceptable.
            defaults.synchronize()
        }
        signalSink("diarizer.preload.started", context.telemetryParameters)
        return startedAt
    }

    func ready(_ context: DiarizerPreloadContext, startedAt: Date) {
        finish(
            event: "diarizer.preload.ready",
            context: context,
            startedAt: startedAt,
            additionalParameters: [:]
        )
    }

    func failed(_ context: DiarizerPreloadContext, startedAt: Date, error: Error) {
        finish(
            event: "diarizer.preload.failed",
            context: context,
            startedAt: startedAt,
            additionalParameters: ["failure_category": Self.failureCategory(for: error)]
        )
    }

    func skipped(_ context: DiarizerPreloadContext, reason: String) {
        var parameters = context.telemetryParameters
        parameters["skip_reason"] = reason
        signalSink("diarizer.preload.skipped", parameters)
    }

    private func finish(
        event: String,
        context: DiarizerPreloadContext,
        startedAt: Date,
        additionalParameters: [String: String]
    ) {
        clearPendingAttempt()
        var parameters = context.telemetryParameters
        parameters["duration_bucket"] = Self.durationBucket(now().timeIntervalSince(startedAt))
        parameters.merge(additionalParameters) { _, new in new }
        signalSink(event, parameters)
    }

    private func clearPendingAttempt() {
        defaults.removeObject(forKey: Self.pendingAttemptKey)
        defaults.synchronize()
    }

    static func durationBucket(_ duration: TimeInterval) -> String {
        switch max(0, duration) {
        case ..<1: return "under_1s"
        case ..<5: return "1_to_5s"
        case ..<15: return "5_to_15s"
        case ..<60: return "15_to_60s"
        default: return "60s_or_more"
        }
    }

    static func failureCategory(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is DiarizerPreloadFailure { return "timeout" }
        if error is URLError { return "network" }

        if let diarizerError = error as? DiarizerError {
            switch diarizerError {
            case .modelDownloadFailed:
                return "model_download"
            case .modelCompilationFailed:
                return "model_compilation"
            case .memoryAllocationFailed:
                return "memory"
            case .notInitialized:
                return "not_initialized"
            case .embeddingExtractionFailed:
                return "embedding_extraction"
            case .invalidAudioData:
                return "invalid_audio"
            case .processingFailed, .invalidArrayBounds:
                return "processing"
            }
        }

        let nsError = error as NSError
        if nsError.domain.localizedCaseInsensitiveContains("coreml") {
            return "coreml"
        }
        if nsError.domain == NSCocoaErrorDomain,
           (NSFileErrorMinimum...NSFileErrorMaximum).contains(nsError.code) {
            return "filesystem"
        }
        return "other"
    }
}

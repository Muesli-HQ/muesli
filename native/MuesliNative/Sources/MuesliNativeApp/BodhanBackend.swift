import Foundation
import FluidAudio
import MuesliCore

enum BodhanLanguage: String, CaseIterable, Codable, Sendable {
    case automatic = "auto"
    case english = "en"
    case hindi = "hi"
    case tamil = "ta"
    case telugu = "te"
    case bengali = "bn"
    case marathi = "mr"
    case malayalam = "ml"
    case kannada = "kn"
    case assamese = "as"
    case bodo = "brx"
    case dogri = "doi"
    case gujarati = "gu"
    case kashmiri = "ks"
    case konkani = "kok"
    case maithili = "mai"
    case manipuri = "mni"
    case nepali = "ne"
    case odia = "or"
    case punjabi = "pa"
    case sanskrit = "sa"
    case santali = "sat"
    case sindhi = "sd"
    case urdu = "ur"
    case bhojpuri = "bho"
    case bhili = "bhb"
    case chhattisgarhi = "hne"
    case haryanvi = "bgc"
    static let defaultLanguage: Self = .hindi
    static func choices(for model: String) -> [Self] {
        switch BodhanModel(rawValue: model) {
        case .core: return allCases.filter { $0 != .chhattisgarhi && $0 != .haryanvi }
        case .flex: return allCases
        case nil: return []
        }
    }
    var label: String {
        switch self {
        case .automatic: return "Auto-detect"
        case .english: return "English"
        case .hindi: return "Hindi"
        case .tamil: return "Tamil"
        case .telugu: return "Telugu"
        case .bengali: return "Bengali"
        case .marathi: return "Marathi"
        case .malayalam: return "Malayalam"
        case .kannada: return "Kannada"
        case .assamese: return "Assamese"
        case .bodo: return "Bodo"
        case .dogri: return "Dogri"
        case .gujarati: return "Gujarati"
        case .kashmiri: return "Kashmiri"
        case .konkani: return "Konkani"
        case .maithili: return "Maithili"
        case .manipuri: return "Manipuri"
        case .nepali: return "Nepali"
        case .odia: return "Odia"
        case .punjabi: return "Punjabi"
        case .sanskrit: return "Sanskrit"
        case .santali: return "Santali"
        case .sindhi: return "Sindhi"
        case .urdu: return "Urdu"
        case .bhojpuri: return "Bhojpuri"
        case .bhili: return "Bhili"
        case .chhattisgarhi: return "Chhattisgarhi"
        case .haryanvi: return "Haryanvi"
        }
    }

    static func resolved(_ rawValue: String?) -> Self {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, let language = Self(rawValue: normalized) else {
            return defaultLanguage
        }
        return language
    }

    static func resolvedCode(_ rawValue: String?) -> String {
        resolved(rawValue).rawValue
    }
}

enum BodhanLogging {
    private static let verboseEnv = "MUESLI_DEBUG_BODHAN_LOGS"

    static var isVerboseEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment[verboseEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func logVerbose(_ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        fputs("[bodhan] \(message())\n", stderr)
    }
}

enum BodhanTranscriptMerger {
    static func mergeOverlappingTranscripts(_ transcripts: [String]) -> String {
        var mergedWords: [String] = []
        for transcript in transcripts {
            let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            guard !mergedWords.isEmpty else {
                mergedWords.append(contentsOf: words)
                continue
            }

            let existing = mergedWords.map(normalizeMergeToken)
            let incoming = words.map(normalizeMergeToken)
            let maxOverlap = min(existing.count, incoming.count, 16)
            var overlap = 0
            if maxOverlap > 0 {
                for count in stride(from: maxOverlap, through: 1, by: -1) {
                    if Array(existing.suffix(count)) == Array(incoming.prefix(count)) {
                        overlap = count
                        break
                    }
                }
            }
            mergedWords.append(contentsOf: words.dropFirst(overlap))
        }
        return mergedWords.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeMergeToken(_ token: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let scalars = token.unicodeScalars.filter { !punctuation.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
}

@available(macOS 15, *)
actor BodhanTranscriber {
    private var runtime: BodhanCoreML?
    private var model: BodhanModel?
    private var loadingModel: BodhanModel?
    private var loadTask: Task<BodhanCoreML, Error>?
    private var generation = 0
    private var warmupTask: Task<Void, Error>?
    private var hasCompletedWarmup = false

    private func load(modelID: String, progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?) async throws {
        guard let selected = BodhanModel(rawValue: modelID) else {
            throw NSError(domain: "BodhanASR", code: 15, userInfo: [NSLocalizedDescriptionKey: "Unknown Bodhan model."])
        }
        if model == selected, runtime != nil { return }
        if loadingModel != selected || loadTask == nil {
            shutdown()
            loadingModel = selected
            loadTask = Task {
                try await selected.download(progress: progress, progressSnapshot: progressSnapshot)
                try Task.checkCancellation()
                progress?(0.9, "Preparing " + selected.name + "...")
                return try BodhanCoreML(root: selected.directory)
            }
        }
        let expectedGeneration = generation
        guard let task = loadTask else { throw CancellationError() }
        do {
            let loaded = try await task.value
            try Task.checkCancellation()
            guard expectedGeneration == generation else { throw CancellationError() }
            runtime = loaded
            model = selected
            loadTask = nil
            loadingModel = nil
        } catch {
            if expectedGeneration == generation { loadTask = nil; loadingModel = nil }
            throw error
        }
    }

    func prepare(modelID: String = BodhanModel.flex.rawValue,
                 progress: ((Double, String?) -> Void)? = nil,
                 progressSnapshot: ModelDownloadProgressHandler? = nil) async throws {
        try await load(modelID: modelID, progress: progress, progressSnapshot: progressSnapshot)
        guard let runtime, let model else { throw CancellationError() }
        let expectedGeneration = generation
        let warming = ModelDownloadProgress.preparing(modelID: modelID, message: "Warming up " + model.name + "...")
        if !hasCompletedWarmup {
            progress?(0.95, warming.message)
            progressSnapshot?(warming)
            if warmupTask == nil {
                let mixed = model.mixedScript
                warmupTask = Task {
                    BodhanLogging.logVerbose("background warmup started")
                    try runtime.warmupEncoderShapes()
                    _ = try runtime.transcribe(samples: [Float](repeating: 0, count: 8000), language: "hi", mixedScript: mixed)
                    try Task.checkCancellation()
                    BodhanLogging.logVerbose("background warmup complete")
                }
            }
            do {
                if let warmupTask { try await warmupTask.value }
                try Task.checkCancellation()
                guard expectedGeneration == generation else { throw CancellationError() }
                hasCompletedWarmup = true
                warmupTask = nil
            } catch {
                if expectedGeneration == generation { warmupTask = nil }
                throw error
            }
        }
        progress?(1.0, model.name + " ready")
        progressSnapshot?(warming.replacing(phase: .ready, message: model.name + " ready"))
    }

    func transcribe(wavURL: URL, modelID: String = BodhanModel.flex.rawValue,
                    language: BodhanLanguage = .defaultLanguage) async throws -> (text: String, processingTime: Double) {
        try await prepare(modelID: modelID)
        guard let runtime, let model else { throw CancellationError() }
        let start = CFAbsoluteTimeGetCurrent()
        let samples = try AudioConverter().resampleAudioFile(wavURL)
        guard !samples.isEmpty else { return ("", CFAbsoluteTimeGetCurrent() - start) }
        var transcripts: [String] = []
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + 28 * 16000, samples.count)
            let result = try runtime.transcribe(samples: Array(samples[offset..<end]),
                language: language == .automatic ? nil : language.rawValue, mixedScript: model.mixedScript)
            transcripts.append(result.text)
            recordBodhanTiming(result, modelID: modelID, audioSeconds: Double(end - offset) / 16000)
            BodhanLogging.logVerbose("Bodhan language=\(result.language), tokens=\(result.tokens), encoder=\(result.encoderSeconds)s, decode=\(result.decodeSeconds)s")
            if end == samples.count { break }
            offset += 27 * 16000
        }
        return (BodhanTranscriptMerger.mergeOverlappingTranscripts(transcripts), CFAbsoluteTimeGetCurrent() - start)
    }

    func shutdown() {
        generation += 1
        loadTask?.cancel(); loadTask = nil; loadingModel = nil
        warmupTask?.cancel(); warmupTask = nil
        runtime = nil; model = nil; hasCompletedWarmup = false
    }
    private func recordBodhanTiming(_ result: BodhanCoreML.Result, modelID: String, audioSeconds: Double) {
        // Local performance telemetry only: no audio, transcript, or vocabulary scores.
        let row: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()), "model": modelID,
            "audioSeconds": audioSeconds, "tokens": result.tokens, "language": result.language,
            "decoderRuntime": BodhanCoreML.decoderRuntime,
            "encoderAsset": result.encoderAsset, "decoderWeightPrecision": result.decoderWeightPrecision,
            "encoderPolicy": result.encoderPolicy, "decoderAsset": BodhanCoreML.decoderRuntime == "mlx" ? "decoder.safetensors" : (ProcessInfo.processInfo.environment["MUESLI_BODHAN_DECODER_ASSET"] ?? "decoder"),
            "threadQoS": result.threadQoS, "thermalState": result.thermalState,
            "lowPowerMode": result.lowPowerMode, "onMainThread": result.onMainThread,
            "encoderSpecialized": result.encoderSpecialized,
            "encoderShapePolicy": result.encoderShapePolicy,
            "encoderInputFrames": result.encoderInputFrames, "encoderValidFrames": result.encoderValidFrames,
            "transferSeconds": result.transferSeconds,
            "frontendSeconds": result.frontendSeconds,
            "encoderSeconds": result.encoderSeconds, "crossSeconds": result.crossSeconds,
            "decodeSeconds": result.decodeSeconds, "predictionSeconds": result.predictionSeconds,
            "selectionSeconds": result.selectionSeconds
        ]
        let url = AppIdentity.supportDirectoryURL.appendingPathComponent("bodhan-performance.jsonl")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
            if size == 0 || size > 2 * 1024 * 1024 {
                try data.write(to: url, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch { BodhanLogging.logVerbose("Could not write Bodhan timing: \(error)") }
    }

}

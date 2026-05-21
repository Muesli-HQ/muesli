import Foundation
import KittenTTS

enum ComputerUseTTSModelOption: String, CaseIterable, Equatable {
    case nanoInt8 = "nano_int8"
    case micro
    case mini

    var label: String {
        switch self {
        case .nanoInt8:
            return "Nano Int8"
        case .micro:
            return "Micro"
        case .mini:
            return "Mini"
        }
    }

    var kittenModel: KittenModel {
        switch self {
        case .nanoInt8:
            return .nanoInt8
        case .micro:
            return .micro
        case .mini:
            return .mini
        }
    }

    static func resolve(_ id: String?) -> ComputerUseTTSModelOption {
        guard let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .micro
        }
        switch normalized {
        case "nano_int8", "nanoint8", "nano-int8", "kitten-tts-nano-0.8-int8":
            return .nanoInt8
        case "mini", "kitten-tts-mini-0.8":
            return .mini
        default:
            return .micro
        }
    }

    static func resolveID(_ id: String?) -> String {
        resolve(id).rawValue
    }

    static var labels: [String] {
        allCases.map(\.label)
    }

    static func option(forLabel label: String) -> ComputerUseTTSModelOption {
        allCases.first { $0.label == label } ?? .micro
    }
}

enum ComputerUseTTSVoiceOption: String, CaseIterable, Equatable {
    case bella
    case jasper
    case luna
    case bruno
    case rosie
    case hugo
    case kiki
    case leo

    var label: String {
        switch self {
        case .bella: return "Bella"
        case .jasper: return "Jasper"
        case .luna: return "Luna"
        case .bruno: return "Bruno"
        case .rosie: return "Rosie"
        case .hugo: return "Hugo"
        case .kiki: return "Kiki"
        case .leo: return "Leo"
        }
    }

    var kittenVoice: KittenVoice {
        switch self {
        case .bella: return .bella
        case .jasper: return .jasper
        case .luna: return .luna
        case .bruno: return .bruno
        case .rosie: return .rosie
        case .hugo: return .hugo
        case .kiki: return .kiki
        case .leo: return .leo
        }
    }

    static func resolve(_ id: String?) -> ComputerUseTTSVoiceOption {
        guard let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .bella
        }
        return allCases.first { option in
            option.rawValue == normalized
                || option.label.lowercased() == normalized
                || option.kittenVoice.rawValue == normalized
        } ?? .bella
    }

    static func resolveID(_ id: String?) -> String {
        resolve(id).rawValue
    }

    static var labels: [String] {
        allCases.map(\.label)
    }

    static func option(forLabel label: String) -> ComputerUseTTSVoiceOption {
        allCases.first { $0.label == label } ?? .bella
    }
}

enum ComputerUseSpeechPolicy {
    static func commandHeardSpeech(for transcript: String) -> String? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Got it."
    }

    static func speech(forStatus status: String) -> String? {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized == "Confirm" {
            return "I need confirmation before continuing."
        }
        if normalized == "Failed" {
            return "CUA failed."
        }
        return nil
    }

    static func finalSpeech(for result: ComputerUsePlannerRuntimeResult) -> String? {
        switch result.status {
        case .done:
            let message = sanitized(result.message, maxCharacters: 140)
            if message.isEmpty || message.lowercased() == "done" {
                return "Done."
            }
            return "Done. \(message)"
        case .timedOut:
            return "CUA timed out."
        case .needsConfirmation:
            let message = sanitized(result.message, maxCharacters: 140)
            return message.isEmpty
                ? "I need confirmation before continuing."
                : "I need confirmation. \(message)"
        case .failed:
            let message = sanitized(result.message, maxCharacters: 140)
            return message.isEmpty ? "CUA failed." : "CUA failed. \(message)"
        case .cancelled:
            return "CUA cancelled."
        }
    }

    static func sanitized(_ text: String, maxCharacters: Int) -> String {
        let compact = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maxCharacters else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: maxCharacters)
        let prefix = String(compact[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }
}

@MainActor
final class ComputerUseSpeechController {
    typealias SpeechHandler = (String, AppConfig) async throws -> Void

    private struct SpeechConfigKey: Equatable {
        let modelID: String
    }

    private struct SpeechRequest {
        let text: String
        let config: AppConfig
    }

    private var tts: KittenTTS?
    private var ttsConfigKey: SpeechConfigKey?
    private var queue: [SpeechRequest] = []
    private var drainTask: Task<Void, Never>?
    private var drainID: UUID?
    private var lastQueuedText = ""
    private let speechHandler: SpeechHandler?

    init(speechHandler: SpeechHandler? = nil) {
        self.speechHandler = speechHandler
    }

    func speakCommandHeard(_ transcript: String, config: AppConfig) {
        enqueue(ComputerUseSpeechPolicy.commandHeardSpeech(for: transcript), config: config)
    }

    func speakStatus(_ status: String, config: AppConfig) {
        enqueue(ComputerUseSpeechPolicy.speech(forStatus: status), config: config)
    }

    func speakFinalResult(_ result: ComputerUsePlannerRuntimeResult, config: AppConfig) {
        enqueue(ComputerUseSpeechPolicy.finalSpeech(for: result), config: config)
    }

    func stop() {
        queue.removeAll()
        lastQueuedText = ""
        drainTask?.cancel()
        drainTask = nil
        drainID = nil
        if let tts {
            Task {
                await tts.stopSpeaking()
            }
        }
    }

    private func enqueue(_ text: String?, config: AppConfig) {
        guard config.soundEnabled, config.enableComputerUseVoiceFeedback else {
            if drainTask != nil || !queue.isEmpty {
                stop()
            } else {
                lastQueuedText = ""
            }
            return
        }
        guard let text, !text.isEmpty, text != lastQueuedText else { return }
        lastQueuedText = text
        queue.append(SpeechRequest(text: text, config: config))
        startDrainingIfNeeded()
    }

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }
        let id = UUID()
        drainID = id
        drainTask = Task { [weak self] in
            await self?.drainQueue(id: id)
        }
    }

    private func drainQueue(id: UUID) async {
        while !Task.isCancelled, !queue.isEmpty {
            let request = queue.removeFirst()
            do {
                if let speechHandler {
                    try await speechHandler(request.text, request.config)
                    continue
                }
                let tts = try await resolveTTS(for: request.config)
                let voice = ComputerUseTTSVoiceOption.resolve(request.config.computerUseTTSVoice).kittenVoice
                let speed = Float(min(max(request.config.computerUseTTSSpeed, 0.5), 2.0))
                _ = try await tts.speak(request.text, voice: voice, speed: speed)
            } catch is CancellationError {
                break
            } catch {
                fputs("[cua-tts] speech failed: \(error)\n", stderr)
            }
        }
        if drainID == id {
            drainTask = nil
            drainID = nil
        }
    }

    private func resolveTTS(for appConfig: AppConfig) async throws -> KittenTTS {
        let key = SpeechConfigKey(
            modelID: ComputerUseTTSModelOption.resolveID(appConfig.computerUseTTSModel)
        )
        if let tts, ttsConfigKey == key {
            return tts
        }

        let model = ComputerUseTTSModelOption.resolve(key.modelID).kittenModel
        let voice = ComputerUseTTSVoiceOption.resolve(appConfig.computerUseTTSVoice).kittenVoice
        let config = KittenTTSConfig(
            model: model,
            defaultVoice: voice,
            speed: Float(min(max(appConfig.computerUseTTSSpeed, 0.5), 2.0)),
            storageDirectory: nil,
            ortNumThreads: 4,
            maxTokensPerChunk: 160
        )
        let isCached = KittenTTS.isModelCached(for: config)
        if !isCached {
            fputs("[cua-tts] downloading \(model.rawValue)\n", stderr)
        }
        let next = try await KittenTTS(config) { progress in
            fputs("[cua-tts] download \(Int((progress * 100).rounded()))%\n", stderr)
        }
        tts = next
        ttsConfigKey = key
        return next
    }
}

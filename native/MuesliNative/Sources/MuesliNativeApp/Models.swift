import AppKit
import Foundation
import MuesliCore

struct BackendOption: Equatable {
    let backend: String
    let model: String
    let label: String
    let sizeLabel: String
    let description: String
    let recommended: Bool

    static let parakeetMultilingual = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        label: "Parakeet v3",
        sizeLabel: "~450 MB",
        description: "Multilingual, 25 languages. Runs on Apple Neural Engine.",
        recommended: true
    )

    static let parakeetEnglish = BackendOption(
        backend: "fluidaudio",
        model: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        label: "Parakeet v2",
        sizeLabel: "~450 MB",
        description: "English-only, highest recall. Runs on Apple Neural Engine.",
        recommended: false
    )

    static let whisperSmall = BackendOption(
        backend: "whisper",
        model: "small.en",
        label: "Whisper Small",
        sizeLabel: "~250 MB",
        description: "Fast, English-optimized. Runs on Apple Neural Engine via CoreML.",
        recommended: false
    )

    static let whisperTinyEnglish = BackendOption(
        backend: "whisper",
        model: "tiny.en",
        label: "Whisper Tiny English",
        sizeLabel: "~153 MB",
        description: "Smallest English WhisperKit CoreML model. Quickest local setup.",
        recommended: false
    )

    static let whisperMedium = BackendOption(
        backend: "whisper",
        model: "medium.en",
        label: "Whisper Medium",
        sizeLabel: "~1.5 GB",
        description: "Better accuracy, English-only. Runs on Apple Neural Engine via CoreML.",
        recommended: false
    )

    static let whisperLargeTurbo = BackendOption(
        backend: "whisper",
        model: "large-v3-v20240930_626MB",
        label: "Whisper Large Turbo",
        sizeLabel: "~626 MB",
        description: "Highest accuracy, multilingual. Quantized CoreML for faster inference.",
        recommended: false
    )

    static let nemotronStreaming = BackendOption(
        backend: "nemotron",
        model: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
        label: "Nemotron Streaming (Experimental)",
        sizeLabel: "~600 MB",
        description: "Experimental. NVIDIA streaming RNNT. English-only. Handsfree mode only. No punctuation (RNNT limitation). Append-only — no corrections.",
        recommended: false
    )

    static let canaryQwen = BackendOption(
        backend: "canary",
        model: "phequals/canary-qwen-2.5b-coreml-int8",
        label: "Canary Qwen",
        sizeLabel: "~2.5 GB",
        description: "INT8 CoreML, autoregressive, experimental. English-first. First use warms up slowly. Final transcript after stop in v1.",
        recommended: false
    )

    static let cohereTranscribe = BackendOption(
        backend: "cohere",
        model: "phequals/cohere-transcribe-coreml-mixed-precision",
        label: "Cohere Transcribe",
        sizeLabel: "~3.8 GB",
        description: "Mixed precision (FP16 encoder + INT8 decoder). 14 languages. High accuracy (#1 Open ASR Leaderboard). Final transcript after stop. May decode hallucinated text during silence — use in quiet environments or with VAD.",
        recommended: false
    )

    // Default alias
    static let whisper = parakeetMultilingual

    static let parakeetFamily: [BackendOption] = [
        .parakeetMultilingual, .parakeetEnglish,
    ]

    static let whisperFamily: [BackendOption] = [
        .whisperTinyEnglish, .whisperSmall, .whisperMedium, .whisperLargeTurbo,
    ]

    static let qwen3Asr = BackendOption(
        backend: "qwen",
        model: "FluidInference/qwen3-asr-0.6b-coreml",
        label: "Qwen3 ASR",
        sizeLabel: "~1.3 GB",
        description: "Multilingual, 52 languages. Slower than Parakeet (~2-3s). First use takes ~30s to warm up.",
        recommended: false
    )

    static let experimental: [BackendOption] = [
        .qwen3Asr, .canaryQwen, .nemotronStreaming,
    ]

    /// Models available for download and use.
    static let all: [BackendOption] = parakeetFamily + whisperFamily + [.cohereTranscribe] + experimental

    /// Conservative first-run choices. Experimental models stay in Models.
    static let onboarding: [BackendOption] = [.parakeetMultilingual, .whisperTinyEnglish, .whisperSmall, .cohereTranscribe]

    /// Models coming soon — shown greyed out in the Models tab.
    static let comingSoon: [BackendOption] = []

    /// Only models that have been downloaded and are ready for inference.
    static var downloaded: [BackendOption] {
        all.filter { $0.isDownloaded }
    }

    static func resolve(backend: String, model: String) -> BackendOption? {
        all.first { $0.backend == backend && $0.model == model }
    }

    static func resolveDownloaded(
        backend: String,
        model: String,
        fallback: BackendOption?,
        downloadedOptions: [BackendOption]
    ) -> BackendOption? {
        if let selected = downloadedOptions.first(where: { $0.backend == backend && $0.model == model }) {
            return selected
        }
        if let fallback,
           downloadedOptions.contains(where: { $0.backend == fallback.backend && $0.model == fallback.model }) {
            return fallback
        }
        return downloadedOptions.first
    }

    /// Check if this model's files exist on disk.
    var isDownloaded: Bool {
        let fm = FileManager.default
        switch backend {
        case "whisper":
            return WhisperKitTranscriber.isModelDownloaded(model)
        case "fluidaudio":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if model.contains("parakeet") {
                let version = model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    return contents.contains { $0.lastPathComponent.contains("parakeet") && $0.lastPathComponent.contains(version) }
                }
            }
            return false
        case "qwen":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            return fm.fileExists(atPath: supportDir.appendingPathComponent("int8/vocab.json").path)
                || fm.fileExists(atPath: supportDir.appendingPathComponent("f32/vocab.json").path)
        case "nemotron":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron-560ms/encoder/encoder_int8.mlmodelc")
            return fm.fileExists(atPath: path.path)
        case "canary":
            return CanaryQwenModelStore.isAvailableLocally()
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        default:
            return false
        }
    }
}

struct SummaryModelPreset {
    let id: String
    let label: String

    static let openAIModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.4-pro", label: "GPT-5.4 Pro"),
        SummaryModelPreset(id: "gpt-5-mini", label: "GPT-5 Mini"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
    ]

    static let chatGPTModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini (default)"),
        SummaryModelPreset(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
        SummaryModelPreset(id: "gpt-4o", label: "GPT-4o"),
    ]

    static let computerUsePlannerModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "gpt-5.5", label: "GPT-5.5 (default)"),
        SummaryModelPreset(id: "gpt-5.4", label: "GPT-5.4"),
        SummaryModelPreset(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
        SummaryModelPreset(id: "gpt-5.2", label: "GPT-5.2"),
    ]

    static let openRouterModels: [SummaryModelPreset] = [
        SummaryModelPreset(id: "stepfun/step-3.5-flash:free", label: "Step 3.5 Flash (256k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-super-120b-a12b:free", label: "Nemotron 3 Super 120B (262k ctx)"),
        SummaryModelPreset(id: "nvidia/nemotron-3-nano-30b-a3b:free", label: "Nemotron 3 Nano 30B (256k ctx)"),
        SummaryModelPreset(id: "arcee-ai/trinity-large-preview:free", label: "Trinity Large (131k ctx)"),
    ]

    static func menuPresets(_ presets: [SummaryModelPreset], currentModel: String) -> [SummaryModelPreset] {
        let trimmedModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return presets }
        guard !presets.contains(where: { $0.id == trimmedModel }) else { return presets }
        return presets + [SummaryModelPreset(id: trimmedModel, label: "Custom: \(trimmedModel)")]
    }
}

struct OpenRouterModelCatalog: Decodable {
    let data: [OpenRouterModel]
}

struct OpenRouterModel: Decodable {
    let id: String
    let name: String
    let contextLength: Int?
    let pricing: Pricing
    let architecture: Architecture?

    struct Pricing: Decodable {
        let prompt: String?
        let completion: String?
        let request: String?

        var isFreeForTextGeneration: Bool {
            isExplicitZero(prompt)
                && isExplicitZero(completion)
                && isZeroOrMissing(request)
        }

        private func isExplicitZero(_ value: String?) -> Bool {
            guard let value else { return false }
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) == 0
        }

        private func isZeroOrMissing(_ value: String?) -> Bool {
            guard let value else { return true }
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) == 0
        }
    }

    struct Architecture: Decodable {
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case outputModalities = "output_modalities"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contextLength = "context_length"
        case pricing
        case architecture
    }
}

extension OpenRouterModel {
    var producesOnlyText: Bool {
        guard let outputModalities = architecture?.outputModalities else {
            return false
        }
        return outputModalities == ["text"]
    }

    var summaryPresetLabel: String {
        if let contextLength, contextLength > 0 {
            return "\(name) (\(Self.formatContextLength(contextLength)) ctx)"
        }
        return name
    }

    private static func formatContextLength(_ value: Int) -> String {
        if value >= 1000 {
            return "\(value / 1000)k"
        }
        return "\(value)"
    }
}

enum OpenRouterModelCatalogFilter {
    private static let minimumSummaryContextLength = 100_000

    static func freeTextSummaryPresets(from models: [OpenRouterModel]) -> [SummaryModelPreset] {
        models
            .filter { model in
                model.producesOnlyText
                    && model.pricing.isFreeForTextGeneration
                    && (model.contextLength ?? 0) >= minimumSummaryContextLength
            }
            .sorted {
                if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.id < $1.id
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { SummaryModelPreset(id: $0.id, label: $0.summaryPresetLabel) }
    }
}

struct MeetingSummaryBackendOption: Equatable {
    let backend: String
    let label: String

    static let openAI = MeetingSummaryBackendOption(
        backend: "openai",
        label: "OpenAI"
    )

    static let openRouter = MeetingSummaryBackendOption(
        backend: "openrouter",
        label: "OpenRouter"
    )

    static let chatGPT = MeetingSummaryBackendOption(
        backend: "chatgpt",
        label: "ChatGPT"
    )

    static let ollama = MeetingSummaryBackendOption(
        backend: "ollama",
        label: "Ollama"
    )

    static let all: [MeetingSummaryBackendOption] = [.chatGPT, .openAI, .openRouter, .ollama]

    static func resolved(_ backend: String?) -> MeetingSummaryBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .chatGPT
        }
        return option
    }
}

struct SalesAgentBackendOption: Equatable {
    let backend: String
    let label: String

    static let localPlanner = SalesAgentBackendOption(
        backend: "local_planner",
        label: "Local Sales Caddie"
    )

    static let hostedJessica = SalesAgentBackendOption(
        backend: "hosted_jessica",
        label: "Hosted Jessica"
    )

    static let openAI = SalesAgentBackendOption(
        backend: "openai",
        label: "OpenAI"
    )

    static let openRouter = SalesAgentBackendOption(
        backend: "openrouter",
        label: "OpenRouter"
    )

    static let ollama = SalesAgentBackendOption(
        backend: "ollama",
        label: "Ollama"
    )

    static let customWebhook = SalesAgentBackendOption(
        backend: "custom_webhook",
        label: "Custom Webhook"
    )

    static let all: [SalesAgentBackendOption] = [
        .hostedJessica,
        .openAI,
        .openRouter,
        .ollama,
        .customWebhook,
    ]

    static func resolved(_ backend: String?) -> SalesAgentBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .hostedJessica
        }
        return option
    }
}

struct SalesAgentUserOption: Equatable, Identifiable {
    let id: String
    let name: String
    let role: String
    let repKey: String

    var label: String { name }

    static let mike = SalesAgentUserOption(id: "mike", name: "Mike Preece", role: "admin", repKey: "mike")
    static let tommy = SalesAgentUserOption(id: "tommy", name: "Tommy", role: "rep", repKey: "tommy")
    static let kaden = SalesAgentUserOption(id: "kaden", name: "Kaden", role: "rep", repKey: "kaden")
    static let clay = SalesAgentUserOption(id: "clay", name: "Clay", role: "rep", repKey: "clay")
    static let jason = SalesAgentUserOption(id: "jason", name: "Jason", role: "rep", repKey: "jason")
    static let kaleb = SalesAgentUserOption(id: "kaleb", name: "Kaleb", role: "rep", repKey: "kaleb")

    static let all: [SalesAgentUserOption] = [.mike, .tommy, .kaden, .clay, .jason, .kaleb]

    static func resolved(userID: String?, repKey: String?) -> SalesAgentUserOption? {
        let normalizedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRepKey = repKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { option in
            option.id == normalizedUserID || option.repKey == normalizedRepKey
        }
    }
}

struct SalesAgentHistoryItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var createdAt: Date = Date()
    var provider: String = SalesAgentBackendOption.localPlanner.backend
    var transcript: String = ""
    var response: String = ""
    var plannerCommand: String?
    var status: String = "done"

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case provider
        case transcript
        case response
        case plannerCommand = "planner_command"
        case status
    }
}

struct PostProcessorOption: Identifiable, Equatable {
    let id: String
    let label: String
    let sizeLabel: String
    let description: String
    let downloadURL: URL
    let filename: String

    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/postproc-\(id)", isDirectory: true)
    }

    var modelURL: URL {
        cacheDirectory.appendingPathComponent(filename)
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    // Fine-tuned Qwen3-0.6B trained on Muesli dictation correction data.
    // HF repo must be public (or token-gated) before distributing alpha builds.
    static let finetunedV2 = PostProcessorOption(
        id: "qwen3-postproc-v2",
        label: "Post-Proc v2 (Finetuned)",
        sizeLabel: "~390 MB",
        description: "Fine-tuned on Muesli dictation data. Best for filler removal, deletion cues, and spoken list formatting.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen3-postproc-v2/resolve/main/qwen3-postproc-v2-q4_k_m.gguf")!,
        filename: "qwen3-postproc-v2-q4_k_m.gguf"
    )

    // Vanilla Qwen3.5-0.8B. Stable for basic cleanup; does not reliably convert spoken list cues.
    static let qwen35_0_8b = PostProcessorOption(
        id: "qwen35-0.8b",
        label: "Qwen3.5 0.8B",
        sizeLabel: "~533 MB",
        description: "Vanilla Qwen3.5-0.8B. Good for typo correction and filler removal. Spoken list formatting is unreliable.",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!,
        filename: "Qwen3.5-0.8B-Q4_K_M.gguf"
    )

    // Fine-tuned Qwen3.5-0.8B v3 trained on Muesli dictation correction data.
    static let finetunedV3 = PostProcessorOption(
        id: "qwen35-postproc-v3",
        label: "Post-Proc v3 (Finetuned)",
        sizeLabel: "~505 MB",
        description: "Fine-tuned Qwen3.5-0.8B on Muesli dictation data. Improved over v2 on filler removal, deletion cues, and spoken list formatting.",
        downloadURL: URL(string: "https://huggingface.co/phequals/qwen35-postproc-v3-gguf/resolve/main/qwen35-postproc-v3-Q4_K_M.gguf")!,
        filename: "qwen35-postproc-v3-Q4_K_M.gguf"
    )

    static let all: [PostProcessorOption] = [.finetunedV3, .finetunedV2, .qwen35_0_8b]
    static let defaultOption: PostProcessorOption = .finetunedV3

    static var downloaded: [PostProcessorOption] {
        all.filter(\.isDownloaded)
    }

    static var downloadedIDs: Set<String> {
        Set(downloaded.map(\.id))
    }

    static func resolve(id: String) -> PostProcessorOption {
        all.first { $0.id == id } ?? defaultOption
    }

    static func firstDownloaded(excluding excludedID: String? = nil) -> PostProcessorOption? {
        firstDownloaded(excluding: excludedID, downloadedIDs: downloadedIDs)
    }

    static func firstDownloaded(excluding excludedID: String? = nil, downloadedIDs: Set<String>) -> PostProcessorOption? {
        all.first { option in
            option.id != excludedID && downloadedIDs.contains(option.id)
        }
    }

    static func resolveDownloaded(id: String) -> PostProcessorOption? {
        resolveDownloaded(id: id, downloadedIDs: downloadedIDs)
    }

    static func resolveDownloaded(id: String, downloadedIDs: Set<String>) -> PostProcessorOption? {
        let resolved = resolve(id: id)
        if downloadedIDs.contains(resolved.id) { return resolved }
        return firstDownloaded(downloadedIDs: downloadedIDs)
    }

    static func runtimeOption(id: String) -> PostProcessorOption? {
        runtimeOption(
            id: id,
            downloadedIDs: downloadedIDs,
            hasDevOverride: Qwen3PostProcessorConfig.devOverrideURL() != nil
        )
    }

    static func runtimeOption(id: String, downloadedIDs: Set<String>, hasDevOverride: Bool) -> PostProcessorOption? {
        let configured = resolve(id: id)
        if downloadedIDs.contains(configured.id) || hasDevOverride { return configured }
        return firstDownloaded(downloadedIDs: downloadedIDs)
    }

    static let defaultSystemPrompt = """
    Clean up speech-to-text transcription. Only make changes when there is a clear error. If the text is already correct, output it exactly as-is.

    You may: fix obvious misspellings, remove filler words (um, uh, like), apply 'scratch that' deletions, and format numbered or bullet lists when dictated.

    Do not: paraphrase, reword, add words, remove meaningful words, change the meaning in any way, wrap the output in markdown, code fences, tags, labels, or commentary, or repeat the output more than once. Preserve the speaker's original phrasing.
    """
}

struct CustomWord: Codable, Equatable, Identifiable {
    var id = UUID()
    var word: String
    var replacement: String?
    var matchingThreshold: Double = 0.85

    enum CodingKeys: String, CodingKey {
        case id
        case word
        case replacement
        case matchingThreshold = "matching_threshold"
    }

    init(id: UUID = UUID(), word: String, replacement: String?, matchingThreshold: Double = 0.85) {
        self.id = id
        self.word = word
        self.replacement = replacement
        self.matchingThreshold = Self.clampedThreshold(matchingThreshold)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement)
        matchingThreshold = Self.clampedThreshold(try c.decodeIfPresent(Double.self, forKey: .matchingThreshold) ?? 0.85)
    }

    var displayLabel: String {
        if let replacement, !replacement.isEmpty {
            return "\(word) → \(replacement)"
        }
        return word
    }

    var targetWord: String {
        replacement ?? word
    }

    private static func clampedThreshold(_ value: Double) -> Double {
        min(max(value, 0.70), 0.95)
    }
}

enum IndicatorAnchor: String, Codable, CaseIterable {
    case topLeading = "top_leading"
    case topCenter = "top_center"
    case topTrailing = "top_trailing"
    case midLeading = "mid_leading"
    case midTrailing = "mid_trailing"
    case bottomLeading = "bottom_leading"
    case bottomCenter = "bottom_center"
    case bottomTrailing = "bottom_trailing"
    case custom = "custom"

    var label: String {
        switch self {
        case .topLeading: return "Top Left"
        case .topCenter: return "Top Center"
        case .topTrailing: return "Top Right"
        case .midLeading: return "Middle Left"
        case .midTrailing: return "Middle Right"
        case .bottomLeading: return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomTrailing: return "Bottom Right"
        case .custom: return "Custom"
        }
    }
}

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16 = 61
    var label: String = "Right Option"

    // Key combination support (e.g. Cmd+Shift+R).
    // When set, the hotkey fires on keyDown with these modifiers held.
    // When nil, the hotkey is a single modifier key (existing behavior).
    var combinationModifiers: UInt? = nil
    var combinationKeyCode: UInt16? = nil

    var isCombination: Bool {
        combinationModifiers != nil && combinationKeyCode != nil
    }

    var displayLabel: String {
        if isCombination { return label }
        return Self.symbolLabel(for: keyCode) ?? label
    }

    static func label(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "Left Cmd"
        case 54: return "Right Cmd"
        case 63: return "Fn"
        case 59: return "Left Ctrl"
        case 62: return "Right Ctrl"
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        default: return nil
        }
    }

    static func symbolLabel(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 55: return "Left ⌘"
        case 54: return "Right ⌘"
        case 63: return "fn"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        default: return nil
        }
    }

    static func letterLabel(for keyCode: UInt16) -> String? {
        let letters: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
        ]
        return letters[keyCode]
    }

    static func combinationLabel(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        let modifiers = supportedCombinationModifiers(from: modifiers)
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        parts.append(letterLabel(for: keyCode) ?? "?")
        return parts.joined()
    }

    static func combination(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> HotkeyConfig {
        let supportedModifiers = supportedCombinationModifiers(from: modifiers)
        let lbl = combinationLabel(modifiers: supportedModifiers, keyCode: keyCode)
        return HotkeyConfig(
            keyCode: UInt16.max,
            label: lbl,
            combinationModifiers: UInt(supportedModifiers.rawValue),
            combinationKeyCode: keyCode
        )
    }

    static func supportedCombinationModifiers(from modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection([.command, .control, .option, .shift])
    }

    var resolvedCombinationModifiers: NSEvent.ModifierFlags? {
        guard let raw = combinationModifiers else { return nil }
        return Self.supportedCombinationModifiers(from: NSEvent.ModifierFlags(rawValue: raw))
    }

    static let `default` = HotkeyConfig()
    static let computerUseDefault = HotkeyConfig(keyCode: 54, label: "Right Cmd")
    static let jessicaDefault = HotkeyConfig(keyCode: 62, label: "Right Ctrl")
    static let meetingRecordingDefault = HotkeyConfig(
        keyCode: UInt16.max,
        label: "⌘⇧R",
        combinationModifiers: UInt(NSEvent.ModifierFlags([.command, .shift]).rawValue),
        combinationKeyCode: 15
    )

    static func computerUseDefault(avoiding dictationHotkey: HotkeyConfig) -> HotkeyConfig {
        dictationHotkey.keyCode == computerUseDefault.keyCode ? .default : .computerUseDefault
    }
}

enum OnboardingUseCase: String, Codable, CaseIterable {
    case voiceNotes = "voice_notes"
    case dictation = "dictation"
    case meetings = "meetings"
    case dictationAndMeetings = "dictation_and_meetings"

    var includesDictation: Bool {
        self == .dictation || self == .dictationAndMeetings
    }

    var includesVoiceNotes: Bool {
        self == .voiceNotes
    }

    var includesPushToTalk: Bool {
        includesVoiceNotes || includesDictation
    }

    var includesMeetings: Bool {
        self == .meetings || self == .dictationAndMeetings
    }

    var canSwitchToVoiceNotesOnly: Bool {
        self == .dictation
    }

    static func resolved(_ rawValue: String?) -> OnboardingUseCase {
        guard let rawValue, let useCase = OnboardingUseCase(rawValue: rawValue) else {
            return .dictation
        }
        return useCase
    }
}

struct SalesAssistObjection: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var priority: String = "medium"
    var triggerPhrases: String = ""
    var guidance: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case priority
        case triggerPhrases = "trigger_phrases"
        case guidance
    }
}

struct SalesAssistLiveCue: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: String = "buying_signal"
    var name: String = ""
    var priority: String = "medium"
    var triggerPhrases: String = ""
    var guidance: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case priority
        case triggerPhrases = "trigger_phrases"
        case guidance
    }
}

struct SalesAssistLearningSuggestion: Codable, Identifiable, Equatable {
    enum SuggestionKind: String, Codable {
        case knowledgeBase = "knowledge_base"
        case objection
    }

    var id: String
    var kind: SuggestionKind
    var title: String
    var content: String
    var reason: String
    var sourceTitle: String
    var createdAt: String
    var objection: SalesAssistObjection?

    init(
        id: String = UUID().uuidString,
        kind: SuggestionKind,
        title: String,
        content: String,
        reason: String,
        sourceTitle: String,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        objection: SalesAssistObjection? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.reason = reason
        self.sourceTitle = sourceTitle
        self.createdAt = createdAt
        self.objection = objection
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case content
        case reason
        case sourceTitle = "source_title"
        case createdAt = "created_at"
        case objection
    }
}

struct SalesAssistObjectionTuningExample: Codable, Identifiable, Equatable {
    enum Outcome: String, Codable {
        case accepted
        case falsePositive = "false_positive"
    }

    var id: String
    var objectionID: String
    var phrase: String
    var outcome: Outcome
    var source: String
    var createdAt: String

    init(
        id: String = UUID().uuidString,
        objectionID: String,
        phrase: String,
        outcome: Outcome,
        source: String = "manual",
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.objectionID = objectionID
        self.phrase = phrase
        self.outcome = outcome
        self.source = source
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case objectionID = "objection_id"
        case phrase
        case outcome
        case source
        case createdAt = "created_at"
    }
}

extension SalesAssistObjection {
    static let defaultKnowledgeBase = """
    Skriber is an AI medical scribe for SMB, solo, and small-group providers. It listens to patient encounters and generates structured clinical notes in roughly 10-30 seconds, including Chief Complaint, HPI, ROS, Objective, Assessment & Plan, billing codes, and patient instructions.

    Core positioning:
    - Close means trial started and account setup begun, not verbal interest.
    - Do not give generic close-rate advice. Coach the rep on the friction point that is preventing live setup.
    - Live account setup is the goal. Keep the prospect on the call while the trial is created, templates are assigned, and their first workflow is clear.
    - Always personalize the demo to the prospect's specialty. Never rely on a generic template.
    - The strongest conversion action is assigning templates live while the prospect watches.
    - The trial should feel low-risk: nothing charges during the trial, and templates can be built before they start using it.
    - If timing is the concern, negotiate the start date rather than accepting a vague follow-up.

    Product facts:
    - Pricing: annual is $85/month billed yearly; monthly is $125/month. Annual saves roughly five months.
    - Trial: 10 visits or 14 days; card on file for the paid trial. Use the Netflix analogy: card on file, nothing bills until trial ends.
    - Custom templates are unlimited and can be built in 3-5 minutes through support.
    - Works with every EHR through copy/paste. Direct integrations cost more and take much longer.
    - Supports ICD-10, CPT, DSM-5, CDT, Advanced Clinical Reasoning, Spanish-to-English, style learning, resume recording, and 24/7 support.
    - HIPAA/GDPR compliant, ISO 27001 certified, BAA available, encrypted in transit and at rest, patient data is not used to train public AI models.

    Demo flow:
    1. Set agenda: discovery, live demo, free trial.
    2. Ask about specialty, note workflow, EMR, time spent charting, billing/coding pain, and decision-maker.
    3. Use their specialty template and a specialty-specific mock patient.
    4. Pause after note generation and ask how long their typical note takes.
    5. Show copy/paste to EHR and mention their EHR by name.
    6. Close by tying the trial to their stated pain and begin setup live.

    Best coaching instincts:
    - Label the concern first, then ask one clarifying question.
    - Convert soft exits into a concrete next step while still on the call.
    - For partner/manager approval, book the second decision-maker demo immediately.
    - For institutional approval, split personal/private patients from hospital/VA/risk-management patients.
    - For competitor objections, suggest a side-by-side trial and anchor on templates, specialty depth, support, and price.
    - For price objections, use time math: $85/month is less than $3/day and far cheaper than human scribes.
    - For HIPAA concerns, answer clearly, offer BAA/compliance summary, then move back to trial setup.
    """

    static let defaultObjections: [SalesAssistObjection] = [
        SalesAssistObjection(
            name: "Decision hesitation",
            priority: "high",
            triggerPhrases: "think about it\nsleep on it\nnot sure\nneed more time\nlet me think\non the fence\nconsider it",
            guidance: "Label it, then lower the risk: \"Totally fair. Let's get the trial open now so you can decide from real notes, not a sales call. I'll build the templates while you think it over.\""
        ),
        SalesAssistObjection(
            name: "Partner or manager approval",
            priority: "high",
            triggerPhrases: "talk to my wife\ntalk to my husband\ntalk to my partner\nask my office manager\ncheck with my manager\nask my boss\nneed approval\nsign off",
            guidance: "Do not accept a vague follow-up. Offer to book the decision-maker now: \"Can we grab 15 minutes with them? I'll show the ROI and templates so you have an easy yes/no.\""
        ),
        SalesAssistObjection(
            name: "Institutional approval",
            priority: "high",
            triggerPhrases: "hospital approval\nrisk management\nmedical director\nVA approval\nDOD approval\nIT department\nprocurement\ncompliance department\nemployer has to approve",
            guidance: "Split the population: \"Does that restriction cover every patient you see, or do you have private/per diem patients where you decide? If so, let's start that today while institutional approval runs.\""
        ),
        SalesAssistObjection(
            name: "Card resistance",
            priority: "high",
            triggerPhrases: "credit card\ncard on file\npayment information\nbilling info\nwhy do you need my card\nnot comfortable giving card\nfree trial card",
            guidance: "Use the Netflix analogy: \"Nothing bills during the trial. The card only keeps the account live if you decide to continue. If it doesn't save time, we cancel before anything charges.\""
        ),
        SalesAssistObjection(
            name: "Send information soft exit",
            priority: "high",
            triggerPhrases: "send me info\nemail me information\nsend me pricing\nsend me details\nsend me a link\nlook at it later\nreview it later",
            guidance: "Do not let the call end as a brochure handoff. Say: \"I can send it, but it'll make more sense after we anchor it to your workflow. Give me 90 seconds and I'll show the exact next step.\""
        ),
        SalesAssistObjection(
            name: "Bad timing",
            priority: "medium",
            triggerPhrases: "too busy\nbad timing\nnot a good time\ncall me back later\nstart later\nnot ready yet\nmaybe next month",
            guidance: "Negotiate the start date: \"Trial starts when you start, not today. I'll build templates now so day one is ready. What date should we have it start?\""
        ),
        SalesAssistObjection(
            name: "Price concern",
            priority: "medium",
            triggerPhrases: "too expensive\ncosts too much\nprice is high\nbudget\nafford\ncheaper\nmonthly cost",
            guidance: "Use time math: \"$85/month is less than $3/day. If it saves even one admin hour or a few minutes per patient, it pays for itself quickly.\""
        ),
        SalesAssistObjection(
            name: "Competitor in use",
            priority: "medium",
            triggerPhrases: "using freed\nusing heidi\nusing doximity\nusing dragon\nusing dax\nusing abridge\nusing suki\nalready have a scribe\nalready use another tool",
            guidance: "Suggest a side-by-side trial: \"Keep what you're using. Let's compare Skriber on your specialty templates, support, and note quality for 30 days. If it doesn't win, cancel.\""
        ),
        SalesAssistObjection(
            name: "Native EHR AI",
            priority: "medium",
            triggerPhrases: "EHR is building it\nEpic AI\nathena ambient\nnative AI\nbuilt into my EHR\nwaiting for my EMR",
            guidance: "Position specialty depth: \"Native EHR AI is built for everyone. Skriber is built around your specialty and custom templates. Try Skriber now so you have a benchmark.\""
        ),
        SalesAssistObjection(
            name: "HIPAA or privacy concern",
            priority: "high",
            triggerPhrases: "HIPAA\nprivacy\npatient consent\nBAA\nsecurity\ndata training\nrecording patients\nPHI",
            guidance: "Answer directly, then move forward: \"Yes, Skriber is HIPAA compliant, encrypted, BAA available, and patient data is not used to train public models. I can send the BAA; let's still get your trial ready.\""
        ),
        SalesAssistObjection(
            name: "Copy-paste or integration concern",
            priority: "medium",
            triggerPhrases: "doesn't integrate\nno integration\ncopy paste\nmanual transfer\nmy EHR won't work\ncheckbox heavy",
            guidance: "Use the time comparison: \"Copy/paste takes 2-3 minutes versus 20-30 minutes writing. We use this workflow to keep cost low and it works across EHRs.\""
        ),
        SalesAssistObjection(
            name: "Team adoption concern",
            priority: "medium",
            triggerPhrases: "doctors won't adopt\nteam won't use it\nproviders won't like it\nhard to get buy in\nstaff won't change",
            guidance: "Start with one workflow: \"Let's build your templates first. When they see a real note in their style, the value lands in 15 seconds.\""
        ),
        SalesAssistObjection(
            name: "Tried Skriber before",
            priority: "medium",
            triggerPhrases: "tried Skriber before\nused Skriber before\ndidn't work before\nhad issues before\ncancelled before",
            guidance: "Acknowledge and name the fix: \"That makes sense. Here's what's different now: [specific improvement]. I'll be your direct contact and we can do an extended high-touch trial.\""
        ),
        SalesAssistObjection(
            name: "ChatGPT comparison",
            priority: "medium",
            triggerPhrases: "just use ChatGPT\nuse Gemini\nuse general AI\nfree AI",
            guidance: "Separate consumer AI from clinical workflow: \"Consumer AI is not HIPAA-safe for PHI and doesn't give you templates, billing codes, ambient capture, or clinical workflow support.\""
        ),
        SalesAssistObjection(
            name: "Accuracy concern",
            priority: "medium",
            triggerPhrases: "how accurate\naccuracy\nwrong notes\nhallucinate\ntrust the note\nmistakes",
            guidance: "Anchor to trial proof: \"The trial is the proof. We'll use your specialty template and real workflow so you can judge note quality before anything bills.\""
        )
    ]
}

extension SalesAssistLiveCue {
    static let supportedKinds = ["objection", "buying_signal", "competitor", "discovery", "pricing", "close", "talk_ratio"]
    static let defaultEnabledKinds = supportedKinds

    static let kindLabels: [String: String] = [
        "objection": "Objections",
        "buying_signal": "Buying signals",
        "competitor": "Battlecards",
        "discovery": "Discovery prompts",
        "pricing": "Pricing/card guidance",
        "close": "Close-now moments",
        "talk_ratio": "Talk-time nudges",
    ]

    static let defaultCues: [SalesAssistLiveCue] = [
        SalesAssistLiveCue(
            kind: "buying_signal",
            name: "Trial interest",
            priority: "medium",
            triggerPhrases: "how do we get started\nwhat is the next step\nstart the trial\nsounds good\ni like this\nthis could work",
            guidance: "Treat this as permission to close. Tie the trial to their pain in one sentence, then start account setup while they are live."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Competitor mentioned",
            priority: "medium",
            triggerPhrases: "competitor\nanother scribe\nanother tool\nalready have a scribe\nalready use another tool\nalready using an AI scribe",
            guidance: "Ask what they like and what still takes work. Offer a side-by-side trial using their specialty templates, note quality, support, and price."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Freed Battlecard",
            priority: "medium",
            triggerPhrases: "Freed\nusing Freed\nFreed AI\nFreed scribe",
            guidance: "Ask what Freed does well and where it still creates cleanup. Contrast on specialty templates, support, billing/code help, and a live side-by-side trial."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Heidi Battlecard",
            priority: "medium",
            triggerPhrases: "Heidi\nusing Heidi\nHeidi Health\nHeidi AI",
            guidance: "Do not argue broad AI quality. Ask whether Heidi matches their specialty note style, then position Skriber around custom templates, support, and workflow fit."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Doximity Battlecard",
            priority: "medium",
            triggerPhrases: "Doximity\nDoximity scribe\nDoximity GPT\nDoximity AI",
            guidance: "Ask if they use Doximity for actual full notes or quick drafting. Position Skriber as the workflow tool for specialty templates, patient instructions, codes, and repeat daily use."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Dragon/DAX Battlecard",
            priority: "medium",
            triggerPhrases: "Dragon\nNuance\nDAX\nDAX Copilot\nDragon Ambient",
            guidance: "Acknowledge Dragon/DAX as established. Ask about cost, setup, and template flexibility, then compare Skriber as faster to trial, easier to customize, and lower-risk for small practices."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Nabla Battlecard",
            priority: "medium",
            triggerPhrases: "Nabla\nusing Nabla\nNabla Copilot",
            guidance: "Ask what part of Nabla they like and whether the output matches their specialty. Offer a side-by-side test on the same visit style and compare cleanup time."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Suki Battlecard",
            priority: "medium",
            triggerPhrases: "Suki\nusing Suki\nSuki AI",
            guidance: "Ask whether Suki is solving notes, orders, or enterprise workflow. Recenter on small-practice speed: custom templates, fast setup, lower price, and direct support."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Abridge Battlecard",
            priority: "medium",
            triggerPhrases: "Abridge\nusing Abridge\nAbridge AI",
            guidance: "Acknowledge Abridge as a strong enterprise option. Ask if they can start quickly and customize notes; position Skriber as easier to trial and tailor for their exact specialty."
        ),
        SalesAssistLiveCue(
            kind: "competitor",
            name: "Native EHR AI Battlecard",
            priority: "medium",
            triggerPhrases: "Epic AI\nathena ambient\nEHR AI\nEMR AI\nnative AI\nbuilt into my EHR\nwaiting for my EHR",
            guidance: "Do not fight the EHR roadmap. Say native AI is built for everyone; Skriber can be tested now against their specialty workflow and becomes the benchmark."
        ),
        SalesAssistLiveCue(
            kind: "discovery",
            name: "Quantify charting pain",
            priority: "medium",
            triggerPhrases: "charting takes\nnotes take\ndocumentation takes\nlate at night\nafter hours\nbehind on notes",
            guidance: "Ask: \"How many minutes per patient does that usually cost you, and how many patients do you see on a normal day?\""
        ),
        SalesAssistLiveCue(
            kind: "discovery",
            name: "Map EHR workflow",
            priority: "medium",
            triggerPhrases: "Epic\nathena\nCerner\nEHR\nEMR\ncopy paste\nintegration",
            guidance: "Ask: \"Where does the note need to land in your EHR, and what part of that handoff is most annoying today?\""
        ),
        SalesAssistLiveCue(
            kind: "discovery",
            name: "Anchor template fit",
            priority: "medium",
            triggerPhrases: "specialty\ntemplate\nSOAP\nHPI\nassessment and plan\nbilling codes",
            guidance: "Ask: \"What does a great note look like for your specialty, and what would make a generated note unusable for you?\""
        ),
        SalesAssistLiveCue(
            kind: "discovery",
            name: "Define trial success",
            priority: "medium",
            triggerPhrases: "trial\ntest it\ntry it\nget started\npricing\ncard",
            guidance: "Ask: \"If we start the trial, what would you need to see in the first few visits to feel confident keeping it?\""
        ),
        SalesAssistLiveCue(
            kind: "close",
            name: "Close the trial",
            priority: "high",
            triggerPhrases: "let's do it\nsign me up\nget me started\nset it up\nready to start\nmove forward",
            guidance: "Move immediately to setup. Ask for the best email, confirm specialty, and keep talking while the account and templates are created."
        ),
    ]

    static let seedCueNamesForMigration: Set<String> = Set(defaultCues.map(\.name))

    static func appendingMissingSeedCues(to cues: [SalesAssistLiveCue]) -> [SalesAssistLiveCue] {
        let existingNames = Set(cues.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let missing = defaultCues.filter { cue in
            seedCueNamesForMigration.contains(cue.name)
                && !existingNames.contains(cue.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return cues + missing
    }
}

struct AppConfig: Codable {
    var dictationHotkey: HotkeyConfig = .default
    var computerUseHotkey: HotkeyConfig = .computerUseDefault
    var enableComputerUseHotkey: Bool = false
    var jessicaHotkey: HotkeyConfig = .jessicaDefault
    var enableJessicaHotkey: Bool = false
    var meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault
    var enableMeetingRecordingHotkey: Bool = false
    var computerUseHotkeyDefaultDisabledMigrationApplied: Bool = true
    var enableComputerUsePlanner: Bool = true
    var computerUsePlannerModel: String = ""
    var computerUseTimeoutSeconds: Int = 120
    var sttBackend: String = BackendOption.whisper.backend
    var sttModel: String = BackendOption.whisper.model
    var cohereLanguage: String = CohereTranscribeLanguage.defaultLanguage.rawValue
    var meetingTranscriptionBackend: String = BackendOption.whisper.backend
    var meetingTranscriptionModel: String = BackendOption.whisper.model
    var meetingSummaryBackend: String = MeetingSummaryBackendOption.chatGPT.backend
    var defaultMeetingTemplateID: String = MeetingTemplates.autoID
    var whisperModel: String = BackendOption.whisper.model
    var idleTimeout: Double = 120
    var autoRecordMeetings: Bool = false
    var showScheduledMeetingNotifications: Bool = true
    var showMeetingDetectionNotification: Bool = true
    var mutedMeetingDetectionAppBundleIDs: [String] = []
    var meetingRecordingSavePolicy: MeetingRecordingSavePolicy = .never
    var darkMode: Bool = true
    var enableDoubleTapDictation: Bool = true
    var hotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultThresholdMilliseconds
    var computerUseHotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultThresholdMilliseconds
    var jessicaHotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultThresholdMilliseconds
    var meetingRecordingHotkeyTriggerThresholdMS: Int = HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds
    var launchAtLogin: Bool = false
    var openDashboardOnLaunch: Bool = true
    var showFloatingIndicator: Bool = true
    var indicatorAnchor: IndicatorAnchor = .midTrailing
    var dashboardWindowFrame: WindowFrame? = nil
    var indicatorOrigin: CGPointCodable? = nil
    var openAIAPIKey: String = ""
    var openRouterAPIKey: String = ""
    var openAIModel: String = ""
    var openRouterModel: String = ""
    var chatGPTModel: String = ""
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen3.5"
    var summaryModel: String = ""
    var meetingSummaryModel: String = ""
    var hasCompletedOnboarding: Bool = false
    var onboardingUseCase: String = OnboardingUseCase.dictation.rawValue
    var userName: String = ""
    var customMeetingTemplates: [CustomMeetingTemplate] = []
    var customWords: [CustomWord] = [
        CustomWord(word: "muesli", replacement: "muesli"),
    ]
    var folderOrder: [Int64] = []
    var soundEnabled: Bool = true
    var pauseMediaDuringDictation: Bool = false
    var muteSystemAudioDuringDictation: Bool = false
    var recordingColorHex: String = "1e1e2e"   // Catppuccin Mocha base, without #
    var menuBarIcon: String = "sales-caddie"
    var showNextMeetingInMenuBar: Bool = true
    var maraudersMapUnlocked: Bool = false
    var maraudersMapAudioClip: String = "bbc_world_news"
    var maraudersMapCustomAudioPath: String?
    var hiddenCalendarEventIDs: [String] = []
    var disabledCalendarIDs: [String] = []
    var googleCalendarPrimaryOnlyDefaultApplied: Bool = false
    var eventKitSubscriptionCalendarDefaultApplied: Bool = false
    var enablePostProcessor: Bool = false
    var activePostProcessorId: String = PostProcessorOption.defaultOption.id
    var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    var enableScreenContext: Bool = false
    var useCoreAudioTap: Bool = true
    var meetingHookEnabled: Bool = false
    var meetingHookPath: String = ""
    var meetingHookTimeoutSeconds: Int = 30
    var salesCaddieInstallID: String = UUID().uuidString
    var salesCaddieCloudSyncEnabled: Bool = false
    var salesCaddieCloudAPIURL: String = ""
    var salesCaddieCloudAPIToken: String = ""
    var salesCaddieCloudWorkspaceSlug: String = ""
    var salesCaddieCloudPermissions: SalesCaddiePermissions? = nil
    var supabaseSyncEnabled: Bool = false
    var supabaseURL: String = ""
    var supabaseAnonKey: String = ""
    var supabaseWorkspaceID: String = ""
    var supabaseUserID: String = ""
    var supabaseSyncJessicaHistory: Bool = true
    var supabaseSyncTranscripts: Bool = false
    var supabaseSyncSalesLibrary: Bool = false
    var salesAssistAdminManagedLibraryEnabled: Bool = false
    var salesAssistAdminLibraryURL: String = ""
    var salesAssistAdminLibraryUpdatedAt: String = ""
    var salesAssistKnowledgeBaseItemID: String = UUID().uuidString
    var salesAgentBackend: String = SalesAgentBackendOption.hostedJessica.backend
    var salesAgentEndpointURL: String = ""
    var salesAgentAuthToken: String = ""
    var salesAgentModel: String = ""
    var salesAgentUserID: String = ""
    var salesAgentUserName: String = ""
    var salesAgentUserRole: String = ""
    var salesAgentRepKey: String = ""
    var salesAgentAllowComputerActions: Bool = false
    var salesAgentSendScreenContext: Bool = false
    var salesAgentSendKnowledgeBase: Bool = true
    var salesAgentHistory: [SalesAgentHistoryItem] = []
    var salesAssistEnabled: Bool = true
    var salesAssistAIEnabled: Bool = true
    var salesAssistEnabledKinds: [String] = SalesAssistLiveCue.defaultEnabledKinds
    var salesAssistKnowledgeBase: String = SalesAssistObjection.defaultKnowledgeBase
    var salesAssistObjections: [SalesAssistObjection] = SalesAssistObjection.defaultObjections
    var salesAssistLiveCues: [SalesAssistLiveCue] = SalesAssistLiveCue.defaultCues
    var salesAssistLearningSuggestions: [SalesAssistLearningSuggestion] = []
    var salesAssistObjectionTuningExamples: [SalesAssistObjectionTuningExample] = []
    var salesPreCallBriefingModules: [SalesPreCallBriefingModule] = SalesPreCallBriefingModule.defaultModules
    var salesPreCallCRMProvider: String = SalesCRMProvider.none.rawValue
    var salesPreCallCRMConnectionLabel: String = ""
    var salesPreCallHighLevelBaseURL: String = "https://services.leadconnectorhq.com"
    var salesPreCallHighLevelToken: String = ""
    var salesPreCallHighLevelLocationID: String = ""

    enum CodingKeys: String, CodingKey {
        case dictationHotkey = "dictation_hotkey"
        case computerUseHotkey = "computer_use_hotkey"
        case enableComputerUseHotkey = "enable_computer_use_hotkey"
        case jessicaHotkey = "jessica_hotkey"
        case enableJessicaHotkey = "enable_jessica_hotkey"
        case meetingRecordingHotkey = "meeting_recording_hotkey"
        case enableMeetingRecordingHotkey = "enable_meeting_recording_hotkey"
        case computerUseHotkeyDefaultDisabledMigrationApplied = "computer_use_hotkey_default_disabled_migration_applied"
        case enableComputerUsePlanner = "enable_computer_use_planner"
        case computerUsePlannerModel = "computer_use_planner_model"
        case computerUseTimeoutSeconds = "computer_use_timeout_seconds"
        case sttBackend = "stt_backend"
        case sttModel = "stt_model"
        case cohereLanguage = "cohere_language"
        case meetingTranscriptionBackend = "meeting_transcription_backend"
        case meetingTranscriptionModel = "meeting_transcription_model"
        case meetingSummaryBackend = "meeting_summary_backend"
        case defaultMeetingTemplateID = "default_meeting_template_id"
        case whisperModel = "whisper_model"
        case idleTimeout = "idle_timeout"
        case autoRecordMeetings = "auto_record_meetings"
        case showScheduledMeetingNotifications = "show_scheduled_meeting_notifications"
        case showMeetingDetectionNotification = "show_meeting_detection_notification"
        case mutedMeetingDetectionAppBundleIDs = "muted_meeting_detection_app_bundle_ids"
        case meetingRecordingSavePolicy = "meeting_recording_save_policy"
        case darkMode = "dark_mode"
        case enableDoubleTapDictation = "enable_double_tap_dictation"
        case hotkeyTriggerThresholdMS = "hotkey_trigger_threshold_ms"
        case computerUseHotkeyTriggerThresholdMS = "computer_use_hotkey_trigger_threshold_ms"
        case jessicaHotkeyTriggerThresholdMS = "jessica_hotkey_trigger_threshold_ms"
        case meetingRecordingHotkeyTriggerThresholdMS = "meeting_recording_hotkey_trigger_threshold_ms"
        case launchAtLogin = "launch_at_login"
        case openDashboardOnLaunch = "open_dashboard_on_launch"
        case showFloatingIndicator = "show_floating_indicator"
        case indicatorAnchor = "indicator_anchor"
        case dashboardWindowFrame = "dashboard_window_frame"
        case indicatorOrigin = "indicator_origin"
        case openAIAPIKey = "openai_api_key"
        case openRouterAPIKey = "openrouter_api_key"
        case openAIModel = "openai_model"
        case openRouterModel = "openrouter_model"
        case chatGPTModel = "chatgpt_model"
        case ollamaURL = "ollama_url"
        case ollamaModel = "ollama_model"
        case summaryModel = "summary_model"
        case meetingSummaryModel = "meeting_summary_model"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case onboardingUseCase = "onboarding_use_case"
        case userName = "user_name"
        case customMeetingTemplates = "custom_meeting_templates"
        case customWords = "custom_words"
        case folderOrder = "folder_order"
        case soundEnabled = "sound_enabled"
        case pauseMediaDuringDictation = "pause_media_during_dictation"
        case muteSystemAudioDuringDictation = "mute_system_audio_during_dictation"
        case recordingColorHex = "recording_color_hex"
        case menuBarIcon = "menu_bar_icon"
        case showNextMeetingInMenuBar = "show_next_meeting_in_menu_bar"
        case maraudersMapUnlocked = "marauders_map_unlocked"
        case maraudersMapAudioClip = "marauders_map_audio_clip"
        case maraudersMapCustomAudioPath = "marauders_map_custom_audio_path"
        case hiddenCalendarEventIDs = "hidden_calendar_event_ids"
        case disabledCalendarIDs = "disabled_calendar_ids"
        case googleCalendarPrimaryOnlyDefaultApplied = "google_calendar_primary_only_default_applied"
        case eventKitSubscriptionCalendarDefaultApplied = "eventkit_subscription_calendar_default_applied"
        case enablePostProcessor = "enable_post_processor"
        case activePostProcessorId = "active_post_processor_id"
        case postProcessorSystemPrompt = "post_processor_system_prompt"
        case enableScreenContext = "enable_screen_context"
        case useCoreAudioTap = "use_core_audio_tap"
        case meetingHookEnabled = "meeting_hook_enabled"
        case meetingHookPath = "meeting_hook_path"
        case meetingHookTimeoutSeconds = "meeting_hook_timeout_seconds"
        case salesCaddieInstallID = "sales_caddie_install_id"
        case salesCaddieCloudSyncEnabled = "sales_caddie_cloud_sync_enabled"
        case salesCaddieCloudAPIURL = "sales_caddie_cloud_api_url"
        case salesCaddieCloudAPIToken = "sales_caddie_cloud_api_token"
        case salesCaddieCloudWorkspaceSlug = "sales_caddie_cloud_workspace_slug"
        case salesCaddieCloudPermissions = "sales_caddie_cloud_permissions"
        case supabaseSyncEnabled = "supabase_sync_enabled"
        case supabaseURL = "supabase_url"
        case supabaseAnonKey = "supabase_anon_key"
        case supabaseWorkspaceID = "supabase_workspace_id"
        case supabaseUserID = "supabase_user_id"
        case supabaseSyncJessicaHistory = "supabase_sync_jessica_history"
        case supabaseSyncTranscripts = "supabase_sync_transcripts"
        case supabaseSyncSalesLibrary = "supabase_sync_sales_library"
        case salesAssistAdminManagedLibraryEnabled = "sales_assist_admin_managed_library_enabled"
        case salesAssistAdminLibraryURL = "sales_assist_admin_library_url"
        case salesAssistAdminLibraryUpdatedAt = "sales_assist_admin_library_updated_at"
        case salesAssistKnowledgeBaseItemID = "sales_assist_knowledge_base_item_id"
        case salesAgentBackend = "sales_agent_backend"
        case salesAgentEndpointURL = "sales_agent_endpoint_url"
        case salesAgentAuthToken = "sales_agent_auth_token"
        case salesAgentModel = "sales_agent_model"
        case salesAgentUserID = "sales_agent_user_id"
        case salesAgentUserName = "sales_agent_user_name"
        case salesAgentUserRole = "sales_agent_user_role"
        case salesAgentRepKey = "sales_agent_rep_key"
        case salesAgentAllowComputerActions = "sales_agent_allow_computer_actions"
        case salesAgentSendScreenContext = "sales_agent_send_screen_context"
        case salesAgentSendKnowledgeBase = "sales_agent_send_knowledge_base"
        case salesAgentHistory = "sales_agent_history"
        case salesAssistEnabled = "sales_assist_enabled"
        case salesAssistAIEnabled = "sales_assist_ai_enabled"
        case salesAssistEnabledKinds = "sales_assist_enabled_kinds"
        case salesAssistKnowledgeBase = "sales_assist_knowledge_base"
        case salesAssistObjections = "sales_assist_objections"
        case salesAssistLiveCues = "sales_assist_live_cues"
        case salesAssistLearningSuggestions = "sales_assist_learning_suggestions"
        case salesAssistObjectionTuningExamples = "sales_assist_objection_tuning_examples"
        case salesPreCallBriefingModules = "sales_pre_call_briefing_modules"
        case salesPreCallCRMProvider = "sales_pre_call_crm_provider"
        case salesPreCallCRMConnectionLabel = "sales_pre_call_crm_connection_label"
        case salesPreCallHighLevelBaseURL = "sales_pre_call_high_level_base_url"
        case salesPreCallHighLevelToken = "sales_pre_call_high_level_token"
        case salesPreCallHighLevelLocationID = "sales_pre_call_high_level_location_id"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        dictationHotkey = (try? c.decode(HotkeyConfig.self, forKey: .dictationHotkey)) ?? defaults.dictationHotkey
        computerUseHotkey = (try? c.decode(HotkeyConfig.self, forKey: .computerUseHotkey))
            ?? HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
        let hasAppliedComputerUseHotkeyDefaultMigration = c.contains(.computerUseHotkeyDefaultDisabledMigrationApplied)
        enableComputerUseHotkey = hasAppliedComputerUseHotkeyDefaultMigration
            ? ((try? c.decode(Bool.self, forKey: .enableComputerUseHotkey)) ?? defaults.enableComputerUseHotkey)
            : false
        computerUseHotkeyDefaultDisabledMigrationApplied = true
        jessicaHotkey = (try? c.decode(HotkeyConfig.self, forKey: .jessicaHotkey)) ?? defaults.jessicaHotkey
        enableJessicaHotkey = (try? c.decode(Bool.self, forKey: .enableJessicaHotkey)) ?? defaults.enableJessicaHotkey
        meetingRecordingHotkey = (try? c.decode(HotkeyConfig.self, forKey: .meetingRecordingHotkey)) ?? defaults.meetingRecordingHotkey
        enableMeetingRecordingHotkey = (try? c.decode(Bool.self, forKey: .enableMeetingRecordingHotkey)) ?? defaults.enableMeetingRecordingHotkey
        enableComputerUsePlanner = (try? c.decode(Bool.self, forKey: .enableComputerUsePlanner)) ?? defaults.enableComputerUsePlanner
        computerUsePlannerModel = (try? c.decode(String.self, forKey: .computerUsePlannerModel)) ?? defaults.computerUsePlannerModel
        computerUseTimeoutSeconds = (try? c.decode(Int.self, forKey: .computerUseTimeoutSeconds)) ?? defaults.computerUseTimeoutSeconds
        sttBackend = (try? c.decode(String.self, forKey: .sttBackend)) ?? defaults.sttBackend
        sttModel = (try? c.decode(String.self, forKey: .sttModel)) ?? defaults.sttModel
        cohereLanguage = CohereTranscribeLanguage.resolvedCode(try? c.decode(String.self, forKey: .cohereLanguage))
        meetingTranscriptionBackend = (try? c.decode(String.self, forKey: .meetingTranscriptionBackend)) ?? sttBackend
        meetingTranscriptionModel = (try? c.decode(String.self, forKey: .meetingTranscriptionModel)) ?? sttModel
        meetingSummaryBackend = (try? c.decode(String.self, forKey: .meetingSummaryBackend)) ?? defaults.meetingSummaryBackend
        defaultMeetingTemplateID = (try? c.decode(String.self, forKey: .defaultMeetingTemplateID)) ?? defaults.defaultMeetingTemplateID
        whisperModel = (try? c.decode(String.self, forKey: .whisperModel)) ?? defaults.whisperModel
        idleTimeout = (try? c.decode(Double.self, forKey: .idleTimeout)) ?? defaults.idleTimeout
        autoRecordMeetings = (try? c.decode(Bool.self, forKey: .autoRecordMeetings)) ?? defaults.autoRecordMeetings
        let decodedShowMeetingDetectionNotification = try? c.decode(Bool.self, forKey: .showMeetingDetectionNotification)
        showScheduledMeetingNotifications =
            (try? c.decode(Bool.self, forKey: .showScheduledMeetingNotifications))
            ?? decodedShowMeetingDetectionNotification
            ?? defaults.showScheduledMeetingNotifications
        showMeetingDetectionNotification = decodedShowMeetingDetectionNotification ?? defaults.showMeetingDetectionNotification
        mutedMeetingDetectionAppBundleIDs = (try? c.decode([String].self, forKey: .mutedMeetingDetectionAppBundleIDs)) ?? defaults.mutedMeetingDetectionAppBundleIDs
        meetingRecordingSavePolicy = (try? c.decode(MeetingRecordingSavePolicy.self, forKey: .meetingRecordingSavePolicy)) ?? defaults.meetingRecordingSavePolicy
        darkMode = (try? c.decode(Bool.self, forKey: .darkMode)) ?? defaults.darkMode
        enableDoubleTapDictation = (try? c.decode(Bool.self, forKey: .enableDoubleTapDictation)) ?? defaults.enableDoubleTapDictation
        hotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .hotkeyTriggerThresholdMS)) ?? defaults.hotkeyTriggerThresholdMS
        )
        computerUseHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .computerUseHotkeyTriggerThresholdMS)) ?? hotkeyTriggerThresholdMS
        )
        jessicaHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .jessicaHotkeyTriggerThresholdMS)) ?? hotkeyTriggerThresholdMS
        )
        meetingRecordingHotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(
            (try? c.decode(Int.self, forKey: .meetingRecordingHotkeyTriggerThresholdMS))
                ?? defaults.meetingRecordingHotkeyTriggerThresholdMS
        )
        launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        openDashboardOnLaunch = (try? c.decode(Bool.self, forKey: .openDashboardOnLaunch)) ?? defaults.openDashboardOnLaunch
        showFloatingIndicator = (try? c.decode(Bool.self, forKey: .showFloatingIndicator)) ?? defaults.showFloatingIndicator
        indicatorAnchor = (try? c.decode(IndicatorAnchor.self, forKey: .indicatorAnchor))
            ?? ((try? c.decodeIfPresent(CGPointCodable.self, forKey: .indicatorOrigin)) != nil ? .custom : .midTrailing)
        dashboardWindowFrame = try? c.decode(WindowFrame.self, forKey: .dashboardWindowFrame)
        indicatorOrigin = try? c.decode(CGPointCodable.self, forKey: .indicatorOrigin)
        openAIAPIKey = (try? c.decode(String.self, forKey: .openAIAPIKey)) ?? defaults.openAIAPIKey
        openRouterAPIKey = (try? c.decode(String.self, forKey: .openRouterAPIKey)) ?? defaults.openRouterAPIKey
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? defaults.openAIModel
        openRouterModel = (try? c.decode(String.self, forKey: .openRouterModel)) ?? defaults.openRouterModel
        chatGPTModel = (try? c.decode(String.self, forKey: .chatGPTModel)) ?? defaults.chatGPTModel
        ollamaURL = (try? c.decode(String.self, forKey: .ollamaURL)) ?? defaults.ollamaURL
        ollamaModel = (try? c.decode(String.self, forKey: .ollamaModel)) ?? defaults.ollamaModel
        summaryModel = (try? c.decode(String.self, forKey: .summaryModel)) ?? defaults.summaryModel
        meetingSummaryModel = (try? c.decode(String.self, forKey: .meetingSummaryModel)) ?? defaults.meetingSummaryModel
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? defaults.hasCompletedOnboarding
        let decodedOnboardingUseCase = try? c.decode(String.self, forKey: .onboardingUseCase)
        if let decodedOnboardingUseCase,
           OnboardingUseCase(rawValue: decodedOnboardingUseCase) != nil {
            onboardingUseCase = decodedOnboardingUseCase
        } else if hasCompletedOnboarding {
            onboardingUseCase = OnboardingUseCase.dictationAndMeetings.rawValue
        } else {
            onboardingUseCase = defaults.onboardingUseCase
        }
        userName = (try? c.decode(String.self, forKey: .userName)) ?? defaults.userName
        customMeetingTemplates = (try? c.decode([CustomMeetingTemplate].self, forKey: .customMeetingTemplates)) ?? defaults.customMeetingTemplates
        customWords = (try? c.decode([CustomWord].self, forKey: .customWords)) ?? defaults.customWords
        folderOrder = (try? c.decode([Int64].self, forKey: .folderOrder)) ?? defaults.folderOrder
        soundEnabled = (try? c.decode(Bool.self, forKey: .soundEnabled)) ?? defaults.soundEnabled
        pauseMediaDuringDictation = (try? c.decode(Bool.self, forKey: .pauseMediaDuringDictation)) ?? defaults.pauseMediaDuringDictation
        muteSystemAudioDuringDictation = (try? c.decode(Bool.self, forKey: .muteSystemAudioDuringDictation)) ?? defaults.muteSystemAudioDuringDictation
        recordingColorHex = (try? c.decode(String.self, forKey: .recordingColorHex)) ?? defaults.recordingColorHex
        menuBarIcon = (try? c.decode(String.self, forKey: .menuBarIcon)) ?? defaults.menuBarIcon
        showNextMeetingInMenuBar = (try? c.decode(Bool.self, forKey: .showNextMeetingInMenuBar)) ?? defaults.showNextMeetingInMenuBar
        maraudersMapUnlocked = (try? c.decode(Bool.self, forKey: .maraudersMapUnlocked)) ?? defaults.maraudersMapUnlocked
        maraudersMapAudioClip = (try? c.decode(String.self, forKey: .maraudersMapAudioClip)) ?? defaults.maraudersMapAudioClip
        maraudersMapCustomAudioPath = try? c.decode(String.self, forKey: .maraudersMapCustomAudioPath)
        hiddenCalendarEventIDs = (try? c.decode([String].self, forKey: .hiddenCalendarEventIDs)) ?? defaults.hiddenCalendarEventIDs
        disabledCalendarIDs = (try? c.decode([String].self, forKey: .disabledCalendarIDs)) ?? defaults.disabledCalendarIDs
        googleCalendarPrimaryOnlyDefaultApplied = (try? c.decode(Bool.self, forKey: .googleCalendarPrimaryOnlyDefaultApplied)) ?? defaults.googleCalendarPrimaryOnlyDefaultApplied
        eventKitSubscriptionCalendarDefaultApplied = (try? c.decode(Bool.self, forKey: .eventKitSubscriptionCalendarDefaultApplied)) ?? defaults.eventKitSubscriptionCalendarDefaultApplied
        enablePostProcessor = (try? c.decode(Bool.self, forKey: .enablePostProcessor)) ?? defaults.enablePostProcessor
        activePostProcessorId = (try? c.decode(String.self, forKey: .activePostProcessorId)) ?? defaults.activePostProcessorId
        postProcessorSystemPrompt = (try? c.decode(String.self, forKey: .postProcessorSystemPrompt)) ?? defaults.postProcessorSystemPrompt
        enableScreenContext = (try? c.decode(Bool.self, forKey: .enableScreenContext)) ?? defaults.enableScreenContext
        useCoreAudioTap = (try? c.decode(Bool.self, forKey: .useCoreAudioTap)) ?? defaults.useCoreAudioTap
        meetingHookEnabled = (try? c.decode(Bool.self, forKey: .meetingHookEnabled)) ?? defaults.meetingHookEnabled
        meetingHookPath = (try? c.decode(String.self, forKey: .meetingHookPath)) ?? defaults.meetingHookPath
        meetingHookTimeoutSeconds = (try? c.decode(Int.self, forKey: .meetingHookTimeoutSeconds)) ?? defaults.meetingHookTimeoutSeconds
        salesCaddieInstallID = (try? c.decode(String.self, forKey: .salesCaddieInstallID)) ?? defaults.salesCaddieInstallID
        salesCaddieCloudSyncEnabled = (try? c.decode(Bool.self, forKey: .salesCaddieCloudSyncEnabled)) ?? defaults.salesCaddieCloudSyncEnabled
        salesCaddieCloudAPIURL = (try? c.decode(String.self, forKey: .salesCaddieCloudAPIURL)) ?? defaults.salesCaddieCloudAPIURL
        salesCaddieCloudAPIToken = (try? c.decode(String.self, forKey: .salesCaddieCloudAPIToken)) ?? defaults.salesCaddieCloudAPIToken
        salesCaddieCloudWorkspaceSlug = (try? c.decode(String.self, forKey: .salesCaddieCloudWorkspaceSlug)) ?? defaults.salesCaddieCloudWorkspaceSlug
        salesCaddieCloudPermissions = try? c.decode(SalesCaddiePermissions.self, forKey: .salesCaddieCloudPermissions)
        supabaseSyncEnabled = (try? c.decode(Bool.self, forKey: .supabaseSyncEnabled)) ?? defaults.supabaseSyncEnabled
        supabaseURL = (try? c.decode(String.self, forKey: .supabaseURL)) ?? defaults.supabaseURL
        supabaseAnonKey = (try? c.decode(String.self, forKey: .supabaseAnonKey)) ?? defaults.supabaseAnonKey
        supabaseWorkspaceID = (try? c.decode(String.self, forKey: .supabaseWorkspaceID)) ?? defaults.supabaseWorkspaceID
        supabaseUserID = (try? c.decode(String.self, forKey: .supabaseUserID)) ?? defaults.supabaseUserID
        supabaseSyncJessicaHistory = (try? c.decode(Bool.self, forKey: .supabaseSyncJessicaHistory)) ?? defaults.supabaseSyncJessicaHistory
        supabaseSyncTranscripts = (try? c.decode(Bool.self, forKey: .supabaseSyncTranscripts)) ?? defaults.supabaseSyncTranscripts
        supabaseSyncSalesLibrary = (try? c.decode(Bool.self, forKey: .supabaseSyncSalesLibrary)) ?? defaults.supabaseSyncSalesLibrary
        salesAssistAdminManagedLibraryEnabled = (try? c.decode(Bool.self, forKey: .salesAssistAdminManagedLibraryEnabled)) ?? defaults.salesAssistAdminManagedLibraryEnabled
        salesAssistAdminLibraryURL = (try? c.decode(String.self, forKey: .salesAssistAdminLibraryURL)) ?? defaults.salesAssistAdminLibraryURL
        salesAssistAdminLibraryUpdatedAt = (try? c.decode(String.self, forKey: .salesAssistAdminLibraryUpdatedAt)) ?? defaults.salesAssistAdminLibraryUpdatedAt
        salesAssistKnowledgeBaseItemID = (try? c.decode(String.self, forKey: .salesAssistKnowledgeBaseItemID)) ?? defaults.salesAssistKnowledgeBaseItemID
        salesAgentBackend = (try? c.decode(String.self, forKey: .salesAgentBackend)) ?? defaults.salesAgentBackend
        salesAgentEndpointURL = (try? c.decode(String.self, forKey: .salesAgentEndpointURL)) ?? defaults.salesAgentEndpointURL
        salesAgentAuthToken = (try? c.decode(String.self, forKey: .salesAgentAuthToken)) ?? defaults.salesAgentAuthToken
        salesAgentModel = (try? c.decode(String.self, forKey: .salesAgentModel)) ?? defaults.salesAgentModel
        salesAgentUserID = (try? c.decode(String.self, forKey: .salesAgentUserID)) ?? defaults.salesAgentUserID
        salesAgentUserName = (try? c.decode(String.self, forKey: .salesAgentUserName)) ?? defaults.salesAgentUserName
        salesAgentUserRole = (try? c.decode(String.self, forKey: .salesAgentUserRole)) ?? defaults.salesAgentUserRole
        salesAgentRepKey = (try? c.decode(String.self, forKey: .salesAgentRepKey)) ?? defaults.salesAgentRepKey
        salesAgentAllowComputerActions = (try? c.decode(Bool.self, forKey: .salesAgentAllowComputerActions)) ?? defaults.salesAgentAllowComputerActions
        salesAgentSendScreenContext = (try? c.decode(Bool.self, forKey: .salesAgentSendScreenContext)) ?? defaults.salesAgentSendScreenContext
        salesAgentSendKnowledgeBase = (try? c.decode(Bool.self, forKey: .salesAgentSendKnowledgeBase)) ?? defaults.salesAgentSendKnowledgeBase
        salesAgentHistory = (try? c.decode([SalesAgentHistoryItem].self, forKey: .salesAgentHistory)) ?? defaults.salesAgentHistory
        salesAssistEnabled = (try? c.decode(Bool.self, forKey: .salesAssistEnabled)) ?? defaults.salesAssistEnabled
        salesAssistAIEnabled = (try? c.decode(Bool.self, forKey: .salesAssistAIEnabled)) ?? defaults.salesAssistAIEnabled
        salesAssistEnabledKinds = (try? c.decode([String].self, forKey: .salesAssistEnabledKinds)) ?? defaults.salesAssistEnabledKinds
        salesAssistKnowledgeBase = (try? c.decode(String.self, forKey: .salesAssistKnowledgeBase)) ?? defaults.salesAssistKnowledgeBase
        salesAssistObjections = (try? c.decode([SalesAssistObjection].self, forKey: .salesAssistObjections)) ?? defaults.salesAssistObjections
        let decodedSalesAssistLiveCues = (try? c.decode([SalesAssistLiveCue].self, forKey: .salesAssistLiveCues)) ?? defaults.salesAssistLiveCues
        salesAssistLiveCues = SalesAssistLiveCue.appendingMissingSeedCues(to: decodedSalesAssistLiveCues)
        salesAssistLearningSuggestions = (try? c.decode([SalesAssistLearningSuggestion].self, forKey: .salesAssistLearningSuggestions)) ?? defaults.salesAssistLearningSuggestions
        salesAssistObjectionTuningExamples = (try? c.decode([SalesAssistObjectionTuningExample].self, forKey: .salesAssistObjectionTuningExamples)) ?? defaults.salesAssistObjectionTuningExamples
        let decodedPreCallModules = (try? c.decode([SalesPreCallBriefingModule].self, forKey: .salesPreCallBriefingModules)) ?? defaults.salesPreCallBriefingModules
        salesPreCallBriefingModules = Self.mergedPreCallModules(decodedPreCallModules)
        salesPreCallCRMProvider = (try? c.decode(String.self, forKey: .salesPreCallCRMProvider)) ?? defaults.salesPreCallCRMProvider
        salesPreCallCRMConnectionLabel = (try? c.decode(String.self, forKey: .salesPreCallCRMConnectionLabel)) ?? defaults.salesPreCallCRMConnectionLabel
        salesPreCallHighLevelBaseURL = (try? c.decode(String.self, forKey: .salesPreCallHighLevelBaseURL)) ?? defaults.salesPreCallHighLevelBaseURL
        salesPreCallHighLevelToken = (try? c.decode(String.self, forKey: .salesPreCallHighLevelToken)) ?? defaults.salesPreCallHighLevelToken
        salesPreCallHighLevelLocationID = (try? c.decode(String.self, forKey: .salesPreCallHighLevelLocationID)) ?? defaults.salesPreCallHighLevelLocationID
    }

    static func mergedPreCallModules(_ modules: [SalesPreCallBriefingModule]) -> [SalesPreCallBriefingModule] {
        let existingIDs = Set(modules.map(\.id))
        let missing = SalesPreCallBriefingModule.defaultModules.filter { !existingIDs.contains($0.id) }
        return (modules + missing).sorted { $0.sortOrder < $1.sortOrder }
    }

    var resolvedCohereLanguage: CohereTranscribeLanguage {
        CohereTranscribeLanguage.resolved(cohereLanguage)
    }

    var resolvedOnboardingUseCase: OnboardingUseCase {
        OnboardingUseCase.resolved(onboardingUseCase)
    }
}

struct WindowFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct CGPointCodable: Codable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var arrayContainer = try? decoder.unkeyedContainer() {
            let x = try arrayContainer.decode(Double.self)
            let y = try arrayContainer.decode(Double.self)
            self.init(x: x, y: y)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }

    enum CodingKeys: String, CodingKey {
        case x, y
    }
}

enum DictationState: String {
    case idle
    case preparing
    case recording
    case transcribing
}

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

    /// Models coming soon — shown greyed out in the Models tab.
    static let comingSoon: [BackendOption] = []

    /// Only models that have been downloaded and are ready for inference.
    static var downloaded: [BackendOption] {
        all.filter { $0.isDownloaded }
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

    static let all: [MeetingSummaryBackendOption] = [.openAI, .openRouter, .chatGPT]

    static func resolved(_ backend: String?) -> MeetingSummaryBackendOption {
        guard let backend, let option = all.first(where: { $0.backend == backend }) else {
            return .openAI
        }
        return option
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
    var keyCode: UInt16 = 55
    var label: String = "Left Cmd"

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

    static let `default` = HotkeyConfig()
    static let computerUseDefault = HotkeyConfig(keyCode: 54, label: "Right Cmd")

    static func computerUseDefault(avoiding dictationHotkey: HotkeyConfig) -> HotkeyConfig {
        dictationHotkey.keyCode == computerUseDefault.keyCode ? .default : .computerUseDefault
    }
}

enum OnboardingUseCase: String, Codable, CaseIterable {
    case dictation = "dictation"
    case meetings = "meetings"
    case dictationAndMeetings = "dictation_and_meetings"

    var includesDictation: Bool {
        self == .dictation || self == .dictationAndMeetings
    }

    var includesMeetings: Bool {
        self == .meetings || self == .dictationAndMeetings
    }

    static func resolved(_ rawValue: String?) -> OnboardingUseCase {
        guard let rawValue, let useCase = OnboardingUseCase(rawValue: rawValue) else {
            return .dictation
        }
        return useCase
    }
}

struct AppConfig: Codable {
    var dictationHotkey: HotkeyConfig = .default
    var computerUseHotkey: HotkeyConfig = .computerUseDefault
    var enableComputerUseHotkey: Bool = true
    var enableComputerUsePlanner: Bool = true
    var computerUsePlannerModel: String = ""
    var computerUseTimeoutSeconds: Int = 120
    var sttBackend: String = BackendOption.whisper.backend
    var sttModel: String = BackendOption.whisper.model
    var cohereLanguage: String = CohereTranscribeLanguage.defaultLanguage.rawValue
    var meetingTranscriptionBackend: String = BackendOption.whisper.backend
    var meetingTranscriptionModel: String = BackendOption.whisper.model
    var meetingSummaryBackend: String = MeetingSummaryBackendOption.openAI.backend
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
    var recordingColorHex: String = "1e1e2e"   // Catppuccin Mocha base, without #
    var menuBarIcon: String = "muesli"
    var showNextMeetingInMenuBar: Bool = true
    var maraudersMapUnlocked: Bool = false
    var maraudersMapAudioClip: String = "bbc_world_news"
    var maraudersMapCustomAudioPath: String?
    var hiddenCalendarEventIDs: [String] = []
    var enablePostProcessor: Bool = false
    var activePostProcessorId: String = PostProcessorOption.defaultOption.id
    var postProcessorSystemPrompt: String = PostProcessorOption.defaultSystemPrompt
    var enableScreenContext: Bool = false
    var useCoreAudioTap: Bool = true
    var meetingHookEnabled: Bool = false
    var meetingHookPath: String = ""
    var meetingHookTimeoutSeconds: Int = 30

    enum CodingKeys: String, CodingKey {
        case dictationHotkey = "dictation_hotkey"
        case computerUseHotkey = "computer_use_hotkey"
        case enableComputerUseHotkey = "enable_computer_use_hotkey"
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
        case summaryModel = "summary_model"
        case meetingSummaryModel = "meeting_summary_model"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case onboardingUseCase = "onboarding_use_case"
        case userName = "user_name"
        case customMeetingTemplates = "custom_meeting_templates"
        case customWords = "custom_words"
        case folderOrder = "folder_order"
        case soundEnabled = "sound_enabled"
        case recordingColorHex = "recording_color_hex"
        case menuBarIcon = "menu_bar_icon"
        case showNextMeetingInMenuBar = "show_next_meeting_in_menu_bar"
        case maraudersMapUnlocked = "marauders_map_unlocked"
        case maraudersMapAudioClip = "marauders_map_audio_clip"
        case maraudersMapCustomAudioPath = "marauders_map_custom_audio_path"
        case hiddenCalendarEventIDs = "hidden_calendar_event_ids"
        case enablePostProcessor = "enable_post_processor"
        case activePostProcessorId = "active_post_processor_id"
        case postProcessorSystemPrompt = "post_processor_system_prompt"
        case enableScreenContext = "enable_screen_context"
        case useCoreAudioTap = "use_core_audio_tap"
        case meetingHookEnabled = "meeting_hook_enabled"
        case meetingHookPath = "meeting_hook_path"
        case meetingHookTimeoutSeconds = "meeting_hook_timeout_seconds"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        dictationHotkey = (try? c.decode(HotkeyConfig.self, forKey: .dictationHotkey)) ?? defaults.dictationHotkey
        computerUseHotkey = (try? c.decode(HotkeyConfig.self, forKey: .computerUseHotkey))
            ?? HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
        enableComputerUseHotkey = (try? c.decode(Bool.self, forKey: .enableComputerUseHotkey)) ?? defaults.enableComputerUseHotkey
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
        summaryModel = (try? c.decode(String.self, forKey: .summaryModel)) ?? defaults.summaryModel
        meetingSummaryModel = (try? c.decode(String.self, forKey: .meetingSummaryModel)) ?? defaults.meetingSummaryModel
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? defaults.hasCompletedOnboarding
        onboardingUseCase = OnboardingUseCase.resolved(try? c.decode(String.self, forKey: .onboardingUseCase)).rawValue
        userName = (try? c.decode(String.self, forKey: .userName)) ?? defaults.userName
        customMeetingTemplates = (try? c.decode([CustomMeetingTemplate].self, forKey: .customMeetingTemplates)) ?? defaults.customMeetingTemplates
        customWords = (try? c.decode([CustomWord].self, forKey: .customWords)) ?? defaults.customWords
        folderOrder = (try? c.decode([Int64].self, forKey: .folderOrder)) ?? defaults.folderOrder
        soundEnabled = (try? c.decode(Bool.self, forKey: .soundEnabled)) ?? defaults.soundEnabled
        recordingColorHex = (try? c.decode(String.self, forKey: .recordingColorHex)) ?? defaults.recordingColorHex
        menuBarIcon = (try? c.decode(String.self, forKey: .menuBarIcon)) ?? defaults.menuBarIcon
        showNextMeetingInMenuBar = (try? c.decode(Bool.self, forKey: .showNextMeetingInMenuBar)) ?? defaults.showNextMeetingInMenuBar
        maraudersMapUnlocked = (try? c.decode(Bool.self, forKey: .maraudersMapUnlocked)) ?? defaults.maraudersMapUnlocked
        maraudersMapAudioClip = (try? c.decode(String.self, forKey: .maraudersMapAudioClip)) ?? defaults.maraudersMapAudioClip
        maraudersMapCustomAudioPath = try? c.decode(String.self, forKey: .maraudersMapCustomAudioPath)
        hiddenCalendarEventIDs = (try? c.decode([String].self, forKey: .hiddenCalendarEventIDs)) ?? defaults.hiddenCalendarEventIDs
        enablePostProcessor = (try? c.decode(Bool.self, forKey: .enablePostProcessor)) ?? defaults.enablePostProcessor
        activePostProcessorId = (try? c.decode(String.self, forKey: .activePostProcessorId)) ?? defaults.activePostProcessorId
        postProcessorSystemPrompt = (try? c.decode(String.self, forKey: .postProcessorSystemPrompt)) ?? defaults.postProcessorSystemPrompt
        enableScreenContext = (try? c.decode(Bool.self, forKey: .enableScreenContext)) ?? defaults.enableScreenContext
        useCoreAudioTap = (try? c.decode(Bool.self, forKey: .useCoreAudioTap)) ?? defaults.useCoreAudioTap
        meetingHookEnabled = (try? c.decode(Bool.self, forKey: .meetingHookEnabled)) ?? defaults.meetingHookEnabled
        meetingHookPath = (try? c.decode(String.self, forKey: .meetingHookPath)) ?? defaults.meetingHookPath
        meetingHookTimeoutSeconds = (try? c.decode(Int.self, forKey: .meetingHookTimeoutSeconds)) ?? defaults.meetingHookTimeoutSeconds
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

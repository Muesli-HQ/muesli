import Foundation

/// Spoken input languages, not translation targets or general text capabilities.
struct ModelInputLanguage: Equatable, Identifiable {
    static let languageCodes = Set(Locale.LanguageCode.isoLanguageCodes.map { $0.identifier.lowercased() })

    let id: String
    let name: String


}

extension BackendOption {
    /// Reuse the runtime's model-specific choices; auto-detection is not a language.
    /// Apple coverage is supplied separately from SpeechTranscriber's supported locales.
    /// Gemma lists published ASR evaluation coverage, not its text-language count.
    var inputLanguages: [ModelInputLanguage] {
        switch backend {
        case "parakeet-unified", "medasr":
            return [.init(id: "en", name: "English")]
        case "fluidaudio":
            if self == .parakeetEnglish { return [.init(id: "en", name: "English")] }
            // Script-filter hints include languages outside the trained coverage.
            // https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3#description
            let supportedCodes: Set<String> = [
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
            ]
            return ParakeetLanguage.allCases.filter { supportedCodes.contains($0.rawValue) }
                .map { .init(id: $0.rawValue, name: $0.label) }
        case "whisper":
            if WhisperKitLanguage.isEnglishOnlyModel(model) { return [.init(id: "en", name: "English")] }
            return WhisperKitLanguage.choices(for: model).filter { $0 != .auto }.map { .init(id: $0.rawValue, name: $0.label) }
        case "nemotron35":
            return Nemotron35Language.allCases.filter { $0 != .auto }.map { .init(id: $0.rawValue, name: $0.label) }
        case "qwen":
            return Qwen3AsrLanguage.allCases.filter { $0 != .auto }.map { .init(id: $0.rawValue, name: $0.label) }
        case "cohere":
            return CohereTranscribeLanguage.allCases.map { .init(id: $0.rawValue, name: $0.label) }
        case "bodhan":
            return BodhanLanguage.choices(for: model).filter { $0 != .automatic }.map { .init(id: $0.rawValue, name: $0.label) }
        case "gemma4-litert":
            guard self == .gemma4E2BLiteRT || self == .gemma4E4BLiteRT else { return [] }
            // Table 7, E2B/E4B FLEURS ASR. Evaluated coverage, not an exhaustive support promise.
            // https://arxiv.org/html/2607.02770v2
            return [
                .init(id: "en", name: "English"), .init(id: "ko", name: "Korean"),
                .init(id: "ja", name: "Japanese"), .init(id: "de", name: "German"),
                .init(id: "fr", name: "French"), .init(id: "hi", name: "Hindi"),
                .init(id: "es", name: "Spanish"), .init(id: "it", name: "Italian"),
                .init(id: "pt-BR", name: "Portuguese (Brazil)"), .init(id: "ru", name: "Russian"),
                .init(id: "ar", name: "Arabic"), .init(id: "zh", name: "Chinese (Mandarin)"),
            ]
        case "sensevoice":
            // Small's five languages, not the larger SenseVoice family's 50+.
            // https://huggingface.co/FunAudioLLM/SenseVoiceSmall#whats-new-
            return [.init(id: "zh", name: "Chinese (Mandarin)"), .init(id: "yue", name: "Cantonese"),
                    .init(id: "en", name: "English"), .init(id: "ja", name: "Japanese"), .init(id: "ko", name: "Korean")]
        default:
            return []
        }
    }

    var inputLanguageCoverageNote: String? {
        switch backend {
        case "gemma4-litert":
            return "These languages have published speech-recognition evaluations. Additional language support is unconfirmed."
        case "nemotron35":
            return "32 transcription-ready or broad-coverage locales. Eight other upstream locales require fine-tuning."
        default:
            return nil
        }
    }

    /// Qwen's 22 dialect/accent entries are distinct from its 30 selectable languages.
    /// These are discovery metadata, never fabricated decoder language codes.
    /// https://github.com/QwenLM/Qwen3-ASR
    var inputDialects: [String] {
        guard backend == "qwen" else { return [] }
        return ["Anhui", "Dongbei", "Fujian", "Gansu", "Guizhou", "Hebei", "Henan", "Hubei", "Hunan",
                "Jiangxi", "Ningxia", "Shandong", "Shaanxi", "Shanxi", "Sichuan", "Tianjin", "Yunnan",
                "Zhejiang", "Cantonese (Hong Kong)", "Cantonese (Guangdong)", "Wu", "Minnan"]
    }

    func supportedInputLanguages(appleLanguages: [AppleSpeechLanguageOption]) -> [ModelInputLanguage] {
        guard backend == "apple-speech" else { return inputLanguages }
        return appleLanguages.filter { $0.id != AppleSpeechLanguageOption.systemIdentifier }.map {
            .init(id: $0.id, name: Locale(identifier: "en").localizedString(forIdentifier: $0.id) ?? $0.label)
        }
    }

    func matchesModelSearch(_ query: String, appleLanguages: [AppleSpeechLanguageOption] = []) -> Bool {
        !ModelLanguageSearchIndex(options: [self], appleLanguages: appleLanguages).search(query).isEmpty
    }
}

struct ModelLanguageSearchResult: Identifiable, Equatable {
    let option: BackendOption
    let matchingLanguages: [String]
    var id: String { option.model }
}

/// Immutable, in-memory index. Locale lookup and normalization happen at construction,
/// never in the per-keystroke search or card rendering paths.
struct ModelLanguageSearchIndex {
    static let current = ModelLanguageSearchIndex(options: BackendOption.compatibleOptions())
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    private struct Language {
        let displayName: String
        let code: String
        let baseCode: String
        let names: [String]
    }

    private struct Entry {
        let option: BackendOption
        let label: String
        let labelWords: Set<String>
        let languages: [Language]
        let dialects: [(name: String, normalized: String)]
    }

    private let entries: [Entry]
    private let coverage: [String: [ModelInputLanguage]]

    init(options: [BackendOption], appleLanguages: [AppleSpeechLanguageOption] = [], locale: Locale = .current) {
        var entries: [Entry] = []
        var coverage: [String: [ModelInputLanguage]] = [:]
        var indexedLanguages: [String: Language] = [:]
        for option in options {
            let languages = option.supportedInputLanguages(appleLanguages: appleLanguages)
            coverage[option.model] = languages
            let indexed = languages.map { language -> Language in
                let key = language.id + ":" + language.name
                if let cached = indexedLanguages[key] { return cached }
                let nativeLocale = Locale(identifier: language.id)
                let baseCode = nativeLocale.language.languageCode?.identifier ?? language.id
                let names = [language.name, nativeLocale.localizedString(forLanguageCode: baseCode),
                             locale.localizedString(forLanguageCode: baseCode),
                             nativeLocale.localizedString(forIdentifier: language.id),
                             locale.localizedString(forIdentifier: language.id)].compactMap { $0 }
                    + (baseCode == "zh" ? ["Mandarin"] : [])
                let value = Language(displayName: language.name, code: Self.normalize(language.id),
                                     baseCode: Self.normalize(baseCode), names: names.map(Self.normalize))
                indexedLanguages[key] = value
                return value
            }
            let label = Self.normalize(option.label)
            let labelWords = Set(label.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            entries.append(Entry(option: option, label: label, labelWords: labelWords, languages: indexed,
                                 dialects: option.inputDialects.map { ($0, Self.normalize($0)) }))
        }
        self.entries = entries
        self.coverage = coverage
    }

    func languages(for option: BackendOption) -> [ModelInputLanguage] {
        coverage[option.model] ?? []
    }

    func search(_ text: String) -> [ModelLanguageSearchResult] {
        let query = Self.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let isCode = ModelInputLanguage.languageCodes.contains(query)
        return entries.compactMap { entry in
            if query.isEmpty { return .init(option: entry.option, matchingLanguages: []) }
            let languages = entry.languages.filter {
                $0.baseCode == query || $0.code == query || (!isCode && $0.names.contains { $0.contains(query) })
            }.map(\.displayName)
            let dialects = entry.dialects.filter {
                isCode ? $0.normalized == query : $0.normalized.contains(query)
            }.map(\.name)
            let matches = languages + dialects
            let matchesLabel = isCode ? entry.labelWords.contains(query) : entry.label.contains(query)
            guard !matches.isEmpty || matchesLabel else { return nil }
            return .init(option: entry.option, matchingLanguages: matches)
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
    }
}

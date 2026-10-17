import Foundation

/// Supported language prompts for the Nemotron 3.5 multilingual checkpoint.
/// Shared by the app and CLI so both use the same prompt IDs.
public enum Nemotron35Language: String, CaseIterable, Codable, Sendable {
    case auto
    case arabic = "ar"
    case bulgarian = "bg"
    case chinese = "zh"
    case chineseTraditional = "zh-TW"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case englishBritish = "en-gb"
    case estonian = "et"
    case finnish = "fi"
    case french = "fr"
    case frenchCanadian = "fr-ca"
    case german = "de"
    case hindi = "hi"
    case hungarian = "hu"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case norwegianBokmal = "nb"
    case polish = "pl"
    case portuguese = "pt"
    case portugueseBrazil = "pt-br"
    case romanian = "ro"
    case russian = "ru"
    case slovak = "sk"
    case spanish = "es"
    case spanishSpain = "es-es"
    case swedish = "sv"
    case turkish = "tr"
    case ukrainian = "uk"
    case vietnamese = "vi"

    /// Contextual script conversion must finish before cursor insertion.
    public var usesStreamingDictation: Bool { self != .chineseTraditional }

    public static let defaultLanguage: Self = .auto

    /// IDs from the multilingual/2240ms checkpoint's metadata.json, limited to NVIDIA's
    /// transcription-ready and broad-coverage locales. Reserved and adaptation-ready
    /// prompts need model changes, not just a picker entry. 101 = auto-detect.
    public var promptId: Int32 {
        switch self {
        case .auto: return 101
        case .arabic: return 7
        case .bulgarian: return 30
        case .chinese, .chineseTraditional: return 4
        case .croatian: return 29
        case .czech: return 22
        case .danish: return 25
        case .dutch: return 16
        case .english: return 0
        case .englishBritish: return 1
        case .estonian: return 60
        case .finnish: return 26
        case .french: return 8
        case .frenchCanadian: return 100
        case .german: return 9
        case .hindi: return 6
        case .hungarian: return 23
        case .italian: return 15
        case .japanese: return 10
        case .korean: return 14
        case .norwegianBokmal: return 103
        case .polish: return 17
        case .portuguese: return 13
        case .portugueseBrazil: return 12
        case .romanian: return 20
        case .russian: return 11
        case .slovak: return 28
        case .spanish: return 3
        case .spanishSpain: return 2
        case .swedish: return 24
        case .turkish: return 18
        case .ukrainian: return 19
        case .vietnamese: return 33
        }
    }

    public var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .arabic: return "Arabic"
        case .bulgarian: return "Bulgarian"
        case .chinese: return "Chinese"
        case .chineseTraditional: return "Chinese (Traditional)"
        case .croatian: return "Croatian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutch: return "Dutch"
        case .english: return "English"
        case .englishBritish: return "English (UK)"
        case .estonian: return "Estonian"
        case .finnish: return "Finnish"
        case .french: return "French"
        case .frenchCanadian: return "French (Canada)"
        case .german: return "German"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .norwegianBokmal: return "Norwegian Bokmål"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .portugueseBrazil: return "Portuguese (Brazil)"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .slovak: return "Slovak"
        case .spanish: return "Spanish"
        case .spanishSpain: return "Spanish (Spain)"
        case .swedish: return "Swedish"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .vietnamese: return "Vietnamese"
        }
    }

    public static func resolved(_ rawValue: String?) -> Self {
        if ChineseTranscriptionOutput.isTraditional(rawValue) { return .chineseTraditional }
        guard let rawValue,
              let language = Self(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return defaultLanguage
        }
        return language
    }

    public static func resolvedCode(_ rawValue: String?) -> String {
        resolved(rawValue).rawValue
    }
}

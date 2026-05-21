/// The eight voices bundled with the KittenTTS nano model.
///
/// Each voice has a recommended base speed (``defaultSpeed``) that is applied
/// multiplicatively with the caller-supplied speed when generating speech.
///
/// ```swift
/// let result = try await tts.generate("Hello!", voice: .luna, speed: 1.2)
/// ```
public enum KittenVoice: String, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    // MARK: - Cases

    /// Bella — female, warm and expressive.
    case bella  = "expr-voice-2-f"
    /// Jasper — male, clear and conversational.
    case jasper = "expr-voice-2-m"
    /// Luna — female, calm and smooth.
    case luna   = "expr-voice-3-f"
    /// Bruno — male, deep and steady.
    case bruno  = "expr-voice-3-m"
    /// Rosie — female, bright and friendly.
    case rosie  = "expr-voice-4-f"
    /// Hugo — male, authoritative.
    case hugo   = "expr-voice-4-m"
    /// Kiki — female, lively and energetic.
    case kiki   = "expr-voice-5-f"
    /// Leo — male, relaxed and natural.
    case leo    = "expr-voice-5-m"

    // MARK: - Identifiable

    /// Stable identifier — equal to the underlying voice key used in the model.
    public var id: String { rawValue }

    // MARK: - Metadata

    /// Human-readable display name (e.g. `"Bella"`).
    public var displayName: String {
        switch self {
        case .bella:  return "Bella"
        case .jasper: return "Jasper"
        case .luna:   return "Luna"
        case .bruno:  return "Bruno"
        case .rosie:  return "Rosie"
        case .hugo:   return "Hugo"
        case .kiki:   return "Kiki"
        case .leo:    return "Leo"
        }
    }

    /// `true` for female voices, `false` for male voices.
    public var isFemale: Bool {
        rawValue.hasSuffix("-f")
    }
}

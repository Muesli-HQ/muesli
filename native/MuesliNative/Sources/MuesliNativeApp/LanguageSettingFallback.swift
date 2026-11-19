import Foundation
import os

/// Reports language settings in `config.json` that a backend does not recognize.
/// Each `*Language.resolved(_:)` quietly falls back to its default for unknown
/// codes, so without this a typo or unsupported code (for example
/// `whisper_language: "xx"`) leaves no trace (#733).
enum LanguageSettingFallback {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "Config")

    /// True when `rawValue` names a language the backend does not know and the
    /// setting fell back to `defaultCode`. Empty values and values that already
    /// equal the default are not fallbacks.
    static func isUnrecognized(_ rawValue: String?, resolvedCode: String, defaultCode: String) -> Bool {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }
        return resolvedCode == defaultCode && normalized != defaultCode
    }

    static func logIfUnrecognized(key: String, rawValue: String?, resolvedCode: String, defaultCode: String) {
        guard isUnrecognized(rawValue, resolvedCode: resolvedCode, defaultCode: defaultCode),
              let rawValue else { return }
        logger.warning(
            "[config] \(key, privacy: .public) \"\(rawValue, privacy: .public)\" is not a supported language; using \(defaultCode, privacy: .public)"
        )
    }
}

import Foundation

public enum OpenAIAPISettings {
    /// A nonblank environment key overrides Settings; blank values use the saved key.
    public static func resolvedAPIKey(environmentValue: String?, savedValue: String) -> String {
        if let override = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return savedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

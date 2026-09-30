import Foundation

public enum AnthropicAPISettings {
    public static let hostedSummaryMaxOutputTokens = 12_000

    /// A blank environment variable should not hide a value saved in Settings.
    public static func resolvedValue(environmentValue: String?, savedValue: String) -> String {
        if let override = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return savedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

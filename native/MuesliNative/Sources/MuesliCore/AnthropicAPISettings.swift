import Foundation

public enum AnthropicAPISettings {
    /// A blank environment variable should not hide a value saved in Settings.
    public static func resolvedValue(environmentValue: String?, savedValue: String) -> String {
        if let override = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return savedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

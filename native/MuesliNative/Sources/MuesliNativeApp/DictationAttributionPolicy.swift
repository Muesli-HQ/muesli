import Foundation

enum DictationAttributionPolicy {
    static func shouldPersist(
        isPasteOutput: Bool,
        source: String,
        text: String
    ) -> Bool {
        guard isPasteOutput,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cua", "ios":
            return false
        default:
            return true
        }
    }
}

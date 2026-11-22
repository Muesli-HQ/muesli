import Foundation
import MuesliCore

enum DictionaryFileOperation { case importing, exporting }

/// The controller and AppState outlive the Dictionary destination. Disk work stays
/// detached; operation guards, current-config merges, and completion UI stay on main.
@MainActor
extension MuesliController {
    @discardableResult
    func importDictionary(
        from url: URL,
        read: @escaping @Sendable (URL) throws -> [CustomWord] = {
            try CustomWordDictionaryCodec.decode(Data(contentsOf: $0))
        }
    ) -> Task<Void, Never>? {
        guard appState.dictionaryFileOperation == nil else { return nil }
        appState.dictionaryFileOperation = .importing
        appState.dictionaryFileMessage = nil
        return Task {
            defer { appState.dictionaryFileOperation = nil }
            do {
                let imported = try await Task.detached(priority: .userInitiated) { try read(url) }.value
                let result = CustomWordDictionaryCodec.merge(imported, into: config.customWords)
                updateConfig { $0.customWords = result.words }
                if result.addedCount + result.updatedCount == 0 {
                    appState.dictionaryFileMessage = imported.isEmpty
                        ? "The selected dictionary did not contain any entries."
                        : "All dictionary entries were already present."
                } else {
                    var details = ["Imported \(result.addedCount) new", "updated \(result.updatedCount)"]
                    if result.skippedCount > 0 { details.append("skipped \(result.skippedCount)") }
                    appState.dictionaryFileMessage = details.joined(separator: ", ") + " dictionary entries."
                }
            } catch {
                appState.dictionaryFileMessage = "Could not import the dictionary. \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func exportDictionary(to url: URL) -> Task<Void, Never>? {
        guard appState.dictionaryFileOperation == nil else { return nil }
        appState.dictionaryFileOperation = .exporting
        appState.dictionaryFileMessage = nil
        let words = config.customWords
        return Task {
            defer { appState.dictionaryFileOperation = nil }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CustomWordDictionaryCodec.encode(words).write(to: url, options: .atomic)
                }.value
                appState.dictionaryFileMessage = "Exported \(words.count) dictionary entries."
            } catch {
                appState.dictionaryFileMessage = "Could not export the dictionary. \(error.localizedDescription)"
            }
        }
    }
}

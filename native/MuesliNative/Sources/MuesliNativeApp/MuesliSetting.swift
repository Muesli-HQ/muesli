import Foundation

@MainActor
struct MuesliSetting {
    enum Presentation: Equatable { case automatic, discreteSlider }
    struct Choice: Codable, Equatable {
        let id: String
        let label: String
    }
    struct Snapshot: Codable {
        let id: String
        let label: String
        let current: String
        let choices: [Choice]
        let unavailable: [String: String]
        var shortcutCombination: ShortcutAssignment.CombinationRules? = nil
        var followUpSelections: [String: String]? = nil
    }
    let id: String
    let label: String
    let choices: [Choice]
    let read: (AppConfig) -> String
    let unavailable: (String) -> String?
    let apply: (String) async throws -> Void
    var presentation: Presentation = .automatic
    var shortcutAssignment: ShortcutAssignment? = nil
    // Source choices that require an explicit model choice in a voice command.
    var followUpSelections: [String: String] = [:]

    func choice(for value: String) -> Choice? {
        if let choice = choices.first(where: { $0.id == value }) { return choice }
        guard let hotkey = shortcutAssignment?.hotkey(for: value) else { return nil }
        return Choice(id: value, label: hotkey.label)
    }

    func snapshot(config: AppConfig) -> Snapshot {
        Snapshot(id: id, label: label, current: read(config), choices: choices,
                 unavailable: Dictionary(uniqueKeysWithValues: choices.compactMap { choice in
                     unavailable(choice.id).map { (choice.id, $0) }
                 }), shortcutCombination: shortcutAssignment?.combinationRules, followUpSelections: followUpSelections.isEmpty ? nil : followUpSelections)
    }
}


@MainActor
enum MuesliSettings {
    struct Selection: Codable {
        let setting: String
        let value: String
    }
    enum Failure: LocalizedError {
        case rejected(String)
        var errorDescription: String? {
            switch self { case .rejected(let message): return message }
        }
    }
    static func apply(
        _ selection: Selection,
        settings: [MuesliSetting],
        snapshots: [MuesliSetting.Snapshot],
        config: () -> AppConfig,
        persistedConfig: () throws -> AppConfig
    ) async throws -> String {
        try Task.checkCancellation()
        guard let setting = settings.first(where: { $0.id == selection.setting }),
              let choice = setting.choice(for: selection.value),
              let snapshot = snapshots.first(where: { $0.id == setting.id }) else {
            throw Failure.rejected("That setting or option is unavailable. Nothing was changed.")
        }
        guard setting.read(config()) == snapshot.current else {
            throw Failure.rejected("\(setting.label) changed while processing your command. Please try again.")
        }
        if let reason = setting.unavailable(choice.id) { throw Failure.rejected(reason) }
        try await setting.apply(choice.id)
        try Task.checkCancellation()
        guard setting.read(config()) == choice.id else {
            throw Failure.rejected("Could not change \(setting.label). Check its requirements in Settings.")
        }
        // ConfigStore.save historically logs write errors. Read the file back so
        // a disk failure or a setter refusing a change cannot produce green Done.
        guard setting.read(try persistedConfig()) == choice.id else {
            throw Failure.rejected("\(setting.label) could not be saved. Please check Settings.")
        }
        return "\(setting.label): \(choice.label)"
    }

}

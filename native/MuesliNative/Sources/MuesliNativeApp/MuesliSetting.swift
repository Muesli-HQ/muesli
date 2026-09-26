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
    struct Discovery: Codable, Hashable { let id: String; let label: String }
    var discovery: Discovery { publicDiscovery ?? Discovery(id: id, label: label) }
    var publicDiscovery: Discovery? = nil
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
    // Declared with the UI definition; never expose these choices to voice tools.
    var voiceRestriction: String? = nil
    var requestPermission: (() -> Void)? = nil

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
    enum ApplySource { case voice, manualUI }
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
        source: ApplySource = .voice,
        config: () -> AppConfig,
        persistedConfig: () throws -> AppConfig
    ) async throws -> String {
        try Task.checkCancellation()
        guard let setting = settings.first(where: { $0.id == selection.setting }) else {
            throw Failure.rejected("That setting or option is unavailable. Nothing was changed.")
        }
        if source == .voice, let reason = setting.voiceRestriction { throw Failure.rejected(reason) }
        guard let choice = setting.choice(for: selection.value),
              let snapshot = snapshots.first(where: { $0.id == setting.id }) else {
            throw Failure.rejected("That setting or option is unavailable. Nothing was changed.")
        }
        guard setting.read(config()) == snapshot.current else {
            throw Failure.rejected("\(setting.label) changed while processing your command. Please try again.")
        }
        if let reason = setting.unavailable(choice.id) { throw Failure.rejected(reason) }
        // Once the setter commits, finish readback even if Stop arrives.
        do {
            try await setting.apply(choice.id)
        } catch is CancellationError {
            // Async post-save work can observe Stop after the setting is durable.
            // Report the verified change instead of falsely claiming it was cancelled.
            guard setting.read(config()) == choice.id,
                  let saved = try? persistedConfig(), setting.read(saved) == choice.id else {
                throw CancellationError()
            }
        }
        guard setting.read(config()) == choice.id else {
            throw Failure.rejected("Could not change \(setting.label). Check its requirements in Settings.")
        }
        // ConfigStore.save historically logs write errors. Read the file back so
        // a disk failure or a setter refusing a change cannot produce green Done.
        do {
            guard setting.read(try persistedConfig()) == choice.id else {
                throw Failure.rejected("Save verification failed.")
            }
        } catch {
            throw Failure.rejected("\(setting.label) changed in this session, but its saved value could not be verified. Check Settings before restarting.")
        }
        return "\(setting.label): \(choice.label)"
    }

}

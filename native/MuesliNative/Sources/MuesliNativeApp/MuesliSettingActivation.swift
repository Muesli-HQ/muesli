import Foundation

/// Canonical dependencies for a preference whose effect depends on an active model.
/// The model cannot bypass this workflow by supplying a mutation source or scope.
@MainActor
struct MuesliSettingActivation {
    struct Target { let id: String; let label: String }
    let label: String
    let targets: [Target]
    let compatibleChoices: (String) -> Set<String>
    let unavailable: (String) -> String?

    typealias Choose = (ComputerUseQuestion, [MuesliSetting.Choice]) async throws -> String

    func apply(
        selection: MuesliSettings.Selection,
        snapshot: MuesliSetting.Snapshot,
        definitions: () -> [MuesliSetting],
        config: () -> AppConfig,
        persistedConfig: () throws -> AppConfig,
        choose: Choose
    ) async throws -> String {
        let original = definitions()
        let baseline = original.map { $0.snapshot(config: config()) }
        let compatible = compatibleChoices(selection.value)
        func candidates(_ ids: [String], in settings: [MuesliSetting]) -> [MuesliSetting.Choice] {
            guard let first = settings.first(where: { $0.id == ids.first }) else { return [] }
            return first.choices.filter { choice in
                compatible.contains(choice.id) && ids.allSatisfy { id in
                    guard let setting = settings.first(where: { $0.id == id }), setting.voiceRestriction == nil,
                          setting.choice(for: choice.id) != nil else { return false }
                    return setting.availability(choice.id) == nil
                }
            }
        }
        var scopes = targets.filter { !candidates([$0.id], in: original).isEmpty }
            .map { MuesliSetting.Choice(id: $0.id, label: $0.label) }
        if targets.count > 1, !candidates(targets.map(\.id), in: original).isEmpty {
            scopes.append(.init(id: "all", label: "Both"))
        }
        scopes.append(.init(id: "preference", label: "Only save the preference"))
        if scopes.count == 1 { scopes.append(.init(id: "cancel", label: "Keep current settings")) }
        let scope = try await choose(.init(
            question: scopes.contains(where: { $0.id != "preference" && $0.id != "cancel" })
                ? "Where should I activate \(label) for this change? Only saving the preference leaves your active models unchanged."
                : "No compatible downloaded \(label) model is available. Save this preference for later?",
            options: Array(scopes.prefix(4).map(\.label))), scopes)
        try Task.checkCancellation()
        guard scopes.contains(where: { $0.id == scope }) else { throw MuesliSettings.Failure.rejected("That choice is no longer available. Nothing was changed.") }
        if scope == "cancel" { throw CancellationError() }
        let targetIDs = scope == "preference" ? [] : scope == "all" ? targets.map(\.id) : [scope]
        var modelID: String?
        if !targetIDs.isEmpty {
            let choices = candidates(targetIDs, in: definitions())
            guard !choices.isEmpty else { throw MuesliSettings.Failure.rejected("No compatible downloaded model is available for that choice. Nothing was changed.") }
            // Even one available variant needs confirmation: the spoken command
            // may have named another variant that is not downloaded.
            let offered = choices.count == 1 ? choices + [.init(id: "cancel", label: "Keep current settings")] : choices
            modelID = try await choose(.init(question: "Which \(label) model should I use?",
                options: Array(offered.prefix(4).map(\.label))), offered)
            if modelID == "cancel" { throw CancellationError() }
            guard choices.contains(where: { $0.id == modelID }) else { throw MuesliSettings.Failure.rejected("That model is unavailable. Nothing was changed.") }
        }
        try Task.checkCancellation()
        let latest = definitions()
        // Validate every dependency before the first write, including manual edits
        // made while the user answered either question.
        for id in targetIDs + [selection.setting] {
            guard let setting = latest.first(where: { $0.id == id }), setting.voiceRestriction == nil,
                  let before = (id == selection.setting ? snapshot : baseline.first { $0.id == id }),
                  setting.read(config()) == before.current else {
                throw MuesliSettings.Failure.rejected("Settings changed while you were answering. Please try again. Nothing was changed.")
            }
        }
        if let modelID, !candidates(targetIDs, in: latest).contains(where: { $0.id == modelID }) {
            throw MuesliSettings.Failure.rejected("The selected model is no longer available. Nothing was changed.")
        }
        guard let preference = latest.first(where: { $0.id == selection.setting }),
              preference.activation != nil, preference.choice(for: selection.value) != nil else {
            throw MuesliSettings.Failure.rejected("That preference is no longer available. Nothing was changed.")
        }
        if let reason = preference.availability(selection.value, source: .confirmedPreference) {
            throw MuesliSettings.Failure.rejected(reason)
        }
        var completed: [String] = []
        var pendingWrite: String?
        var attemptedWrite = false
        do {
            if let modelID {
                for id in targetIDs {
                    try Task.checkCancellation()
                    let current = definitions()
                    guard let target = current.first(where: { $0.id == id }) else { throw MuesliSettings.Failure.rejected("Model setting disappeared.") }
                    pendingWrite = "\(target.label): \(target.choice(for: modelID)?.label ?? modelID)"
                    attemptedWrite = true
                    let message = try await MuesliSettings.apply(.init(setting: id, value: modelID), settings: current,
                        snapshots: baseline, config: config, persistedConfig: persistedConfig)
                    completed.append(message)
                    pendingWrite = nil
                }
            }
            try Task.checkCancellation()
            // Confirmed preference scope is local state, never a model argument.
            // Revalidate compatibility after asynchronous model setters too.
            if let modelID, !candidates(targetIDs, in: definitions()).contains(where: { $0.id == modelID }) {
                throw MuesliSettings.Failure.rejected("Model availability changed during activation.")
            }
            let current = definitions()
            if let modelID {
                let saved = try persistedConfig()
                guard targetIDs.allSatisfy({ id in
                    guard let target = current.first(where: { $0.id == id }) else { return false }
                    return target.read(config()) == modelID && target.read(saved) == modelID
                }) else { throw MuesliSettings.Failure.rejected("Model selection changed during activation.") }
            }
            pendingWrite = "\(preference.label): \(preference.choice(for: selection.value)?.label ?? selection.value)"
            attemptedWrite = true
            let message = try await MuesliSettings.apply(selection, settings: current, snapshots: [snapshot],
                source: .confirmedPreference, config: config, persistedConfig: persistedConfig)
            if targetIDs.isEmpty {
                let prefix = unavailable(selection.value) == nil ? "Saved" : "Saved for later"
                return "\(prefix): \(message). Active model selections were not changed."
            }
            completed.append(message)
            let otherModels = current.first { $0.id == selection.setting }?.activation?.unavailable(selection.value) != nil
            return completed.joined(separator: "; ") + (otherModels ? ". Other models remain unchanged and may not use this preference." : "")
        } catch {
            guard attemptedWrite else { throw error }
            let saved = (completed.isEmpty ? "" : "Saved: " + completed.joined(separator: "; ") + ". ")
                + (pendingWrite.map { "Could not verify saving \($0); it may have changed." }
                   ?? "The remaining steps did not complete; check the saved selections.")
            throw MuesliSettings.Failure.rejected("Could not finish the whole request. \(saved) Check Settings before retrying.")
        }
    }
}

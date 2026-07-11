import Foundation

enum ComputerUseMuesliSettingsMutation: Equatable {
    case transcriptionModel(BackendOption)
    case aiCleanup(Bool)
    case dictionaryWord(CustomWord)
    case removeDictionaryWord(String)
    case computerUseEnabled(Bool)
    case computerUseSafetyLimit(Int)
    case pauseMediaDuringDictation(Bool)
    case muteSystemAudioDuringDictation(Bool)
    case floatingIndicatorEnabled(Bool)
    case floatingIndicatorPosition(IndicatorAnchor)
    case soundEffects(Bool)
    case darkMode(Bool)
    case openDashboardOnLaunch(Bool)
}

struct ComputerUseMuesliSettingsError: Error, Equatable {
    let message: String
}

enum ComputerUsePreparedSettingsResult: Equatable {
    case committed
    case cancelled
    case failed(String)
}

enum ComputerUseMuesliSettingsDriver {
    @MainActor
    static func prepareThenPersist(
        prepare: () async throws -> Void,
        persist: () -> Void
    ) async -> ComputerUsePreparedSettingsResult {
        do {
            try await prepare()
            persist()
            return .committed
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func mutation(for toolCall: ComputerUseToolCall) -> Result<ComputerUseMuesliSettingsMutation, ComputerUseMuesliSettingsError> {
        guard toolCall.tool == .updateMuesliSettings else {
            return .failure(.init(message: "Expected update_muesli_settings tool call"))
        }
        guard let operation = toolCall.operation else {
            return .failure(.init(message: "update_muesli_settings requires operation"))
        }

        switch operation {
        case .setTranscriptionModel:
            let requested = trimmed(toolCall.model)
            guard let option = transcriptionModel(named: requested) else {
                let supported = BackendOption.all.map(\.label).joined(separator: ", ")
                return .failure(.init(message: "Unsupported transcription model '\(requested)'. Supported models: \(supported)."))
            }
            return .success(.transcriptionModel(option))

        case .setAICleanup:
            guard let enabled = toolCall.enabled else {
                return .failure(.init(message: "set_ai_cleanup requires enabled"))
            }
            return .success(.aiCleanup(enabled))

        case .addDictionaryWord:
            let word = trimmed(toolCall.word)
            let replacement = trimmed(toolCall.replacement)
            guard isValidDictionaryText(word) else {
                return .failure(.init(message: "Dictionary word must be a single-line value between 1 and 128 characters."))
            }
            guard replacement.isEmpty || isValidDictionaryText(replacement) else {
                return .failure(.init(message: "Dictionary replacement must be a single-line value no longer than 128 characters."))
            }
            return .success(.dictionaryWord(CustomWord(
                word: word,
                replacement: replacement.isEmpty ? nil : replacement
            )))

        case .removeDictionaryWord:
            let word = trimmed(toolCall.word)
            guard isValidDictionaryText(word) else {
                return .failure(.init(message: "Dictionary word must be a single-line value between 1 and 128 characters."))
            }
            return .success(.removeDictionaryWord(word))

        case .setComputerUseEnabled:
            return booleanMutation(toolCall.enabled, operation: operation, ComputerUseMuesliSettingsMutation.computerUseEnabled)

        case .setComputerUseSafetyLimit:
            guard let seconds = toolCall.seconds, (1...600).contains(seconds) else {
                return .failure(.init(message: "Computer Use safety limit must be between 1 and 600 seconds."))
            }
            return .success(.computerUseSafetyLimit(seconds))

        case .setPauseMediaDuringDictation:
            return booleanMutation(toolCall.enabled, operation: operation, ComputerUseMuesliSettingsMutation.pauseMediaDuringDictation)

        case .setMuteSystemAudioDuringDictation:
            return booleanMutation(toolCall.enabled, operation: operation, ComputerUseMuesliSettingsMutation.muteSystemAudioDuringDictation)

        case .setFloatingIndicatorEnabled:
            return booleanMutation(toolCall.enabled, operation: operation, ComputerUseMuesliSettingsMutation.floatingIndicatorEnabled)

        case .setFloatingIndicatorPosition:
            let requested = trimmed(toolCall.position)
            guard let anchor = indicatorAnchor(named: requested) else {
                let supported = IndicatorAnchor.allCases
                    .filter { $0 != .custom }
                    .map(\.label)
                    .joined(separator: ", ")
                return .failure(.init(message: "Unsupported floating indicator position '\(requested)'. Supported positions: \(supported)."))
            }
            return .success(.floatingIndicatorPosition(anchor))

        case .setSoundEffects:
            return booleanMutation(toolCall.enabled, operation: operation, ComputerUseMuesliSettingsMutation.soundEffects)

        case .setTheme:
            switch canonical(trimmed(toolCall.theme)) {
            case "dark":
                return .success(.darkMode(true))
            case "light":
                return .success(.darkMode(false))
            default:
                return .failure(.init(message: "Theme must be light or dark."))
            }

        case .setOpenDashboardOnLaunch:
            return booleanMutation(toolCall.enabled, operation: operation, ComputerUseMuesliSettingsMutation.openDashboardOnLaunch)
        }
    }

    static func indicatorAnchor(named requested: String) -> IndicatorAnchor? {
        let key = canonical(requested)
        guard !key.isEmpty else { return nil }
        return IndicatorAnchor.allCases.first {
            $0 != .custom && (canonical($0.rawValue) == key || canonical($0.label) == key)
        }
    }

    static func transcriptionModel(named requested: String) -> BackendOption? {
        let key = canonical(requested)
        guard !key.isEmpty else { return nil }

        let aliases: [String: BackendOption] = [
            "parakeet": .parakeetMultilingual,
            "parakeet multilingual": .parakeetMultilingual,
            "parakeet v3": .parakeetMultilingual,
            "parakeet english": .parakeetEnglish,
            "parakeet v2": .parakeetEnglish,
            "qwen": .qwen3Asr,
            "qwen3": .qwen3Asr,
            "qwen 3": .qwen3Asr,
            "nemotron": .nemotron35Multilingual,
            "nemotron 3 5": .nemotron35Multilingual,
        ]
        if let alias = aliases[key] {
            return alias
        }

        if let exact = BackendOption.all.first(where: {
            canonical($0.label) == key || canonical($0.model) == key
        }) {
            return exact
        }

        let labelMatches = BackendOption.all.filter {
            let label = canonical($0.label)
            return label.contains(key) || key.contains(label)
        }
        return labelMatches.count == 1 ? labelMatches[0] : nil
    }

    private static func isValidDictionaryText(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && !value.contains("\n")
            && !value.contains("\r")
    }

    private static func booleanMutation(
        _ enabled: Bool?,
        operation: ComputerUseMuesliSettingsOperation,
        _ mutation: (Bool) -> ComputerUseMuesliSettingsMutation
    ) -> Result<ComputerUseMuesliSettingsMutation, ComputerUseMuesliSettingsError> {
        guard let enabled else {
            return .failure(.init(message: "\(operation.rawValue) requires enabled."))
        }
        return .success(mutation(enabled))
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func canonical(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}

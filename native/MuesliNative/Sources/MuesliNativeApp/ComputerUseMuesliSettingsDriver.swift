import Foundation

enum ComputerUseMuesliSettingsMutation: Equatable {
    case transcriptionModel(BackendOption)
    case aiCleanup(Bool)
    case dictionaryWord(CustomWord)
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

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func canonical(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}

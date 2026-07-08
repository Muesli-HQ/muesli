import Foundation
import LLM

enum Qwen3PostProcessorLogging {
    private static let verboseEnv = "MUESLI_DEBUG_POSTPROC_LOGS"
    private static let pairLogEnv = "MUESLI_LOG_POSTPROC_PAIRS"

    static var isVerboseEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment[verboseEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static var isPairLoggingEnabled: Bool {
        guard isVerboseEnabled else { return false }
        let raw = ProcessInfo.processInfo.environment[pairLogEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func logVerbose(_ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        fputs("[muesli-native] \(message())\n", stderr)
    }
}

enum Qwen3DeletionCueDetector {
    private static let deletionCues: [String] = [
        "scratch that", "delete that", "forget that", "never mind",
    ]

    static func containsDeletionCue(_ text: String) -> Bool {
        let lower = text.lowercased()
        return deletionCues.contains { lower.contains($0) }
    }
}

enum Qwen3PostProcessorOutputCleaner {
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        result = result.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?is)<think\b[^>]*>[\s\S]*$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<\|im_(?:start|end)\|>"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```[A-Za-z0-9_-]*\s*"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^`+|`+$"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[end of text\]"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:[#>*-]+\s*)?(?:\*\*|__)?(?:transcription|cleaned transcription|output|response)(?:\*\*|__)?\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        // Observed model leakage from earlier prompt variants. Keep narrow so normal transcript text is not rewritten.
        result = result.replacingOccurrences(
            of: #"(?im)^\s*when the speaker is dictating a numbered list or bullet list,\s*format each item on its own line\.?\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*if the speaker is dictating a list, such as saying ["“”]?first point["“”]?[,]?\s*["“”]?second point["“”]?[,]?\s*or ["“”]?bullet point["“”]?[,]?\s*format each item on its own line\.?\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?im)^\s*(?:\*\*|__)([^*\n_]{1,80})(?:\*\*|__)\s*$"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldFallbackToInput(cleaned: String, input: String) -> Bool {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lower = trimmed.lowercased()
        if isPlaceholderOutput(trimmed) {
            return true
        }

        let assistantMarkers = [
            "the user is asking",
            "**analysis:**",
            "analysis:",
            "**action plan:**",
            "action plan:",
            "grammar/spelling:",
            "meaning:",
            "remove the filler word",
        ]
        if assistantMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let inputLength = max(input.trimmingCharacters(in: .whitespacesAndNewlines).count, 1)
        // Cleanup should usually compress text. Treat expansion as a hallucination signal,
        // with a lower absolute floor for short dictations.
        let expansion = Double(trimmed.count) / Double(inputLength)
        if inputLength < 50 {
            return expansion > 4.0 && trimmed.count > 80
        }
        if inputLength < 150 {
            return expansion > 2.5 && trimmed.count > 150
        }
        return expansion > 2.0 && trimmed.count > 200
    }

    private static func isPlaceholderOutput(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "…", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "..." || normalized == ". . ." {
            return true
        }
        let punctuationOnly = normalized.allSatisfy { character in
            character.isWhitespace || ".…-_,;:!?()[]{}".contains(character)
        }
        return punctuationOnly && normalized.count <= 8
    }
}

enum Qwen3PostProcessorConfig {
    // Local development override — takes precedence over the UI-selected model when set.
    static let envOverride = "MUESLI_QWEN3_POSTPROC_GGUF"
    static let legacyDirectoryEnvOverride = "MUESLI_QWEN3_POSTPROC_DIR"
    // Dictation-only cleanup cap. Keep bounded to avoid slow local inference; long dictations may be truncated by LLM.swift.
    static let maxContextTokens: Int32 = 1024
    static let defaultAppContextCharacterLimit = 1_200

    static func formatInput(
        _ text: String,
        appContext: String? = nil,
        maxAppContextCharacters: Int = defaultAppContextCharacterLimit
    ) -> String {
        var parts = ""
        if let appContext, !appContext.isEmpty {
            parts += "<APP-CONTEXT>\n\(String(appContext.prefix(maxAppContextCharacters)))\n</APP-CONTEXT>\n\n"
        }
        parts += "<USER-INPUT>\n\(text)\n</USER-INPUT>"
        return parts
    }

    /// Checks for a local development env-var override and returns the resolved GGUF URL if present.
    static func devOverrideURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        for key in [envOverride, legacyDirectoryEnvOverride] {
            guard let raw = env[key], !raw.isEmpty else { continue }
            let url = URL(fileURLWithPath: raw)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let found = firstGGUF(in: url) { return found }
            } else if url.pathExtension.lowercased() == "gguf" {
                return url
            }
        }
        return nil
    }

    private static func firstGGUF(in directory: URL) -> URL? {
        guard let e = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let f as URL in e where f.pathExtension.lowercased() == "gguf" { return f }
        return nil
    }
}

actor Qwen3InferenceGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isProcessing = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !isProcessing {
            isProcessing = true
            return
        }

        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard acquired else { throw CancellationError() }
    }

    func release() {
        if waiters.isEmpty {
            isProcessing = false
            return
        }

        waiters.removeFirst().continuation.resume(returning: true)
    }

    func queuedWaiterCount() -> Int {
        waiters.count
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

@available(macOS 15, *)
private actor Qwen3PostProcessorManager {
    private let modelURL: URL
    private let systemPrompt: String
    private var bot: LLM?
    private let inferenceGate = Qwen3InferenceGate()

    init(modelURL: URL, systemPrompt: String) {
        self.modelURL = modelURL
        self.systemPrompt = systemPrompt
    }

    func warm() throws {
        _ = try loadBot()
    }

    func process(_ text: String, appContext: String? = nil) async throws -> String {
        // Actors can re-enter while respond() awaits; serialize access to the cached mutable LLM.
        try await inferenceGate.acquire()
        do {
            try Task.checkCancellation()
            let bot = try loadBot()
            defer { bot.reset() }
            let formattedInput = Qwen3PostProcessorConfig.formatInput(text, appContext: appContext)
            await bot.respond(to: formattedInput, thinking: .suppressed)
            let raw = bot.output
            let cleaned = Qwen3PostProcessorOutputCleaner.clean(raw)
            Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF prompt chars=\(bot.preprocess(formattedInput, [], .suppressed).count)")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF raw output: \(raw)")
            Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF cleaned output: \(cleaned)")
            let result: String
            if Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: cleaned, input: text) {
                Qwen3PostProcessorLogging.logVerbose("Qwen3 GGUF output rejected; falling back to deterministic cleanup")
                throw NSError(domain: "Qwen3PostProcessor", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Qwen3 GGUF output was rejected by transcript safety checks",
                ])
            } else {
                result = cleaned
            }
            await inferenceGate.release()
            return result
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    private func loadBot() throws -> LLM {
        if let bot { return bot }
        guard let loaded = LLM(
            from: modelURL,
            seed: 7,
            topK: 1,
            topP: 1.0,
            temp: 0.0,
            repeatPenalty: 1.0,
            repetitionLookback: 64,
            historyLimit: 0,
            maxTokenCount: Qwen3PostProcessorConfig.maxContextTokens
        ) else {
            throw NSError(domain: "Qwen3PostProcessor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load Qwen3 GGUF model at \(modelURL.path)",
            ])
        }
        loaded.useResolvedTemplate(systemPrompt: systemPrompt)
        bot = loaded
        return loaded
    }
}

@available(macOS 15, *)
actor Qwen3PostProcessor {
    private struct LoadTaskState {
        let id = UUID()
        let modelURL: URL
        let systemPrompt: String
        let task: Task<Qwen3PostProcessorManager, Error>
    }

    private var modelURL: URL
    private var systemPrompt: String
    private var manager: Qwen3PostProcessorManager?
    private var loadTask: LoadTaskState?

    init(modelURL: URL, systemPrompt: String) {
        // Local development env-var override takes precedence.
        self.modelURL = Qwen3PostProcessorConfig.devOverrideURL() ?? modelURL
        self.systemPrompt = systemPrompt
    }

    /// Swap to a different model or system prompt. Discards the loaded manager so
    /// the next `prepare()` or `process()` call reloads with the new config.
    func reconfigure(modelURL: URL, systemPrompt: String) {
        let resolved = Qwen3PostProcessorConfig.devOverrideURL() ?? modelURL
        guard resolved != self.modelURL || systemPrompt != self.systemPrompt else { return }
        self.modelURL = resolved
        self.systemPrompt = systemPrompt
        manager = nil
        loadTask?.task.cancel()
        loadTask = nil
    }

    func prepare() async throws {
        _ = try await loadManager()
    }

    func process(_ text: String, appContext: String? = nil) async throws -> String {
        let manager = try await loadManager()
        return try await manager.process(text, appContext: appContext)
    }

    func shutdown() {
        manager = nil
        loadTask?.task.cancel()
        loadTask = nil
    }

    private func loadManager() async throws -> Qwen3PostProcessorManager {
        if let manager { return manager }
        if let loadTask { return try await finishLoad(loadTask) }

        let url = self.modelURL
        let prompt = self.systemPrompt
        let task = Task<Qwen3PostProcessorManager, Error> {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "Qwen3PostProcessor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Post-processor model not found at \(url.path). Download it from the Models tab.",
                ])
            }
            let manager = Qwen3PostProcessorManager(modelURL: url, systemPrompt: prompt)
            try await manager.warm()
            return manager
        }
        let state = LoadTaskState(modelURL: url, systemPrompt: prompt, task: task)
        loadTask = state
        return try await finishLoad(state)
    }

    private func finishLoad(_ state: LoadTaskState) async throws -> Qwen3PostProcessorManager {
        do {
            let loaded = try await state.task.value
            guard state.modelURL == modelURL, state.systemPrompt == systemPrompt else {
                if loadTask?.id == state.id {
                    loadTask = nil
                }
                return try await loadManager()
            }
            if let manager { return manager }
            guard loadTask?.id == state.id else { throw CancellationError() }
            manager = loaded
            loadTask = nil
            return loaded
        } catch {
            if loadTask?.id == state.id {
                loadTask = nil
            }
            throw error
        }
    }
}

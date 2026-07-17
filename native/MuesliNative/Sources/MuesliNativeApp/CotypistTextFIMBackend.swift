import Foundation
import LLM

enum CotypistTextFIMModelStore {
    static let id = "qwen3-0.6b-text-fim"
    static let label = "Qwen3 0.6B Text FIM"
    static let sizeLabel = "~397 MB"
    static let filename = "Qwen3-0.6B-Text-FIM-Q4_K_M.gguf"
    static let downloadURL = URL(
        string: "https://huggingface.co/OleFranz/Qwen3-0.6B-Text-FIM-GGUF/resolve/main/Qwen3-0.6B-Text-FIM-Q4_K_M.gguf"
    )!
    static let sourceURL = URL(string: "https://huggingface.co/OleFranz/Qwen3-0.6B-Text-FIM-GGUF")!
    static let licenseLabel = "GPL-3.0"
    static let developmentOverrideEnvironmentKey = "MUESLI_COTYPIST_QWEN_FIM_GGUF"

    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/cotypist-\(id)", isDirectory: true)
    }

    static var modelURL: URL {
        cacheDirectory.appendingPathComponent(filename)
    }

    static func resolvedModelURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let path = environment[developmentOverrideEnvironmentKey], !path.isEmpty else {
            return modelURL
        }
        return URL(fileURLWithPath: path)
    }

    static func isAvailableLocally() -> Bool {
        FileManager.default.fileExists(atPath: resolvedModelURL().path)
    }
}

private final class CotypistFIMOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func set(_ value: String) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Raw fill-in-the-middle inference for a base GGUF checkpoint. This deliberately
/// bypasses chat templates, system prompts, and the transcript post-processing path.
@available(macOS 15, *)
actor CotypistTextFIMEngine {
    static let maximumContextTokens: Int32 = 2_048

    private let modelURL: URL
    private let inferenceGate = InferenceGate()
    private var bot: LLM?

    init(modelURL: URL = CotypistTextFIMModelStore.resolvedModelURL()) {
        self.modelURL = modelURL
    }

    func prepare() throws {
        _ = try loadBot()
    }

    func completeText(_ request: CotypistCompletionRequest) async throws -> String {
        try await inferenceGate.acquire()
        do {
            try Task.checkCancellation()
            let bot = try loadBot()
            let outputBuffer = CotypistFIMOutputBuffer()

            await bot.respond(to: request.fimPrompt, thinking: .none) { stream in
                var output = ""
                var generatedTokenCount = 0
                var requestedStop = false
                for await piece in stream {
                    if Task.isCancelled, !requestedStop {
                        bot.stop()
                        requestedStop = true
                    }
                    if !requestedStop {
                        output += piece
                        generatedTokenCount += 1
                    }
                    if generatedTokenCount >= request.maxOutputTokens, !requestedStop {
                        bot.stop()
                        requestedStop = true
                    }
                }
                outputBuffer.set(output)
                return output
            }

            try Task.checkCancellation()
            let result = outputBuffer.value()
            await inferenceGate.release()
            return result
        } catch {
            await inferenceGate.release()
            throw error
        }
    }

    func cancel() {
        bot?.stop()
    }

    func shutdown() {
        bot = nil
    }

    private func loadBot() throws -> LLM {
        if let bot { return bot }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NSError(domain: "CotypistTextFIM", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cotypist model not found. Download \(CotypistTextFIMModelStore.label) in Local Language Models.",
            ])
        }
        guard let loaded = LLM(
            from: modelURL,
            seed: 7,
            topK: 1,
            topP: 1.0,
            temp: 0.0,
            repeatPenalty: 1.0,
            repetitionLookback: 64,
            historyLimit: 0,
            maxTokenCount: Self.maximumContextTokens
        ) else {
            throw NSError(domain: "CotypistTextFIM", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load the Cotypist GGUF model.",
            ])
        }
        // LLM.swift prints through this callback by default. Cotypist content must
        // remain ephemeral and must never enter stdout, stderr, or telemetry.
        loaded.postprocess = { _ in }
        bot = loaded
        return loaded
    }
}

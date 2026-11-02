import Foundation

enum TranscriptCleanupDebugLogger {
    private static let logEnv = "MUESLI_LOG_TRANSCRIPT_CLEANUP_DEBUG"
    private static let maxLoggedTextCharacters = 4_000
    private static let maxLogFileBytes: UInt64 = 5 * 1024 * 1024
    private static let writeQueue = DispatchQueue(label: "MuesliNative.TranscriptCleanupDebugLogger")

    @TaskLocal static var requestID: String?
    @TaskLocal static var suppressContentLogging = false

    struct PromptEntry: Encodable {
        let requestID: String?
        let userPrompt: String
    }

    static func prompt(_ userPrompt: String) {
        guard isEnabled else { return }
        append(PromptEntry(requestID: requestID, userPrompt: userPrompt),
               to: AppIdentity.supportDirectoryURL.appendingPathComponent("cleanup-prompts.jsonl"))
    }

    struct TimingEntry: Encodable {
        let ts: String
        let requestID: String?
        let stage: String
        let elapsedMs: Double
        let detail: String?
    }

    /// Monotonic durations; no transcript or screen contents in timing records.
    static func timing(_ stage: String, since start: TimeInterval, detail: String? = nil) {
        guard isEnabled else { return }
        append(TimingEntry(ts: ISO8601DateFormatter().string(from: Date()),
                           requestID: requestID, stage: stage,
                           elapsedMs: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                           detail: detail),
               to: AppIdentity.supportDirectoryURL.appendingPathComponent("cleanup-timing.jsonl"))
    }

    struct Entry: Encodable {
        let requestID: String?

        let ts: String
        let status: String
        let cleanupBackend: String
        let cleanupModel: String
        let asrBackend: String
        let appContextText: String?
        let rawASRText: String
        let rawCleanupOutputText: String?
        let cleanupOutputText: String?
        let errorDescription: String?
        let elapsedMs: Double?
    }

    static func append(
        status: String,
        cleanupBackend: TranscriptCleanupBackendOption,
        cleanupModel: String,
        asrBackend: String,
        appContextText: String? = nil,
        rawASRText: String,
        rawCleanupOutputText: String? = nil,
        cleanupOutputText: String? = nil,
        errorDescription: String? = nil,
        elapsedMs: Double? = nil
    ) {
        guard isEnabled else { return }
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = Entry(
            requestID: requestID,
            ts: iso8601.string(from: Date()),
            status: status,
            cleanupBackend: cleanupBackend.backend,
            cleanupModel: cleanupModel,
            asrBackend: asrBackend,
            appContextText: appContextText.map(bounded),
            rawASRText: bounded(rawASRText),
            rawCleanupOutputText: rawCleanupOutputText.map(bounded),
            cleanupOutputText: cleanupOutputText.map(bounded),
            errorDescription: errorDescription,
            elapsedMs: elapsedMs
        )
        append(entry, to: AppIdentity.supportDirectoryURL.appendingPathComponent("transcript-cleanup-debug.jsonl"))
    }

    static var isEnabled: Bool {
        guard !suppressContentLogging else { return false }
        let raw = ProcessInfo.processInfo.environment[logEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes" || Qwen3PostProcessorLogging.isPairLoggingEnabled
    }

    private static func append<T: Encodable>(_ entry: T, to logURL: URL) {
        writeQueue.sync {
            guard var data = try? JSONEncoder().encode(entry) else { return }
            data.append(0x0A)
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotateIfNeeded(logURL)
            if FileManager.default.fileExists(atPath: logURL.path),
               let fh = try? FileHandle(forWritingTo: logURL) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    private static func bounded(_ text: String) -> String {
        guard text.count > maxLoggedTextCharacters else { return text }
        return "\(text.prefix(maxLoggedTextCharacters))...[truncated]"
    }

    private static func rotateIfNeeded(_ logURL: URL) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? UInt64,
            size > maxLogFileBytes
        else { return }
        try? FileManager.default.removeItem(at: logURL)
    }
}

import Darwin
import Foundation

/// Appends app lifecycle/usage events as JSON Lines to `events.jsonl` in the
/// app support directory. Events stay on this machine — this is the local
/// replacement for the removed TelemetryDeck analytics.
final class EventLogWriter: @unchecked Sendable {
    private let fileURL: URL
    private let rotatedFileURL: URL
    private let maxBytes: Int
    private let appVersion: String?
    private let queue = DispatchQueue(label: "com.muesli.event-log")
    private let stateLock = NSLock()
    private var enabled: Bool

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        directory: URL,
        isEnabled: Bool,
        maxBytes: Int = 5 * 1024 * 1024,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) {
        self.fileURL = directory.appendingPathComponent("events.jsonl")
        self.rotatedFileURL = directory.appendingPathComponent("events.jsonl.1")
        self.enabled = isEnabled
        self.maxBytes = maxBytes
        self.appVersion = appVersion
    }

    var logURL: URL { fileURL }

    var isEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return enabled
    }

    func setEnabled(_ value: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        enabled = value
    }

    func write(_ name: String, parameters: [String: String] = [:]) {
        guard isEnabled else { return }
        guard let line = encodeLine(name: name, parameters: parameters) else {
            fputs("[event-log] failed to encode event \(name)\n", stderr)
            return
        }
        queue.async { [self] in
            append(line)
        }
    }

    /// Blocks until queued writes have landed. Called at app termination and
    /// from tests.
    func flush() {
        queue.sync {}
    }

    private func encodeLine(name: String, parameters: [String: String]) -> Data? {
        var payload: [String: Any] = [
            "ts": Self.timestampFormatter.string(from: Date()),
            "event": name,
        ]
        if let appVersion {
            payload["app_version"] = appVersion
        }
        if !parameters.isEmpty {
            payload["params"] = parameters
        }
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }

    private func append(_ line: Data) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded()
            // O_APPEND never truncates an existing file and keeps concurrent
            // line-sized appends atomic; mode 0600 applies on create.
            let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            // Tighten permissions even when the file pre-existed with a looser mode.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            try handle.write(contentsOf: line)
        } catch {
            fputs("[event-log] failed to append event: \(error)\n", stderr)
        }
    }

    private func rotateIfNeeded() {
        let fileManager = FileManager.default
        guard
            let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
            size >= maxBytes
        else {
            return
        }
        do {
            if fileManager.fileExists(atPath: rotatedFileURL.path) {
                try fileManager.removeItem(at: rotatedFileURL)
            }
            try fileManager.moveItem(at: fileURL, to: rotatedFileURL)
        } catch {
            fputs("[event-log] failed to rotate event log: \(error)\n", stderr)
        }
    }
}

/// Drop-in replacement for `TelemetryDeck.signal` that records events locally.
/// Stays disabled until `configure(enabled:)` is called with the loaded config
/// value (`enable_event_log` in config.json); MuesliController re-applies it on
/// every config change, so toggling the flag takes effect immediately.
enum LocalTelemetry {
    private static let writer = EventLogWriter(
        directory: AppIdentity.supportDirectoryURL,
        isEnabled: false
    )

    static func configure(enabled: Bool) {
        writer.setEnabled(enabled)
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        writer.write(name, parameters: parameters)
    }

    /// Drains pending writes; called from applicationWillTerminate.
    static func flush() {
        writer.flush()
    }
}

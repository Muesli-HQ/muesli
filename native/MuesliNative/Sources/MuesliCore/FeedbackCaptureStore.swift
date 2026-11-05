import Foundation
import Darwin
import Darwin.sys.file
import SQLite3

/// Local-only bundles. The journal remains authoritative until manifest AND row publication succeed.
public final class FeedbackCaptureStore: @unchecked Sendable {
    public let support: URL
    public var root: URL { support.appendingPathComponent("feedback-captures", isDirectory: true) }
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var active: Set<String> = []
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL, support: URL) throws {
        self.support = support
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure("Open database") }
        sqlite3_busy_timeout(db, 5_000)
    }
    deinit { sqlite3_close(db) }
    static func migrate(db: OpaquePointer?) throws {
        guard sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS feedback_captures(id TEXT PRIMARY KEY, created_at REAL NOT NULL, duration_ms INTEGER NOT NULL, state TEXT NOT NULL, bundle_path TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS feedback_captures_time ON feedback_captures(created_at);
        """, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "FeedbackCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot migrate Scrawl captures"]) }
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "FeedbackCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private func validID(_ id: String) -> Bool {
        id.range(of: "^fc-[0-9]+-[0-9a-f]{4}$", options: .regularExpression) != nil
    }
    public func bundleURL(id: String) throws -> URL {
        guard validID(id) else { throw failure("Invalid capture ID") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let result = root.appendingPathComponent(id + ".capture").standardizedFileURL.resolvingSymlinksInPath()
        guard base.path.hasPrefix(support.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              result == base.appendingPathComponent(id + ".capture") else { throw failure("Invalid capture path") }
        return result
    }
    public func mediaURL(id: String, path: String) throws -> URL {
        let bundle = try bundleURL(id: id)
        let result = bundle.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), result.path.hasPrefix(bundle.path + "/") else { throw failure("Invalid capture media path") }
        return result
    }
    private func withCaptureMutationLock<T>(id: String, _ body: () throws -> T) throws -> T {
        guard validID(id) else { throw failure("Invalid capture ID") }
        _ = try bundleURL(id: id)
        let directory = root.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(id).lock", isDirectory: false)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw failure("Open capture mutation lock") }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw failure("Lock capture mutation") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func captureRowExists(id: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM feedback_captures WHERE id=? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw failure("Prepare capture lookup")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, transient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure("Check capture row")
        }
    }
    /// Mutate an existing capture bundle while coordinating with deletion in every process.
    /// `nil` means the row or bundle no longer exists; the body is never run in that case.
    public func withExistingBundleMutation<T>(id: String, _ body: (URL) throws -> T) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        let folder = try bundleURL(id: id)
        let result: T? = try withCaptureMutationLock(id: id) {
            guard try captureRowExists(id: id), FileManager.default.fileExists(atPath: folder.path) else { return nil }
            return try body(folder)
        }
        return result
    }
    public func begin(target: FeedbackCaptureTarget, now: Date = Date()) throws -> FeedbackCaptureManifest {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let id = "fc-\(ms)-\(UUID().uuidString.prefix(4).lowercased())"
        let bundle = try bundleURL(id: id)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifest = FeedbackCaptureManifest(id: id, createdAtMs: ms, target: target)
        try checkpoint(manifest)
        active.insert(id)
        do { try save(manifest) }
        catch { active.remove(id); throw error }
        return manifest
    }
    public func checkpoint(_ manifest: FeedbackCaptureManifest) throws {
        lock.lock(); defer { lock.unlock() }
        try validatePaths(manifest)
        try JSONEncoder().encode(manifest).write(to: mediaURL(id: manifest.id, path: "unfinished.json"), options: .atomic)
    }
    public func isActive(id: String) -> Bool { lock.withLock { active.contains(id) } }
    public func release(id: String) { lock.lock(); defer { lock.unlock() }; active.remove(id) }
    public func manifest(id: String) throws -> FeedbackCaptureManifest {
        lock.lock(); defer { lock.unlock() }
        let journal = try mediaURL(id: id, path: "unfinished.json")
        let url = FileManager.default.fileExists(atPath: journal.path) ? journal : try mediaURL(id: id, path: "capture.json")
        let result = try JSONDecoder().decode(FeedbackCaptureManifest.self, from: Data(contentsOf: url))
        guard result.id == id else { throw failure("Capture identity mismatch") }
        return result
    }
    private func validatePaths(_ manifest: FeedbackCaptureManifest) throws {
        for path in [manifest.audio, manifest.video, manifest.contactSheet].compactMap({ $0 }) + manifest.keyframes.map(\.file) + manifest.marks.compactMap(\.frame) {
            _ = try mediaURL(id: manifest.id, path: path)
        }
    }
    public func save(_ manifest: FeedbackCaptureManifest) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try bundleURL(id: manifest.id)
        try validatePaths(manifest)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO feedback_captures VALUES(?,?,?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure("Prepare capture save") }
        defer { sqlite3_finalize(stmt) }
        var projection: [String: Any] = ["keyframeCount": manifest.keyframes.count, "targetApp": manifest.target.appName]
        projection["transcriptSource"] = manifest.transcript?.source
        let body = String(decoding: try JSONSerialization.data(withJSONObject: projection), as: UTF8.self)
        sqlite3_bind_text(stmt, 1, manifest.id, -1, transient)
        sqlite3_bind_double(stmt, 2, Double(manifest.createdAtMs) / 1000)
        sqlite3_bind_int64(stmt, 3, manifest.durationMs)
        sqlite3_bind_text(stmt, 4, manifest.state.rawValue, -1, transient)
        sqlite3_bind_text(stmt, 5, "feedback-captures/\(manifest.id).capture", -1, transient)
        sqlite3_bind_text(stmt, 6, manifest.transcript?.firstClause ?? manifest.target.appName, -1, transient)
        sqlite3_bind_text(stmt, 7, body, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure("Save capture: \(String(cString: sqlite3_errmsg(db)))") }
    }
    public func publish(_ manifest: FeedbackCaptureManifest) throws {
        lock.lock(); defer { lock.unlock() }
        try checkpoint(manifest)
        try JSONEncoder().encode(manifest).write(to: mediaURL(id: manifest.id, path: "capture.json"), options: .atomic)
        try save(manifest)
        let journal = try mediaURL(id: manifest.id, path: "unfinished.json")
        if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
    }
    public func list() throws -> [FeedbackCaptureRecord] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,created_at,duration_ms,state,bundle_path,title FROM feedback_captures ORDER BY created_at DESC,id DESC", -1, &stmt, nil) == SQLITE_OK else { throw failure("List captures") }
        defer { sqlite3_finalize(stmt) }
        var result: [FeedbackCaptureRecord] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            func text(_ i: Int32) -> String { String(cString: sqlite3_column_text(stmt, i)) }
            if let state = FeedbackCaptureState(rawValue: text(3)) {
                result.append(.init(id: text(0), createdAt: sqlite3_column_double(stmt, 1), durationMs: sqlite3_column_int64(stmt, 2), state: state, bundlePath: text(4), title: text(5)))
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure("Read captures") }
        return result
    }
    public func get(id: String) throws -> FeedbackCaptureRecord? {
        let journal = try mediaURL(id: id, path: "unfinished.json")
        if !FileManager.default.fileExists(atPath: journal.path) {
            return try list().first { $0.id == id }
        }
        let m = try manifest(id: id)
        return FeedbackCaptureRecord(id: m.id, createdAt: Double(m.createdAtMs) / 1000,
            durationMs: m.durationMs, state: m.state, bundlePath: "feedback-captures/\(id).capture", title: m.target.appName)
    }
    private func isEmptyWAV(_ url: URL, size: Int) throws -> Bool {
        guard size == 44 else { return false }
        let header = try Data(contentsOf: url)
        return header.count == 44 && header.prefix(4) == Data("RIFF".utf8)
            && header[8..<12] == Data("WAVE".utf8)
            && header[36..<40] == Data("data".utf8)
            && header[40..<44].allSatisfy { $0 == 0 }
    }
    /// Probe each medium independently, retaining files whose validity is uncertain.
    /// The same operation reconciles a normal Finish and an interrupted journal.
    public func reconcileMedia(_ recording: FeedbackCaptureManifest,
        audioDuration: @escaping (URL) throws -> Int64?, videoDuration: @escaping (URL) throws -> Int64?) -> (manifest: FeedbackCaptureManifest, retainsContent: Bool) {
        var m = recording
        var openGap: Int64?
        let log = try? mediaURL(id: m.id, path: "events.jsonl")
        if let log, FileManager.default.fileExists(atPath: log.path) {
            do {
                let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: m.target)
                m.events = replay.events; m.strokes = replay.strokes
                var mergedGaps: [FeedbackCaptureInputGap] = []
                for gap in m.inputGaps + replay.inputGaps where !mergedGaps.contains(gap) {
                    mergedGaps.append(gap)
                }
                m.inputGaps = mergedGaps; openGap = replay.gapStart
                m.durationMs = max(m.durationMs, replay.durationMs)
                for issue in replay.failures where !m.failures.contains(issue) { m.failures.append(issue) }
            } catch { m.failures.append(.init(stage: "events", message: error.localizedDescription)) }
        }
        m.durationMs = max(m.durationMs, m.events.map(\.end).max() ?? 0)
        m.durationMs = max(m.durationMs, m.strokes.map(\.t1).max() ?? 0)
        if m.marks.isEmpty { m.marks = FeedbackCaptureInk.marks(m.strokes) }
        var retainsContent = !m.events.isEmpty || !m.strokes.isEmpty
        for (path, stage, probe) in [("narration.wav", "audio", audioDuration), ("recording.mp4", "video", videoDuration)] {
            do {
                let url = try mediaURL(id: m.id, path: path)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let emptyWAV = try stage == "audio" && isEmptyWAV(url, size: size)
                retainsContent = retainsContent || (size > 0 && !emptyWAV)
                if let duration = try probe(url) {
                    retainsContent = true
                    if stage == "audio" { m.audio = path } else { m.video = path }
                    m.alignClocks()
                    m.durationMs = max(m.durationMs, duration + (stage == "video" ? m.videoOffsetMs ?? 0 : 0))
                } else if size > 0, !emptyWAV, (stage == "audio" ? m.audio : m.video) == nil {
                    m.failures.append(.init(stage: stage, message: "Retained \(stage) is unavailable for playback."))
                }
            } catch {
                m.failures.append(.init(stage: stage, message: error.localizedDescription))
                // An unreadable path is uncertain, never proof of an empty bundle.
                retainsContent = true
            }
        }
        if let start = openGap {
            let gap = FeedbackCaptureInputGap(t0: start, t1: max(start, m.durationMs))
            if !m.inputGaps.contains(gap) { m.inputGaps.append(gap) }
        }
        return (m, retainsContent)
    }
    public func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !active.contains(id) else { throw failure("Capture is still recording or finalizing") }
        let folder = try bundleURL(id: id)
        try withCaptureMutationLock(id: id) {
            // Keep the row visible if filesystem removal fails.
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM feedback_captures WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure("Delete capture") }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure("Delete capture row") }
        }
    }
    /// Repair and claim interrupted bundles. The caller resumes its finalizer before publication.
    @discardableResult
    public func recover(audioDuration: @escaping (URL) throws -> Int64?, videoDuration: @escaping (URL) throws -> Int64?,
                        onError: (String, Error) -> Void = { _, _ in }) throws -> [FeedbackCaptureManifest] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var pending: [FeedbackCaptureManifest] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where folder.pathExtension == "capture" {
            let id = folder.deletingPathExtension().lastPathComponent
            do {
                guard !active.contains(id), validID(id) else { continue }
                let entries = try FileManager.default.contentsOfDirectory(at: bundleURL(id: id), includingPropertiesForKeys: nil)
                if entries.isEmpty {
                    try delete(id: id); continue
                }
                let journal = try mediaURL(id: id, path: "unfinished.json")
                let interrupted = FileManager.default.fileExists(atPath: journal.path)
                var m = try manifest(id: id)
                if !interrupted { try save(m); continue }
                let reconciled = reconcileMedia(m, audioDuration: audioDuration, videoDuration: videoDuration)
                m = reconciled.manifest
                if !reconciled.retainsContent {
                    for entry in entries {
                        let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular,
                              let size = attributes[.size] as? NSNumber,
                              FileManager.default.isReadableFile(atPath: entry.path) else {
                            throw failure("Interrupted capture contains uncertain contents")
                        }
                        if ["unfinished.json", "capture.json"].contains(entry.lastPathComponent) {
                            _ = try Data(contentsOf: entry)
                        } else if size.intValue != 0, try !isEmptyWAV(entry, size: size.intValue) {
                            throw failure("Interrupted capture contains unknown contents")
                        }
                    }
                    try delete(id: id); continue
                }
                m.state = .processing
                if !m.failures.contains(where: { $0.stage == "recording" && $0.message == "Recording interrupted" }) {
                    m.failures.append(.init(stage: "recording", message: "Recording interrupted"))
                }
                try checkpoint(m)
                try save(m)
                active.insert(id)
                pending.append(m)
            } catch { onError(id, error) }
        }
        return pending
    }
}

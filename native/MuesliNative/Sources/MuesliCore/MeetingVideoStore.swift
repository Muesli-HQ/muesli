import Foundation
import SQLite3

public final class MeetingVideoStore: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var activeRecordings: Set<String> = []
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL, root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open_v2(databaseURL.path, &db,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw failure()
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA foreign_keys=ON")

    }
    /// Called by DictationStore's schema migration, before tombstone purging.
    static func migrate(db: OpaquePointer?) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS meeting_video_clips(id TEXT PRIMARY KEY, kind TEXT NOT NULL, meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, captured REAL NOT NULL, body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS meeting_video_clips_time ON meeting_video_clips(kind,captured);
        CREATE INDEX IF NOT EXISTS meeting_video_clips_meeting ON meeting_video_clips(meeting_id);
        CREATE TABLE IF NOT EXISTS meeting_video_cleanup(id TEXT PRIMARY KEY, body TEXT NOT NULL);
        CREATE TRIGGER IF NOT EXISTS meeting_video_soft_delete AFTER UPDATE OF deleted_at ON meetings WHEN NEW.deleted_at IS NOT NULL BEGIN
            INSERT OR REPLACE INTO meeting_video_cleanup SELECT id, body FROM meeting_video_clips WHERE meeting_id=NEW.id;
            DELETE FROM meeting_video_clips WHERE meeting_id=NEW.id;
        END;
        CREATE TRIGGER IF NOT EXISTS meeting_video_hard_delete BEFORE DELETE ON meetings BEGIN
            INSERT OR REPLACE INTO meeting_video_cleanup SELECT id, body FROM meeting_video_clips WHERE meeting_id=OLD.id;
        END;
        INSERT OR REPLACE INTO meeting_video_cleanup SELECT v.id, v.body FROM meeting_video_clips v LEFT JOIN meetings m ON m.id=v.meeting_id WHERE m.id IS NULL OR m.deleted_at IS NOT NULL;
        DELETE FROM meeting_video_clips WHERE id IN (SELECT id FROM meeting_video_cleanup);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "MeetingVideoStore", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "MeetingVideoStore", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    public func url(for path: String) throws -> URL {
        let resolved = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), resolved.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            throw NSError(domain: "MeetingVideoStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid media path"])
        }
        return resolved
    }
    public func save(_ items: [VisualMemoryItem]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            for item in items {
                guard item.kind == .meetingVideo, item.meetingID != nil else {
                    throw NSError(domain: "MeetingVideoStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Video requires a meeting owner."])
                }
                _ = try url(for: item.path)
                let body = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meeting_video_clips SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM meetings WHERE id=? AND deleted_at IS NULL)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, item.id, -1, transient)
                sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, transient)
                if let id = item.meetingID { sqlite3_bind_int64(stmt, 3, id) } else { sqlite3_bind_null(stmt, 3) }
                sqlite3_bind_double(stmt, 4, item.capturedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 5, body, -1, transient)
                sqlite3_bind_int64(stmt, 6, item.meetingID!)
                guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw failure() }

            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func items() throws -> [VisualMemoryItem] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM meeting_video_clips ORDER BY captured DESC", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        var result: [VisualMemoryItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            let body = String(cString: sqlite3_column_text(stmt, 0))
            result.append(try JSONDecoder().decode(VisualMemoryItem.self, from: Data(body.utf8)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }
    /// Persist ownership before capture/finalization; active files are never recovered mid-write.
    public func beginRecording(_ item: VisualMemoryItem) throws {
        lock.lock(); defer { lock.unlock() }
        try JSONEncoder().encode(item).write(to: url(for: item.path + ".recording.json"), options: .atomic)
        activeRecordings.insert(item.id)
    }

    public func endRecording(_ item: VisualMemoryItem) {
        lock.lock(); defer { lock.unlock() }
        activeRecordings.remove(item.id)
    }

    public func hasMedia(meetingID: Int64) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if try items().contains(where: { $0.meetingID == meetingID }) { return true }
        return try journals().contains { $0.meetingID == meetingID }
    }

    private func journals() throws -> [VisualMemoryItem] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".pending.json") || $0.lastPathComponent.hasSuffix(".recording.json") }
            .compactMap { try? JSONDecoder().decode(VisualMemoryItem.self, from: Data(contentsOf: $0)) }
    }

    /// Journal completed recordings before attempting the database write. A busy DB
    /// leaves both the MP4 and its owner metadata available for recovery on next launch.
    public func persistCompleted(_ item: VisualMemoryItem) throws {
        lock.lock(); defer { lock.unlock() }
        let pending = try url(for: item.path + ".pending.json")
        try JSONEncoder().encode(item).write(to: pending, options: .atomic)
        try save([item])
        try FileManager.default.removeItem(at: pending)
        let recording = try url(for: item.path + ".recording.json")
        if FileManager.default.fileExists(atPath: recording.path) { try FileManager.default.removeItem(at: recording) }
    }

    public func maintain(recoverRecording: ((URL) -> Double?)? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var firstError: Error?
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasSuffix(".pending.json") || file.lastPathComponent.hasSuffix(".recording.json") {
            do {
                guard var item = try? JSONDecoder().decode(VisualMemoryItem.self, from: Data(contentsOf: file)) else { continue }
                if activeRecordings.contains(item.id) { continue }
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT 1 FROM meetings WHERE id=? AND deleted_at IS NULL AND NOT EXISTS(SELECT 1 FROM meeting_video_cleanup WHERE id=?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, item.meetingID ?? -1)
                sqlite3_bind_text(stmt, 2, item.id, -1, transient)
                let status = sqlite3_step(stmt)
                if status == SQLITE_ROW {
                    let video = try url(for: item.path)
                    guard FileManager.default.fileExists(atPath: video.path) else { continue }
                    if file.lastPathComponent.hasSuffix(".recording.json") {
                        guard let duration = recoverRecording?(video), duration.isFinite, duration > 0 else { continue }
                        item.duration = duration
                        item.bytes = (try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.int64Value ?? 0
                    }
                    try save([item])
                } else if status == SQLITE_DONE {
                    let video = try url(for: item.path)
                    if FileManager.default.fileExists(atPath: video.path) { try FileManager.default.removeItem(at: video) }
                } else { throw failure() }
                try FileManager.default.removeItem(at: file)
            } catch { if firstError == nil { firstError = error } }
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM meeting_video_cleanup", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        var pending: [VisualMemoryItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            pending.append(try JSONDecoder().decode(VisualMemoryItem.self, from: Data(String(cString: sqlite3_column_text(stmt, 0)).utf8)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        let retained = Set(try items().map(\.path))
        for item in pending {
            do {
                if !retained.contains(item.path) {
                    for path in [item.path, item.path + ".pending.json", item.path + ".recording.json"] {
                        let file = try url(for: path)
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                }
                var deletion: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM meeting_video_cleanup WHERE id=?", -1, &deletion, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(deletion) }
                sqlite3_bind_text(deletion, 1, item.id, -1, transient)
                guard sqlite3_step(deletion) == SQLITE_DONE else { throw failure() }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    public func delete(ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        // Include recovery journals whose database save has not succeeded yet.
        let pending = try journals()
        for item in pending where ids.contains(item.id) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meeting_video_cleanup VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, item.id, -1, transient)
            sqlite3_bind_text(statement, 2, String(decoding: try JSONEncoder().encode(item), as: UTF8.self), -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                for sql in ["INSERT OR REPLACE INTO meeting_video_cleanup SELECT id,body FROM meeting_video_clips WHERE id=?", "DELETE FROM meeting_video_clips WHERE id=?"] {
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, id, -1, transient)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try maintain()
    }
}

public extension MeetingVideoStore {
    /// Copy, commit, retire. One invalid legacy owner must not block later clips.
    func migrateLegacyVideos(from legacy: VisualMemoryStore) throws {
        var firstError: Error?
        for item in try legacy.items() where item.kind == .meetingVideo {
            var copied: URL?
            var committed = false
            do {
                let source = try legacy.url(for: item.path)
                let destination = try url(for: item.path)
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path) else {
                        throw NSError(domain: "MeetingVideoStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Existing video differs; original retained."])
                    }
                } else {
                    try FileManager.default.copyItem(at: source, to: destination)
                    copied = destination
                }
                try save([item]); committed = true
                try legacy.delete(ids: [item.id])
            } catch {
                if !committed, let copied { try? FileManager.default.removeItem(at: copied) }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

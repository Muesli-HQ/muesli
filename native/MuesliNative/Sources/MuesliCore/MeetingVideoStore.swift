import Foundation
import SQLite3

public final class MeetingVideoStore: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
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
        try execute("CREATE TABLE IF NOT EXISTS meeting_video_clips(id TEXT PRIMARY KEY, kind TEXT NOT NULL, meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, captured REAL NOT NULL, body TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS meeting_video_clips_time ON meeting_video_clips(kind,captured)")
        try execute("CREATE INDEX IF NOT EXISTS meeting_video_clips_meeting ON meeting_video_clips(meeting_id)")

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
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meeting_video_clips VALUES(?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, item.id, -1, transient)
                sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, transient)
                if let id = item.meetingID { sqlite3_bind_int64(stmt, 3, id) } else { sqlite3_bind_null(stmt, 3) }
                sqlite3_bind_double(stmt, 4, item.capturedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 5, body, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }

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
    /// Remove metadata first, then only unreferenced files. A crash can leave an orphan,
    /// never a surviving reference to deliberately forgotten meeting_video_clips.
    public func delete(ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        let before = try items()
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM meeting_video_clips WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, id, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        let retainedPaths = Set(before.filter { !ids.contains($0.id) }.map(\.path))
        for path in Set(before.filter { ids.contains($0.id) }.map(\.path)).subtracting(retainedPaths) {
            let file = try url(for: path)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}

public extension MeetingVideoStore {
    /// Copy first, commit the new owner, then retire legacy metadata/files. Retry safe.
    func migrateLegacyVideos(from legacy: VisualMemoryStore) throws {
        for item in try legacy.items() where item.kind == .meetingVideo {
            let source = try legacy.url(for: item.path)
            let destination = try url(for: item.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path) else {
                    throw NSError(domain: "MeetingVideoStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Existing video differs; original retained."])
                }
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            try save([item])
            try legacy.delete(ids: [item.id])
        }
    }
}

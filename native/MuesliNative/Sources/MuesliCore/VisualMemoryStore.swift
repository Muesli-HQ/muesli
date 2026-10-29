import Foundation
import CoreGraphics
import SQLite3

/// Device-local evidence. Deliberately separate from meeting CloudKit records.
public struct VisualMemoryItem: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case meetingVideo, moment }
    public var id: String
    public var kind: Kind
    public var meetingID: Int64?
    public var capturedAt: Date
    public var source: String
    public var bundleID: String
    public var text: String
    public var path: String
    public var duration: Double
    public var meetingOffset: Double
    public var frameIndex: Int?
    public var captureCompletedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var bytes: Int64

    public init(id: String = UUID().uuidString, kind: Kind, meetingID: Int64? = nil,
                capturedAt: Date = Date(), source: String, bundleID: String = "", text: String = "",
                path: String, duration: Double = 0, meetingOffset: Double = 0, frameIndex: Int? = nil, bytes: Int64 = 0,
                captureCompletedAt: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.id = id; self.kind = kind; self.meetingID = meetingID; self.capturedAt = capturedAt
        self.source = source; self.bundleID = bundleID; self.text = text; self.path = path
        self.captureCompletedAt = captureCompletedAt; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.duration = duration; self.meetingOffset = meetingOffset; self.frameIndex = frameIndex; self.bytes = bytes
    }
}

/// Serialized, bound SQLite writes; media bytes live alongside the catalog.
public final class VisualMemoryStore: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL, readOnly: Bool = false) throws {
        self.root = root
        if !readOnly { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &db,
                             (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw failure()
        }
        sqlite3_busy_timeout(db, 5_000)
        if readOnly { return }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS evidence(id TEXT PRIMARY KEY, kind TEXT NOT NULL, meeting_id INTEGER, captured REAL NOT NULL, body TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS evidence_time ON evidence(kind,captured)")
        try execute("CREATE INDEX IF NOT EXISTS evidence_meeting ON evidence(meeting_id)")

    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "VisualMemoryStore", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    public func url(for path: String) throws -> URL {
        let resolved = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), resolved.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            throw NSError(domain: "VisualMemoryStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid media path"])
        }
        return resolved
    }
    public func save(_ items: [VisualMemoryItem]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            for item in items {
                _ = try url(for: item.path)
                let body = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO evidence VALUES(?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
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
        guard sqlite3_prepare_v2(db, "SELECT body FROM evidence ORDER BY captured DESC", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
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
    /// never a surviving reference to deliberately forgotten evidence.
    public func delete(ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        let before = try items()
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM evidence WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
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

public struct ScreenRecordingPauseState: Equatable, Sendable {
    public var userPaused = false
    public var meetingPaused = false
    public var isPaused: Bool { userPaused || meetingPaused }
    public init() {}
}

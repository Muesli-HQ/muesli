import Foundation
import SQLite3
import MuesliCore

struct SavedTimeTurnerRecap: Codable, Sendable {
    let version: Int
    let dayStart: Date
    let dayEnd: Date
    let timeZone: String
    let generatedAt: Date
    let provider: String
    let model: String
    let insights: [TimeTurnerRecapInsight]
    let sources: [TimeTurnerRecapSource]

    var key: String { Self.key(dayStart: dayStart, timeZone: timeZone) }
    static func key(dayStart: Date, timeZone: String) -> String {
        "\(timeZone)|\(dayStart.timeIntervalSince1970)"
    }
}

/// Local-only, lazily migrated store in muesli.db. Call off the main actor.
/// The versioned body owns its source snapshots; no CloudKit or export projection.
final class TimeTurnerRecapStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(databaseURL: URL) throws {
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw Self.failure
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS time_turner_recaps (
                day_key TEXT PRIMARY KEY NOT NULL,
                day_start REAL NOT NULL,
                day_end REAL NOT NULL,
                time_zone TEXT NOT NULL,
                generated_at REAL NOT NULL,
                body TEXT NOT NULL
            )
            """)
    }
    deinit { sqlite3_close(db) }
    private static var failure: NSError {
        NSError(domain: "TimeTurnerRecapStore", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The daily recap could not be loaded or saved on this Mac."])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.failure }
    }
    private func statement(_ sql: String) throws -> OpaquePointer? {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK else { throw Self.failure }
        return result
    }
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        _ = sqlite3_bind_text(statement, index, value, -1, transient)
    }
    func save(_ recap: SavedTimeTurnerRecap) throws {
        guard recap.version == 1, recap.dayEnd > recap.dayStart else { throw Self.failure }
        let body = String(decoding: try JSONEncoder().encode(recap), as: UTF8.self)
        let s = try statement("INSERT OR REPLACE INTO time_turner_recaps(day_key,day_start,day_end,time_zone,generated_at,body) VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(s) }
        bind(recap.key, to: s, at: 1)
        sqlite3_bind_double(s, 2, recap.dayStart.timeIntervalSince1970)
        sqlite3_bind_double(s, 3, recap.dayEnd.timeIntervalSince1970)
        bind(recap.timeZone, to: s, at: 4)
        sqlite3_bind_double(s, 5, recap.generatedAt.timeIntervalSince1970)
        bind(body, to: s, at: 6)
        guard sqlite3_step(s) == SQLITE_DONE else { throw Self.failure }
    }
    /// Delete derived text, including stored OCR snapshots, without needing to open its day.
    func delete(captureIDs: Set<String>) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let s = try statement("""
                DELETE FROM time_turner_recaps WHERE EXISTS (
                    SELECT 1 FROM json_each(time_turner_recaps.body, '$.sources')
                    WHERE json_extract(value, '$.capture.id') = ?
                )
                """)
            defer { sqlite3_finalize(s) }
            for id in captureIDs {
                sqlite3_reset(s); sqlite3_clear_bindings(s); bind(id, to: s, at: 1)
                guard sqlite3_step(s) == SQLITE_DONE else { throw Self.failure }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func load(key: String) throws -> SavedTimeTurnerRecap? {
        let s = try statement("SELECT body FROM time_turner_recaps WHERE day_key=?")
        defer { sqlite3_finalize(s) }
        bind(key, to: s, at: 1)
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { throw Self.failure }
        let value = try JSONDecoder().decode(SavedTimeTurnerRecap.self, from: Data(String(cString: text).utf8))
        guard value.version == 1, value.key == key else { throw Self.failure }
        return value
    }
    func delete(key: String, generatedAt: Date? = nil) throws {
        let s = try statement("DELETE FROM time_turner_recaps WHERE day_key=?" + (generatedAt == nil ? "" : " AND generated_at=?"))
        defer { sqlite3_finalize(s) }
        bind(key, to: s, at: 1)
        if let generatedAt { sqlite3_bind_double(s, 2, generatedAt.timeIntervalSince1970) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw Self.failure }
    }
}

/// Serializes in-process source deletion and recap publication across the two local
/// databases. Capture tombstones persist until recap cleanup succeeds, so a restart
/// retries interrupted cleanup without relying on a user opening the recap.
enum TimeTurnerRetention {
    private static let lock = NSRecursiveLock()

    static func maintain(store: VisualMemoryStore, databaseURL: URL,
                         policy: VisualMemoryRetentionPolicy, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        // Expire source history even if a previous recap cleanup failed. Both success
        // and failure paths retry durable IDs, independently of media cleanup.
        do { try store.applyRetention(policy, now: now) }
        catch {
            try purgeDeletedSources(store: store, databaseURL: databaseURL)
            throw error
        }
        try purgeDeletedSources(store: store, databaseURL: databaseURL)
    }

    static func delete(ids: Set<String>, store: VisualMemoryStore, databaseURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        do { try store.delete(ids: ids) }
        catch {
            try purgeDeletedSources(store: store, databaseURL: databaseURL)
            throw error
        }
        try purgeDeletedSources(store: store, databaseURL: databaseURL)
    }

    private static func purgeDeletedSources(store: VisualMemoryStore, databaseURL: URL) throws {
        let ids = try store.pendingCaptureDeletions()
        guard !ids.isEmpty else { return }
        try TimeTurnerRecapStore(databaseURL: databaseURL).delete(captureIDs: ids)
        try store.acknowledgeCaptureDeletions(ids)
    }

    static func save(_ recap: SavedTimeTurnerRecap, root: URL?, databaseURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard try TimeTurnerRecap.sourcesAreCurrent(recap.sources, root: root, databaseURL: databaseURL) else {
            throw TimeTurnerRecapError.changedSources
        }
        try TimeTurnerRecapStore(databaseURL: databaseURL).save(recap)
    }
}

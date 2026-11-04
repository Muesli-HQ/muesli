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
    var includedInputs: [TimeTurnerRecapInput]? = nil

    var key: String { Self.key(dayStart: dayStart, timeZone: timeZone) }
    static func key(dayStart: Date, timeZone: String) -> String {
        "\(timeZone)|\(dayStart.timeIntervalSince1970)"
    }
}

/// Navigation carries the persisted identity and day bounds, never a date rebuilt
/// in the device's current timezone. No source content is cached in this target.
struct TimeTurnerRecapSelection: Equatable, Sendable {
    let key: String
    let interval: DateInterval
    let timeZone: String

    init(_ recap: SavedTimeTurnerRecap) {
        key = recap.key
        interval = DateInterval(start: recap.dayStart, end: recap.dayEnd)
        timeZone = recap.timeZone
    }

    // Date controls browse local calendar days; only presentation is converted.
    // The persisted key and original generation interval remain untouched.
    func browsingDay(in calendar: Calendar = .current) -> Date {
        var original = calendar
        original.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let parts = original.dateComponents([.era, .year, .month, .day], from: interval.start)
        return calendar.date(from: parts) ?? interval.start
    }

    var dayLabel: String {
        var style = Date.FormatStyle().day().month(.abbreviated).year()
        style.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        return interval.start.formatted(style)
    }
}

/// Local-only, lazily migrated store in muesli.db. Call off the main actor.
/// The versioned body owns its source snapshots; no CloudKit or export projection.
final class TimeTurnerRecapStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(databaseURL: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(databaseURL.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw Self.failure
        }
        sqlite3_busy_timeout(db, 5_000)
        if readOnly { return }
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
        try execute("BEGIN IMMEDIATE")
        do {
            try installHistoryInvalidation()
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
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
    /// Triggers invalidate dependent quotes in the source mutation transaction,
    /// including soft deletes and edits, without waiting for the Recap tab to open.
    private func installHistoryInvalidation() throws {
        let check = try statement("SELECT 1 FROM sqlite_master WHERE name='time_turner_recap_history_sources'")
        let projectionStatus = sqlite3_step(check)
        sqlite3_finalize(check)
        guard projectionStatus == SQLITE_ROW || projectionStatus == SQLITE_DONE else { throw Self.failure }
        let projectionExists = projectionStatus == SQLITE_ROW
        try execute("""
            CREATE TABLE IF NOT EXISTS time_turner_recap_history_sources (
                day_key TEXT NOT NULL, kind TEXT NOT NULL, source_id TEXT NOT NULL, parent_id TEXT NOT NULL,
                PRIMARY KEY(day_key,kind,source_id)
            );
            CREATE INDEX IF NOT EXISTS recap_history_source ON time_turner_recap_history_sources(kind,source_id,day_key);
            CREATE INDEX IF NOT EXISTS recap_history_parent ON time_turner_recap_history_sources(kind,parent_id,day_key);
            CREATE TRIGGER IF NOT EXISTS recap_history_projection_delete AFTER DELETE ON time_turner_recaps
            BEGIN DELETE FROM time_turner_recap_history_sources WHERE day_key=OLD.day_key; END;
            """)
        for event in ["INSERT", "UPDATE OF body"] {
            let name = event.hasPrefix("INSERT") ? "insert" : "update"
            try execute("""
                CREATE TRIGGER IF NOT EXISTS recap_history_projection_\(name) AFTER \(event) ON time_turner_recaps
                BEGIN
                    DELETE FROM time_turner_recap_history_sources WHERE day_key=NEW.day_key;
                    INSERT OR IGNORE INTO time_turner_recap_history_sources
                    SELECT NEW.day_key,json_extract(value,'$.history.kind'),json_extract(value,'$.history.id'),json_extract(value,'$.history.parentID')
                    FROM json_each(NEW.body,'$.sources') WHERE json_extract(value,'$.history.id') IS NOT NULL;
                END;
                """)
        }
        if !projectionExists {
            try execute("""
                INSERT OR IGNORE INTO time_turner_recap_history_sources
                SELECT r.day_key,json_extract(j.value,'$.history.kind'),json_extract(j.value,'$.history.id'),json_extract(j.value,'$.history.parentID')
                FROM time_turner_recaps r,json_each(r.body,'$.sources') j WHERE json_extract(j.value,'$.history.id') IS NOT NULL;
                """)
        }
        let rules: [(String, String, String, String, String?)] = [
            ("dictations", "dictations','commands", "source_id", "id", "raw_text,timestamp,source,target_app_name,target_app_bundle_id,deleted_at"),
            ("quill_conversations", "quill", "parent_id", "id", "deleted_at"),
            ("quill_conversation_turns", "quill", "source_id", "turn_id", "body"),
            ("cotypist_sessions", "cotypist", "parent_id", "id", "deleted_at"),
            ("cotypist_suggestions", "cotypist", "source_id", "id", "accepted_text,timestamp,session_id"),
            ("meeting_chat_sessions", "chat", "source_id", "id", "body,updated_at"),
            ("meeting_chat_turns", "chat", "parent_id", "session_id", nil)
        ]
        for (table, kinds, field, column, updates) in rules {
            let check = try statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?")
            bind(table, to: check, at: 1)
            let status = sqlite3_step(check); sqlite3_finalize(check)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Self.failure }
            if status == SQLITE_DONE { continue }
            for event in ["DELETE", "UPDATE"] {
                let operation = event == "UPDATE" ? "UPDATE" + (updates.map { " OF " + $0 } ?? "") : event
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS recap_history_\(table)_\(event)_v1 AFTER \(operation) ON \(table)
                    BEGIN
                        DELETE FROM time_turner_recaps WHERE day_key IN (
                            SELECT day_key FROM time_turner_recap_history_sources
                            WHERE kind IN ('\(kinds)') AND \(field)=CAST(OLD.\(column) AS TEXT)
                        );
                    END;
                    """)
            }
        }
    }

    /// Serialize main-database validation with publication. Source mutations must
    /// occur before validation or after INSERT, where the invalidation trigger sees it.
    func publish(_ recap: SavedTimeTurnerRecap, validate: () throws -> Bool) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            guard try validate() else { throw TimeTurnerRecapError.changedSources }
            try save(recap)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func save(_ recap: SavedTimeTurnerRecap) throws {
        try ContentPrivacy.shared.beginWrite()
        defer { ContentPrivacy.shared.endWrite() }
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
        guard try GlobalSearchIndex.stepSourceWrite(s) == SQLITE_DONE else { throw Self.failure }
    }
    /// Delete derived text, including stored OCR snapshots, without needing to open its day.
    func delete(captureIDs: Set<String>) throws {
        guard !captureIDs.isEmpty else { return }
        let ids = String(decoding: try JSONEncoder().encode(captureIDs.sorted()), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            let s = try statement("""
                DELETE FROM time_turner_recaps WHERE EXISTS (
                    SELECT 1 FROM json_each(time_turner_recaps.body, '$.sources')
                    WHERE json_extract(value, '$.capture.id') IN (SELECT value FROM json_each(?))
                )
                """)
            defer { sqlite3_finalize(s) }
            bind(ids, to: s, at: 1)
            guard try GlobalSearchIndex.stepSourceWrite(s) == SQLITE_DONE else { throw Self.failure }
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
        guard try GlobalSearchIndex.stepSourceWrite(s) == SQLITE_DONE else { throw Self.failure }
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
        try MeetingChatStore(databaseURL: databaseURL).invalidateHistoryCaptures(Array(ids))
        try store.acknowledgeCaptureDeletions(ids)
    }

    static func save(_ recap: SavedTimeTurnerRecap, root: URL?, databaseURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try TimeTurnerRecapStore(databaseURL: databaseURL).publish(recap) {
            try TimeTurnerRecap.sourcesAreCurrent(recap.sources, root: root, databaseURL: databaseURL)
        }
    }
}

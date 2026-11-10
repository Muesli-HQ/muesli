import Foundation
import CryptoKit
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
    public var appName: String?
    public var windowTitle: String?
    /// Present for whole-display captures; legacy/focused-window captures omit it.
    public var display: VisualMemoryDisplay?
    public var includedApps: [VisualMemoryApp]?
    public var path: String
    public var duration: Double
    public var meetingOffset: Double
    public var frameIndex: Int?
    public var captureCompletedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// Non-nil after screenshot expiry; OCR and identity remain searchable.
    public var mediaDeletedAt: Date?
    public var bytes: Int64

    public init(id: String = UUID().uuidString, kind: Kind, meetingID: Int64? = nil,
                capturedAt: Date = Date(), source: String, bundleID: String = "", text: String = "",
                path: String, duration: Double = 0, meetingOffset: Double = 0, frameIndex: Int? = nil, bytes: Int64 = 0,
                captureCompletedAt: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, appName: String? = nil, windowTitle: String? = nil,
                display: VisualMemoryDisplay? = nil, includedApps: [VisualMemoryApp]? = nil) {
        self.display = display; self.includedApps = includedApps
        self.appName = appName; self.windowTitle = windowTitle
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
    private var hasCaptureTable = false
    private var hasCaptureApps = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL, readOnly: Bool = false) throws {
        self.root = root
        if !readOnly { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &db,
                             (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw failure()
        }
        sqlite3_busy_timeout(db, 5_000)
        hasCaptureTable = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='time_turner_captures'") > 0
        hasCaptureApps = try scalar("SELECT count(*) FROM sqlite_master WHERE name='time_turner_capture_apps'") > 0
        if readOnly {
            if try scalar("SELECT count(*) FROM sqlite_master WHERE name='evidence_search'") == 0 {
                try execute("PRAGMA temp_store=MEMORY")
                try execute("CREATE VIRTUAL TABLE temp.evidence_search USING fts5(id UNINDEXED, text)")
                try execute("INSERT INTO temp.evidence_search SELECT id,json_extract(body,'$.source') || ' ' || json_extract(body,'$.text') FROM evidence")
            }
            return
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS evidence(id TEXT PRIMARY KEY, kind TEXT NOT NULL, meeting_id INTEGER, captured REAL NOT NULL, body TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS evidence_time ON evidence(kind,captured)")
        try execute("CREATE INDEX IF NOT EXISTS evidence_meeting ON evidence(meeting_id)")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS evidence_search USING fts5(id UNINDEXED, text)")
        try migrateCaptureTable()
        try migrateRetention()
        try migrateSearchRowIDs()
        try migrateDisplays()
        hasCaptureApps = true
        try execute("CREATE TABLE IF NOT EXISTS time_turner_lifecycle(id INTEGER PRIMARY KEY CHECK(id=1), capture_ready_at REAL NOT NULL)")
        // Existing captures prove capture was ready before this version was installed.
        try execute("INSERT OR IGNORE INTO time_turner_lifecycle SELECT 1,captured FROM evidence WHERE kind='moment' ORDER BY captured LIMIT 1")

    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "VisualMemoryStore", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func scalar(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Set once, when capture is enabled and permissions are ready. Pausing and
    /// retention do not restart this clock; this contains no captured content.
    @discardableResult public func markCaptureReady(at date: Date) throws -> Date {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO time_turner_lifecycle VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return try captureReadyAt() ?? date
    }

    public func captureReadyAt() throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        let installed = try scalar("SELECT count(*) FROM sqlite_master WHERE name='time_turner_lifecycle'") > 0
        let sql = installed ? "SELECT capture_ready_at FROM time_turner_lifecycle WHERE id=1"
            : "SELECT min(captured) FROM evidence WHERE kind='moment'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// Indexed existence check. Retired screenshots still count as retained history.
    public func hasMoments(from: Date, until: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM evidence WHERE kind='moment' AND captured>=? AND captured<? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure() }
        return result == SQLITE_ROW
    }

    /// Versioned, transactional projection for SQL consumers. Evidence remains the
    /// compatibility record; triggers keep typed columns in sync even for older writers.
    private func migrateCaptureTable() throws {
        let version = try scalar("PRAGMA user_version")
        guard version <= 4 else { throw NSError(domain: "VisualMemoryStore", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Screen history was created by a newer Muesli version."]) }
        guard version < 1 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            // Another connection may have upgraded while BEGIN waited for its lock.
            if try scalar("PRAGMA user_version") >= 1 {
                try execute("COMMIT"); hasCaptureTable = true; return
            }
            try execute("DROP VIEW IF EXISTS time_turner_captures")
            try execute("""
                CREATE TABLE time_turner_captures (
                    id TEXT PRIMARY KEY NOT NULL,
                    captured_at_unix REAL NOT NULL,
                    captured_at_utc TEXT NOT NULL,
                    capture_completed_at_unix REAL,
                    source TEXT NOT NULL,
                    bundle_id TEXT NOT NULL COLLATE NOCASE,
                    app_name TEXT NOT NULL COLLATE NOCASE,
                    window_title TEXT,
                    ocr_text TEXT NOT NULL,
                    media_relative_path TEXT NOT NULL,
                    archive_frame_index INTEGER,
                    pixel_width INTEGER,
                    pixel_height INTEGER,
                    media_bytes INTEGER NOT NULL
                );
                CREATE INDEX captures_time ON time_turner_captures(captured_at_unix DESC,id);
                CREATE INDEX captures_bundle_time ON time_turner_captures(bundle_id,captured_at_unix DESC,id);
                CREATE INDEX captures_app_time ON time_turner_captures(app_name,captured_at_unix DESC,id);
                """)
            let projection = """
                SELECT id, captured, strftime('%Y-%m-%dT%H:%M:%fZ', captured, 'unixepoch'),
                    json_extract(body,'$.captureCompletedAt') + 978307200,
                    json_extract(body,'$.source'), coalesce(json_extract(body,'$.bundleID'),''),
                    coalesce(json_extract(body,'$.appName'), CASE WHEN instr(json_extract(body,'$.source'),' · ')>0
                        THEN substr(json_extract(body,'$.source'),1,instr(json_extract(body,'$.source'),' · ')-1)
                        ELSE json_extract(body,'$.source') END),
                    json_extract(body,'$.windowTitle'), json_extract(body,'$.text'),
                    json_extract(body,'$.path'), json_extract(body,'$.frameIndex'),
                    json_extract(body,'$.pixelWidth'), json_extract(body,'$.pixelHeight'), json_extract(body,'$.bytes')
                FROM evidence WHERE kind='moment'
                """
            try execute("INSERT INTO time_turner_captures " + projection)
            for event in ["INSERT", "UPDATE"] {
                let oldIDCleanup = event == "UPDATE" ? "DELETE FROM time_turner_captures WHERE id=OLD.id;" : ""
                try execute("""
                    CREATE TRIGGER captures_after_\(event.lowercased()) AFTER \(event) ON evidence BEGIN
                        \(oldIDCleanup)
                        DELETE FROM time_turner_captures WHERE id=NEW.id;
                        INSERT INTO time_turner_captures (id,captured_at_unix,captured_at_utc,capture_completed_at_unix,source,bundle_id,app_name,window_title,ocr_text,media_relative_path,archive_frame_index,pixel_width,pixel_height,media_bytes) \(projection) AND id=NEW.id;
                    END;
                    """)
            }
            try execute("""
                CREATE TRIGGER captures_after_delete AFTER DELETE ON evidence BEGIN
                    DELETE FROM time_turner_captures WHERE id=OLD.id;
                END;
                DELETE FROM evidence_search;
                INSERT INTO evidence_search SELECT id,json_extract(body,'$.source') || ' ' || json_extract(body,'$.text') FROM evidence;
                PRAGMA user_version=1;
                COMMIT;
                """)
            hasCaptureTable = true
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func migrateRetention() throws {
        guard try scalar("PRAGMA user_version") < 2 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if try scalar("PRAGMA user_version") < 2 {
                let triggers = try strings("SELECT sql FROM sqlite_master WHERE type='trigger' AND name IN ('captures_after_insert','captures_after_update')")
                for name in ["captures_after_insert", "captures_after_update"] { try execute("DROP TRIGGER IF EXISTS " + name) }
                for trigger in triggers {
                    let columns = "(id,captured_at_unix,captured_at_utc,capture_completed_at_unix,source,bundle_id,app_name,window_title,ocr_text,media_relative_path,archive_frame_index,pixel_width,pixel_height,media_bytes)"
                    let updated = trigger.replacingOccurrences(of: "INSERT INTO time_turner_captures SELECT", with: "INSERT INTO time_turner_captures " + columns + " SELECT")
                    try execute(updated)
                }
                try execute("""
                    ALTER TABLE time_turner_captures ADD COLUMN media_deleted_at_unix REAL;
                    CREATE TRIGGER capture_retention_insert AFTER INSERT ON time_turner_captures BEGIN
                        UPDATE time_turner_captures SET media_deleted_at_unix =
                            (SELECT json_extract(body,'$.mediaDeletedAt') + 978307200 FROM evidence WHERE id=NEW.id)
                            WHERE id=NEW.id;
                    END;
                    CREATE TABLE pending_capture_deletions(id TEXT PRIMARY KEY NOT NULL);
                    CREATE TABLE pending_media_deletions(path TEXT PRIMARY KEY NOT NULL);
                    PRAGMA user_version=2;
                    """)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Preserve evidence rowids on updates so FTS deletion is an indexed lookup.
    private func migrateSearchRowIDs() throws {
        guard try scalar("PRAGMA user_version") < 3 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if try scalar("PRAGMA user_version") < 3 {
                try execute("""
                    DELETE FROM evidence_search;
                    INSERT INTO evidence_search(rowid,id,text)
                        SELECT rowid,id,json_extract(body,'$.source') || ' ' || json_extract(body,'$.text') FROM evidence;
                    PRAGMA user_version=3;
                    """)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Additive projection: each screenshot owns one OCR body and zero or more apps.
    /// App rows survive screenshot expiry and disappear with their observation.
    private func migrateDisplays() throws {
        guard try scalar("PRAGMA user_version") < 4 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if try scalar("PRAGMA user_version") < 4 {
                try execute("""
                    ALTER TABLE time_turner_captures ADD COLUMN display_uuid TEXT;
                    ALTER TABLE time_turner_captures ADD COLUMN display_name TEXT;
                    ALTER TABLE time_turner_captures ADD COLUMN display_id INTEGER;
                    CREATE TABLE time_turner_capture_apps (
                        capture_id TEXT NOT NULL, bundle_id TEXT NOT NULL COLLATE NOCASE,
                        app_name TEXT NOT NULL COLLATE NOCASE,
                        PRIMARY KEY(capture_id,bundle_id)
                    );
                    CREATE INDEX capture_apps_bundle ON time_turner_capture_apps(bundle_id,capture_id);
                    CREATE INDEX capture_apps_name ON time_turner_capture_apps(app_name,capture_id);
                    CREATE TRIGGER capture_apps_delete AFTER DELETE ON time_turner_captures BEGIN
                        DELETE FROM time_turner_capture_apps WHERE capture_id=OLD.id;
                    END;
                    """)
                let projection = """
                    UPDATE time_turner_captures SET
                        display_uuid=json_extract(e.body,'$.display.uuid'),
                        display_name=json_extract(e.body,'$.display.name'),
                        display_id=json_extract(e.body,'$.display.id'),
                        app_name=CASE WHEN json_type(e.body,'$.display')='object' THEN '' ELSE app_name END
                    FROM evidence e WHERE e.id=time_turner_captures.id
                    """
                let apps = """
                    SELECT e.id,json_extract(a.value,'$.bundleID'),json_extract(a.value,'$.name')
                    FROM evidence e, json_each(e.body,'$.includedApps') a WHERE e.kind='moment'
                    """
                let focused = """
                    SELECT id,bundle_id,app_name FROM time_turner_captures WHERE (bundle_id!='' OR app_name!='')
                    """
                try execute(projection)
                try execute("INSERT OR IGNORE INTO time_turner_capture_apps " + apps)
                try execute("INSERT OR IGNORE INTO time_turner_capture_apps " + focused)
                try execute("""
                    CREATE TRIGGER capture_display_insert AFTER INSERT ON time_turner_captures BEGIN
                        \(projection) AND e.id=NEW.id;
                        INSERT OR IGNORE INTO time_turner_capture_apps \(apps) AND e.id=NEW.id;
                        INSERT OR IGNORE INTO time_turner_capture_apps \(focused) AND id=NEW.id;
                    END;
                    PRAGMA user_version=4;
                    """)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func bindAndRun(_ sql: String, value: String) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, value, -1, transient)
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    private func strings(_ sql: String) throws -> [String] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(s) }
        var result: [String] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            result.append(String(cString: sqlite3_column_text(s, 0)))
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    /// Durable IDs allow recap cleanup to recover after a crash between the two databases.
    public func pendingCaptureDeletions() throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(try strings("SELECT id FROM pending_capture_deletions"))
    }
    public func acknowledgeCaptureDeletions(_ ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        for id in ids { try bindAndRun("DELETE FROM pending_capture_deletions WHERE id=?", value: id) }
    }
    public func finishMediaDeletions() throws {
        lock.lock(); defer { lock.unlock() }
        let pending = try strings("SELECT path FROM pending_media_deletions")
        guard !pending.isEmpty else { return }
        let active = Set(try strings("""
            SELECT media_relative_path FROM time_turner_captures WHERE media_deleted_at_unix IS NULL
            UNION SELECT json_extract(body,'$.path') FROM evidence
                WHERE kind!='moment' AND json_extract(body,'$.mediaDeletedAt') IS NULL
            """))
        for path in pending {
            guard !active.contains(path) else { continue }
            let file = try url(for: path)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try bindAndRun("DELETE FROM pending_media_deletions WHERE path=?", value: path)
        }
    }

    /// Applies wall-clock limits regardless of whether capture is enabled or paused.
    /// An archive is evicted as a unit; OCR rows keep their individual timestamps.
    public func applyRetention(_ policy: VisualMemoryRetentionPolicy, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        // Read only retention metadata, never materialize OCR bodies for maintenance.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,captured_at_unix,media_relative_path,media_bytes,media_deleted_at_unix FROM time_turner_captures", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var moments: [VisualMemoryItem] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var item = VisualMemoryItem(id: String(cString: sqlite3_column_text(statement, 0)), kind: .moment,
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), source: "",
                path: String(cString: sqlite3_column_text(statement, 2)), bytes: sqlite3_column_int64(statement, 3))
            if sqlite3_column_type(statement, 4) != SQLITE_NULL {
                item.mediaDeletedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            }
            moments.append(item)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        sqlite3_reset(statement)
        let expired = Set(moments.filter { item in policy.historyDays.map { days in
            item.capturedAt.addingTimeInterval(Double(days) * 86400) <= now
        } ?? false }.map(\.id))
        // Retire shared media before deleting expired observations. Otherwise the older
        // frame becomes invisible to subsequent age checks while remaining in the archive.
        let expiredPaths = Set(moments.filter { expired.contains($0.id) }.map(\.path))
        let remaining = moments.filter { $0.kind == .moment && $0.mediaDeletedAt == nil }
        let groups = Dictionary(grouping: remaining, by: \.path).values.sorted {
            ($0.map(\.capturedAt).min() ?? .distantPast) < ($1.map(\.capturedAt).min() ?? .distantPast)
        }
        var total = groups.reduce(Int64(0)) { $0 + ($1.first?.bytes ?? 0) }
        for group in groups {
            guard let first = group.first else { continue }
            let aged = expiredPaths.contains(first.path) || group.contains { item in
                policy.screenshotDays.map { item.capturedAt.addingTimeInterval(Double($0) * 86400) <= now } ?? false
            }
            guard aged || total > policy.mediaBudgetBytes else { continue }
            // The queue and JSON/projection update commit together. OCR and FTS stay intact.
            try execute("BEGIN IMMEDIATE")
            do {
                try bindAndRun("INSERT OR IGNORE INTO pending_media_deletions VALUES(?)", value: first.path)
                var update: OpaquePointer?
                guard sqlite3_prepare_v2(db, "UPDATE evidence SET body=json_set(body,'$.mediaDeletedAt',?,'$.bytes',0) WHERE id=?", -1, &update, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(update) }
                for item in group {
                    sqlite3_reset(update)
                    sqlite3_bind_double(update, 1, now.timeIntervalSinceReferenceDate)
                    sqlite3_bind_text(update, 2, item.id, -1, transient)
                    guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
                }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            total -= first.bytes
        }
        if !expired.isEmpty { try delete(ids: expired) }
        try finishMediaDeletions()
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
                guard sqlite3_prepare_v2(db, "INSERT INTO evidence VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,meeting_id=excluded.meeting_id,captured=excluded.captured,body=excluded.body", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, item.id, -1, transient)
                sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, transient)
                if let id = item.meetingID { sqlite3_bind_int64(stmt, 3, id) } else { sqlite3_bind_null(stmt, 3) }
                sqlite3_bind_double(stmt, 4, item.capturedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 5, body, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
                try removeSearch(item.id)
                var search: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO evidence_search(rowid,id,text) SELECT rowid,?,? FROM evidence WHERE id=?", -1, &search, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(search) }
                sqlite3_bind_text(search, 1, item.id, -1, transient)
                sqlite3_bind_text(search, 2, item.source + " " + item.text, -1, transient)
                sqlite3_bind_text(search, 3, item.id, -1, transient)
                guard sqlite3_step(search) == SQLITE_DONE else { throw failure() }
            }
            if let first = items.filter({ $0.kind == .moment }).map(\.capturedAt).min() {
                try markCaptureReady(at: first)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    /// Do not let background compaction restore media or records removed by retention.
    public func replaceMedia(_ replacements: [VisualMemoryItem], ifUnchanged expected: [VisualMemoryItem]) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard replacements.count == expected.count else { return false }
        for original in expected {
            guard let current = try moment(id: original.id), current == original, current.mediaDeletedAt == nil else { return false }
        }
        try save(replacements)
        return true
    }

    private func removeSearch(_ id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM evidence_search WHERE rowid=(SELECT rowid FROM evidence WHERE id=?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
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
    /// Only decodes observations in the requested half-open day/range, including OCR-only history.
    public func moments(from: Date, until: Date) throws -> [VisualMemoryItem] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM evidence WHERE kind='moment' AND captured>=? AND captured<? ORDER BY captured,id", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        return try decodeItems(statement)
    }

    /// Content identity excludes media paths, so compression is not new evidence.
    public func recapRevision(from: Date, until: Date) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = "SELECT id,captured,json_extract(body,'$.source'),json_extract(body,'$.bundleID'),json_extract(body,'$.text') FROM evidence WHERE kind='moment' AND captured>=? AND captured<? ORDER BY captured,id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        var digest = SHA256()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let fields = (0..<5).map { column in
                sqlite3_column_text(statement, Int32(column)).map { String(cString: $0) } ?? ""
            }
            digest.update(data: try JSONEncoder().encode(fields))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public struct Summary: Sendable {
        public let revision: String
        public let apps: [String: String]
        public let mediaBytes: Int64
        public let averageImageBytes: Int64?
    }

    /// No OCR decoding or file I/O. Unchanged maintenance passes reuse the prior aggregates.
    private var cachedSummary: Summary?
    public func summary() throws -> Summary {
        lock.lock(); defer { lock.unlock() }
        let revision = "\(sqlite3_total_changes64(db)):\(try scalar("PRAGMA data_version"))"
        if let cachedSummary, cachedSummary.revision == revision { return cachedSummary }
        var apps: [String: String] = [:]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, hasCaptureApps ? "SELECT bundle_id,MAX(app_name) FROM time_turner_capture_apps WHERE bundle_id!='' GROUP BY bundle_id" : "SELECT bundle_id,MAX(COALESCE(app_name,bundle_id)) FROM time_turner_captures WHERE bundle_id!='' GROUP BY bundle_id", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            apps[String(cString: sqlite3_column_text(statement, 0))] = String(cString: sqlite3_column_text(statement, 1))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        let bytes = try scalar("SELECT COALESCE(SUM(bytes),0) FROM (SELECT MAX(media_bytes) bytes FROM time_turner_captures WHERE media_deleted_at_unix IS NULL GROUP BY media_relative_path)")
        let average = try scalar("SELECT COALESCE(AVG(media_bytes),-1) FROM time_turner_captures WHERE media_deleted_at_unix IS NULL AND archive_frame_index IS NULL")
        let value = Summary(revision: revision, apps: apps, mediaBytes: Int64(bytes), averageImageBytes: average < 0 ? nil : Int64(average))
        cachedSummary = value
        return value
    }

    /// Decode only one eligible archive batch, never the entire OCR history.
    public func compactionBatch(now: Date = Date(), excludingIDs: Set<String> = []) throws -> [VisualMemoryItem] {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        WITH eligible AS (
            SELECT * FROM time_turner_captures WHERE media_deleted_at_unix IS NULL
              AND archive_frame_index IS NULL AND captured_at_unix<? AND pixel_width>0 AND pixel_height>0
              AND id NOT IN (SELECT value FROM json_each(?))
        ), chosen AS (
            SELECT source,pixel_width,pixel_height FROM eligible
            GROUP BY source,pixel_width,pixel_height HAVING COUNT(*)>=25
            ORDER BY MIN(captured_at_unix),MIN(id) LIMIT 1
        )
        SELECT e.body FROM eligible c JOIN chosen g USING(source,pixel_width,pixel_height)
        JOIN evidence e ON e.id=c.id ORDER BY c.captured_at_unix,c.id LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-600).timeIntervalSince1970)
        let excluded = String(decoding: try JSONEncoder().encode(Array(excludingIDs)), as: UTF8.self)
        sqlite3_bind_text(statement, 2, excluded, -1, transient)
        return try decodeItems(statement)
    }

    public func momentIDs(mediaPath: String) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM time_turner_captures WHERE media_relative_path=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, mediaPath, -1, transient)
        var ids = Set<String>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { ids.insert(String(cString: sqlite3_column_text(statement, 0))); status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure() }
        return ids
    }

    private func decodeItems(_ statement: OpaquePointer?) throws -> [VisualMemoryItem] {
        var result: [VisualMemoryItem] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(try JSONDecoder().decode(VisualMemoryItem.self, from: Data(String(cString: sqlite3_column_text(statement, 0)).utf8)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    public func moment(id: String) throws -> VisualMemoryItem? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM evidence WHERE kind='moment' AND id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return try JSONDecoder().decode(VisualMemoryItem.self, from: Data(String(cString: sqlite3_column_text(stmt, 0)).utf8))
    }

    /// Literal word/phrase search with a half-open UTC time range and bounded results.
    /// Newest first by default; chronological history uses ascending time. IDs break ties
    /// in ascending order in both modes. A cursor must use the same order and filters.
    /// This does not expose SQL or FTS expression syntax to callers.
    public func searchMoments(text: String = "", from: Date = .distantPast,
                              until: Date = .distantFuture, app: String? = nil, limit: Int = 100, after: VisualMemoryCursor? = nil, chronological: Bool = false, includeText: Bool = true) throws -> [VisualMemoryItem] {
        lock.lock(); defer { lock.unlock() }
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchClause = phrase.isEmpty ? "" : " AND id IN (SELECT id FROM evidence_search WHERE evidence_search MATCH ?)"
        let legacyAppClause = app == nil ? "" : " AND (lower(json_extract(body,'$.bundleID'))=lower(?) OR lower(CASE WHEN instr(json_extract(body,'$.source'),' · ')>0 THEN substr(json_extract(body,'$.source'),1,instr(json_extract(body,'$.source'),' · ')-1) ELSE json_extract(body,'$.source') END)=lower(?))"
        let appClause = app == nil ? "" : (hasCaptureApps
            ? " AND id IN (SELECT capture_id FROM time_turner_capture_apps WHERE bundle_id=? COLLATE NOCASE OR app_name=? COLLATE NOCASE)"
            : hasCaptureTable
            ? " AND id IN (SELECT id FROM time_turner_captures WHERE bundle_id=? COLLATE NOCASE OR app_name=? COLLATE NOCASE)"
            : legacyAppClause)
        let comparison = chronological ? ">" : "<"
        let direction = chronological ? "ASC" : "DESC"
        let cursorClause = after == nil ? "" : " AND (captured\(comparison)? OR (captured=? AND id>?))"
        var stmt: OpaquePointer?
        let projection = includeText ? "body" : "json_set(body,'$.text','')"
        let sql = "SELECT \(projection) FROM evidence WHERE kind='moment' AND captured>=? AND captured<?" + searchClause + appClause + cursorClause + " ORDER BY captured \(direction),id LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
        var slot: Int32 = 3
        if !phrase.isEmpty {
            let literal = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sqlite3_bind_text(stmt, slot, literal, -1, transient); slot += 1
        }
        if let app {
            sqlite3_bind_text(stmt, slot, app, -1, transient); slot += 1
            sqlite3_bind_text(stmt, slot, app, -1, transient); slot += 1
        }
        if let after {
            sqlite3_bind_double(stmt, slot, after.capturedAtUnix); slot += 1
            sqlite3_bind_double(stmt, slot, after.capturedAtUnix); slot += 1
            sqlite3_bind_text(stmt, slot, after.id, -1, transient); slot += 1
        }
        sqlite3_bind_int(stmt, slot, Int32(max(1, min(1001, limit))))
        var result: [VisualMemoryItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append(try JSONDecoder().decode(VisualMemoryItem.self,
                from: Data(String(cString: sqlite3_column_text(stmt, 0)).utf8)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    /// Remove metadata first, then only unreferenced files. A crash can leave an orphan,
    /// never a surviving reference to deliberately forgotten evidence.
    public func delete(ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try bindAndRun("INSERT OR IGNORE INTO pending_capture_deletions SELECT id FROM evidence WHERE id=? AND kind='moment'", value: id)
                try bindAndRun("INSERT OR IGNORE INTO pending_media_deletions SELECT json_extract(body,'$.path') FROM evidence WHERE id=?", value: id)
                try removeSearch(id)
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM evidence WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, id, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try finishMediaDeletions()
    }
}

public struct ScreenRecordingPauseState: Equatable, Sendable {
    public var userPaused = false
    public var meetingPaused = false
    public var isPaused: Bool { userPaused || meetingPaused }
    public init() {}
}

/// Match the entire focused window, not a same-width toolbar or overlay.
public enum VisualMemoryWindowMatch {
    public static func matches(candidate: CGRect, focused: CGRect, layer: Int) -> Bool {
        layer == 0 && candidate.width >= 100 && candidate.height >= 100
            && abs(candidate.minX - focused.minX) < 3
            && abs(candidate.minY - focused.minY) < 3
            && abs(candidate.width - focused.width) < 3
            && abs(candidate.height - focused.height) < 3
    }
}

/// Wall-clock navigation is independent of app groups and archive frame offsets.
public enum VisualMemoryDayTimeline {
    public static func moments(_ items: [VisualMemoryItem], on day: Date, calendar: Calendar = .current) -> [VisualMemoryItem] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return items.filter { $0.kind == .moment && $0.capturedAt >= interval.start && $0.capturedAt < interval.end }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt }
    }

    /// Fit the track to saved evidence, never to future hours. A single sample gets
    /// one second of preceding space so the track remains finite without inventing future coverage.
    public static func captureInterval(in ordered: [VisualMemoryItem]) -> DateInterval? {
        guard let first = ordered.first?.capturedAt, let last = ordered.last?.capturedAt else { return nil }
        return DateInterval(start: min(first, last.addingTimeInterval(-1)), end: last)
    }

    /// Nearest sample; ties choose the earlier capture. Never crosses a day boundary.
    public static func nearestIndex(in ordered: [VisualMemoryItem], to time: Date) -> Int? {
        guard !ordered.isEmpty else { return nil }
        var low = 0, high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if ordered[mid].capturedAt < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == ordered.count { return ordered.count - 1 }
        return time.timeIntervalSince(ordered[low - 1].capturedAt) <= ordered[low].capturedAt.timeIntervalSince(time) ? low - 1 : low
    }
}

/// Compresses empty time on the browse axis without changing evidence timestamps.
public struct VisualMemoryScrubScale {
    private let dates: [Date]
    private let positions: [Double]
    public let compressesGaps: Bool
    public init(dates: [Date]) {
        self.dates = dates.sorted()
        var offsets = [Double]()
        for (index, date) in self.dates.enumerated() {
            offsets.append(index == 0 ? 0 : offsets[index - 1] + min(120, max(1, date.timeIntervalSince(self.dates[index - 1]))))
        }
        positions = offsets
        compressesGaps = zip(self.dates, self.dates.dropFirst()).contains { $1.timeIntervalSince($0) > 120 }
    }
    private func lowerBound<T: Comparable>(_ values: [T], _ target: T) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if values[middle] < target { low = middle + 1 } else { high = middle }
        }
        return low
    }
    public func fraction(for date: Date) -> Double {
        guard let first = dates.first, let last = dates.last, let total = positions.last, total > 0 else { return 0 }
        if date <= first { return 0 }; if date >= last { return 1 }
        let upper = lowerBound(dates, date)
        let lower = upper - 1
        let interval = dates[upper].timeIntervalSince(dates[lower])
        let local = interval > 0 ? date.timeIntervalSince(dates[lower]) / interval : 0
        return (positions[lower] + local * (positions[upper] - positions[lower])) / total
    }
    public func date(at fraction: Double) -> Date? {
        guard let first = dates.first, let total = positions.last, total > 0 else { return dates.first }
        let position = min(1, max(0, fraction)) * total
        let upper = lowerBound(positions, position)
        guard upper > 0 else { return first }
        let lower = upper - 1
        let local = (position - positions[lower]) / (positions[upper] - positions[lower])
        return dates[lower].addingTimeInterval(local * dates[upper].timeIntervalSince(dates[lower]))
    }
}

/// Stable keyset position; does not depend on the referenced capture still existing.
public struct VisualMemoryCursor: Codable, Sendable {
    public let capturedAtUnix: Double
    public let id: String
    public init(capturedAtUnix: Double, id: String) {
        self.capturedAtUnix = capturedAtUnix; self.id = id
    }
}

/// Capture age is measured in elapsed 24-hour days, not days of active recording.
public struct VisualMemoryRetentionPolicy: Equatable, Sendable {
    public let screenshotDays: Int?
    public let historyDays: Int?
    public let mediaBudgetBytes: Int64
    public init(screenshotDays: Int? = 7, historyDays: Int? = 30, mediaBudgetBytes: Int64 = 10_000_000_000) {
        self.screenshotDays = screenshotDays.map { max(1, $0) }
        self.historyDays = historyDays.map { max(1, $0) }
        self.mediaBudgetBytes = max(0, mediaBudgetBytes)
    }
}

/// Choose the oldest encodable group; a short-lived window must not starve others.
public enum VisualMemoryCompaction {
    private struct Key: Hashable {
        let source: String
        let width: Int
        let height: Int
    }
    public static func batch(from items: [VisualMemoryItem], now: Date = Date()) -> [VisualMemoryItem] {
        let candidates = items.filter {
            $0.kind == .moment && $0.mediaDeletedAt == nil && $0.frameIndex == nil &&
            $0.capturedAt < now.addingTimeInterval(-600) && ($0.pixelWidth ?? 0) > 0 && ($0.pixelHeight ?? 0) > 0
        }.sorted { ($0.capturedAt, $0.id) < ($1.capturedAt, $1.id) }
        let groups = Dictionary(grouping: candidates) {
            Key(source: $0.source, width: $0.pixelWidth!, height: $0.pixelHeight!)
        }
        return groups.values.filter { $0.count >= 25 }
            .min { ($0[0].capturedAt, $0[0].id) < ($1[0].capturedAt, $1[0].id) }
            .map { Array($0.prefix(100)) } ?? []
    }
}

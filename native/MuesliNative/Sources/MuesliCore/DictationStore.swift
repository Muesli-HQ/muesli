import Foundation
import SQLite3

public enum DictationStoreError: Error, LocalizedError {
    case dictationNotFound(id: Int64)
    case meetingNotFound(id: Int64)

    public var errorDescription: String? {
        switch self {
        case .dictationNotFound(let id):
            return "Dictation \(id) no longer exists."
        case .meetingNotFound(let id):
            return "Meeting \(id) no longer exists."
        }
    }
}

public struct MeetingThreadNavigation: Equatable, Sendable {
    public let predecessorID: Int64?
    public let successorIDs: [Int64]
    public let count: Int
}

public final class DictationStore {
    public static let defaultTombstoneRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let iso8601FormatterLock = NSLock()

    private let databaseURL: URL
    private static let dictationColumns = """
    d.id, d.timestamp, d.duration_seconds, d.raw_text, d.app_context, d.word_count, d.source,
    t.id, t.final_status, t.final_message, t.trace_json, t.created_at
    """
    private static let meetingColumns = """
    id, title, start_time, duration_seconds, raw_transcript, formatted_notes, word_count, folder_id, calendar_event_id, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source, follow_up_to_id, follow_up_to_record_name
    """

    public init() {
        self.databaseURL = MuesliPaths.defaultDatabaseURL()
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public var resolvedDatabaseURL: URL {
        databaseURL
    }

    public var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    public func migrateIfNeeded() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS dictations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            duration_seconds REAL,
            raw_text TEXT,
            app_context TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'dictation',
            started_at TEXT,
            ended_at TEXT,
            updated_at REAL NOT NULL DEFAULT 0,
            deleted_at REAL,
            cloud_record_name TEXT,
            cloud_change_tag TEXT,
            last_synced_at REAL,
            sync_dirty INTEGER NOT NULL DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_dictations_timestamp ON dictations(timestamp DESC);

        CREATE TABLE IF NOT EXISTS computer_use_traces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            dictation_id INTEGER NOT NULL UNIQUE REFERENCES dictations(id) ON DELETE CASCADE,
            final_status TEXT NOT NULL,
            final_message TEXT NOT NULL,
            trace_json TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_computer_use_traces_dictation_id ON computer_use_traces(dictation_id);

        CREATE TABLE IF NOT EXISTS meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            saved_recording_path TEXT,
            meeting_status TEXT NOT NULL DEFAULT 'completed',
            manual_notes TEXT NOT NULL DEFAULT '',
            word_count INTEGER NOT NULL DEFAULT 0,
            selected_template_id TEXT,
            selected_template_name TEXT,
            selected_template_kind TEXT,
            selected_template_prompt TEXT,
            source TEXT NOT NULL DEFAULT 'meeting',
            updated_at REAL NOT NULL DEFAULT 0,
            deleted_at REAL,
            cloud_record_name TEXT,
            cloud_change_tag TEXT,
            cloud_transcript_record_name TEXT,
            last_synced_at REAL,
            sync_dirty INTEGER NOT NULL DEFAULT 1,
            follow_up_to_id INTEGER REFERENCES meetings(id) ON DELETE SET NULL,
            follow_up_to_record_name TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_meetings_start_time ON meetings(start_time DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_meetings_calendar_event_id ON meetings(calendar_event_id) WHERE calendar_event_id IS NOT NULL;

        CREATE TABLE IF NOT EXISTS meeting_transcript_checkpoints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            timestamp_label TEXT NOT NULL,
            speaker TEXT NOT NULL,
            start_seconds REAL NOT NULL,
            end_seconds REAL NOT NULL,
            text TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_meeting_transcript_checkpoints_meeting
            ON meeting_transcript_checkpoints(meeting_id, start_seconds, id);

        CREATE TABLE IF NOT EXISTS meeting_resume_snapshots (
            meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
            raw_transcript TEXT NOT NULL DEFAULT '',
            formatted_notes TEXT,
            duration_seconds REAL NOT NULL DEFAULT 0,
            start_time TEXT NOT NULL,
            end_time TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        try exec(createSQL, db: db)

        let foldersSQL = """
        CREATE TABLE IF NOT EXISTS meeting_folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            parent_id INTEGER REFERENCES meeting_folders(id),
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        try exec(foldersSQL, db: db)

        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN folder_id INTEGER REFERENCES meeting_folders(id)", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        // These template columns are also present in CREATE TABLE for fresh databases.
        // The ALTER TABLE path upgrades pre-existing databases where meetings already exists.
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_id TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_name TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_kind TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN selected_template_prompt TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN saved_recording_path TEXT", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN meeting_status TEXT NOT NULL DEFAULT 'completed'", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN manual_notes TEXT NOT NULL DEFAULT ''", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN source TEXT NOT NULL DEFAULT 'meeting'", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        if sqlite3_exec(db, "ALTER TABLE dictations ADD COLUMN source TEXT NOT NULL DEFAULT 'dictation'", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        for sql in [
            "ALTER TABLE dictations ADD COLUMN updated_at REAL NOT NULL DEFAULT 0",
            "ALTER TABLE dictations ADD COLUMN deleted_at REAL",
            "ALTER TABLE dictations ADD COLUMN cloud_record_name TEXT",
            "ALTER TABLE dictations ADD COLUMN cloud_change_tag TEXT",
            "ALTER TABLE dictations ADD COLUMN last_synced_at REAL",
            "ALTER TABLE dictations ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1",
            "ALTER TABLE meetings ADD COLUMN updated_at REAL NOT NULL DEFAULT 0",
            "ALTER TABLE meetings ADD COLUMN deleted_at REAL",
            "ALTER TABLE meetings ADD COLUMN cloud_record_name TEXT",
            "ALTER TABLE meetings ADD COLUMN cloud_change_tag TEXT",
            "ALTER TABLE meetings ADD COLUMN cloud_transcript_record_name TEXT",
            "ALTER TABLE meetings ADD COLUMN last_synced_at REAL",
            "ALTER TABLE meetings ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1"
        ] {
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
        if sqlite3_exec(db, "ALTER TABLE meeting_folders ADD COLUMN parent_id INTEGER REFERENCES meeting_folders(id)", nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            if !msg.localizedCaseInsensitiveContains("duplicate column") {
                throw lastError(db)
            }
        }
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_meeting_folders_parent ON meeting_folders(parent_id)", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_meetings_folder ON meetings(folder_id)", nil, nil, nil)
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN follow_up_to_id INTEGER REFERENCES meetings(id) ON DELETE SET NULL", nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            if !msg.localizedCaseInsensitiveContains("duplicate column") {
                throw lastError(db)
            }
        }
        if sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN follow_up_to_record_name TEXT", nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            if !msg.localizedCaseInsensitiveContains("duplicate column") {
                throw lastError(db)
            }
        }
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_meetings_follow_up ON meetings(follow_up_to_id)", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_meetings_follow_up_record_name ON meetings(follow_up_to_record_name)", nil, nil, nil)
        let _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_meetings_live_follow_up_unique", nil, nil, nil)
        let _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_dictations_cloud_record_name", nil, nil, nil)
        let _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_meetings_cloud_record_name", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_dictations_cloud_record_name ON dictations(cloud_record_name)", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_meetings_cloud_record_name ON meetings(cloud_record_name)", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_dictations_sync_dirty ON dictations(updated_at DESC) WHERE sync_dirty = 1", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_meetings_sync_dirty ON meetings(updated_at DESC) WHERE sync_dirty = 1", nil, nil, nil)
        try migrateInsightsCache(db: db)
        try repairLegacyMacOriginSources(db: db)
        _ = try purgeSoftDeletedTextRecords(olderThan: Self.defaultTombstoneRetentionInterval, db: db)
    }

    private func migrateInsightsCache(db: OpaquePointer?) throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS insights_cache_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS insights_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS insights_record_cache (
            kind TEXT NOT NULL,
            record_id INTEGER NOT NULL,
            source_updated_at REAL NOT NULL,
            activity_day TEXT NOT NULL,
            word_count INTEGER NOT NULL,
            duration_seconds REAL NOT NULL,
            dictation_sessions INTEGER NOT NULL,
            meeting_words INTEGER NOT NULL,
            meetings INTEGER NOT NULL,
            token_blob BLOB NOT NULL,
            PRIMARY KEY(kind, record_id)
        );
        CREATE INDEX IF NOT EXISTS idx_insights_record_updated
            ON insights_record_cache(source_updated_at);
        CREATE TABLE IF NOT EXISTS insights_daily_cache (
            day TEXT PRIMARY KEY,
            dictation_words INTEGER NOT NULL DEFAULT 0,
            dictation_sessions INTEGER NOT NULL DEFAULT 0,
            meeting_words INTEGER NOT NULL DEFAULT 0,
            meetings INTEGER NOT NULL DEFAULT 0,
            duration_seconds REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS insights_token_totals (
            token_id INTEGER PRIMARY KEY REFERENCES insights_tokens(id) ON DELETE CASCADE,
            dictation_count INTEGER NOT NULL DEFAULT 0,
            meeting_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS insights_daily_tokens (
            day TEXT NOT NULL,
            token_id INTEGER NOT NULL REFERENCES insights_tokens(id) ON DELETE CASCADE,
            dictation_count INTEGER NOT NULL DEFAULT 0,
            meeting_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day, token_id)
        );
        CREATE INDEX IF NOT EXISTS idx_insights_daily_tokens_token
            ON insights_daily_tokens(token_id, day);
        """, db: db)
    }

    @discardableResult
    public func insertDictation(
        text: String,
        durationSeconds: Double,
        appContext: String = "",
        source: String = "dictation",
        startedAt: Date,
        endedAt: Date
    ) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO dictations
        (timestamp, duration_seconds, raw_text, app_context, word_count, source, started_at, ended_at, updated_at, sync_dirty)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let timestamp = formatISODate(endedAt)
        let started = formatISODate(startedAt)
        let ended = formatISODate(endedAt)
        sqlite3_bind_text(statement, 1, (timestamp as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, durationSeconds)
        sqlite3_bind_text(statement, 3, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (appContext as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(Self.countWords(in: text)))
        sqlite3_bind_text(statement, 6, (source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (started as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, (ended as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func recentDictations(
        limit: Int = 10,
        offset: Int = 0,
        fromDate: String? = nil,
        toDate: String? = nil,
        origin: RecordOriginFilter = .all
    ) throws -> [DictationRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var conditions: [String] = []
        var boundValues: [String] = []
        if let fromDate {
            conditions.append("d.timestamp >= ?")
            boundValues.append(fromDate)
        }
        if let toDate {
            conditions.append("d.timestamp <= ?")
            boundValues.append(toDate)
        }
        switch origin {
        case .all:
            break
        case .thisMac:
            conditions.append("LOWER(TRIM(COALESCE(d.source, ''))) <> 'ios'")
        case .fromIPhone:
            conditions.append("LOWER(TRIM(COALESCE(d.source, ''))) = 'ios'")
        }
        conditions.insert("d.deleted_at IS NULL", at: 0)
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
        SELECT \(Self.dictationColumns)
        FROM dictations d
        LEFT JOIN computer_use_traces t ON t.dictation_id = d.id
        \(whereClause)
        ORDER BY d.timestamp DESC, d.id DESC
        LIMIT ? OFFSET ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in boundValues.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, nil)
        }
        let limitIndex = Int32(boundValues.count + 1)
        let offsetIndex = Int32(boundValues.count + 2)
        sqlite3_bind_int(statement, limitIndex, Int32(limit))
        sqlite3_bind_int(statement, offsetIndex, Int32(offset))

        var rows: [DictationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeDictationRecord(statement))
        }
        return rows
    }

    public func dictation(id: Int64) throws -> DictationRecord? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.dictationColumns)
        FROM dictations d
        LEFT JOIN computer_use_traces t ON t.dictation_id = d.id
        WHERE d.id = ? AND d.deleted_at IS NULL
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return makeDictationRecord(statement)
    }

    public func meetingCounts(
        origin: RecordOriginFilter = .all
    ) throws -> (total: Int, byFolder: [Int64: Int], directByFolder: [Int64: Int]) {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let originCondition: String
        switch origin {
        case .all:
            originCondition = ""
        case .thisMac:
            originCondition = " AND LOWER(TRIM(COALESCE(source, ''))) <> 'ios'"
        case .fromIPhone:
            originCondition = " AND LOWER(TRIM(COALESCE(source, ''))) = 'ios'"
        }

        var total = 0
        var stmt: OpaquePointer?
        let totalSQL = "SELECT COUNT(*) FROM meetings WHERE deleted_at IS NULL\(originCondition)"
        if sqlite3_prepare_v2(db, totalSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { total = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        } else {
            fputs("[muesli-store] meetingCounts: failed to prepare total count query\n", stderr)
        }

        // Direct counts per folder.
        var directByFolder: [Int64: Int] = [:]
        var stmt2: OpaquePointer?
        let folderSQL = "SELECT folder_id, COUNT(*) FROM meetings WHERE folder_id IS NOT NULL AND deleted_at IS NULL\(originCondition) GROUP BY folder_id"
        if sqlite3_prepare_v2(db, folderSQL, -1, &stmt2, nil) == SQLITE_OK {
            while sqlite3_step(stmt2) == SQLITE_ROW {
                directByFolder[sqlite3_column_int64(stmt2, 0)] = Int(sqlite3_column_int(stmt2, 1))
            }
            sqlite3_finalize(stmt2)
        } else {
            fputs("[muesli-store] meetingCounts: failed to prepare folder count query\n", stderr)
        }

        // Load the folder tree to compute recursive counts.
        let allFolders = (try? listFoldersInternal(db: db)) ?? []
        var childrenMap: [Int64: [Int64]] = [:]
        for folder in allFolders {
            if let pid = folder.parentID {
                childrenMap[pid, default: []].append(folder.id)
            }
        }

        // Count each folder plus every reachable descendant exactly once.
        var byFolder: [Int64: Int] = [:]
        func recursiveCount(for id: Int64) -> Int {
            var reachable: Set<Int64> = [id]
            var queue: [Int64] = [id]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                for childID in childrenMap[current] ?? [] {
                    if reachable.insert(childID).inserted {
                        queue.append(childID)
                    }
                }
            }
            let count = reachable.reduce(0) { $0 + (directByFolder[$1] ?? 0) }
            byFolder[id] = count
            return count
        }
        for folder in allFolders {
            _ = recursiveCount(for: folder.id)
        }

        return (total, byFolder, directByFolder)
    }

    private func listFoldersInternal(db: OpaquePointer?) throws -> [MeetingFolder] {
        let sql = "SELECT id, name, parent_id, created_at FROM meeting_folders ORDER BY id ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [MeetingFolder] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let parentID: Int64? = sqlite3_column_type(statement, 2) != SQLITE_NULL
                ? sqlite3_column_int64(statement, 2) : nil
            rows.append(MeetingFolder(
                id: sqlite3_column_int64(statement, 0),
                name: stringColumn(statement, index: 1),
                parentID: parentID,
                createdAt: stringColumn(statement, index: 3)
            ))
        }
        return rows
    }

    public func recentMeetings(
        limit: Int? = nil,
        folderID: Int64? = nil,
        origin: RecordOriginFilter = .all
    ) throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let originCondition: String
        switch origin {
        case .all:
            originCondition = ""
        case .thisMac:
            originCondition = " AND LOWER(TRIM(COALESCE(source, ''))) <> 'ios'"
        case .fromIPhone:
            originCondition = " AND LOWER(TRIM(COALESCE(source, ''))) = 'ios'"
        }

        var sql: String
        if folderID != nil {
            // Recursive CTE collects the selected folder and all descendants
            // without needing one placeholder per folder.
            sql = """
                WITH RECURSIVE folder_tree(id) AS (
                    SELECT id FROM meeting_folders WHERE id = ?
                    UNION
                    SELECT mf.id FROM meeting_folders mf
                    JOIN folder_tree ft ON mf.parent_id = ft.id
                )
                SELECT \(Self.meetingColumns) FROM meetings
                WHERE folder_id IN (SELECT id FROM folder_tree) AND deleted_at IS NULL\(originCondition)
                ORDER BY id DESC
                """
        } else {
            sql = "SELECT \(Self.meetingColumns) FROM meetings WHERE deleted_at IS NULL\(originCondition) ORDER BY id DESC"
        }
        if limit != nil { sql += " LIMIT ?" }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        var bindIndex: Int32 = 1
        if let folderID {
            sqlite3_bind_int64(statement, bindIndex, folderID)
            bindIndex += 1
        }
        if let limit {
            sqlite3_bind_int(statement, bindIndex, Int32(limit))
        }

        var rows: [MeetingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeMeetingRecord(statement))
        }
        return rows
    }

    public func staleLiveMeetings() throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE meeting_status IN (?, ?) AND deleted_at IS NULL
        ORDER BY id DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (MeetingStatus.recording.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (MeetingStatus.processing.rawValue as NSString).utf8String, -1, nil)

        var rows: [MeetingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeMeetingRecord(statement))
        }
        return rows
    }

    public func meeting(id: Int64) throws -> MeetingRecord? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE id = ? AND deleted_at IS NULL
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return makeMeetingRecord(statement)
    }

    private static func escapeLikePattern(_ query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    public func searchDictations(query: String, limit: Int = 50) throws -> [DictationRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.dictationColumns)
        FROM dictations d
        LEFT JOIN computer_use_traces t ON t.dictation_id = d.id
        WHERE d.deleted_at IS NULL AND (d.raw_text LIKE ? ESCAPE '\\' OR d.app_context LIKE ? ESCAPE '\\' OR t.final_message LIKE ? ESCAPE '\\' OR t.trace_json LIKE ? ESCAPE '\\')
        ORDER BY d.id DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        let pattern = Self.escapeLikePattern(query) as NSString
        sqlite3_bind_text(statement, 1, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, pattern.utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(limit))

        var rows: [DictationRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeDictationRecord(statement))
        }
        return rows
    }

    public func searchMeetings(query: String, limit: Int = 50) throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE deleted_at IS NULL AND (title LIKE ? ESCAPE '\\' OR raw_transcript LIKE ? ESCAPE '\\' OR formatted_notes LIKE ? ESCAPE '\\' OR manual_notes LIKE ? ESCAPE '\\')
        ORDER BY id DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        let pattern = Self.escapeLikePattern(query) as NSString
        sqlite3_bind_text(statement, 1, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, pattern.utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, pattern.utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(limit))

        var rows: [MeetingRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(makeMeetingRecord(statement))
        }
        return rows
    }

    public func meetingByCalendarEventID(_ calendarEventID: String) throws -> MeetingRecord? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT \(Self.meetingColumns)
        FROM meetings
        WHERE calendar_event_id = ? AND deleted_at IS NULL
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (calendarEventID as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return makeMeetingRecord(statement)
    }

    @discardableResult
    public func insertMeeting(
        title: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        rawTranscript: String,
        formattedNotes: String,
        micAudioPath: String?,
        systemAudioPath: String?,
        savedRecordingPath: String? = nil,
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        source: MeetingSource = .meeting
    ) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO meetings
        (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes, mic_audio_path, system_audio_path, saved_recording_path, word_count, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source, updated_at, sync_dirty)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let startString = formatISODate(startTime)
        let endString = formatISODate(endTime)
        let durationSeconds = max(endTime.timeIntervalSince(startTime), 0)
        let wordCount = Self.countWords(in: rawTranscript)

        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        bindOptionalText(calendarEventID, at: 2, statement: statement)
        sqlite3_bind_text(statement, 3, (startString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (endString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 5, durationSeconds)
        sqlite3_bind_text(statement, 6, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (formattedNotes as NSString).utf8String, -1, nil)
        bindOptionalText(micAudioPath, at: 8, statement: statement)
        bindOptionalText(systemAudioPath, at: 9, statement: statement)
        bindOptionalText(savedRecordingPath, at: 10, statement: statement)
        sqlite3_bind_int(statement, 11, Int32(wordCount))
        bindOptionalText(selectedTemplateID, at: 12, statement: statement)
        bindOptionalText(selectedTemplateName, at: 13, statement: statement)
        bindOptionalText(selectedTemplateKind?.rawValue, at: 14, statement: statement)
        bindOptionalText(selectedTemplatePrompt, at: 15, statement: statement)
        sqlite3_bind_text(statement, 16, (source.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 17, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    @discardableResult
    public func createLiveMeeting(
        title: String,
        calendarEventID: String?,
        startTime: Date,
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        folderID: Int64? = nil,
        followUpToID: Int64? = nil
    ) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let followUpRecordName = try followUpToID.flatMap { try meetingCloudRecordName(id: $0, db: db) }

        let sql = """
        INSERT INTO meetings
        (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, word_count, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source, updated_at, sync_dirty, folder_id, follow_up_to_id, follow_up_to_record_name)
        VALUES (?, ?, ?, NULL, 0, '', '', NULL, NULL, NULL, ?, '', 0, ?, ?, ?, ?, 'meeting', ?, 1, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let startString = ISO8601DateFormatter().string(from: startTime)
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        bindOptionalText(calendarEventID, at: 2, statement: statement)
        sqlite3_bind_text(statement, 3, (startString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (MeetingStatus.recording.rawValue as NSString).utf8String, -1, nil)
        bindOptionalText(selectedTemplateID, at: 5, statement: statement)
        bindOptionalText(selectedTemplateName, at: 6, statement: statement)
        bindOptionalText(selectedTemplateKind?.rawValue, at: 7, statement: statement)
        bindOptionalText(selectedTemplatePrompt, at: 8, statement: statement)
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
        if let folderID {
            sqlite3_bind_int64(statement, 10, folderID)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        if let followUpToID {
            sqlite3_bind_int64(statement, 11, followUpToID)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        bindOptionalText(followUpRecordName, at: 12, statement: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// The meeting that `id` points to as its follow-up predecessor, if any.
    public func meetingPredecessorID(of id: Int64) throws -> Int64? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingPredecessorID(of: id, db: db)
    }

    private func meetingPredecessorID(of id: Int64, db: OpaquePointer?) throws -> Int64? {
        var statement: OpaquePointer?
        let sql = """
        SELECT predecessor.id
        FROM meetings AS child
        JOIN meetings AS predecessor
          ON predecessor.id = child.follow_up_to_id
         AND predecessor.deleted_at IS NULL
        WHERE child.id = ?
          AND child.deleted_at IS NULL
        LIMIT 1
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// The earliest meeting recorded as a follow-up to `id`, if any.
    /// A predecessor may have multiple follow-ups; callers that need the whole
    /// set should use `meetingThreadIDs(containing:)`.
    public func meetingSuccessorID(of id: Int64) throws -> Int64? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingSuccessorID(of: id, db: db)
    }

    private func meetingSuccessorID(of id: Int64, db: OpaquePointer?) throws -> Int64? {
        try meetingSuccessorIDs(of: id, db: db).first
    }

    private func meetingSuccessorIDs(of id: Int64, db: OpaquePointer?) throws -> [Int64] {
        var statement: OpaquePointer?
        let sql = """
        SELECT child.id
        FROM meetings AS predecessor
        JOIN meetings AS child
          ON child.follow_up_to_id = predecessor.id
         AND child.deleted_at IS NULL
        WHERE predecessor.id = ?
          AND predecessor.deleted_at IS NULL
        ORDER BY child.start_time ASC, child.id ASC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)

        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
        }
        return ids
    }

    /// Returns the latest chronological meeting in the follow-up tree that
    /// contains `id`. A predecessor can have multiple follow-ups.
    public func latestMeetingIDInThread(of id: Int64) throws -> Int64 {
        try meetingThreadIDs(containing: id).last ?? id
    }

    /// Parent, direct child follow-ups, and chronological position for `id`.
    /// Returns nil for meetings that are not part of a follow-up thread.
    public func meetingThreadNavigation(containing id: Int64) throws -> MeetingThreadNavigation? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let thread = try meetingThreadIDs(containing: id, db: db)
        guard thread.count > 1, thread.contains(id) else { return nil }
        return MeetingThreadNavigation(
            predecessorID: try meetingPredecessorID(of: id, db: db),
            successorIDs: try meetingSuccessorIDs(of: id, db: db),
            count: thread.count
        )
    }

    /// The follow-up tree containing `id`, ordered chronologically. A meeting
    /// with no links returns just itself.
    public func meetingThreadIDs(containing id: Int64) throws -> [Int64] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try meetingThreadIDs(containing: id, db: db)
    }

    private func meetingThreadIDs(containing id: Int64, db: OpaquePointer?) throws -> [Int64] {
        // Walk back to the root.
        var root = id
        var visited: Set<Int64> = [id]
        while let predecessor = try meetingPredecessorID(of: root, db: db) {
            guard visited.insert(predecessor).inserted else { break }
            root = predecessor
        }

        let sql = """
        WITH RECURSIVE thread(id, start_time, path) AS (
            SELECT id, start_time, ',' || id || ','
            FROM meetings
            WHERE id = ?
              AND deleted_at IS NULL
            UNION ALL
            SELECT child.id, child.start_time, thread.path || child.id || ','
            FROM meetings AS child
            JOIN thread ON child.follow_up_to_id = thread.id
            WHERE child.deleted_at IS NULL
              AND instr(thread.path, ',' || child.id || ',') = 0
        )
        SELECT id
        FROM thread
        ORDER BY start_time ASC, id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, root)

        var thread: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            thread.append(sqlite3_column_int64(statement, 0))
        }
        return thread
    }

    private func meetingCloudRecordName(id: Int64, db: OpaquePointer?) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT cloud_record_name FROM meetings WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalStringColumn(statement, index: 0)
    }

    public func dictationStats() throws -> DictationStats {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
            COUNT(*) AS total_sessions,
            COALESCE(SUM(word_count), 0) AS total_words,
            COALESCE(SUM(duration_seconds), 0) AS total_duration_seconds
        FROM dictations
        WHERE deleted_at IS NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return DictationStats(totalWords: 0, totalSessions: 0, averageWordsPerSession: 0, averageWPM: 0, currentStreakDays: 0, longestStreakDays: 0)
        }

        let totalSessions = Int(sqlite3_column_int(statement, 0))
        let totalWords = Int(sqlite3_column_int(statement, 1))
        let totalDuration = sqlite3_column_double(statement, 2)
        let streaks = try dictationStreaks(db: db)
        return DictationStats(
            totalWords: totalWords,
            totalSessions: totalSessions,
            averageWordsPerSession: totalSessions > 0 ? Double(totalWords) / Double(totalSessions) : 0,
            averageWPM: totalDuration > 0 ? Double(totalWords) / (totalDuration / 60.0) : 0,
            currentStreakDays: streaks.current,
            longestStreakDays: streaks.longest
        )
    }

    public func meetingStats() throws -> MeetingStats {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
            COUNT(*) AS total_meetings,
            COALESCE(SUM(word_count), 0) AS total_words,
            COALESCE(SUM(duration_seconds), 0) AS total_duration_seconds
        FROM meetings
        WHERE deleted_at IS NULL AND meeting_status IN (?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (MeetingStatus.noteOnly.rawValue as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)
        }

        let totalMeetings = Int(sqlite3_column_int(statement, 0))
        let totalWords = Int(sqlite3_column_int(statement, 1))
        let totalDuration = sqlite3_column_double(statement, 2)
        return MeetingStats(
            totalWords: totalWords,
            totalMeetings: totalMeetings,
            averageWPM: totalDuration > 0 ? Double(totalWords) / (totalDuration / 60.0) : 0
        )
    }

    public func insightsSnapshot(
        range: InsightsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> InsightsSnapshot {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try reconcileInsightsCache(db: db, calendar: calendar)

        let startDate = range.startDate(now: now, calendar: calendar)
        let startDay = startDate.map { cacheDay($0, calendar: calendar) }
        let lifetime = try cachedInsightsTotals(db: db, sinceDay: nil)
        let selected = try cachedInsightsTotals(db: db, sinceDay: startDay)
        let cachedDays = try cachedDailyActivity(db: db, sinceDay: startDay, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let firstDay = startDate.map { calendar.startOfDay(for: $0) }
            ?? cachedDays.keys.min()
            ?? today
        var activity: [InsightsDailyActivity] = []
        var cursor = min(firstDay, today)
        while cursor <= today {
            let value = cachedDays[cursor, default: (0, 0)]
            activity.append(InsightsDailyActivity(date: cursor, words: value.words, meetings: value.meetings))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let streaks = try dictationStreaks(db: db)
        return InsightsSnapshot(
            range: range,
            generatedAt: now,
            lifetime: lifetime,
            selected: selected,
            dailyActivity: activity,
            currentStreakDays: streaks.current,
            longestStreakDays: streaks.longest,
            activeDaysInRange: activity.filter { $0.words > 0 || $0.meetings > 0 }.count,
            dictationWords: try cachedTopWords(db: db, sinceDay: startDay, meeting: false),
            meetingWords: try cachedTopWords(db: db, sinceDay: startDay, meeting: true)
        )
    }

    private struct InsightsCacheSource {
        let kind: String
        let id: Int64
        let updatedAt: Double
        let date: Date
        let wordCount: Int
        let duration: Double
        let deleted: Bool
        let eligible: Bool
    }

    private static let insightsCacheBatchSize = 64

    private func reconcileInsightsCache(db: OpaquePointer?, calendar: Calendar) throws {
        let signature = "2|\(calendar.timeZone.identifier)"
        if try insightsCacheMeta("signature", db: db) != signature {
            try resetInsightsCache(signature: signature, db: db)
        }

        while true {
            let stale = try staleInsightsCacheKeys(db: db, limit: Self.insightsCacheBatchSize)
            guard !stale.isEmpty else { break }
            for (kind, id) in stale {
                if Task.isCancelled { throw CancellationError() }
                try withInsightsWriteTransaction(db: db) {
                    try removeCachedInsightsRecord(kind: kind, id: id, db: db)
                }
            }
        }

        while true {
            let changed = try changedInsightsSources(db: db, limit: Self.insightsCacheBatchSize)
            guard !changed.isEmpty else { break }
            for source in changed {
                if Task.isCancelled { throw CancellationError() }
                var counts: [String: Int] = [:]
                if !source.deleted, source.eligible {
                    guard let text = try insightsSourceText(source, db: db) else { continue }
                    if source.kind == "meeting" {
                        InsightsWordAnalyzer.accumulateMeetingTranscript(text, into: &counts)
                    } else {
                        InsightsWordAnalyzer.accumulate(text, into: &counts)
                    }
                }
                try applyInsightsSource(source, counts: counts, calendar: calendar, db: db)
            }
        }

        try withInsightsWriteTransaction(db: db) {
            try exec("""
            DELETE FROM insights_daily_cache
              WHERE dictation_words = 0 AND dictation_sessions = 0 AND meeting_words = 0 AND meetings = 0;
            DELETE FROM insights_daily_tokens WHERE dictation_count = 0 AND meeting_count = 0;
            DELETE FROM insights_token_totals WHERE dictation_count = 0 AND meeting_count = 0;
            """, db: db)
        }
    }

    private func resetInsightsCache(signature: String, db: OpaquePointer?) throws {
        try withInsightsWriteTransaction(db: db) {
            try exec("""
            DELETE FROM insights_record_cache;
            DELETE FROM insights_daily_cache;
            DELETE FROM insights_daily_tokens;
            DELETE FROM insights_token_totals;
            DELETE FROM insights_tokens;
            """, db: db)
            let sql = """
            INSERT INTO insights_cache_meta(key, value) VALUES('signature', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (signature as NSString).utf8String, -1, nil)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
        }
    }

    private func changedInsightsSources(db: OpaquePointer?, limit: Int) throws -> [InsightsCacheSource] {
        let sql = """
        SELECT kind, record_id, source_updated_at, activity_date, word_count,
               duration_seconds, deleted, eligible
        FROM (
            SELECT 'dictation' AS kind, d.id AS record_id, d.updated_at AS source_updated_at,
                   d.timestamp AS activity_date, d.word_count AS word_count,
                   COALESCE(d.duration_seconds, 0) AS duration_seconds,
                   d.deleted_at IS NOT NULL AS deleted, 1 AS eligible
            FROM dictations d
            LEFT JOIN insights_record_cache c ON c.kind = 'dictation' AND c.record_id = d.id
            WHERE c.record_id IS NULL OR c.source_updated_at != d.updated_at
            UNION ALL
            SELECT 'meeting', m.id, m.updated_at, m.start_time, m.word_count,
                   COALESCE(m.duration_seconds, 0), m.deleted_at IS NOT NULL,
                   m.meeting_status IN ('completed', 'note_only')
            FROM meetings m
            LEFT JOIN insights_record_cache c ON c.kind = 'meeting' AND c.record_id = m.id
            WHERE c.record_id IS NULL OR c.source_updated_at != m.updated_at
        )
        ORDER BY kind, record_id
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [InsightsCacheSource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let parsedDate = parseISODate(stringColumn(statement, index: 3))
            rows.append(InsightsCacheSource(
                kind: stringColumn(statement, index: 0), id: sqlite3_column_int64(statement, 1),
                updatedAt: sqlite3_column_double(statement, 2),
                date: parsedDate ?? Date(timeIntervalSince1970: 0),
                wordCount: Int(sqlite3_column_int64(statement, 4)), duration: sqlite3_column_double(statement, 5),
                deleted: sqlite3_column_int(statement, 6) != 0,
                eligible: parsedDate != nil && sqlite3_column_int(statement, 7) != 0
            ))
        }
        return rows
    }

    private func insightsSourceText(_ source: InsightsCacheSource, db: OpaquePointer?) throws -> String? {
        let sql: String
        if source.kind == "meeting" {
            sql = """
            SELECT CASE WHEN meeting_status = 'note_only' THEN COALESCE(manual_notes, '') ELSE COALESCE(raw_transcript, '') END
            FROM meetings WHERE id = ? AND updated_at = ?
            """
        } else {
            sql = "SELECT COALESCE(raw_text, '') FROM dictations WHERE id = ? AND updated_at = ?"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, source.id)
        sqlite3_bind_double(statement, 2, source.updatedAt)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return stringColumn(statement, index: 0)
    }

    @discardableResult
    private func applyInsightsSource(
        _ source: InsightsCacheSource,
        counts: [String: Int],
        calendar: Calendar,
        db: OpaquePointer?
    ) throws -> Bool {
        try withInsightsWriteTransaction(db: db) {
            guard try insightsSourceIsCurrent(source, db: db) else { return false }
            try removeCachedInsightsRecord(kind: source.kind, id: source.id, db: db)
            let day = cacheDay(source.date, calendar: calendar)
            guard !source.deleted, source.eligible else {
                try markInsightsSourceProcessed(source, day: day, db: db)
                return true
            }
            var pairs: [InsightsContributionCodec.Pair] = []
            pairs.reserveCapacity(counts.count)
            for (token, count) in counts {
                pairs.append(.init(tokenID: try internInsightsToken(token, db: db), count: count))
            }
            try addCachedInsightsRecord(source, day: day, pairs: pairs, db: db)
            return true
        }
    }

    private func insightsSourceIsCurrent(_ source: InsightsCacheSource, db: OpaquePointer?) throws -> Bool {
        let table = source.kind == "meeting" ? "meetings" : "dictations"
        let sql = "SELECT 1 FROM \(table) WHERE id = ? AND updated_at = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, source.id)
        sqlite3_bind_double(statement, 2, source.updatedAt)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func staleInsightsCacheKeys(db: OpaquePointer?, limit: Int) throws -> [(String, Int64)] {
        let sql = """
        SELECT kind, record_id FROM insights_record_cache c
        WHERE (kind = 'dictation' AND NOT EXISTS (SELECT 1 FROM dictations d WHERE d.id = c.record_id))
           OR (kind = 'meeting' AND NOT EXISTS (SELECT 1 FROM meetings m WHERE m.id = c.record_id))
        ORDER BY kind, record_id
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var keys: [(String, Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW { keys.append((stringColumn(statement, index: 0), sqlite3_column_int64(statement, 1))) }
        return keys
    }

    private func withInsightsWriteTransaction<T>(db: OpaquePointer?, _ work: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE", db: db)
        do {
            let result = try work()
            try exec("COMMIT", db: db)
            return result
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func addCachedInsightsRecord(_ source: InsightsCacheSource, day: String, pairs: [InsightsContributionCodec.Pair], db: OpaquePointer?) throws {
        let isMeeting = source.kind == "meeting"
        try adjustInsightsDaily(day: day, dictationWords: isMeeting ? 0 : source.wordCount,
            dictationSessions: isMeeting ? 0 : 1, meetingWords: isMeeting ? source.wordCount : 0,
            meetings: isMeeting ? 1 : 0, duration: source.duration, db: db)
        for pair in pairs { try adjustInsightsToken(day: day, pair: pair, meeting: isMeeting, multiplier: 1, db: db) }
        let sql = """
        INSERT INTO insights_record_cache
          (kind, record_id, source_updated_at, activity_day, word_count, duration_seconds,
           dictation_sessions, meeting_words, meetings, token_blob)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (source.kind as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, source.id); sqlite3_bind_double(statement, 3, source.updatedAt)
        sqlite3_bind_text(statement, 4, (day as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 5, Int64(isMeeting ? 0 : source.wordCount)); sqlite3_bind_double(statement, 6, source.duration)
        sqlite3_bind_int(statement, 7, isMeeting ? 0 : 1); sqlite3_bind_int64(statement, 8, Int64(isMeeting ? source.wordCount : 0))
        sqlite3_bind_int(statement, 9, isMeeting ? 1 : 0)
        let blob = InsightsContributionCodec.encode(pairs)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32(blob.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    /// Records the source revision even when it contributes no analytics. This keeps
    /// deleted and unfinished rows out of subsequent delta scans until they change.
    private func markInsightsSourceProcessed(_ source: InsightsCacheSource, day: String, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO insights_record_cache
          (kind, record_id, source_updated_at, activity_day, word_count, duration_seconds,
           dictation_sessions, meeting_words, meetings, token_blob)
        VALUES (?, ?, ?, ?, 0, 0, 0, 0, 0, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (source.kind as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, source.id)
        sqlite3_bind_double(statement, 3, source.updatedAt)
        sqlite3_bind_text(statement, 4, (day as NSString).utf8String, -1, nil)
        let blob = InsightsContributionCodec.encode([])
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(blob.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    private func removeCachedInsightsRecord(kind: String, id: Int64, db: OpaquePointer?) throws {
        let sql = "SELECT activity_day, word_count, duration_seconds, dictation_sessions, meeting_words, meetings, token_blob FROM insights_record_cache WHERE kind = ? AND record_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        sqlite3_bind_text(statement, 1, (kind as NSString).utf8String, -1, nil); sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); return }
        let day = stringColumn(statement, index: 0), words = Int(sqlite3_column_int64(statement, 1))
        let duration = sqlite3_column_double(statement, 2), sessions = Int(sqlite3_column_int(statement, 3))
        let meetingWords = Int(sqlite3_column_int64(statement, 4)), meetings = Int(sqlite3_column_int(statement, 5))
        let bytes = sqlite3_column_blob(statement, 6), count = Int(sqlite3_column_bytes(statement, 6))
        let blob = bytes.map { Data(bytes: $0, count: count) } ?? Data()
        sqlite3_finalize(statement)
        do {
            try adjustInsightsDaily(day: day, dictationWords: -words, dictationSessions: -sessions,
                meetingWords: -meetingWords, meetings: -meetings, duration: -duration, db: db)
        } catch {
            throw NSError(domain: "MuesliInsightsCache", code: 3, userInfo: [NSLocalizedDescriptionKey: "Subtracting daily contribution: \(error.localizedDescription)"])
        }
        for pair in InsightsContributionCodec.decode(blob) {
            do {
                try adjustInsightsToken(day: day, pair: pair, meeting: kind == "meeting", multiplier: -1, db: db)
            } catch {
                throw NSError(domain: "MuesliInsightsCache", code: 4, userInfo: [NSLocalizedDescriptionKey: "Subtracting token \(pair.tokenID): \(error.localizedDescription)"])
            }
        }
        var delete: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM insights_record_cache WHERE kind = ? AND record_id = ?", -1, &delete, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(delete) }
        sqlite3_bind_text(delete, 1, (kind as NSString).utf8String, -1, nil); sqlite3_bind_int64(delete, 2, id)
        guard sqlite3_step(delete) == SQLITE_DONE else { throw lastError(db) }
    }

    private func adjustInsightsDaily(day: String, dictationWords: Int, dictationSessions: Int, meetingWords: Int, meetings: Int, duration: Double, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO insights_daily_cache(day, dictation_words, dictation_sessions, meeting_words, meetings, duration_seconds)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(day) DO UPDATE SET dictation_words=dictation_words+excluded.dictation_words,
          dictation_sessions=dictation_sessions+excluded.dictation_sessions, meeting_words=meeting_words+excluded.meeting_words,
          meetings=meetings+excluded.meetings, duration_seconds=duration_seconds+excluded.duration_seconds
        """
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, (day as NSString).utf8String, -1, nil); sqlite3_bind_int64(s, 2, Int64(dictationWords))
        sqlite3_bind_int(s, 3, Int32(dictationSessions)); sqlite3_bind_int64(s, 4, Int64(meetingWords)); sqlite3_bind_int(s, 5, Int32(meetings)); sqlite3_bind_double(s, 6, duration)
        guard sqlite3_step(s) == SQLITE_DONE else { throw lastError(db) }
    }

    private func adjustInsightsToken(day: String, pair: InsightsContributionCodec.Pair, meeting: Bool, multiplier: Int, db: OpaquePointer?) throws {
        let dictation = meeting ? 0 : pair.count * multiplier, meetingCount = meeting ? pair.count * multiplier : 0
        for sql in [
            "INSERT INTO insights_token_totals(token_id,dictation_count,meeting_count) VALUES(?,?,?) ON CONFLICT(token_id) DO UPDATE SET dictation_count=dictation_count+excluded.dictation_count, meeting_count=meeting_count+excluded.meeting_count",
            "INSERT INTO insights_daily_tokens(day,token_id,dictation_count,meeting_count) VALUES(?,?,?,?) ON CONFLICT(day,token_id) DO UPDATE SET dictation_count=dictation_count+excluded.dictation_count, meeting_count=meeting_count+excluded.meeting_count"
        ] {
            var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
            var index: Int32 = 1
            if sql.contains("daily_tokens") { sqlite3_bind_text(s, index, (day as NSString).utf8String, -1, nil); index += 1 }
            sqlite3_bind_int64(s, index, pair.tokenID); sqlite3_bind_int(s, index + 1, Int32(dictation)); sqlite3_bind_int(s, index + 2, Int32(meetingCount))
            guard sqlite3_step(s) == SQLITE_DONE else { throw lastError(db) }
        }
    }

    private func internInsightsToken(_ token: String, db: OpaquePointer?) throws -> Int64 {
        var insert: OpaquePointer?; guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO insights_tokens(token) VALUES(?)", -1, &insert, nil) == SQLITE_OK else { throw lastError(db) }
        sqlite3_bind_text(insert, 1, (token as NSString).utf8String, -1, nil); guard sqlite3_step(insert) == SQLITE_DONE else { sqlite3_finalize(insert); throw lastError(db) }; sqlite3_finalize(insert)
        var select: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT id FROM insights_tokens WHERE token=?", -1, &select, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(select) }
        sqlite3_bind_text(select, 1, (token as NSString).utf8String, -1, nil); guard sqlite3_step(select) == SQLITE_ROW else { throw lastError(db) }
        return sqlite3_column_int64(select, 0)
    }

    private func insightsCacheMeta(_ key: String, db: OpaquePointer?) throws -> String? {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT value FROM insights_cache_meta WHERE key=?", -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, (key as NSString).utf8String, -1, nil); return sqlite3_step(s) == SQLITE_ROW ? stringColumn(s, index: 0) : nil
    }

    private func cacheDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func cachedInsightsTotals(db: OpaquePointer?, sinceDay: String?) throws -> InsightsTotals {
        let sql = """
        SELECT COALESCE(SUM(dictation_words),0), COALESCE(SUM(dictation_sessions),0),
          COALESCE(SUM(meeting_words),0), COALESCE(SUM(meetings),0), COALESCE(SUM(duration_seconds),0)
        FROM insights_daily_cache WHERE (? IS NULL OR day >= ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError(db) }
        defer { sqlite3_finalize(statement) }
        bindOptionalText(sinceDay, at: 1, statement: statement); bindOptionalText(sinceDay, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return InsightsTotals(dictationWords: 0, dictationSessions: 0, meetingWords: 0, meetings: 0, averageWPM: 0)
        }
        let dictationWords = Int(sqlite3_column_int64(statement, 0))
        let dictationSessions = Int(sqlite3_column_int64(statement, 1))
        let meetingWords = Int(sqlite3_column_int64(statement, 2))
        let meetings = Int(sqlite3_column_int64(statement, 3))
        let duration = sqlite3_column_double(statement, 4)
        let totalWords = dictationWords + meetingWords
        return InsightsTotals(
            dictationWords: dictationWords,
            dictationSessions: dictationSessions,
            meetingWords: meetingWords,
            meetings: meetings,
            averageWPM: duration > 0 ? Double(totalWords) / (duration / 60) : 0
        )
    }

    private func cachedDailyActivity(db: OpaquePointer?, sinceDay: String?, calendar: Calendar) throws -> [Date: (words: Int, meetings: Int)] {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT day,dictation_words+meeting_words,meetings FROM insights_daily_cache WHERE (? IS NULL OR day>=?) ORDER BY day", -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        bindOptionalText(sinceDay, at: 1, statement: s); bindOptionalText(sinceDay, at: 2, statement: s)
        var result: [Date: (Int, Int)] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let parts = stringColumn(s, index: 0).split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                result[calendar.startOfDay(for: date)] = (Int(sqlite3_column_int64(s, 1)), Int(sqlite3_column_int64(s, 2)))
            }
        }
        return result
    }

    private func cachedTopWords(db: OpaquePointer?, sinceDay: String?, meeting: Bool) throws -> [InsightsWordFrequency] {
        let column = meeting ? "meeting_count" : "dictation_count"
        let sql = "SELECT t.token,SUM(d.\(column)) total FROM insights_daily_tokens d JOIN insights_tokens t ON t.id=d.token_id WHERE (? IS NULL OR d.day>=?) GROUP BY d.token_id HAVING total>0 ORDER BY total DESC,t.token ASC LIMIT 48"
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw lastError(db) }; defer { sqlite3_finalize(s) }
        bindOptionalText(sinceDay, at: 1, statement: s); bindOptionalText(sinceDay, at: 2, statement: s)
        var words: [InsightsWordFrequency] = []
        while sqlite3_step(s) == SQLITE_ROW { words.append(.init(word: stringColumn(s, index: 0), count: Int(sqlite3_column_int64(s, 1)))) }
        return words
    }

    public func deleteDictation(id: Int64) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try deleteComputerUseTrace(dictationID: id, db: db)
        let sql = """
        UPDATE dictations
        SET raw_text = '',
            app_context = '',
            word_count = 0,
            duration_seconds = 0,
            deleted_at = ?,
            updated_at = ?,
            sync_dirty = 1
        WHERE id = ? AND deleted_at IS NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.dictationNotFound(id: id)
        }
    }

    public func deleteMeeting(id: Int64) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try exec("BEGIN IMMEDIATE", db: db)

        do {
            try deleteResumeSnapshot(meetingID: id, db: db)
            try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
            let sql = """
            UPDATE meetings
            SET title = 'Deleted Meeting',
                raw_transcript = '',
                formatted_notes = NULL,
                manual_notes = '',
                mic_audio_path = NULL,
                system_audio_path = NULL,
                saved_recording_path = NULL,
                follow_up_to_id = NULL,
                follow_up_to_record_name = NULL,
                word_count = 0,
                duration_seconds = 0,
                deleted_at = ?,
                updated_at = ?,
                sync_dirty = 1
            WHERE id = ? AND deleted_at IS NULL
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(statement, 1, now)
            sqlite3_bind_double(statement, 2, now)
            sqlite3_bind_int64(statement, 3, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError(db)
            }
            guard sqlite3_changes(db) > 0 else {
                throw DictationStoreError.meetingNotFound(id: id)
            }
            try detachFollowUpSuccessors(of: id, db: db)
            try exec("COMMIT", db: db)
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func clearDictations() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try exec("DELETE FROM computer_use_traces", db: db)
        try exec(
            """
            UPDATE dictations
            SET raw_text = '',
                app_context = '',
                word_count = 0,
                duration_seconds = 0,
                deleted_at = strftime('%s','now'),
                updated_at = strftime('%s','now'),
                sync_dirty = 1
            WHERE deleted_at IS NULL
            """,
            db: db
        )
    }

    public func insertComputerUseTrace(
        dictationID: Int64,
        finalStatus: String,
        finalMessage: String,
        events: [ComputerUseTraceEvent]
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(events)
        let traceJSON = String(data: data, encoding: .utf8) ?? "[]"

        var existenceCheck: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM dictations WHERE id = ? AND deleted_at IS NULL LIMIT 1",
            -1,
            &existenceCheck,
            nil
        ) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(existenceCheck) }
        sqlite3_bind_int64(existenceCheck, 1, dictationID)
        guard sqlite3_step(existenceCheck) == SQLITE_ROW else {
            throw DictationStoreError.dictationNotFound(id: dictationID)
        }

        let sql = """
        INSERT OR REPLACE INTO computer_use_traces
        (dictation_id, final_status, final_message, trace_json)
        VALUES (?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, dictationID)
        sqlite3_bind_text(statement, 2, (finalStatus as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (finalMessage as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (traceJSON as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func clearMeetings() throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try exec("DELETE FROM meeting_resume_snapshots", db: db)
        try exec("DELETE FROM meeting_transcript_checkpoints", db: db)
        try exec(
            """
            UPDATE meetings
            SET title = 'Deleted Meeting',
                raw_transcript = '',
                formatted_notes = NULL,
                manual_notes = '',
                mic_audio_path = NULL,
                system_audio_path = NULL,
                saved_recording_path = NULL,
                word_count = 0,
                duration_seconds = 0,
                deleted_at = strftime('%s','now'),
                updated_at = strftime('%s','now'),
                sync_dirty = 1
            WHERE deleted_at IS NULL
            """,
            db: db
        )
    }

    public func updateMeeting(id: Int64, title: String, formattedNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET title = ?, formatted_notes = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 4, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingNotes(id: Int64, formattedNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET formatted_notes = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingTranscript(id: Int64, rawTranscript: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let wordCount = Self.countWords(in: rawTranscript) + Self.countWords(in: manualNotes)
        let sql = "UPDATE meetings SET raw_transcript = ?, word_count = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(wordCount))
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 4, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        try deleteResumeSnapshot(meetingID: id, db: db)
    }

    /// Returns the stored raw transcript for a meeting, or `nil` if the meeting does not exist.
    /// Used by the resume-recording flow to append new transcript onto the prior one.
    public func meetingRawTranscript(id: Int64) throws -> String? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT raw_transcript
        FROM meetings
        WHERE id = ? AND deleted_at IS NULL
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return stringColumn(statement, index: 0)
    }

    /// Atomically records the prior completed state and reopens the same row for resume recording.
    /// Returns the transcript snapshot to use for in-memory merge on a normal stop.
    public func prepareMeetingForResume(id: Int64) throws -> String {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        do {
            let snapshot = try resumeSnapshotSource(meetingID: id, db: db)
            try upsertResumeSnapshot(meetingID: id, snapshot: snapshot, db: db)
            try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
            try updateMeetingStatus(id: id, status: .recording, db: db)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            return snapshot.rawTranscript
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func appendLiveTranscriptCheckpoints(meetingID: Int64, entries: [LiveTranscriptCheckpointEntry]) throws {
        let trimmedEntries = entries.compactMap { entry -> LiveTranscriptCheckpointEntry? in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LiveTranscriptCheckpointEntry(
                timestampLabel: entry.timestampLabel,
                speaker: entry.speaker,
                startSeconds: entry.startSeconds,
                endSeconds: entry.endSeconds,
                text: text
            )
        }
        guard !trimmedEntries.isEmpty else { return }

        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }

        do {
            let sql = """
            INSERT INTO meeting_transcript_checkpoints
            (meeting_id, timestamp_label, speaker, start_seconds, end_seconds, text)
            VALUES (?, ?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(statement) }

            for entry in trimmedEntries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, meetingID)
                sqlite3_bind_text(statement, 2, (entry.timestampLabel as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (entry.speaker as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 4, entry.startSeconds)
                sqlite3_bind_double(statement, 5, entry.endSeconds)
                sqlite3_bind_text(statement, 6, (entry.text as NSString).utf8String, -1, nil)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw lastError(db)
                }
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func liveTranscriptCheckpointText(meetingID: Int64) throws -> String? {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try liveTranscriptCheckpointText(meetingID: meetingID, db: db)
    }

    @discardableResult
    public func recoverLiveMeetingFromTranscriptCheckpoints(id: Int64) throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        if let snapshot = try resumeSnapshot(meetingID: id, db: db) {
            return try recoverResumedMeeting(id: id, snapshot: snapshot, db: db)
        }
        guard let transcript = try liveTranscriptCheckpointText(meetingID: id, db: db) else {
            return false
        }

        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let formattedNotes = """
        ## Raw Transcript

        Recovered from live transcript checkpoints after the meeting did not finalize normally. This fallback may be incomplete and may not include final diarization or reconciliation.

        \(transcript)
        """
        let wordCount = Self.countWords(in: transcript) + Self.countWords(in: manualNotes)
        let durationSeconds = try liveTranscriptCheckpointDuration(meetingID: id, db: db)
        let endTime = try liveMeetingFallbackEndTime(meetingID: id, durationSeconds: durationSeconds, db: db)
        let sql = """
        UPDATE meetings
        SET end_time = ?, duration_seconds = ?, raw_transcript = ?, formatted_notes = ?, meeting_status = ?, word_count = ?, updated_at = ?, sync_dirty = 1
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        bindOptionalText(endTime, at: 1, statement: statement)
        sqlite3_bind_double(statement, 2, durationSeconds)
        sqlite3_bind_text(statement, 3, (transcript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 6, Int32(wordCount))
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        return true
    }

    public func updateMeetingManualNotes(id: Int64, manualNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET manual_notes = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (manualNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
    }

    public func updateMeetingStatus(id: Int64, status: MeetingStatus) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try updateMeetingStatus(id: id, status: status, db: db)
    }

    @discardableResult
    public func restoreResumedMeetingIfNeeded(id: Int64) throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard let snapshot = try resumeSnapshot(meetingID: id, db: db) else { return false }
        try restoreResumedMeeting(id: id, snapshot: snapshot, db: db)
        return true
    }

    private func updateMeetingStatus(id: Int64, status: MeetingStatus, db: OpaquePointer?) throws {
        let wordCount = try manualNoteWordCountIfNeeded(for: status, id: id, db: db)
        let sql = wordCount == nil
            ? "UPDATE meetings SET meeting_status = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?"
            : "UPDATE meetings SET meeting_status = ?, word_count = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (status.rawValue as NSString).utf8String, -1, nil)
        if let wordCount {
            sqlite3_bind_int(statement, 2, Int32(wordCount))
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 4, id)
        } else {
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 3, id)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
    }

    public func completeLiveMeeting(
        id: Int64,
        title: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        durationSeconds explicitDurationSeconds: Double? = nil,
        rawTranscript: String,
        formattedNotes: String,
        micAudioPath: String?,
        systemAudioPath: String?,
        savedRecordingPath: String? = nil,
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        UPDATE meetings
        SET title = ?, calendar_event_id = ?, start_time = ?, end_time = ?, duration_seconds = ?, raw_transcript = ?, formatted_notes = ?, mic_audio_path = ?, system_audio_path = ?, saved_recording_path = ?, meeting_status = ?, word_count = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?, updated_at = ?, sync_dirty = 1
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let formatter = ISO8601DateFormatter()
        let startString = formatter.string(from: startTime)
        let endString = formatter.string(from: endTime)
        let durationSeconds = max(explicitDurationSeconds ?? endTime.timeIntervalSince(startTime), 0)
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let wordCount = Self.countWords(in: rawTranscript) + Self.countWords(in: manualNotes)

        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        bindOptionalText(calendarEventID, at: 2, statement: statement)
        sqlite3_bind_text(statement, 3, (startString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (endString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 5, durationSeconds)
        sqlite3_bind_text(statement, 6, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (formattedNotes as NSString).utf8String, -1, nil)
        bindOptionalText(micAudioPath, at: 8, statement: statement)
        bindOptionalText(systemAudioPath, at: 9, statement: statement)
        bindOptionalText(savedRecordingPath, at: 10, statement: statement)
        sqlite3_bind_text(statement, 11, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 12, Int32(wordCount))
        bindOptionalText(selectedTemplateID, at: 13, statement: statement)
        bindOptionalText(selectedTemplateName, at: 14, statement: statement)
        bindOptionalText(selectedTemplateKind?.rawValue, at: 15, statement: statement)
        bindOptionalText(selectedTemplatePrompt, at: 16, statement: statement)
        sqlite3_bind_double(statement, 17, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 18, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        try deleteResumeSnapshot(meetingID: id, db: db)
    }

    private func manualNoteWordCountIfNeeded(for status: MeetingStatus, id: Int64, db: OpaquePointer?) throws -> Int? {
        switch status {
        case .noteOnly, .failed:
            return Self.countWords(in: try manualNotesForMeeting(id: id, db: db))
        case .recording, .processing, .completed:
            return nil
        }
    }

    private func manualNotesForMeeting(id: Int64, db: OpaquePointer?) throws -> String {
        let sql = "SELECT manual_notes FROM meetings WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        return stringColumn(statement, index: 0)
    }

    private func liveTranscriptCheckpointText(meetingID: Int64, db: OpaquePointer?) throws -> String? {
        let sql = """
        SELECT timestamp_label, speaker, text
        FROM meeting_transcript_checkpoints
        WHERE meeting_id = ?
        ORDER BY start_seconds ASC, id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)

        var lines: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = stringColumn(statement, index: 0)
            let speaker = stringColumn(statement, index: 1)
            let text = stringColumn(statement, index: 2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("[\(timestamp)] \(speaker): \(text)")
        }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private func liveTranscriptCheckpointDuration(meetingID: Int64, db: OpaquePointer?) throws -> Double {
        let sql = """
        SELECT COALESCE(MAX(end_seconds), 0)
        FROM meeting_transcript_checkpoints
        WHERE meeting_id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw lastError(db)
        }
        return max(sqlite3_column_double(statement, 0), 0)
    }

    private func liveMeetingFallbackEndTime(meetingID: Int64, durationSeconds: Double, db: OpaquePointer?) throws -> String? {
        guard durationSeconds > 0 else { return nil }
        let sql = "SELECT start_time FROM meetings WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DictationStoreError.meetingNotFound(id: meetingID)
        }
        let startTimeString = stringColumn(statement, index: 0)
        guard let startTime = ISO8601DateFormatter().date(from: startTimeString) else {
            return nil
        }
        return ISO8601DateFormatter().string(from: startTime.addingTimeInterval(durationSeconds))
    }

    private struct ResumeSnapshot {
        var rawTranscript: String
        var formattedNotes: String
        var durationSeconds: Double
        var startTime: String
        var endTime: String?
    }

    private func resumeSnapshotSource(meetingID: Int64, db: OpaquePointer?) throws -> ResumeSnapshot {
        let sql = """
        SELECT raw_transcript, formatted_notes, COALESCE(duration_seconds, 0), start_time, end_time
        FROM meetings
        WHERE id = ? AND deleted_at IS NULL AND meeting_status = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DictationStoreError.meetingNotFound(id: meetingID)
        }
        return ResumeSnapshot(
            rawTranscript: stringColumn(statement, index: 0),
            formattedNotes: stringColumn(statement, index: 1),
            durationSeconds: max(sqlite3_column_double(statement, 2), 0),
            startTime: stringColumn(statement, index: 3),
            endTime: optionalStringColumn(statement, index: 4)
        )
    }

    private func upsertResumeSnapshot(meetingID: Int64, snapshot: ResumeSnapshot, db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO meeting_resume_snapshots
            (meeting_id, raw_transcript, formatted_notes, duration_seconds, start_time, end_time, created_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(meeting_id) DO UPDATE SET
            raw_transcript = excluded.raw_transcript,
            formatted_notes = excluded.formatted_notes,
            duration_seconds = excluded.duration_seconds,
            start_time = excluded.start_time,
            end_time = excluded.end_time,
            created_at = excluded.created_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_text(statement, 2, (snapshot.rawTranscript as NSString).utf8String, -1, nil)
        bindOptionalText(snapshot.formattedNotes, at: 3, statement: statement)
        sqlite3_bind_double(statement, 4, snapshot.durationSeconds)
        sqlite3_bind_text(statement, 5, (snapshot.startTime as NSString).utf8String, -1, nil)
        bindOptionalText(snapshot.endTime, at: 6, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func resumeSnapshot(meetingID: Int64, db: OpaquePointer?) throws -> ResumeSnapshot? {
        let sql = """
        SELECT raw_transcript, formatted_notes, duration_seconds, start_time, end_time
        FROM meeting_resume_snapshots
        WHERE meeting_id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return ResumeSnapshot(
            rawTranscript: stringColumn(statement, index: 0),
            formattedNotes: stringColumn(statement, index: 1),
            durationSeconds: max(sqlite3_column_double(statement, 2), 0),
            startTime: stringColumn(statement, index: 3),
            endTime: optionalStringColumn(statement, index: 4)
        )
    }

    @discardableResult
    private func recoverResumedMeeting(id: Int64, snapshot: ResumeSnapshot, db: OpaquePointer?) throws -> Bool {
        guard let checkpointTranscript = try liveTranscriptCheckpointText(meetingID: id, db: db) else {
            try restoreResumedMeeting(id: id, snapshot: snapshot, db: db)
            return true
        }

        let combined = combinedResumeRecoveryTranscript(prior: snapshot.rawTranscript, new: checkpointTranscript)
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let resumedDurationSeconds = try liveTranscriptCheckpointDuration(meetingID: id, db: db)
        let durationSeconds = snapshot.durationSeconds + resumedDurationSeconds
        let endTime = snapshotEndTime(
            startTimeString: snapshot.startTime,
            fallbackEndTime: snapshot.endTime,
            durationSeconds: durationSeconds
        )
        let formattedNotes = resumedRecoveryNotes(priorNotes: snapshot.formattedNotes, combinedTranscript: combined)
        let wordCount = Self.countWords(in: combined) + Self.countWords(in: manualNotes)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        do {
            try completeResumedRecovery(
                id: id,
                snapshot: snapshot,
                rawTranscript: combined,
                formattedNotes: formattedNotes,
                endTime: endTime,
                durationSeconds: durationSeconds,
                wordCount: wordCount,
                db: db
            )
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return true
    }

    private func restoreResumedMeeting(id: Int64, snapshot: ResumeSnapshot, db: OpaquePointer?) throws {
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let wordCount = Self.countWords(in: snapshot.rawTranscript) + Self.countWords(in: manualNotes)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        do {
            try completeResumedRecovery(
                id: id,
                snapshot: snapshot,
                rawTranscript: snapshot.rawTranscript,
                formattedNotes: snapshot.formattedNotes,
                endTime: snapshot.endTime,
                durationSeconds: snapshot.durationSeconds,
                wordCount: wordCount,
                db: db
            )
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func completeResumedRecovery(
        id: Int64,
        snapshot: ResumeSnapshot,
        rawTranscript: String,
        formattedNotes: String,
        endTime: String?,
        durationSeconds: Double,
        wordCount: Int,
        db: OpaquePointer?
    ) throws {
        let sql = """
        UPDATE meetings
        SET start_time = ?, end_time = ?, duration_seconds = ?, raw_transcript = ?, formatted_notes = ?, meeting_status = ?, word_count = ?, updated_at = ?, sync_dirty = 1
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (snapshot.startTime as NSString).utf8String, -1, nil)
        bindOptionalText(endTime, at: 2, statement: statement)
        sqlite3_bind_double(statement, 3, durationSeconds)
        sqlite3_bind_text(statement, 4, (rawTranscript as NSString).utf8String, -1, nil)
        bindOptionalText(formattedNotes, at: 5, statement: statement)
        sqlite3_bind_text(statement, 6, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 7, Int32(wordCount))
        sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 9, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
        try deleteLiveTranscriptCheckpoints(meetingID: id, db: db)
        try deleteResumeSnapshot(meetingID: id, db: db)
    }

    private func combinedResumeRecoveryTranscript(prior: String, new: String) -> String {
        let trimmedPrior = prior.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return prior }
        guard !trimmedPrior.isEmpty else { return new }
        return prior + "\n\n— Resumed —\n\n" + new
    }

    private func resumedRecoveryNotes(priorNotes: String, combinedTranscript: String) -> String {
        let recoveryNotes = """
        ## Raw Transcript

        Recovered from live transcript checkpoints after a resumed meeting did not finalize normally. This fallback may be incomplete and may not include final diarization or reconciliation.

        \(combinedTranscript)
        """
        let trimmedPriorNotes = priorNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPriorNotes.isEmpty else { return recoveryNotes }
        return trimmedPriorNotes + "\n\n" + recoveryNotes
    }

    private func snapshotEndTime(startTimeString: String, fallbackEndTime: String?, durationSeconds: Double) -> String? {
        guard durationSeconds > 0,
              let startTime = ISO8601DateFormatter().date(from: startTimeString) else {
            return fallbackEndTime
        }
        return ISO8601DateFormatter().string(from: startTime.addingTimeInterval(durationSeconds))
    }

    private func deleteResumeSnapshot(meetingID: Int64, db: OpaquePointer?) throws {
        let sql = "DELETE FROM meeting_resume_snapshots WHERE meeting_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func deleteLiveTranscriptCheckpoints(meetingID: Int64, db: OpaquePointer?) throws {
        let sql = "DELETE FROM meeting_transcript_checkpoints WHERE meeting_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func deleteComputerUseTrace(dictationID: Int64, db: OpaquePointer?) throws {
        let sql = "DELETE FROM computer_use_traces WHERE dictation_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, dictationID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingSummary(
        id: Int64,
        title: String,
        formattedNotes: String,
        selectedTemplateID: String,
        selectedTemplateName: String,
        selectedTemplateKind: MeetingTemplateKind,
        selectedTemplatePrompt: String
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = """
        UPDATE meetings
        SET title = ?, formatted_notes = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?, updated_at = ?, sync_dirty = 1
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (selectedTemplateID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (selectedTemplateName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (selectedTemplateKind.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (selectedTemplatePrompt as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingTranscriptAndSummary(
        id: Int64,
        rawTranscript: String,
        formattedNotes: String,
        selectedTemplateID: String,
        selectedTemplateName: String,
        selectedTemplateKind: MeetingTemplateKind,
        selectedTemplatePrompt: String
    ) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let manualNotes = try manualNotesForMeeting(id: id, db: db)
        let wordCount = Self.countWords(in: rawTranscript) + Self.countWords(in: manualNotes)
        let sql = """
        UPDATE meetings
        SET raw_transcript = ?, formatted_notes = ?, meeting_status = ?, word_count = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?, updated_at = ?, sync_dirty = 1
        WHERE id = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (rawTranscript as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (MeetingStatus.completed.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(wordCount))
        sqlite3_bind_text(statement, 5, (selectedTemplateID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (selectedTemplateName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (selectedTemplateKind.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, (selectedTemplatePrompt as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 10, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
    }

    public func updateMeetingTitle(id: Int64, title: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET title = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingSavedRecordingPath(id: Int64, path: String?) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET saved_recording_path = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        bindOptionalText(path, at: 1, statement: statement)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    @discardableResult
    public func createFolder(name: String, parentID: Int64? = nil) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO meeting_folders (name, parent_id) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        if let parentID {
            sqlite3_bind_int64(statement, 2, parentID)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func renameFolder(id: Int64, name: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meeting_folders SET name = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func deleteFolder(id: Int64) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw lastError(db)
        }

        do {
            // Look up the deleted folder's parent so children can be reparented.
            var parentID: Int64?
            var pStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT parent_id FROM meeting_folders WHERE id = ?", -1, &pStmt, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(pStmt) }
            sqlite3_bind_int64(pStmt, 1, id)
            if sqlite3_step(pStmt) == SQLITE_ROW, sqlite3_column_type(pStmt, 0) != SQLITE_NULL {
                parentID = sqlite3_column_int64(pStmt, 0)
            }

            var childIDs: [Int64] = []
            var childStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id FROM meeting_folders WHERE parent_id = ?", -1, &childStmt, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            sqlite3_bind_int64(childStmt, 1, id)
            while sqlite3_step(childStmt) == SQLITE_ROW {
                childIDs.append(sqlite3_column_int64(childStmt, 0))
            }
            sqlite3_finalize(childStmt)

            func folderExists(_ folderID: Int64) throws -> Bool {
                var existsStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT 1 FROM meeting_folders WHERE id = ? LIMIT 1", -1, &existsStmt, nil) == SQLITE_OK else {
                    throw lastError(db)
                }
                defer { sqlite3_finalize(existsStmt) }
                sqlite3_bind_int64(existsStmt, 1, folderID)
                return sqlite3_step(existsStmt) == SQLITE_ROW
            }

            func safeReplacementParent(for childID: Int64) throws -> Int64? {
                guard let parentID,
                      parentID != id,
                      parentID != childID,
                      try folderExists(parentID)
                else {
                    return nil
                }
                let descendants = try descendantFolderIDs(of: childID, db: db)
                return descendants.contains(parentID) ? nil : parentID
            }

            var reparentStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE meeting_folders SET parent_id = ? WHERE id = ?", -1, &reparentStmt, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(reparentStmt) }
            for childID in childIDs where childID != id {
                sqlite3_reset(reparentStmt)
                sqlite3_clear_bindings(reparentStmt)
                if let replacementParent = try safeReplacementParent(for: childID) {
                    sqlite3_bind_int64(reparentStmt, 1, replacementParent)
                } else {
                    sqlite3_bind_null(reparentStmt, 1)
                }
                sqlite3_bind_int64(reparentStmt, 2, childID)
                guard sqlite3_step(reparentStmt) == SQLITE_DONE else {
                    throw lastError(db)
                }
            }

            // Move meetings in deleted folder to unfiled.
            var s1: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE meetings SET folder_id = NULL WHERE folder_id = ?", -1, &s1, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(s1) }
            sqlite3_bind_int64(s1, 1, id)
            guard sqlite3_step(s1) == SQLITE_DONE else {
                throw lastError(db)
            }

            var s2: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM meeting_folders WHERE id = ?", -1, &s2, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(s2) }
            sqlite3_bind_int64(s2, 1, id)
            guard sqlite3_step(s2) == SQLITE_DONE else {
                throw lastError(db)
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw lastError(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func listFolders() throws -> [MeetingFolder] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try listFoldersInternal(db: db)
    }

    public func moveMeeting(id: Int64, toFolder folderID: Int64?) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET folder_id = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        if let folderID {
            sqlite3_bind_int64(statement, 1, folderID)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func moveFolder(id: Int64, toParent newParentID: Int64?) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        // Prevent moving a folder into itself or one of its own descendants.
        if let newParentID {
            let descendants = try descendantFolderIDs(of: id, db: db)
            guard newParentID != id, !descendants.contains(newParentID) else { return }
        }
        let sql = "UPDATE meeting_folders SET parent_id = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        if let newParentID {
            sqlite3_bind_int64(statement, 1, newParentID)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func descendantFolderIDs(of folderID: Int64) throws -> Set<Int64> {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try descendantFolderIDs(of: folderID, db: db)
    }

    func descendantFolderIDs(of folderID: Int64, db: OpaquePointer?) throws -> Set<Int64> {
        // BFS traversal to collect all descendant folder IDs.
        var result: Set<Int64> = []
        var queue: [Int64] = [folderID]
        let sql = "SELECT id FROM meeting_folders WHERE parent_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        while !queue.isEmpty {
            let current = queue.removeFirst()
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, current)
            while sqlite3_step(statement) == SQLITE_ROW {
                let childID = sqlite3_column_int64(statement, 0)
                if childID != folderID, result.insert(childID).inserted {
                    queue.append(childID)
                }
            }
        }
        return result
    }

    public func textRecordsNeedingSync(limit: Int = 200) throws -> [SyncTextRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try ensureCloudRecordNames(db: db)

        let boundedLimit = max(limit, 1)
        let dictationShare = (boundedLimit + 1) / 2
        let meetingShare = boundedLimit - dictationShare

        var dictations = try dirtyDictationTextRecords(limit: dictationShare, offset: 0, db: db)
        var meetings = try dirtyMeetingTextRecords(limit: meetingShare, offset: 0, db: db)

        var remaining = boundedLimit - dictations.count - meetings.count
        if remaining > 0, dictations.count == dictationShare {
            let additional = try dirtyDictationTextRecords(limit: remaining, offset: dictationShare, db: db)
            dictations.append(contentsOf: additional)
            remaining -= additional.count
        }
        if remaining > 0, meetings.count == meetingShare {
            let additional = try dirtyMeetingTextRecords(limit: remaining, offset: meetingShare, db: db)
            meetings.append(contentsOf: additional)
        }

        return Array((dictations + meetings).prefix(boundedLimit))
    }

    private func dirtyDictationTextRecords(
        limit: Int,
        offset: Int,
        db: OpaquePointer?
    ) throws -> [SyncTextRecord] {
        guard limit > 0 else { return [] }
        var records: [SyncTextRecord] = []
        let dictationSQL = """
        SELECT cloud_record_name, raw_text, app_context, timestamp, started_at, ended_at,
               duration_seconds, word_count, source, updated_at, deleted_at, cloud_change_tag
        FROM dictations
        WHERE sync_dirty = 1 AND cloud_record_name IS NOT NULL
        ORDER BY updated_at DESC, id DESC
        LIMIT ?
        OFFSET ?
        """
        var dictationStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, dictationSQL, -1, &dictationStatement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(dictationStatement) }
        sqlite3_bind_int(dictationStatement, 1, Int32(limit))
        sqlite3_bind_int(dictationStatement, 2, Int32(max(offset, 0)))
        while sqlite3_step(dictationStatement) == SQLITE_ROW {
            guard let record = makeSyncDictationRecord(dictationStatement) else { continue }
            records.append(record)
        }
        return records
    }

    private func dirtyMeetingTextRecords(
        limit: Int,
        offset: Int,
        db: OpaquePointer?
    ) throws -> [SyncTextRecord] {
        guard limit > 0 else { return [] }
        var records: [SyncTextRecord] = []
        let meetingSQL = """
        SELECT m.cloud_record_name, m.title, m.raw_transcript, m.formatted_notes, m.manual_notes,
               m.start_time, m.duration_seconds, m.word_count, m.source, m.meeting_status,
               m.updated_at, m.deleted_at, m.cloud_change_tag,
               COALESCE(m.follow_up_to_record_name, predecessor.cloud_record_name)
        FROM meetings AS m
        LEFT JOIN meetings AS predecessor ON predecessor.id = m.follow_up_to_id
        WHERE m.sync_dirty = 1 AND m.cloud_record_name IS NOT NULL
          AND m.meeting_status NOT IN (?, ?)
        ORDER BY m.updated_at DESC, m.id DESC
        LIMIT ?
        OFFSET ?
        """
        var meetingStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, meetingSQL, -1, &meetingStatement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(meetingStatement) }
        sqlite3_bind_text(meetingStatement, 1, (MeetingStatus.recording.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(meetingStatement, 2, (MeetingStatus.processing.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(meetingStatement, 3, Int32(limit))
        sqlite3_bind_int(meetingStatement, 4, Int32(max(offset, 0)))
        while sqlite3_step(meetingStatement) == SQLITE_ROW {
            guard let record = makeSyncMeetingRecord(meetingStatement) else { continue }
            records.append(record)
        }
        return records
    }

    public func hasTextRecordsNeedingSync() throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try ensureCloudRecordNames(db: db)

        if try hasDirtyTextRecords(table: "dictations", db: db) {
            return true
        }
        return try hasDirtyMeetingTextRecords(db: db)
    }

    public func textRecordsForSyncMigration(
        kind: SyncTextRecordKind,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [SyncTextRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try ensureCloudRecordNames(db: db)

        let boundedLimit = max(limit, 1)
        let boundedOffset = max(offset, 0)

        switch kind {
        case .dictation:
            return try textDictationRecordsForSyncMigration(
                limit: boundedLimit,
                offset: boundedOffset,
                db: db
            )
        case .meeting:
            return try textMeetingRecordsForSyncMigration(
                limit: boundedLimit,
                offset: boundedOffset,
                db: db
            )
        }
    }

    private func textDictationRecordsForSyncMigration(
        limit: Int,
        offset: Int,
        db: OpaquePointer?
    ) throws -> [SyncTextRecord] {
        var records: [SyncTextRecord] = []
        let dictationSQL = """
        SELECT cloud_record_name, raw_text, app_context, timestamp, started_at, ended_at,
               duration_seconds, word_count, source, updated_at, deleted_at, cloud_change_tag
        FROM dictations
        WHERE cloud_record_name IS NOT NULL
        ORDER BY updated_at DESC, id DESC
        LIMIT ?
        OFFSET ?
        """
        var dictationStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, dictationSQL, -1, &dictationStatement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(dictationStatement) }
        sqlite3_bind_int(dictationStatement, 1, Int32(limit))
        sqlite3_bind_int(dictationStatement, 2, Int32(offset))
        while sqlite3_step(dictationStatement) == SQLITE_ROW {
            guard let record = makeSyncDictationRecord(dictationStatement) else { continue }
            records.append(record)
        }
        return records
    }

    private func textMeetingRecordsForSyncMigration(
        limit: Int,
        offset: Int,
        db: OpaquePointer?
    ) throws -> [SyncTextRecord] {
        var records: [SyncTextRecord] = []
        let meetingSQL = """
        SELECT m.cloud_record_name, m.title, m.raw_transcript, m.formatted_notes, m.manual_notes,
               m.start_time, m.duration_seconds, m.word_count, m.source, m.meeting_status,
               m.updated_at, m.deleted_at, m.cloud_change_tag,
               COALESCE(m.follow_up_to_record_name, predecessor.cloud_record_name)
        FROM meetings AS m
        LEFT JOIN meetings AS predecessor ON predecessor.id = m.follow_up_to_id
        WHERE m.cloud_record_name IS NOT NULL
        ORDER BY m.updated_at DESC, m.id DESC
        LIMIT ?
        OFFSET ?
        """
        var meetingStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, meetingSQL, -1, &meetingStatement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(meetingStatement) }
        sqlite3_bind_int(meetingStatement, 1, Int32(limit))
        sqlite3_bind_int(meetingStatement, 2, Int32(offset))
        while sqlite3_step(meetingStatement) == SQLITE_ROW {
            guard let record = makeSyncMeetingRecord(meetingStatement) else { continue }
            records.append(record)
        }
        return records
    }

    private func hasDirtyTextRecords(table: String, db: OpaquePointer?) throws -> Bool {
        let sql = """
        SELECT 1
        FROM \(table)
        WHERE sync_dirty = 1 AND cloud_record_name IS NOT NULL
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func hasDirtyMeetingTextRecords(db: OpaquePointer?) throws -> Bool {
        let sql = """
        SELECT 1
        FROM meetings
        WHERE sync_dirty = 1
          AND cloud_record_name IS NOT NULL
          AND meeting_status NOT IN (?, ?)
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (MeetingStatus.recording.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (MeetingStatus.processing.rawValue as NSString).utf8String, -1, nil)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    @discardableResult
    public func upsertSyncedTextRecord(_ record: SyncTextRecord) throws -> Bool {
        let applied = try upsertSyncedTextRecords([record])
        return !applied.isEmpty
    }

    @discardableResult
    public func upsertSyncedTextRecords(_ records: [SyncTextRecord]) throws -> [SyncTextRecord] {
        guard !records.isEmpty else { return [] }

        let db = try openDatabase()
        defer { sqlite3_close(db) }

        try exec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            var applied: [SyncTextRecord] = []
            var sawMeeting = false
            for record in records {
                let changed: Bool
                switch record.kind {
                case .dictation:
                    changed = try upsertSyncedDictation(record, db: db)
                case .meeting:
                    sawMeeting = true
                    changed = try upsertSyncedMeeting(record, db: db)
                }
                if changed {
                    applied.append(record)
                }
            }
            if sawMeeting {
                try reconcileFollowUpLinks(db: db)
            }
            try exec("COMMIT", db: db)
            return applied
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func markTextRecordSynced(
        kind: SyncTextRecordKind,
        recordName: String,
        changeTag: String?,
        recordUpdatedAt: Date,
        syncedAt: Date = Date()
    ) throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let table = kind == .dictation ? "dictations" : "meetings"
        let sql = """
        UPDATE \(table)
        SET cloud_change_tag = ?, last_synced_at = ?, sync_dirty = 0
        WHERE cloud_record_name = ? AND updated_at <= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        bindOptionalText(changeTag, at: 1, statement: statement)
        sqlite3_bind_double(statement, 2, syncedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, (recordName as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 4, recordUpdatedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_changes(db) > 0
    }

    public func databasePath() -> URL {
        databaseURL
    }

    @discardableResult
    public func purgeSoftDeletedTextRecords(
        olderThan retentionInterval: TimeInterval = DictationStore.defaultTombstoneRetentionInterval,
        now: Date = Date()
    ) throws -> (dictations: Int, meetings: Int) {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        return try purgeSoftDeletedTextRecords(olderThan: retentionInterval, now: now, db: db)
    }

    public static func countWords(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func purgeSoftDeletedTextRecords(
        olderThan retentionInterval: TimeInterval,
        now: Date = Date(),
        db: OpaquePointer?
    ) throws -> (dictations: Int, meetings: Int) {
        let cutoff = now.addingTimeInterval(-max(retentionInterval, 0)).timeIntervalSince1970
        try exec("BEGIN IMMEDIATE", db: db)
        do {
            let dictations = try purgeSoftDeletedRows(table: "dictations", deletedBefore: cutoff, db: db)
            try detachFollowUpSuccessorsOfPurgeableMeetings(deletedBefore: cutoff, db: db)
            let meetings = try purgeSoftDeletedRows(table: "meetings", deletedBefore: cutoff, db: db)
            try exec("COMMIT", db: db)
            return (dictations, meetings)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func detachFollowUpSuccessors(of predecessorID: Int64, db: OpaquePointer?) throws {
        let sql = """
        UPDATE meetings
        SET follow_up_to_id = NULL,
            follow_up_to_record_name = NULL,
            updated_at = ?,
            sync_dirty = 1
        WHERE (
            follow_up_to_id = ?
            OR follow_up_to_record_name = (
                SELECT cloud_record_name
                FROM meetings
                WHERE id = ?
                  AND cloud_record_name IS NOT NULL
                  AND cloud_record_name != ''
                LIMIT 1
            )
        )
          AND deleted_at IS NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, predecessorID)
        sqlite3_bind_int64(statement, 3, predecessorID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func detachFollowUpSuccessorsOfPurgeableMeetings(
        deletedBefore cutoff: TimeInterval,
        db: OpaquePointer?
    ) throws {
        let sql = """
        UPDATE meetings
        SET follow_up_to_id = NULL,
            follow_up_to_record_name = NULL,
            updated_at = ?,
            sync_dirty = 1
        WHERE deleted_at IS NULL
          AND (
              follow_up_to_id IN (
                  SELECT id
                  FROM meetings
                  WHERE deleted_at IS NOT NULL
                    AND deleted_at <= ?
                    AND (sync_dirty = 0 OR cloud_record_name IS NULL OR cloud_record_name = '')
              )
              OR follow_up_to_record_name IN (
                  SELECT cloud_record_name
                  FROM meetings
                  WHERE deleted_at IS NOT NULL
                    AND deleted_at <= ?
                    AND cloud_record_name IS NOT NULL
                    AND cloud_record_name != ''
                    AND sync_dirty = 0
              )
          )
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, cutoff)
        sqlite3_bind_double(statement, 3, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func purgeSoftDeletedRows(
        table: String,
        deletedBefore cutoff: TimeInterval,
        db: OpaquePointer?
    ) throws -> Int {
        let sql = """
        DELETE FROM \(table)
        WHERE deleted_at IS NOT NULL
          AND deleted_at <= ?
          AND (sync_dirty = 0 OR cloud_record_name IS NULL OR cloud_record_name = '')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return Int(sqlite3_changes(db))
    }

    private func ensureCloudRecordNames(db: OpaquePointer?) throws {
        try ensureCloudRecordNames(table: "dictations", prefix: "dictation", db: db)
        try ensureCloudRecordNames(table: "meetings", prefix: "meeting", db: db)
        try reconcileFollowUpLinks(db: db)
    }

    private func ensureCloudRecordNames(table: String, prefix: String, db: OpaquePointer?) throws {
        let sql = """
        SELECT id
        FROM \(table)
        WHERE (cloud_record_name IS NULL OR cloud_record_name = '')
          AND deleted_at IS NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
        }

        for id in ids {
            let recordName = "\(prefix)-\(UUID().uuidString)"
            let updateSQL = """
            UPDATE \(table)
            SET cloud_record_name = ?,
                updated_at = CASE WHEN updated_at = 0 THEN ? ELSE updated_at END,
                sync_dirty = 1
            WHERE id = ?
            """
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &update, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(update) }
            sqlite3_bind_text(update, 1, (recordName as NSString).utf8String, -1, nil)
            sqlite3_bind_double(update, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(update, 3, id)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw lastError(db)
            }
        }
    }

    private func reconcileFollowUpLinks(db: OpaquePointer?) throws {
        let now = Date().timeIntervalSince1970
        let fillRecordNameSQL = """
        UPDATE meetings AS child
        SET follow_up_to_record_name = (
                SELECT predecessor.cloud_record_name
                FROM meetings AS predecessor
                WHERE predecessor.id = child.follow_up_to_id
                LIMIT 1
            ),
            updated_at = ?,
            sync_dirty = 1
        WHERE child.deleted_at IS NULL
          AND child.follow_up_to_id IS NOT NULL
          AND (child.follow_up_to_record_name IS NULL OR child.follow_up_to_record_name = '')
          AND EXISTS (
              SELECT 1
              FROM meetings AS predecessor
              WHERE predecessor.id = child.follow_up_to_id
                AND predecessor.cloud_record_name IS NOT NULL
                AND predecessor.cloud_record_name != ''
          )
        """
        var fillRecordName: OpaquePointer?
        guard sqlite3_prepare_v2(db, fillRecordNameSQL, -1, &fillRecordName, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(fillRecordName) }
        sqlite3_bind_double(fillRecordName, 1, now)
        guard sqlite3_step(fillRecordName) == SQLITE_DONE else {
            throw lastError(db)
        }

        let fillLocalIDSQL = """
        UPDATE meetings AS child
        SET follow_up_to_id = (
                SELECT predecessor.id
                FROM meetings AS predecessor
                WHERE predecessor.cloud_record_name = child.follow_up_to_record_name
                  AND predecessor.deleted_at IS NULL
                  AND predecessor.id != child.id
                LIMIT 1
            )
        WHERE child.deleted_at IS NULL
          AND child.follow_up_to_record_name IS NOT NULL
          AND child.follow_up_to_record_name != ''
          AND (
              child.follow_up_to_id IS NULL
              OR NOT EXISTS (
                  SELECT 1
                  FROM meetings AS current_predecessor
                  WHERE current_predecessor.id = child.follow_up_to_id
                    AND current_predecessor.deleted_at IS NULL
              )
          )
          AND EXISTS (
              SELECT 1
              FROM meetings AS predecessor
              WHERE predecessor.cloud_record_name = child.follow_up_to_record_name
                AND predecessor.deleted_at IS NULL
                AND predecessor.id != child.id
          )
        """
        var fillLocalID: OpaquePointer?
        guard sqlite3_prepare_v2(db, fillLocalIDSQL, -1, &fillLocalID, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(fillLocalID) }
        guard sqlite3_step(fillLocalID) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    private func makeSyncDictationRecord(_ statement: OpaquePointer?) -> SyncTextRecord? {
        guard let recordName = optionalStringColumn(statement, index: 0), !recordName.isEmpty else { return nil }
        let timestamp = stringColumn(statement, index: 3)
        let createdAt = parseISODate(timestamp) ?? Date()
        let startedAt = parseOptionalISODate(statement, index: 4)
        let endedAt = parseOptionalISODate(statement, index: 5)
        let updatedAt = dateFromUnixColumn(statement, index: 9) ?? endedAt ?? createdAt
        let localSource = normalizedSourceColumn(from: statement, index: 8)
        let source = cloudSyncDeviceSource(localSource)
        return SyncTextRecord(
            id: recordName,
            kind: .dictation,
            text: stringColumn(statement, index: 1),
            source: source,
            localSource: localSource,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: sqlite3_column_double(statement, 6),
            wordCount: Int(sqlite3_column_int(statement, 7)),
            isDeleted: sqlite3_column_type(statement, 10) != SQLITE_NULL,
            cloudChangeTag: optionalStringColumn(statement, index: 11)
        )
    }

    private func makeSyncMeetingRecord(_ statement: OpaquePointer?) -> SyncTextRecord? {
        guard let recordName = optionalStringColumn(statement, index: 0), !recordName.isEmpty else { return nil }
        let startTime = stringColumn(statement, index: 5)
        let createdAt = parseISODate(startTime) ?? Date()
        let duration = sqlite3_column_double(statement, 6)
        let updatedAt = dateFromUnixColumn(statement, index: 10) ?? createdAt
        let rawTranscript = stringColumn(statement, index: 2)
        let localSource = normalizedSourceColumn(from: statement, index: 8)
        let source = cloudSyncDeviceSource(localSource)
        let meetingStatus = MeetingStatus(rawValue: stringColumn(statement, index: 9)) ?? .completed
        return SyncTextRecord(
            id: recordName,
            kind: .meeting,
            title: stringColumn(statement, index: 1),
            text: rawTranscript,
            summaryText: optionalStringColumn(statement, index: 3),
            manualNotes: optionalStringColumn(statement, index: 4),
            source: source,
            localSource: localSource,
            meetingStatus: meetingStatus,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: createdAt,
            endedAt: createdAt.addingTimeInterval(duration),
            durationSeconds: duration,
            wordCount: Int(sqlite3_column_int(statement, 7)),
            isDeleted: sqlite3_column_type(statement, 11) != SQLITE_NULL,
            cloudChangeTag: optionalStringColumn(statement, index: 12),
            followUpToRecordName: optionalStringColumn(statement, index: 13)
        )
    }

    private func normalizedSourceColumn(from statement: OpaquePointer?, index: Int32) -> String? {
        let source = optionalStringColumn(statement, index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return source?.isEmpty == true ? nil : source
    }

    private func cloudSyncDeviceSource(_ localSource: String?) -> String {
        switch localSource {
        case "ios", "iphone":
            return "ios"
        case "macos", "mac":
            return "macos"
        default:
            return "macos"
        }
    }

    private func syncImportSource(for record: SyncTextRecord, fallback: String) -> String {
        if let localSource = normalizedSyncLocalSource(record.localSource, kind: record.kind),
           record.source == "macos" || isMacGeneratedCloudRecordName(record.id, prefix: record.kind.rawValue) {
            return localSource
        }

        switch record.kind {
        case .dictation where isMacGeneratedCloudRecordName(record.id, prefix: "dictation"):
            return "dictation"
        case .meeting where isMacGeneratedCloudRecordName(record.id, prefix: "meeting"):
            return MeetingSource.meeting.rawValue
        default:
            return record.source ?? fallback
        }
    }

    private func normalizedSyncLocalSource(_ source: String?, kind: SyncTextRecordKind) -> String? {
        let normalized = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        switch kind {
        case .dictation:
            return normalized
        case .meeting:
            return MeetingSource(rawValue: normalized)?.rawValue
        }
    }

    private func repairLegacyMacOriginSources(db: OpaquePointer?) throws {
        try repairLegacyMacOriginSource(
            table: "dictations",
            source: "dictation",
            recordPrefix: "dictation",
            db: db
        )
        try repairLegacyMacOriginSource(
            table: "meetings",
            source: MeetingSource.meeting.rawValue,
            recordPrefix: "meeting",
            db: db
        )
    }

    private func repairLegacyMacOriginSource(
        table: String,
        source: String,
        recordPrefix: String,
        db: OpaquePointer?
    ) throws {
        let selectSQL = """
        SELECT id, cloud_record_name
        FROM \(table)
        WHERE lower(trim(source)) IN ('ios', 'iphone')
          AND cloud_record_name LIKE ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, ("\(recordPrefix)-%" as NSString).utf8String, -1, nil)

        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recordName = stringColumn(statement, index: 1)
            guard isMacGeneratedCloudRecordName(recordName, prefix: recordPrefix) else { continue }
            ids.append(sqlite3_column_int64(statement, 0))
        }

        let updateSQL = """
        UPDATE \(table)
        SET source = ?,
            sync_dirty = 1
        WHERE id = ?
        """
        for id in ids {
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &update, nil) == SQLITE_OK else {
                throw lastError(db)
            }
            defer { sqlite3_finalize(update) }
            sqlite3_bind_text(update, 1, (source as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(update, 2, id)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw lastError(db)
            }
        }
    }

    private func isMacGeneratedCloudRecordName(_ recordName: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard recordName.hasPrefix(marker) else { return false }
        let uuidPart = String(recordName.dropFirst(marker.count))
        return UUID(uuidString: uuidPart) != nil
    }

    private func upsertSyncedDictation(_ record: SyncTextRecord, db: OpaquePointer?) throws -> Bool {
        if let localUpdatedAt = try localUpdatedAt(table: "dictations", recordName: record.id, db: db),
           localUpdatedAt > record.updatedAt.timeIntervalSince1970 {
            return false
        }

        let sql = """
        INSERT INTO dictations (
            timestamp, duration_seconds, raw_text, app_context, word_count, source,
            started_at, ended_at, updated_at, deleted_at, cloud_record_name,
            cloud_change_tag, last_synced_at, sync_dirty
        )
        VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(cloud_record_name) DO UPDATE SET
            timestamp = excluded.timestamp,
            duration_seconds = excluded.duration_seconds,
            raw_text = excluded.raw_text,
            word_count = excluded.word_count,
            source = excluded.source,
            started_at = excluded.started_at,
            ended_at = excluded.ended_at,
            updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at,
            cloud_change_tag = excluded.cloud_change_tag,
            last_synced_at = excluded.last_synced_at,
            sync_dirty = 0
        WHERE excluded.updated_at > dictations.updated_at
           OR (excluded.updated_at = dictations.updated_at AND dictations.sync_dirty = 0)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let timestamp = record.endedAt ?? record.createdAt
        sqlite3_bind_text(statement, 1, (formatISODate(timestamp) as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, record.durationSeconds)
        sqlite3_bind_text(statement, 3, (record.text as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(record.wordCount))
        sqlite3_bind_text(statement, 5, (syncImportSource(for: record, fallback: "icloud") as NSString).utf8String, -1, nil)
        bindOptionalText(record.startedAt.map(formatISODate), at: 6, statement: statement)
        bindOptionalText(record.endedAt.map(formatISODate), at: 7, statement: statement)
        sqlite3_bind_double(statement, 8, record.updatedAt.timeIntervalSince1970)
        bindOptionalDouble(record.isDeleted ? record.updatedAt.timeIntervalSince1970 : nil, at: 9, statement: statement)
        sqlite3_bind_text(statement, 10, (record.id as NSString).utf8String, -1, nil)
        bindOptionalText(record.cloudChangeTag, at: 11, statement: statement)
        sqlite3_bind_double(statement, 12, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_changes(db) > 0
    }

    private func upsertSyncedMeeting(_ record: SyncTextRecord, db: OpaquePointer?) throws -> Bool {
        if let localUpdatedAt = try localUpdatedAt(table: "meetings", recordName: record.id, db: db),
           localUpdatedAt > record.updatedAt.timeIntervalSince1970 {
            return false
        }

        let start = record.startedAt ?? record.createdAt
        let end = record.endedAt ?? start.addingTimeInterval(record.durationSeconds)
        let followUpRecordName = normalizedFollowUpRecordName(record.followUpToRecordName, recordName: record.id)
        let sql = """
        INSERT INTO meetings (
            title, calendar_event_id, start_time, end_time, duration_seconds,
            raw_transcript, formatted_notes, mic_audio_path, system_audio_path,
            saved_recording_path, meeting_status, manual_notes, word_count, source,
            follow_up_to_id, follow_up_to_record_name, updated_at, deleted_at, cloud_record_name, cloud_change_tag,
            last_synced_at, sync_dirty
        )
        VALUES (?, NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?,
                (SELECT id FROM meetings WHERE cloud_record_name = ? AND deleted_at IS NULL LIMIT 1),
                ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(cloud_record_name) DO UPDATE SET
            title = excluded.title,
            start_time = excluded.start_time,
            end_time = excluded.end_time,
            duration_seconds = excluded.duration_seconds,
            raw_transcript = excluded.raw_transcript,
            formatted_notes = excluded.formatted_notes,
            meeting_status = excluded.meeting_status,
            manual_notes = excluded.manual_notes,
            word_count = excluded.word_count,
            source = excluded.source,
            follow_up_to_id = excluded.follow_up_to_id,
            follow_up_to_record_name = excluded.follow_up_to_record_name,
            updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at,
            cloud_change_tag = excluded.cloud_change_tag,
            last_synced_at = excluded.last_synced_at,
            sync_dirty = 0
        WHERE excluded.updated_at > meetings.updated_at
           OR (excluded.updated_at = meetings.updated_at AND meetings.sync_dirty = 0)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ((record.title ?? "Meeting") as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formatISODate(start) as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (formatISODate(end) as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 4, record.durationSeconds)
        let rawTranscript = record.speakerTranscript ?? record.text
        sqlite3_bind_text(statement, 5, (rawTranscript as NSString).utf8String, -1, nil)
        bindOptionalText(record.summaryText, at: 6, statement: statement)
        let meetingStatus = record.meetingStatus ?? .completed
        sqlite3_bind_text(statement, 7, (meetingStatus.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, ((record.manualNotes ?? "") as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 9, Int32(record.wordCount))
        sqlite3_bind_text(statement, 10, (syncImportSource(for: record, fallback: MeetingSource.meeting.rawValue) as NSString).utf8String, -1, nil)
        bindOptionalText(followUpRecordName, at: 11, statement: statement)
        bindOptionalText(followUpRecordName, at: 12, statement: statement)
        sqlite3_bind_double(statement, 13, record.updatedAt.timeIntervalSince1970)
        bindOptionalDouble(record.isDeleted ? record.updatedAt.timeIntervalSince1970 : nil, at: 14, statement: statement)
        sqlite3_bind_text(statement, 15, (record.id as NSString).utf8String, -1, nil)
        bindOptionalText(record.cloudChangeTag, at: 16, statement: statement)
        sqlite3_bind_double(statement, 17, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_changes(db) > 0
    }

    private func normalizedFollowUpRecordName(_ followUpRecordName: String?, recordName: String) -> String? {
        let trimmed = followUpRecordName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != recordName else { return nil }
        return trimmed
    }

    private func localUpdatedAt(table: String, recordName: String, db: OpaquePointer?) throws -> Double? {
        let sql = "SELECT updated_at FROM \(table) WHERE cloud_record_name = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (recordName as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    private func makeDictationRecord(_ statement: OpaquePointer?) -> DictationRecord {
        let trace: ComputerUseTraceRecord?
        if sqlite3_column_type(statement, 7) == SQLITE_NULL {
            trace = nil
        } else {
            let traceJSON = stringColumn(statement, index: 10)
            let events = (try? JSONDecoder().decode(
                [ComputerUseTraceEvent].self,
                from: Data(traceJSON.utf8)
            )) ?? []
            trace = ComputerUseTraceRecord(
                id: sqlite3_column_int64(statement, 7),
                dictationID: sqlite3_column_int64(statement, 0),
                finalStatus: stringColumn(statement, index: 8),
                finalMessage: stringColumn(statement, index: 9),
                events: events,
                createdAt: stringColumn(statement, index: 11)
            )
        }

        return DictationRecord(
            id: sqlite3_column_int64(statement, 0),
            timestamp: stringColumn(statement, index: 1),
            durationSeconds: sqlite3_column_double(statement, 2),
            rawText: stringColumn(statement, index: 3),
            appContext: stringColumn(statement, index: 4),
            wordCount: Int(sqlite3_column_int(statement, 5)),
            source: stringColumn(statement, index: 6),
            computerUseTrace: trace
        )
    }

    private func makeMeetingRecord(_ statement: OpaquePointer?) -> MeetingRecord {
        let folderID: Int64? = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 7)
        let calendarEventID: String? = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : stringColumn(statement, index: 8)
        let micAudioPath: String? = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : stringColumn(statement, index: 9)
        let systemAudioPath: String? = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : stringColumn(statement, index: 10)
        let savedRecordingPath: String? = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : stringColumn(statement, index: 11)
        let status = MeetingStatus(rawValue: stringColumn(statement, index: 12)) ?? .completed
        let manualNotes = stringColumn(statement, index: 13)
        let selectedTemplateID: String? = sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : stringColumn(statement, index: 14)
        let selectedTemplateName: String? = sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : stringColumn(statement, index: 15)
        let selectedTemplateKind: MeetingTemplateKind? = sqlite3_column_type(statement, 16) == SQLITE_NULL
            ? nil
            : MeetingTemplateKind(rawValue: stringColumn(statement, index: 16))
        let selectedTemplatePrompt: String? = sqlite3_column_type(statement, 17) == SQLITE_NULL ? nil : stringColumn(statement, index: 17)
        let source = MeetingSource(rawValue: stringColumn(statement, index: 18)) ?? .meeting
        let followUpToID: Int64? = sqlite3_column_type(statement, 19) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 19)
        let followUpToRecordName = optionalStringColumn(statement, index: 20)
        return MeetingRecord(
            id: sqlite3_column_int64(statement, 0),
            title: stringColumn(statement, index: 1),
            startTime: stringColumn(statement, index: 2),
            durationSeconds: sqlite3_column_double(statement, 3),
            rawTranscript: stringColumn(statement, index: 4),
            formattedNotes: stringColumn(statement, index: 5),
            wordCount: Int(sqlite3_column_int(statement, 6)),
            folderID: folderID,
            calendarEventID: calendarEventID,
            micAudioPath: micAudioPath,
            systemAudioPath: systemAudioPath,
            savedRecordingPath: savedRecordingPath,
            status: status,
            manualNotes: manualNotes,
            selectedTemplateID: selectedTemplateID,
            selectedTemplateName: selectedTemplateName,
            selectedTemplateKind: selectedTemplateKind,
            selectedTemplatePrompt: selectedTemplatePrompt,
            source: source,
            followUpToID: followUpToID,
            followUpToRecordName: followUpToRecordName
        )
    }

    private func openDatabase() throws -> OpaquePointer? {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw lastError(db)
        }
        if sqlite3_busy_timeout(db, 5_000) != SQLITE_OK {
            throw lastError(db)
        }
        if sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil) != SQLITE_OK {
            throw lastError(db)
        }
        if sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) != SQLITE_OK {
            throw lastError(db)
        }
        return db
    }

    private func exec(_ sql: String, db: OpaquePointer?) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw lastError(db)
        }
    }

    private func lastError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "MuesliDB",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func optionalStringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    private func bindOptionalText(_ value: String?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalDouble(_ value: Double?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func parseOptionalISODate(_ statement: OpaquePointer?, index: Int32) -> Date? {
        optionalStringColumn(statement, index: index).flatMap(parseISODate)
    }

    private func parseISODate(_ value: String) -> Date? {
        Self.iso8601FormatterLock.lock()
        defer { Self.iso8601FormatterLock.unlock() }
        return Self.iso8601Formatter.date(from: value)
    }

    private func formatISODate(_ date: Date) -> String {
        Self.iso8601FormatterLock.lock()
        defer { Self.iso8601FormatterLock.unlock() }
        return Self.iso8601Formatter.string(from: date)
    }

    private func dateFromUnixColumn(_ statement: OpaquePointer?, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, index)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private func dictationStreaks(db: OpaquePointer?) throws -> (current: Int, longest: Int) {
        let sql = """
        SELECT DISTINCT date(timestamp) AS used_day
        FROM dictations
        WHERE deleted_at IS NULL
        ORDER BY used_day ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        var days: [Date] = []
        let formatter = ISO8601DateFormatter()
        while sqlite3_step(statement) == SQLITE_ROW {
            let raw = stringColumn(statement, index: 0)
            if let date = formatter.date(from: "\(raw)T00:00:00Z") {
                days.append(date)
            }
        }
        return Self.computeStreak(days: days)
    }

    private static func computeStreak(days: [Date]) -> (current: Int, longest: Int) {
        let calendar = Calendar.current
        let normalized = days
            .map { calendar.startOfDay(for: $0) }
            .sorted()
        guard !normalized.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for index in 1..<normalized.count {
            let previous = normalized[index - 1]
            let current = normalized[index]
            if let next = calendar.date(byAdding: .day, value: 1, to: previous), calendar.isDate(next, inSameDayAs: current) {
                run += 1
            } else if !calendar.isDate(previous, inSameDayAs: current) {
                longest = max(longest, run)
                run = 1
            }
        }
        longest = max(longest, run)

        let today = calendar.startOfDay(for: Date())
        let anchor: Date
        if calendar.isDate(normalized.last!, inSameDayAs: today) {
            anchor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  calendar.isDate(normalized.last!, inSameDayAs: yesterday) {
            anchor = yesterday
        } else {
            return (0, longest)
        }

        var current = 0
        var cursor = anchor
        let set = Set(normalized)
        while set.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }
}

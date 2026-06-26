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
    id, title, start_time, duration_seconds, raw_transcript, formatted_notes, word_count, folder_id, calendar_event_id, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source
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
        let _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_dictations_cloud_record_name", nil, nil, nil)
        let _ = sqlite3_exec(db, "DROP INDEX IF EXISTS idx_meetings_cloud_record_name", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_dictations_cloud_record_name ON dictations(cloud_record_name)", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_meetings_cloud_record_name ON meetings(cloud_record_name)", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_dictations_sync_dirty ON dictations(updated_at DESC) WHERE sync_dirty = 1", nil, nil, nil)
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_meetings_sync_dirty ON meetings(updated_at DESC) WHERE sync_dirty = 1", nil, nil, nil)
        try repairLegacyMacOriginSources(db: db)
        _ = try purgeSoftDeletedTextRecords(olderThan: Self.defaultTombstoneRetentionInterval, db: db)
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

    public func recentDictations(limit: Int = 10, offset: Int = 0, fromDate: String? = nil, toDate: String? = nil) throws -> [DictationRecord] {
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

    public func meetingCounts() throws -> (total: Int, byFolder: [Int64: Int], directByFolder: [Int64: Int]) {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var total = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meetings WHERE deleted_at IS NULL", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { total = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        } else {
            fputs("[muesli-store] meetingCounts: failed to prepare total count query\n", stderr)
        }

        // Direct counts per folder.
        var directByFolder: [Int64: Int] = [:]
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT folder_id, COUNT(*) FROM meetings WHERE folder_id IS NOT NULL AND deleted_at IS NULL GROUP BY folder_id", -1, &stmt2, nil) == SQLITE_OK {
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

    public func recentMeetings(limit: Int? = nil, folderID: Int64? = nil) throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

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
                WHERE folder_id IN (SELECT id FROM folder_tree) AND deleted_at IS NULL
                ORDER BY id DESC
                """
        } else {
            sql = "SELECT \(Self.meetingColumns) FROM meetings WHERE deleted_at IS NULL ORDER BY id DESC"
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
        selectedTemplatePrompt: String? = nil
    ) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO meetings
        (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, word_count, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source, updated_at, sync_dirty)
        VALUES (?, ?, ?, NULL, 0, '', '', NULL, NULL, NULL, ?, '', 0, ?, ?, ?, ?, 'meeting', ?, 1)
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

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_last_insert_rowid(db)
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
        let durationSeconds = max(endTime.timeIntervalSince(startTime), 0)
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
        SELECT cloud_record_name, title, raw_transcript, formatted_notes, manual_notes,
               start_time, duration_seconds, word_count, source, meeting_status,
               updated_at, deleted_at, cloud_change_tag
        FROM meetings
        WHERE sync_dirty = 1 AND cloud_record_name IS NOT NULL
        ORDER BY updated_at DESC, id DESC
        LIMIT ?
        OFFSET ?
        """
        var meetingStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, meetingSQL, -1, &meetingStatement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(meetingStatement) }
        sqlite3_bind_int(meetingStatement, 1, Int32(limit))
        sqlite3_bind_int(meetingStatement, 2, Int32(max(offset, 0)))
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
        return try hasDirtyTextRecords(table: "meetings", db: db)
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
        SELECT cloud_record_name, title, raw_transcript, formatted_notes, manual_notes,
               start_time, duration_seconds, word_count, source, meeting_status,
               updated_at, deleted_at, cloud_change_tag
        FROM meetings
        WHERE cloud_record_name IS NOT NULL
        ORDER BY updated_at DESC, id DESC
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

    @discardableResult
    public func upsertSyncedTextRecord(_ record: SyncTextRecord) throws -> Bool {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        switch record.kind {
        case .dictation:
            return try upsertSyncedDictation(record, db: db)
        case .meeting:
            return try upsertSyncedMeeting(record, db: db)
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
        let dictations = try purgeSoftDeletedRows(table: "dictations", deletedBefore: cutoff, db: db)
        let meetings = try purgeSoftDeletedRows(table: "meetings", deletedBefore: cutoff, db: db)
        return (dictations, meetings)
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
            cloudChangeTag: optionalStringColumn(statement, index: 12)
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
        let sql = """
        INSERT INTO meetings (
            title, calendar_event_id, start_time, end_time, duration_seconds,
            raw_transcript, formatted_notes, mic_audio_path, system_audio_path,
            saved_recording_path, meeting_status, manual_notes, word_count, source,
            updated_at, deleted_at, cloud_record_name, cloud_change_tag,
            last_synced_at, sync_dirty
        )
        VALUES (?, NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
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
        sqlite3_bind_double(statement, 11, record.updatedAt.timeIntervalSince1970)
        bindOptionalDouble(record.isDeleted ? record.updatedAt.timeIntervalSince1970 : nil, at: 12, statement: statement)
        sqlite3_bind_text(statement, 13, (record.id as NSString).utf8String, -1, nil)
        bindOptionalText(record.cloudChangeTag, at: 14, statement: statement)
        sqlite3_bind_double(statement, 15, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        return sqlite3_changes(db) > 0
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
            source: source
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

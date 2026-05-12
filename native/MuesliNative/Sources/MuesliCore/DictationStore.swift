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
    private let databaseURL: URL
    private static let dictationColumns = """
    d.id, d.timestamp, d.duration_seconds, d.raw_text, d.app_context, d.word_count, d.source,
    t.id, t.final_status, t.final_message, t.trace_json, t.created_at
    """
    private static let meetingColumns = """
    id, title, start_time, duration_seconds, raw_transcript, formatted_notes, word_count, folder_id, calendar_event_id, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt
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
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_meetings_start_time ON meetings(start_time DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_meetings_calendar_event_id ON meetings(calendar_event_id) WHERE calendar_event_id IS NOT NULL;
        """
        try exec(createSQL, db: db)

        let foldersSQL = """
        CREATE TABLE IF NOT EXISTS meeting_folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
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
        if sqlite3_exec(db, "ALTER TABLE dictations ADD COLUMN source TEXT NOT NULL DEFAULT 'dictation'", nil, nil, nil) != SQLITE_OK {
            // Column may already exist.
        }
        let _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_meetings_folder ON meetings(folder_id)", nil, nil, nil)
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
        (timestamp, duration_seconds, raw_text, app_context, word_count, source, started_at, ended_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }

        let timestamp = ISO8601DateFormatter().string(from: endedAt)
        let started = ISO8601DateFormatter().string(from: startedAt)
        let ended = ISO8601DateFormatter().string(from: endedAt)
        sqlite3_bind_text(statement, 1, (timestamp as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, durationSeconds)
        sqlite3_bind_text(statement, 3, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (appContext as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(Self.countWords(in: text)))
        sqlite3_bind_text(statement, 6, (source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (started as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, (ended as NSString).utf8String, -1, nil)

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
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
        SELECT \(Self.dictationColumns)
        FROM dictations d
        LEFT JOIN computer_use_traces t ON t.dictation_id = d.id
        \(whereClause)
        ORDER BY d.id DESC
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
        WHERE d.id = ?
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

    public func meetingCounts() throws -> (total: Int, byFolder: [Int64: Int]) {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var total = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meetings", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { total = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        } else {
            fputs("[muesli-store] meetingCounts: failed to prepare total count query\n", stderr)
        }

        var byFolder: [Int64: Int] = [:]
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT folder_id, COUNT(*) FROM meetings WHERE folder_id IS NOT NULL GROUP BY folder_id", -1, &stmt2, nil) == SQLITE_OK {
            while sqlite3_step(stmt2) == SQLITE_ROW {
                byFolder[sqlite3_column_int64(stmt2, 0)] = Int(sqlite3_column_int(stmt2, 1))
            }
            sqlite3_finalize(stmt2)
        } else {
            fputs("[muesli-store] meetingCounts: failed to prepare folder count query\n", stderr)
        }

        return (total, byFolder)
    }

    public func recentMeetings(limit: Int? = nil, folderID: Int64? = nil) throws -> [MeetingRecord] {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        var sql: String
        if folderID != nil {
            sql = "SELECT \(Self.meetingColumns) FROM meetings WHERE folder_id = ? ORDER BY id DESC"
        } else {
            sql = "SELECT \(Self.meetingColumns) FROM meetings ORDER BY id DESC"
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
        WHERE meeting_status IN (?, ?)
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
        WHERE id = ?
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
        WHERE d.raw_text LIKE ? ESCAPE '\\' OR d.app_context LIKE ? ESCAPE '\\' OR t.final_message LIKE ? ESCAPE '\\' OR t.trace_json LIKE ? ESCAPE '\\'
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
        WHERE title LIKE ? ESCAPE '\\' OR raw_transcript LIKE ? ESCAPE '\\' OR formatted_notes LIKE ? ESCAPE '\\' OR manual_notes LIKE ? ESCAPE '\\'
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
        WHERE calendar_event_id = ?
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
        selectedTemplatePrompt: String? = nil
    ) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO meetings
        (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes, mic_audio_path, system_audio_path, saved_recording_path, word_count, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'meeting')
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
        (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes, mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, word_count, selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source)
        VALUES (?, ?, ?, NULL, 0, '', '', NULL, NULL, NULL, ?, '', 0, ?, ?, ?, ?, 'meeting')
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
        WHERE meeting_status IN (?, ?)
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
        let sql = "DELETE FROM dictations WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
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
        let sql = "DELETE FROM meetings WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
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
        try exec("DELETE FROM dictations", db: db)
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
        try exec("DELETE FROM meetings", db: db)
    }

    public func updateMeeting(id: Int64, title: String, formattedNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET title = ?, formatted_notes = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingNotes(id: Int64, formattedNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET formatted_notes = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (formattedNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
    }

    public func updateMeetingManualNotes(id: Int64, manualNotes: String) throws {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "UPDATE meetings SET manual_notes = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (manualNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, id)
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
            ? "UPDATE meetings SET meeting_status = ? WHERE id = ?"
            : "UPDATE meetings SET meeting_status = ?, word_count = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (status.rawValue as NSString).utf8String, -1, nil)
        if let wordCount {
            sqlite3_bind_int(statement, 2, Int32(wordCount))
            sqlite3_bind_int64(statement, 3, id)
        } else {
            sqlite3_bind_int64(statement, 2, id)
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
        SET title = ?, calendar_event_id = ?, start_time = ?, end_time = ?, duration_seconds = ?, raw_transcript = ?, formatted_notes = ?, mic_audio_path = ?, system_audio_path = ?, saved_recording_path = ?, meeting_status = ?, word_count = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?
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
        sqlite3_bind_int64(statement, 17, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError(db)
        }
        guard sqlite3_changes(db) > 0 else {
            throw DictationStoreError.meetingNotFound(id: id)
        }
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
        SET title = ?, formatted_notes = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?
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
        sqlite3_bind_int64(statement, 7, id)
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
        SET raw_transcript = ?, formatted_notes = ?, meeting_status = ?, word_count = ?, selected_template_id = ?, selected_template_name = ?, selected_template_kind = ?, selected_template_prompt = ?
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
        sqlite3_bind_int64(statement, 9, id)
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
        let sql = "UPDATE meetings SET title = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, id)
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
    public func createFolder(name: String) throws -> Int64 {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO meeting_folders (name) VALUES (?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
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
        let sql = "SELECT id, name, created_at FROM meeting_folders ORDER BY id ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [MeetingFolder] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(MeetingFolder(
                id: sqlite3_column_int64(statement, 0),
                name: stringColumn(statement, index: 1),
                createdAt: stringColumn(statement, index: 2)
            ))
        }
        return rows
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

    public func databasePath() -> URL {
        databaseURL
    }

    public static func countWords(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
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
            selectedTemplatePrompt: selectedTemplatePrompt
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

    private func bindOptionalText(_ value: String?, at index: Int32, statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func dictationStreaks(db: OpaquePointer?) throws -> (current: Int, longest: Int) {
        let sql = "SELECT DISTINCT date(timestamp) AS used_day FROM dictations ORDER BY used_day ASC"
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

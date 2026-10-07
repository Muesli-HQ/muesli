import Foundation
import SQLite3
import CryptoKit

enum MeetingChatSQL {
    enum Value { case text(String), integer(Int64), real(Double), null }
    static func execute(_ sql: String, _ values: [Value] = [], db: OpaquePointer?) throws {
        _ = try rows(sql, values, db: db) { _ in () }
    }
    static func rows<T>(_ sql: String, _ values: [Value] = [], db: OpaquePointer?, map: (OpaquePointer?) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error(db) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
            case .real(let real): sqlite3_bind_double(statement, index, real)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error(db) }
            result.append(try map(statement))
        }
    }
    static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    private static func error(_ db: OpaquePointer?) -> NSError {
        NSError(domain: "MeetingChatDB", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: "Meeting chat storage could not be updated."])
    }
    static func transaction<T>(db: OpaquePointer?, _ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            let result = try operation()
            try execute("COMMIT", db: db)
            return result
        } catch { try? execute("ROLLBACK", db: db); throw error }
    }

    static func migrate(db: OpaquePointer?) throws {
        // An outer SQLite UPSERT conflict policy can override a trigger's OR IGNORE.
        // Guard insertion with NOT EXISTS instead, including upgrades from earlier trigger definitions.
        for name in ["meeting_chat_index_source_inserted", "meeting_chat_index_source_edited", "meeting_chat_participant_inserted", "meeting_chat_participant_edited", "meeting_chat_participant_removed"] {
            try execute("DROP TRIGGER IF EXISTS \(name)", db: db)
        }
        let statements = [
            "CREATE TABLE IF NOT EXISTS meeting_chat_sessions (id TEXT PRIMARY KEY, body TEXT NOT NULL, updated_at REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS meeting_chat_turns (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES meeting_chat_sessions(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, state TEXT NOT NULL, body TEXT NOT NULL, UNIQUE(session_id, ordinal))",
            "CREATE TABLE IF NOT EXISTS meeting_chat_dependencies (turn_id TEXT NOT NULL REFERENCES meeting_chat_turns(id) ON DELETE CASCADE, meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, revision TEXT NOT NULL, PRIMARY KEY(turn_id,meeting_id))",
            "CREATE INDEX IF NOT EXISTS idx_meeting_chat_dependencies_source ON meeting_chat_dependencies(meeting_id)",
            "CREATE TABLE IF NOT EXISTS meeting_chat_passages (id TEXT PRIMARY KEY, meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, revision TEXT NOT NULL, text TEXT NOT NULL, body TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS idx_meeting_chat_passages_source ON meeting_chat_passages(meeting_id)",
            "CREATE TABLE IF NOT EXISTS meeting_chat_dirty_sources (meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE)",
            "CREATE TABLE IF NOT EXISTS meeting_chat_index_state (meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE, revision TEXT NOT NULL, start_time REAL NOT NULL, folder_id INTEGER)",
            "CREATE INDEX IF NOT EXISTS idx_meeting_chat_index_scope ON meeting_chat_index_state(folder_id,start_time)",
            """
            CREATE TRIGGER IF NOT EXISTS meeting_chat_index_source_inserted AFTER INSERT ON meetings
            WHEN NEW.deleted_at IS NULL BEGIN INSERT INTO meeting_chat_dirty_sources SELECT NEW.id
              WHERE NOT EXISTS (SELECT 1 FROM meeting_chat_dirty_sources WHERE meeting_id=NEW.id); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS meeting_chat_index_source_edited
            AFTER UPDATE OF title,start_time,folder_id,raw_transcript,manual_notes,formatted_notes,meeting_status,source ON meetings
            WHEN NEW.deleted_at IS NULL BEGIN INSERT INTO meeting_chat_dirty_sources SELECT NEW.id
              WHERE NOT EXISTS (SELECT 1 FROM meeting_chat_dirty_sources WHERE meeting_id=NEW.id); END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS meeting_chat_index_source_deleted AFTER UPDATE OF deleted_at ON meetings
            WHEN NEW.deleted_at IS NOT NULL BEGIN
              DELETE FROM meeting_chat_index_state WHERE meeting_id=NEW.id;
              DELETE FROM meeting_chat_dirty_sources WHERE meeting_id=NEW.id;
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS meeting_chat_source_deleted AFTER UPDATE OF deleted_at ON meetings
            WHEN NEW.deleted_at IS NOT NULL
            BEGIN
                UPDATE meeting_chat_turns SET state='sourceDeleted', body=json_set(body,
                  '$.state','sourceDeleted','$.originalAnswer',NULL,'$.editableDraft',NULL,'$.citations',json('[]'),'$.error',NULL)
                WHERE id IN (SELECT turn_id FROM meeting_chat_dependencies WHERE meeting_id=NEW.id);
                DELETE FROM meeting_chat_passages WHERE meeting_id=NEW.id;
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS meeting_chat_source_purged BEFORE DELETE ON meetings
            BEGIN
                UPDATE meeting_chat_turns SET state='sourceDeleted', body=json_set(body,
                  '$.state','sourceDeleted','$.originalAnswer',NULL,'$.editableDraft',NULL,'$.citations',json('[]'),'$.error',NULL)
                WHERE id IN (SELECT turn_id FROM meeting_chat_dependencies WHERE meeting_id=OLD.id);
            END
            """
        ]
        for sql in statements { try execute(sql, db: db) }
        for (name, event, owner) in [("inserted", "INSERT", "NEW"), ("edited", "UPDATE", "NEW"), ("removed", "DELETE", "OLD")] {
            try execute("""
                CREATE TRIGGER IF NOT EXISTS meeting_chat_participant_\(name) AFTER \(event) ON meeting_participants
                BEGIN INSERT INTO meeting_chat_dirty_sources
                  SELECT id FROM meetings WHERE id=\(owner).meeting_id AND deleted_at IS NULL
                    AND NOT EXISTS (SELECT 1 FROM meeting_chat_dirty_sources WHERE meeting_id=\(owner).meeting_id); END
                """, db: db)
        }
        try execute("""
            INSERT OR IGNORE INTO meeting_chat_dirty_sources SELECT id FROM meetings
            WHERE deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM local_migrations WHERE identifier='meeting_chat_incremental_index_v1')
            """, db: db)
        try execute("INSERT OR IGNORE INTO local_migrations VALUES('meeting_chat_incremental_index_v1',strftime('%s','now'))", db: db)
    }

    static func invalidateSources(meetingIDs: [Int64], db: OpaquePointer?) throws {
        for id in meetingIDs {
            try execute("UPDATE meeting_chat_turns SET state='sourceDeleted', body=json_set(body,'$.state','sourceDeleted','$.originalAnswer',NULL,'$.editableDraft',NULL,'$.citations',json('[]'),'$.error',NULL) WHERE id IN (SELECT turn_id FROM meeting_chat_dependencies WHERE meeting_id=?)", [.integer(id)], db: db)
            try execute("DELETE FROM meeting_chat_passages WHERE meeting_id=?", [.integer(id)], db: db)
            try execute("DELETE FROM meeting_chat_index_state WHERE meeting_id=?", [.integer(id)], db: db)
            try execute("DELETE FROM meeting_chat_dirty_sources WHERE meeting_id=?", [.integer(id)], db: db)
        }
    }
    static func clear(db: OpaquePointer?) throws {
        try execute("DELETE FROM meeting_chat_sessions", db: db)
        try execute("DELETE FROM meeting_chat_passages", db: db)
        try execute("DELETE FROM meeting_chat_index_state", db: db)
        try execute("DELETE FROM meeting_chat_dirty_sources", db: db)
    }

    static func snapshots(scope: MeetingChatScope, db: OpaquePointer?, afterID: Int64 = 0, limit: Int = 200) throws -> [MeetingChatSourceSnapshot] {
        var clause = "m.deleted_at IS NULL AND m.meeting_status NOT IN ('recording','processing') AND m.id>?"
        var bindings: [Value] = [.integer(afterID)]
        switch scope.selection {
        case .all: break
        case .folder(let id): clause += " AND m.folder_id=?"; bindings.append(.integer(id))
        case .meetings(let ids):
            guard !ids.isEmpty else { return [] }
            clause += " AND m.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            bindings += ids.map { .integer($0) }
        }
        // ISO date parsing is performed after query because imported legacy timestamps vary in format.
        bindings.append(.integer(Int64(limit)))
        return try rows("""
            SELECT m.id,m.title,m.start_time,m.folder_id,m.raw_transcript,COALESCE(m.manual_notes,''),COALESCE(m.formatted_notes,''),m.meeting_status,m.source,
              COALESCE((SELECT json_group_array(display_name) FROM (SELECT display_name FROM meeting_participants WHERE meeting_id=m.id AND is_suppressed=0 ORDER BY insertion_order)), '[]')
            FROM meetings m WHERE \(clause) ORDER BY m.id LIMIT ?
            """, bindings, db: db) { s in
            let fields = (1...9).map { text(s, Int32($0)) }
            let date = parseDate(fields[1]) ?? .distantPast
            let transcript = fields[3]
            let notes = fields[5].hasPrefix("## Summary failed") || fields[5].hasPrefix("## Raw Transcript") ? "" : fields[5]
            let revisionData = try JSONEncoder().encode(fields)
            let revision = SHA256.hash(data: revisionData).map { String(format: "%02x", $0) }.joined()
            return MeetingChatSourceSnapshot(meetingID: sqlite3_column_int64(s, 0), title: fields[0], startDate: date,
                folderID: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 3), transcript: transcript,
                manualNotes: fields[4], generatedNotes: notes,
                participantNames: (try? decode([String].self, fields[8])) ?? [], revision: revision)
        }
    }
    static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

import Foundation
import SQLite3

/// A read-only connection to saved meetings, with chat tables shadowed in RAM.
/// SQLite cannot write the main file; temp_store=MEMORY prevents spill to disk.
/// Existing saved chats are not copied into the private conversation workspace.
final class EphemeralChatDatabase: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: EphemeralChatDatabase] = [:]
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private var sourceVersion: Int64 = -1

    static func withConnection<T>(url: URL, session: ContentPrivacy.Session, operation: (OpaquePointer?) throws -> T) throws -> T {
        let key = url.path + "|" + session.epoch.uuidString
        let instance = try registryLock.withLock { () throws -> EphemeralChatDatabase in
            if let cached = registry[key] { return cached }
            let created = try EphemeralChatDatabase(url: url)
            registry[key] = created
            return created
        }
        return try instance.lock.withLock {
            let version = try MeetingChatSQL.rows("SELECT version FROM main.meeting_chat_source_version WHERE id=1", db: instance.db) { sqlite3_column_int64($0, 0) }.first ?? 0
            if version != instance.sourceVersion {
                try instance.markChangedIndexSources()
                try instance.invalidateChangedSources()
                instance.sourceVersion = version
            }
            return try operation(instance.db)
        }
    }
    private func markChangedIndexSources() throws {
        // A reconciled durable index has the current revision. New, removed and
        // moved meetings can also be identified without reading transcript text.
        try MeetingChatSQL.execute("""
            INSERT OR IGNORE INTO temp.meeting_chat_dirty_sources
            SELECT m.id FROM main.meetings m
            LEFT JOIN temp.meeting_chat_index_state p ON p.meeting_id=m.id
            LEFT JOIN main.meeting_chat_index_state d ON d.meeting_id=m.id
            LEFT JOIN main.meeting_chat_dirty_sources q ON q.meeting_id=m.id
            WHERE m.deleted_at IS NULL AND m.meeting_status NOT IN ('recording','processing')
              AND (p.meeting_id IS NULL OR p.folder_id IS NOT m.folder_id
                   OR (q.meeting_id IS NULL AND d.revision IS NOT NULL AND p.revision != d.revision))
            UNION ALL
            SELECT p.meeting_id FROM temp.meeting_chat_index_state p
            LEFT JOIN main.meetings m ON m.id=p.meeting_id
            WHERE m.id IS NULL OR m.deleted_at IS NOT NULL OR m.meeting_status IN ('recording','processing')
            """, db: db)
        // If the durable index itself is stale, compare live content revisions
        // in bounded batches. Only changed content enters passage extraction.
        var afterID: Int64 = 0
        while true {
            let candidates = try MeetingChatSQL.rows("""
                SELECT p.meeting_id,p.revision FROM temp.meeting_chat_index_state p
                LEFT JOIN main.meeting_chat_index_state d ON d.meeting_id=p.meeting_id
                LEFT JOIN main.meeting_chat_dirty_sources q ON q.meeting_id=p.meeting_id
                LEFT JOIN temp.meeting_chat_dirty_sources queued ON queued.meeting_id=p.meeting_id
                WHERE p.meeting_id>? AND queued.meeting_id IS NULL
                  AND (d.meeting_id IS NULL OR q.meeting_id IS NOT NULL)
                ORDER BY p.meeting_id LIMIT 32
                """, [.integer(afterID)], db: db) { (sqlite3_column_int64($0, 0), MeetingChatSQL.text($0, 1)) }
            guard let last = candidates.last else { return }
            let revisions = Dictionary(uniqueKeysWithValues: candidates)
            let sources = try MeetingChatSQL.snapshots(scope: .init(selection: .meetings(candidates.map { $0.0 })), db: db)
            for source in sources where revisions[source.meetingID] != source.revision {
                try MeetingChatSQL.execute("INSERT OR IGNORE INTO temp.meeting_chat_dirty_sources VALUES(?)", [.integer(source.meetingID)], db: db)
            }
            afterID = last.0
        }
    }
    private func invalidateChangedSources() throws {
        let turns = try MeetingChatSQL.rows("SELECT body FROM meeting_chat_turns", db: db) {
            try MeetingChatSQL.decode(MeetingChatTurn.self, MeetingChatSQL.text($0, 0))
        }
        for var turn in turns {
            let dependencies = try MeetingChatSQL.rows("SELECT meeting_id,revision FROM meeting_chat_dependencies WHERE turn_id=?", [.text(turn.id.uuidString)], db: db) {
                (sqlite3_column_int64($0, 0), MeetingChatSQL.text($0, 1))
            }
            guard !dependencies.isEmpty else { continue }
            let sources = try MeetingChatSQL.snapshots(scope: .init(selection: .meetings(dependencies.map { $0.0 })), db: db)
            let revisions = Dictionary(uniqueKeysWithValues: sources.map { ($0.meetingID, $0.revision) })
            guard dependencies.contains(where: { revisions[$0.0] != $0.1 }) else { continue }
            turn.state = .sourceDeleted
            turn.originalAnswer = nil; turn.editableDraft = nil; turn.citations = []
            try MeetingChatSQL.execute("UPDATE meeting_chat_turns SET state=?,body=? WHERE id=?",
                [.text(turn.state.rawValue), .text(try MeetingChatSQL.encode(turn)), .text(turn.id.uuidString)], db: db)
        }
        try MeetingChatSQL.execute("UPDATE meeting_chat_sessions SET body=json_remove(body,'$.rollingSummary')", db: db)
        try MeetingChatSQL.execute("""
        UPDATE meeting_chat_sessions SET body=json_set(body,'$.title','New chat')
        WHERE json_extract(body,'$.titleIsAutomatic')=1 AND json_extract(body,'$.generatedTitleTurnID') IN
          (SELECT id FROM meeting_chat_turns WHERE state='sourceDeleted')
        """, db: db)
        try MeetingChatSQL.execute("DELETE FROM meeting_chat_session_meetings WHERE meeting_id NOT IN (SELECT id FROM main.meetings WHERE deleted_at IS NULL)", db: db)
    }
    public static func discard() { registryLock.withLock { registry.removeAll() } }
    private init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ContentPrivacy.Failure.ephemeralContent }
        do {
            try MeetingChatSQL.execute("PRAGMA temp_store=MEMORY", db: db)
            let schemas = try MeetingChatSQL.rows("SELECT sql FROM main.sqlite_master WHERE type='table' AND name LIKE 'meeting_chat_%' AND name NOT LIKE 'meeting_chat_fts%' AND name <> 'meeting_chat_source_version'", db: db) { MeetingChatSQL.text($0, 0) }
            guard !schemas.isEmpty else { throw ContentPrivacy.Failure.ephemeralContent }
            for sql in schemas {
                try MeetingChatSQL.execute(sql.replacingOccurrences(of: "CREATE TABLE", with: "CREATE TEMP TABLE"), db: db)
            }
            try MeetingChatSQL.execute("CREATE UNIQUE INDEX temp.private_single_anchor ON meeting_chat_session_meetings(session_id) WHERE role='anchor'", db: db)
            // Keep session ownership/cascades in RAM; references to durable meetings
            // are validated by the existing source/dependency checks.
            try MeetingChatSQL.execute("CREATE TEMP TRIGGER private_session_deleted AFTER DELETE ON meeting_chat_sessions BEGIN DELETE FROM meeting_chat_turns WHERE session_id=OLD.id; DELETE FROM meeting_chat_session_meetings WHERE session_id=OLD.id; END", db: db)
            try MeetingChatSQL.execute("CREATE TEMP TRIGGER private_turn_deleted AFTER DELETE ON meeting_chat_turns BEGIN DELETE FROM meeting_chat_dependencies WHERE turn_id=OLD.id; END", db: db)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
}

extension ContentPrivacy {
    public static func discardEphemeralChats() { EphemeralChatDatabase.discard() }
}

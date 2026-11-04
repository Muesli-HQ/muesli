import Foundation
import SQLite3

/// Track source identities without duplicating OCR or quoted text in chat storage.
package struct ChatHistoryDependency: Sendable {
    package let kind: String
    package let id: String
    package let parent: String
    package init(kind: String, id: String, parent: String) {
        self.kind = kind
        self.id = id
        self.parent = parent
    }
}

extension MeetingChatSQL {
    static func migrateChatHistoryDependencies(db: OpaquePointer?) throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS meeting_chat_history_dependencies(
                turn_id TEXT NOT NULL REFERENCES meeting_chat_turns(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, source_id TEXT NOT NULL, parent_id TEXT NOT NULL,
                PRIMARY KEY(turn_id,kind,source_id));
            CREATE INDEX IF NOT EXISTS chat_history_source ON meeting_chat_history_dependencies(kind,source_id);
            CREATE INDEX IF NOT EXISTS chat_history_parent ON meeting_chat_history_dependencies(kind,parent_id);
            CREATE TRIGGER IF NOT EXISTS chat_history_dependency_removed AFTER DELETE ON meeting_chat_history_dependencies
            WHEN EXISTS(SELECT 1 FROM meeting_chat_turns WHERE id=OLD.turn_id AND state!='sourceDeleted')
            BEGIN
              UPDATE meeting_chat_turns SET state='sourceDeleted',body=json_set(body,'$.state','sourceDeleted',
                '$.originalAnswer',NULL,'$.editableDraft',NULL,'$.citations',json('[]'),'$.documentCoverage',NULL,'$.error',NULL) WHERE id=OLD.turn_id;
              UPDATE meeting_chat_sessions SET body=json_set(body,'$.rollingSummary',NULL)
                WHERE id=(SELECT session_id FROM meeting_chat_turns WHERE id=OLD.turn_id);
              UPDATE meeting_chat_sessions SET body=json_set(body,'$.title','New chat','$.generatedTitleTurnID',NULL)
                WHERE id=(SELECT session_id FROM meeting_chat_turns WHERE id=OLD.turn_id) AND json_extract(body,'$.generatedTitleTurnID')=OLD.turn_id;
              UPDATE meeting_chat_source_version SET version=version+1 WHERE id=1;
            END;
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MeetingChatError.invalidResponse }
    }

    // Optional tables may be initialized after migration. Install their triggers
    // when first recording a dependency, inside the same write transaction.
    static func observeHistory(kind: String, db: OpaquePointer?) throws {
        let rules: [(String, String, String, String)]
        switch kind {
        case "sqlMeeting": rules = [("meetings","source_id","id","title,start_time,raw_transcript,manual_notes,formatted_notes,deleted_at,meeting_status")]
        case "dictations","commands": rules = [("dictations","source_id","id","raw_text,timestamp,source,target_app_name,target_app_bundle_id,deleted_at")]
        case "quill": rules = [("quill_conversations","parent_id","id","deleted_at"),("quill_conversation_turns","source_id","turn_id","body")]
        case "cotypist": rules = [("cotypist_sessions","parent_id","id","deleted_at"),("cotypist_suggestions","source_id","id","accepted_text,timestamp,session_id")]
        case "quillSession": rules = [("quill_conversations","parent_id","id","timestamp,deleted_at"),("quill_conversation_turns","parent_id","conversation_id","body,conversation_id")]
        case "cotypistSession": rules = [("cotypist_sessions","parent_id","id","timestamp,target_app_name,target_app_bundle_id,deleted_at"),("cotypist_suggestions","parent_id","session_id","accepted_text,session_id,timestamp")]
        case "recap": rules = [("time_turner_recaps","source_id","day_key","body,day_start")]
        case "chat": rules = [("meeting_chat_sessions","source_id","id","body,updated_at"),("meeting_chat_turns","parent_id","session_id","body,state")]
        default: return // Capture deletions arrive via the screen catalog outbox.
        }
        for (table, field, column, updates) in rules {
            if (kind == "recap" || kind == "quillSession" || kind == "cotypistSession") {
                // REPLACE on a recap and new turns in a session can change an already issued source.
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS chat_history_\(kind)_\(table)_ins AFTER INSERT ON \(table)
                    BEGIN DELETE FROM meeting_chat_history_dependencies WHERE kind='\(kind)' AND \(field)=CAST(NEW.\(column) AS TEXT); END
                    """, db: db)
            }
            for (event, operation) in [("del","DELETE"),("upd","UPDATE OF " + updates)] {
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS chat_history_\(kind)_\(table)_\(event) AFTER \(operation) ON \(table)
                    BEGIN DELETE FROM meeting_chat_history_dependencies WHERE kind='\(kind)' AND \(field)=CAST(OLD.\(column) AS TEXT); END
                    """, db: db)
            }
        }
    }
}

extension MeetingChatStore {
    package func recordHistory(_ sources: [ChatHistoryDependency], turn: MeetingChatTurn, validate: () throws -> Bool) throws {
        try ContentPrivacy.shared.beginWrite(privacy)
        defer { ContentPrivacy.shared.endWrite() }
        try DictationStore(databaseURL: databaseURL).withChatDatabase { db in
            try MeetingChatSQL.transaction(db: db) {
                let active = try MeetingChatSQL.rows("SELECT body FROM meeting_chat_turns WHERE id=? AND state IN ('finding','writing')",
                    [.text(turn.id.uuidString)], db: db) { try MeetingChatSQL.decode(MeetingChatTurn.self, MeetingChatSQL.text($0, 0)) }
                guard active.first?.attemptID == turn.attemptID, !active.isEmpty, try validate() else { throw MeetingChatError.sourceChanged }
                for kind in Set(sources.map(\.kind)) { try MeetingChatSQL.observeHistory(kind: kind, db: db) }
                for source in sources {
                    try MeetingChatSQL.execute("INSERT OR IGNORE INTO meeting_chat_history_dependencies VALUES(?,?,?,?)",
                        [.text(turn.id.uuidString),.text(source.kind),.text(source.id),.text(source.parent)], db: db)
                }
            }
        }
    }
    package func invalidateHistoryCaptures(_ ids: [String]) throws {
        try DictationStore(databaseURL: databaseURL).withChatDatabase { db in
            guard !(try MeetingChatSQL.rows("SELECT 1 FROM sqlite_master WHERE name='meeting_chat_history_dependencies'", db: db) { _ in true }).isEmpty else { return }
            try MeetingChatSQL.transaction(db: db) {
                for id in ids {
                    try MeetingChatSQL.execute("DELETE FROM meeting_chat_history_dependencies WHERE kind='capture' AND source_id=?", [.text(id)], db: db)
                }
            }
        }
    }
}

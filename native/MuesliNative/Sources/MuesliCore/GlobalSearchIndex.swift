import Foundation
import SQLite3

public enum GlobalSearchError: Error { case changedSources, unavailableSources(Set<GlobalSearchKind>) }

/// Source identities remain owned by their stores. Search never becomes a second history store.
public enum GlobalSearchKind: String, CaseIterable, Codable, Sendable {
    case dictation, meeting, command, quill, cotypist, screenHistory, chat, recap, vidshot
}

public struct GlobalSearchQuery: Sendable {
    public var text: String
    public var kinds: Set<GlobalSearchKind>
    public var from: Date
    public var until: Date
    public var app: String?
    public var person: MeetingParticipantDraft?
    public var limit: Int
    public var offset: Int
    public init(text: String, kinds: Set<GlobalSearchKind> = Set(GlobalSearchKind.allCases),
                from: Date = .distantPast, until: Date = .distantFuture, app: String? = nil, person: MeetingParticipantDraft? = nil, limit: Int = 50, offset: Int = 0) {
        self.text = text; self.kinds = kinds; self.from = from; self.until = until; self.app = app; self.person = person; self.limit = limit; self.offset = offset
    }
}

public struct GlobalSearchResult: Identifiable, Sendable, Equatable {
    public var id: String { kind.rawValue + ":" + sourceID }
    public let kind: GlobalSearchKind
    public let sourceID: String
    public let date: Date
    public let title: String
    public let excerpt: String
    public let appName: String
    public let bundleID: String
    public let mediaAvailable: Bool
}

/// Incremental lexical index for muesli.db. Construct and query on a worker, never in a view body.
/// Time Turner continues to own its OCR index. The application combines these typed results.
public final class GlobalSearchIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var installedSchemaVersion: Int64 = -1
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) throws {
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw Self.error
        }
        sqlite3_busy_timeout(db, 5_000)
        try installAvailableSources()
    }
    deinit { sqlite3_close(db) }
    private static var error: NSError { NSError(domain: "GlobalSearch", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Search history could not be read on this Mac."]) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.error }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error }
        return statement
    }
    private func bind(_ value: String, _ statement: OpaquePointer?, _ slot: Int32) {
        sqlite3_bind_text(statement, slot, value, -1, transient)
    }
    private func exists(_ name: String) throws -> Bool {
        let s = try prepare("SELECT 1 FROM sqlite_master WHERE name=?")
        defer { sqlite3_finalize(s) }; bind(name, s, 1)
        return sqlite3_step(s) == SQLITE_ROW
    }

    private func schemaVersion() throws -> Int64 {
        let s = try prepare("PRAGMA schema_version")
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw Self.error }
        return sqlite3_column_int64(s, 0)
    }

    private func dataVersion() throws -> Int64 {
        let s = try prepare("PRAGMA data_version")
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw Self.error }
        return sqlite3_column_int64(s, 0)
    }

    /// Source stores may recover a failed statement only after proving the global
    /// FTS projection is inconsistent. Never replay a transaction or source work
    /// on SQLITE_BUSY, constraints, I/O errors, or corruption of another index.
    public static func stepSourceWrite(_ statement: OpaquePointer?) throws -> Int32 {
        let db = sqlite3_db_handle(statement)
        let wasAutocommit = sqlite3_get_autocommit(db)
        let status = sqlite3_step(statement)
        let corruptVirtualTable = SQLITE_CORRUPT | (1 << 8)
        guard status != SQLITE_DONE, status != SQLITE_ROW,
              sqlite3_stmt_readonly(statement) == 0,
              sqlite3_extended_errcode(db) == corruptVirtualTable else { return status }
        func failure() -> NSError {
            NSError(domain: "MuesliDB", code: Int(sqlite3_extended_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        let original = failure()
        // A failed statement must not have rolled back the caller's transaction.
        guard sqlite3_get_autocommit(db) == wasAutocommit else { throw original }
        sqlite3_reset(statement) // bindings survive; the aborted statement can be retried once
        let check = sqlite3_exec(db, "INSERT INTO global_search_fts(global_search_fts,rank) VALUES('integrity-check',1)", nil, nil, nil)
        guard check != SQLITE_OK, sqlite3_extended_errcode(db) == corruptVirtualTable else { throw original }
        func run(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        }
        try run("SAVEPOINT global_search_repair")
        do {
            // Only derived token data is replaced. Documents and authoritative
            // records remain intact, including earlier writes in an outer transaction.
            do {
                try run("INSERT INTO global_search_fts(global_search_fts) VALUES('rebuild')")
            } catch {
                guard sqlite3_extended_errcode(db) == corruptVirtualTable else { throw error }
                try run("DROP TABLE global_search_fts")
                try run("CREATE VIRTUAL TABLE global_search_fts USING fts5(title,text,content='global_search_documents',content_rowid='rowid')")
                try run("INSERT INTO global_search_fts(global_search_fts) VALUES('rebuild')")
            }
            let retried = sqlite3_step(statement)
            guard retried == SQLITE_DONE else { throw failure() }
            try run("RELEASE global_search_repair")
            return retried
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK TO global_search_repair", nil, nil, nil)
            _ = sqlite3_exec(db, "RELEASE global_search_repair", nil, nil, nil)
            throw error
        }
    }

    /// Idempotent lazy installation handles Chat/Recap tables created after first search.
    /// Each source backfills once. Subsequent source writes update affected documents in their transaction.
    public func installAvailableSources() throws {
        lock.lock(); defer { lock.unlock() }
        guard try schemaVersion() != installedSchemaVersion else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS global_search_documents (
                    rowid INTEGER PRIMARY KEY, identity TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL, source_id TEXT NOT NULL, timestamp REAL NOT NULL,
                    title TEXT NOT NULL, text TEXT NOT NULL, app_name TEXT NOT NULL, bundle_id TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS global_search_kind_time ON global_search_documents(kind,timestamp DESC);
                CREATE INDEX IF NOT EXISTS global_search_app_time ON global_search_documents(bundle_id,timestamp DESC);
                CREATE VIRTUAL TABLE IF NOT EXISTS global_search_fts USING fts5(title,text,
                    content='global_search_documents',content_rowid='rowid');
                CREATE TRIGGER IF NOT EXISTS global_search_document_insert AFTER INSERT ON global_search_documents BEGIN
                    INSERT INTO global_search_fts(rowid,title,text) VALUES(NEW.rowid,NEW.title,NEW.text);
                END;
                CREATE TRIGGER IF NOT EXISTS global_search_document_delete AFTER DELETE ON global_search_documents BEGIN
                    INSERT INTO global_search_fts(global_search_fts,rowid,title,text) VALUES('delete',OLD.rowid,OLD.title,OLD.text);
                END;
                CREATE TRIGGER IF NOT EXISTS global_search_document_update AFTER UPDATE ON global_search_documents BEGIN
                    INSERT INTO global_search_fts(global_search_fts,rowid,title,text) VALUES('delete',OLD.rowid,OLD.title,OLD.text);
                    INSERT INTO global_search_fts(rowid,title,text) VALUES(NEW.rowid,NEW.title,NEW.text);
                END;
                """)
            for source in Self.sources {
                // Replace the old unguarded JSON projections as well as their
                // embedded trigger SQL on existing installations.
                if source.version > 1 {
                    let oldView = "global_search_\(source.prefix)_v1"
                    for (table, _) in source.watches {
                        for event in ["INSERT", "UPDATE", "DELETE"] {
                            try execute("DROP TRIGGER IF EXISTS \(oldView)_\(table)_\(event)")
                        }
                    }
                    try execute("DROP VIEW IF EXISTS \(oldView)")
                }
                guard try source.tables.allSatisfy({ try exists($0) }) else { continue }
                let complete = try exists(source.view) && source.triggerNames.allSatisfy { try exists($0) }
                guard !complete else { continue }
                // Dropping a source table removes its triggers, but leaves its view and indexed text.
                // Repair the entire source atomically so deleted/changed rows cannot survive a migration.
                try execute("DELETE FROM global_search_documents WHERE identity GLOB '\(source.prefix):*'")
                try execute("CREATE VIEW IF NOT EXISTS \(source.view) AS \(source.select)")
                try execute("INSERT INTO global_search_documents(identity,kind,source_id,timestamp,title,text,app_name,bundle_id) SELECT * FROM \(source.view)")
                for (table, key) in source.watches {
                    for event in ["INSERT", "UPDATE", "DELETE"] {
                        let rows = event == "INSERT" ? ["NEW"] : event == "DELETE" ? ["OLD"] : ["OLD", "NEW"]
                        let refresh = rows.map { row in
                            let identity = "'\(source.prefix):' || \(row).\(key)"
                            return """
                                DELETE FROM global_search_documents WHERE identity=\(identity);
                                INSERT INTO global_search_documents(identity,kind,source_id,timestamp,title,text,app_name,bundle_id)
                                    \(source.select) AND \(source.primaryKey)=\(row).\(key);
                                """
                        }.joined(separator: "\n")
                        try execute("CREATE TRIGGER IF NOT EXISTS \(source.view)_\(table)_\(event) AFTER \(event) ON \(table) BEGIN \(refresh) END")
                    }
                }
            }
            try execute("COMMIT")
            installedSchemaVersion = try schemaVersion()
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Stable newest-first pages for one permitted class. Only identities leave this boundary;
    /// Chat re-reads and validates each source before exposing text or metadata.
    package func historyIDs(kind: GlobalSearchKind, phrase: String, from: Date, until: Date,
                            app: String?, after: VisualMemoryCursor?, limit: Int, refreshSchema: Bool = true) throws -> [(id: String, date: Date)] {
        lock.lock(); defer { lock.unlock() }
        guard (1...20).contains(limit), from < until, phrase.utf8.count <= 512 else { throw Self.error }
        if refreshSchema { try installAvailableSources() }
        let match = phrase.isEmpty ? "" : " AND d.rowid IN (SELECT rowid FROM global_search_fts WHERE global_search_fts MATCH ?)"
        let byApp = app == nil ? "" : " AND (d.app_name=? COLLATE NOCASE OR d.bundle_id=? COLLATE NOCASE)"
        let cursor = after == nil ? "" : " AND (d.timestamp<? OR (d.timestamp=? AND d.source_id>?))"
        let s = try prepare("SELECT d.source_id,d.timestamp FROM global_search_documents d WHERE d.kind=? AND d.timestamp>=? AND d.timestamp<?" + match + byApp + cursor + " ORDER BY d.timestamp DESC,d.source_id LIMIT ?")
        defer { sqlite3_finalize(s) }
        bind(kind.rawValue, s, 1)
        sqlite3_bind_double(s, 2, from.timeIntervalSince1970)
        sqlite3_bind_double(s, 3, until.timeIntervalSince1970)
        var slot: Int32 = 4
        if !phrase.isEmpty {
            bind("\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\"", s, slot); slot += 1
        }
        if let app { bind(app, s, slot); bind(app, s, slot + 1); slot += 2 }
        if let after {
            sqlite3_bind_double(s, slot, after.capturedAtUnix); sqlite3_bind_double(s, slot + 1, after.capturedAtUnix)
            bind(after.id, s, slot + 2); slot += 3
        }
        sqlite3_bind_int(s, slot, Int32(limit))
        var rows: [(String, Date)] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            rows.append((String(cString: sqlite3_column_text(s, 0)), Date(timeIntervalSince1970: sqlite3_column_double(s, 1))))
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw Self.error }
        return rows
    }

    /// Bounded, literal phrase search. An empty kind set means no results, never all content.
    /// Chat and recaps require the application's current-source validator before any derived text is exposed.
    public func search(_ query: GlobalSearchQuery, validateDerived: ((GlobalSearchKind, String) throws -> Bool)? = nil) throws -> [GlobalSearchResult] {
        lock.lock(); defer { lock.unlock() }
        do {
            return try searchSnapshot(query, validateDerived: validateDerived)
        } catch GlobalSearchError.changedSources {
            // A save on another connection may be unrelated. Re-read and revalidate once rather
            // than exposing a transient failure or returning excerpts from before a deletion.
            return try searchSnapshot(query, validateDerived: validateDerived)
        }
    }

    private func searchSnapshot(_ query: GlobalSearchQuery,
                                validateDerived: ((GlobalSearchKind, String) throws -> Bool)?) throws -> [GlobalSearchResult] {
        guard !query.kinds.isEmpty, query.from < query.until else { return [] }
        try installAvailableSources()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || query.person != nil), text.utf8.count <= 4096 else { return [] }
        let excluded: Set<GlobalSearchKind> = validateDerived == nil ? [.screenHistory, .chat, .recap] : [.screenHistory]
        let kinds = query.kinds.subtracting(excluded).filter { query.person == nil || $0 == .meeting }.map(\.rawValue).sorted()
        guard !kinds.isEmpty else { return [] }
        let appClause = query.app == nil ? "" : " AND (d.bundle_id=? COLLATE NOCASE OR d.app_name=? COLLATE NOCASE)"
        let personClause = query.person == nil ? "" : " AND EXISTS (SELECT 1 FROM meeting_participants p WHERE p.meeting_id=CAST(d.source_id AS INTEGER) AND p.is_suppressed=0 AND " + (query.person?.personID == nil ? "p.participant_identifier=?" : "p.person_id=?") + ")"
        let revision = try dataVersion()
        let limit = max(1, min(200, query.limit))
        let batchSize = limit
        func candidates(offset: Int) throws -> [GlobalSearchResult] {
            let match = text.isEmpty ? "" : "global_search_fts MATCH ? AND "
            let excerpt = text.isEmpty ? "substr(d.text,1,240)" : "snippet(global_search_fts,-1,'','',' … ',28)"
            let order = text.isEmpty ? "d.timestamp DESC,d.identity" : "bm25(global_search_fts,4.0,1.0),d.timestamp DESC,d.identity"
            let s = try prepare("""
                SELECT d.kind,d.source_id,d.timestamp,d.title,
                    \(excerpt),d.app_name,d.bundle_id
                FROM global_search_fts JOIN global_search_documents d ON d.rowid=global_search_fts.rowid
                WHERE \(match)d.timestamp>=? AND d.timestamp<?
                    AND d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))\(appClause)\(personClause)
                ORDER BY \(order) LIMIT ? OFFSET ?
                """)
            defer { sqlite3_finalize(s) }
            var slot: Int32 = 1
            if !text.isEmpty { bind("\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"", s, slot); slot += 1 }
            sqlite3_bind_double(s, slot, query.from.timeIntervalSince1970); slot += 1
            sqlite3_bind_double(s, slot, query.until.timeIntervalSince1970); slot += 1
            for kind in kinds { bind(kind, s, slot); slot += 1 }
            if let app = query.app { bind(app, s, slot); bind(app, s, slot + 1); slot += 2 }
            if let person = query.person {
                bind(person.personID ?? person.participantIdentifier, s, slot); slot += 1
            }
            sqlite3_bind_int(s, slot, Int32(batchSize))
            sqlite3_bind_int64(s, slot + 1, Int64(offset))
            var batch: [GlobalSearchResult] = []
            var status = sqlite3_step(s)
            while status == SQLITE_ROW {
                func string(_ column: Int32) -> String { sqlite3_column_text(s, column).map { String(cString: $0) } ?? "" }
                if let kind = GlobalSearchKind(rawValue: string(0)) {
                    batch.append(.init(kind: kind, sourceID: string(1), date: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                        title: string(3), excerpt: string(4), appName: string(5), bundleID: string(6), mediaAvailable: false))
                }
                status = sqlite3_step(s)
            }
            guard status == SQLITE_DONE else { throw Self.error }
            return batch
        }
        var result: [GlobalSearchResult] = []
        var offset = query.person == nil ? 0 : max(0, query.offset)
        while result.count < limit {
            try Task.checkCancellation()
            let batch = try candidates(offset: offset)
            // Finalize each read before source validation. Rejected derived hits do
            // not spend result slots: continue in rank order until full or exhausted.
            for item in batch {
                if try (![GlobalSearchKind.chat, .recap].contains(item.kind) ||
                        (validateDerived?(item.kind, item.sourceID) ?? false)) {
                    result.append(item)
                    if result.count == limit { break }
                }
            }
            // OFFSET is valid only while the source set/ranking stays unchanged.
            // Restart the entire query on mutation, including previously accepted hits.
            guard try dataVersion() == revision else { throw GlobalSearchError.changedSources }
            if batch.count < batchSize { break }
            offset += batch.count
        }
        return result
    }

    private struct Source {
        let prefix: String
        let tables: [String]
        let watches: [(String, String)]
        let select: String
        var version: Int { ["meeting", "quill", "chat", "recap"].contains(prefix) ? 2 : 1 }
        var view: String { "global_search_\(prefix)_v\(version)" }
        var triggerNames: [String] {
            watches.flatMap { table, _ in ["INSERT", "UPDATE", "DELETE"].map { "\(view)_\(table)_\($0)" } }
        }
        var primaryKey: String { prefix == "recap" ? "day_key" : prefix == "meeting" ? "m.id" : ["quill", "cotypist", "chat"].contains(prefix) ? "c.id" : "id" }
    }
    private static func unix(_ expression: String) -> String { "coalesce((julianday(\(expression))-2440587.5)*86400.0,0)" }
    private static let sources: [Source] = [
        .init(prefix: "vidshot", tables: ["vidshots"], watches: [("vidshots", "id")], select: """
            SELECT 'vidshot:' || id AS identity,'vidshot' AS kind,id AS source_id,created_at AS timestamp,
                title,coalesce(CASE WHEN json_valid(body) THEN json_extract(body,'$.transcript') END,'') AS text,
                coalesce(CASE WHEN json_valid(body) THEN json_extract(body,'$.targetApp') END,'') AS app_name,'' AS bundle_id
            FROM vidshots WHERE state IN ('ready','recovered','failed')
            """),
        .init(prefix: "dictation", tables: ["dictations"], watches: [("dictations", "id")], select: """
            SELECT 'dictation:' || id AS identity, CASE WHEN source='cua' THEN 'command' ELSE 'dictation' END AS kind,
                CAST(id AS TEXT) AS source_id, \(unix("timestamp")) AS timestamp,
                substr(coalesce(raw_text,''),1,100) AS title, coalesce(raw_text,'') AS text,
                coalesce(target_app_name,'') AS app_name,coalesce(target_app_bundle_id,'') AS bundle_id
            FROM dictations WHERE deleted_at IS NULL
            """),
        .init(prefix: "meeting", tables: ["meetings", "meeting_participants"], watches: [("meetings", "id"), ("meeting_participants", "meeting_id")], select: """
            SELECT 'meeting:' || m.id AS identity,'meeting' AS kind,CAST(m.id AS TEXT) AS source_id,
                \(unix("m.start_time")) AS timestamp, m.title,
                coalesce(m.raw_transcript,'') || char(10) || coalesce(m.manual_notes,'') || char(10) || coalesce(m.formatted_notes,'') || char(10) ||
                coalesce((SELECT group_concat(p.display_name || ' ' || coalesce(p.email_address,''),char(10))
                          FROM meeting_participants p WHERE p.meeting_id=m.id AND p.is_suppressed=0),'') AS text,
                '' AS app_name,'' AS bundle_id FROM meetings m WHERE m.deleted_at IS NULL
            """),
        .init(prefix: "quill", tables: ["quill_conversations","quill_conversation_turns"],
              watches: [("quill_conversations","id"),("quill_conversation_turns","conversation_id")], select: """
            SELECT 'quill:' || c.id AS identity,'quill' AS kind,CAST(c.id AS TEXT) AS source_id,
                \(unix("c.timestamp")) AS timestamp,'Quill conversation' AS title,
                coalesce((SELECT group_concat(coalesce(CASE WHEN json_valid(body) THEN json_extract(body,'$.question') END,'') || char(10) ||
                    coalesce(CASE WHEN json_valid(body) THEN json_extract(body,'$.answer') END,''),char(10)) FROM quill_conversation_turns WHERE conversation_id=c.id),'') AS text,
                '' AS app_name,'' AS bundle_id FROM quill_conversations c WHERE deleted_at IS NULL
            """),
        .init(prefix: "cotypist", tables: ["cotypist_sessions","cotypist_suggestions"],
              watches: [("cotypist_sessions","id"),("cotypist_suggestions","session_id")], select: """
            SELECT 'cotypist:' || c.id AS identity,'cotypist' AS kind,CAST(c.id AS TEXT) AS source_id,
                \(unix("c.timestamp")) AS timestamp,'Cotypist writing' AS title,
                coalesce((SELECT group_concat(accepted_text,char(10)) FROM cotypist_suggestions WHERE session_id=c.id AND accepted_text!=''),'') AS text,
                c.target_app_name AS app_name,c.target_app_bundle_id AS bundle_id FROM cotypist_sessions c WHERE deleted_at IS NULL
            """),
        .init(prefix: "chat", tables: ["meeting_chat_sessions","meeting_chat_turns"],
              watches: [("meeting_chat_sessions","id"),("meeting_chat_turns","session_id")], select: """
            SELECT 'chat:' || c.id AS identity,'chat' AS kind,c.id AS source_id,c.updated_at AS timestamp,
                coalesce(CASE WHEN json_valid(c.body) THEN json_extract(c.body,'$.title') END,'Chat') AS title,
                coalesce((SELECT group_concat(coalesce(CASE WHEN json_valid(body) THEN json_extract(body,'$.question') END,'') || char(10) ||
                    CASE WHEN state='completed' THEN coalesce(CASE WHEN json_valid(body) THEN json_extract(body,'$.originalAnswer') END,'') ELSE '' END,char(10))
                    FROM meeting_chat_turns WHERE session_id=c.id AND state!='sourceDeleted'),'') AS text,
                '' AS app_name,'' AS bundle_id FROM meeting_chat_sessions c WHERE 1
            """),
        .init(prefix: "recap", tables: ["time_turner_recaps"], watches: [("time_turner_recaps","day_key")], select: """
            SELECT 'recap:' || day_key AS identity,'recap' AS kind,day_key AS source_id,day_start AS timestamp,
                'Daily recap' AS title,coalesce((SELECT group_concat(CASE WHEN json_valid(value) THEN json_extract(value,'$.text') END,char(10))
                    FROM json_each(body,'$.insights')),'') AS text,'' AS app_name,'' AS bundle_id
            FROM time_turner_recaps WHERE CASE WHEN json_valid(body) THEN json_extract(body,'$.version') END=1
            """)
    ]
}

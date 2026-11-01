import Foundation
import SQLite3

public enum GlobalSearchError: Error { case changedSources }

/// Source identities remain owned by their stores. Search never becomes a second history store.
public enum GlobalSearchKind: String, CaseIterable, Codable, Sendable {
    case dictation, meeting, command, quill, cotypist, screenHistory, chat, recap
}

public struct GlobalSearchQuery: Sendable {
    public var text: String
    public var kinds: Set<GlobalSearchKind>
    public var from: Date
    public var until: Date
    public var app: String?
    public var limit: Int
    public init(text: String, kinds: Set<GlobalSearchKind> = Set(GlobalSearchKind.allCases),
                from: Date = .distantPast, until: Date = .distantFuture, app: String? = nil, limit: Int = 50) {
        self.text = text; self.kinds = kinds; self.from = from; self.until = until; self.app = app; self.limit = limit
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
                guard try source.tables.allSatisfy({ try exists($0) }), !(try exists(source.view)) else { continue }
                try execute("CREATE VIEW \(source.view) AS \(source.select)")
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
                        try execute("CREATE TRIGGER \(source.view)_\(table)_\(event) AFTER \(event) ON \(table) BEGIN \(refresh) END")
                    }
                }
            }
            try execute("COMMIT")
            installedSchemaVersion = try schemaVersion()
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Bounded, literal phrase search. An empty kind set means no results, never all content.
    /// Chat and recaps require the application's current-source validator before any derived text is exposed.
    public func search(_ query: GlobalSearchQuery, validateDerived: ((GlobalSearchKind, String) throws -> Bool)? = nil) throws -> [GlobalSearchResult] {
        lock.lock(); defer { lock.unlock() }
        guard !query.kinds.isEmpty, query.from < query.until else { return [] }
        try installAvailableSources()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096 else { return [] }
        let kinds = query.kinds.subtracting([.screenHistory]).map(\.rawValue).sorted()
        guard !kinds.isEmpty else { return [] }
        let appClause = query.app == nil ? "" : " AND (d.bundle_id=? COLLATE NOCASE OR d.app_name=? COLLATE NOCASE)"
        let revision = try dataVersion()
        var s = try prepare("""
            SELECT d.kind,d.source_id,d.timestamp,d.title,
                snippet(global_search_fts,-1,'','',' … ',28),d.app_name,d.bundle_id
            FROM global_search_fts JOIN global_search_documents d ON d.rowid=global_search_fts.rowid
            WHERE global_search_fts MATCH ? AND d.timestamp>=? AND d.timestamp<?
                AND d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))\(appClause)
            ORDER BY bm25(global_search_fts,4.0,1.0),d.timestamp DESC,d.identity LIMIT ?
            """)
        defer { sqlite3_finalize(s) }
        bind("\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"", s, 1)
        sqlite3_bind_double(s, 2, query.from.timeIntervalSince1970)
        sqlite3_bind_double(s, 3, query.until.timeIntervalSince1970)
        var slot: Int32 = 4
        for kind in kinds { bind(kind, s, slot); slot += 1 }
        if let app = query.app { bind(app, s, slot); bind(app, s, slot + 1); slot += 2 }
        sqlite3_bind_int(s, slot, Int32(max(1, min(200, query.limit))))
        var result: [GlobalSearchResult] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            func string(_ column: Int32) -> String { sqlite3_column_text(s, column).map { String(cString: $0) } ?? "" }
            if let kind = GlobalSearchKind(rawValue: string(0)) {
                result.append(.init(kind: kind, sourceID: string(1), date: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                    title: string(3), excerpt: string(4), appName: string(5), bundleID: string(6), mediaAvailable: false))
            }
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw Self.error }
        sqlite3_finalize(s); s = nil
        // Validate outside the FTS read snapshot. Source deletion must not race a cached excerpt.
        result = try result.filter { item in
            try (![GlobalSearchKind.chat, .recap].contains(item.kind) || (validateDerived?(item.kind, item.sourceID) ?? false))
        }
        guard try dataVersion() == revision else { throw GlobalSearchError.changedSources }
        return result
    }

    private struct Source {
        let prefix: String
        let tables: [String]
        let watches: [(String, String)]
        let select: String
        var view: String { "global_search_\(prefix)_v1" }
        var primaryKey: String { prefix == "recap" ? "day_key" : ["quill", "cotypist", "chat"].contains(prefix) ? "c.id" : "id" }
    }
    private static func unix(_ expression: String) -> String { "coalesce((julianday(\(expression))-2440587.5)*86400.0,0)" }
    private static let sources: [Source] = [
        .init(prefix: "dictation", tables: ["dictations"], watches: [("dictations", "id")], select: """
            SELECT 'dictation:' || id AS identity, CASE WHEN source='cua' THEN 'command' ELSE 'dictation' END AS kind,
                CAST(id AS TEXT) AS source_id, \(unix("timestamp")) AS timestamp,
                substr(coalesce(raw_text,''),1,100) AS title, coalesce(raw_text,'') AS text,
                coalesce(target_app_name,'') AS app_name,coalesce(target_app_bundle_id,'') AS bundle_id
            FROM dictations WHERE deleted_at IS NULL
            """),
        .init(prefix: "meeting", tables: ["meetings"], watches: [("meetings", "id")], select: """
            SELECT 'meeting:' || id AS identity,'meeting' AS kind,CAST(id AS TEXT) AS source_id,
                \(unix("start_time")) AS timestamp, title,
                coalesce(raw_transcript,'') || char(10) || coalesce(manual_notes,'') || char(10) || coalesce(formatted_notes,'') AS text,
                '' AS app_name,'' AS bundle_id FROM meetings WHERE deleted_at IS NULL
            """),
        .init(prefix: "quill", tables: ["quill_conversations","quill_conversation_turns"],
              watches: [("quill_conversations","id"),("quill_conversation_turns","conversation_id")], select: """
            SELECT 'quill:' || c.id AS identity,'quill' AS kind,CAST(c.id AS TEXT) AS source_id,
                \(unix("c.timestamp")) AS timestamp,'Quill conversation' AS title,
                coalesce((SELECT group_concat(coalesce(json_extract(body,'$.question'),'') || char(10) ||
                    coalesce(json_extract(body,'$.answer'),''),char(10)) FROM quill_conversation_turns WHERE conversation_id=c.id),'') AS text,
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
                coalesce(json_extract(c.body,'$.title'),'Chat') AS title,
                coalesce((SELECT group_concat(coalesce(json_extract(body,'$.question'),'') || char(10) ||
                    CASE WHEN state='completed' THEN coalesce(json_extract(body,'$.originalAnswer'),'') ELSE '' END,char(10))
                    FROM meeting_chat_turns WHERE session_id=c.id AND state!='sourceDeleted'),'') AS text,
                '' AS app_name,'' AS bundle_id FROM meeting_chat_sessions c WHERE 1
            """),
        .init(prefix: "recap", tables: ["time_turner_recaps"], watches: [("time_turner_recaps","day_key")], select: """
            SELECT 'recap:' || day_key AS identity,'recap' AS kind,day_key AS source_id,day_start AS timestamp,
                'Daily recap' AS title,coalesce((SELECT group_concat(json_extract(value,'$.text'),char(10))
                    FROM json_each(body,'$.insights')),'') AS text,'' AS app_name,'' AS bundle_id
            FROM time_turner_recaps WHERE json_extract(body,'$.version')=1
            """)
    ]
}

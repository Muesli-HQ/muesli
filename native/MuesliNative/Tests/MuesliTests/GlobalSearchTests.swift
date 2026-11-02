import Foundation
import SQLite3
import Testing
import MuesliCore

@Suite("Global search")
struct GlobalSearchTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("global-search-\(UUID())")
        var db: OpaquePointer?
        var url: URL { root.appendingPathComponent("muesli.db") }
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            try sql("""
                PRAGMA foreign_keys=ON;
                PRAGMA journal_mode=WAL;
                CREATE TABLE dictations(id INTEGER PRIMARY KEY,timestamp TEXT,raw_text TEXT,source TEXT,target_app_name TEXT,target_app_bundle_id TEXT,deleted_at REAL);
                CREATE TABLE computer_use_traces(dictation_id INTEGER,final_message TEXT,trace_json TEXT);
                CREATE TABLE meetings(id INTEGER PRIMARY KEY,start_time TEXT,title TEXT,raw_transcript TEXT,manual_notes TEXT,formatted_notes TEXT,deleted_at REAL);
                CREATE TABLE quill_conversations(id INTEGER PRIMARY KEY,timestamp TEXT,deleted_at REAL);
                CREATE TABLE quill_conversation_turns(id INTEGER PRIMARY KEY,conversation_id INTEGER REFERENCES quill_conversations(id) ON DELETE CASCADE,body TEXT);
                CREATE TABLE cotypist_sessions(id INTEGER PRIMARY KEY,timestamp TEXT,target_app_name TEXT,target_app_bundle_id TEXT,deleted_at REAL);
                CREATE TABLE cotypist_suggestions(id INTEGER PRIMARY KEY,session_id INTEGER REFERENCES cotypist_sessions(id) ON DELETE CASCADE,accepted_text TEXT,suggestion_text TEXT);
                CREATE TABLE meeting_chat_sessions(id TEXT PRIMARY KEY,body TEXT,updated_at REAL);
                CREATE TABLE meeting_chat_turns(id TEXT PRIMARY KEY,session_id TEXT REFERENCES meeting_chat_sessions(id) ON DELETE CASCADE,state TEXT,body TEXT);
                """)
        }
        func sql(_ text: String) throws {
            guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)) + " SQL: " + text])
            }
        }
        func reopenWriter() throws {
            sqlite3_close(db)
            db = nil
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            try sql("PRAGMA foreign_keys=ON")
        }
        deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
    }

    @Test("Unvalidated derived kinds cannot consume the result limit")
    func derivedKindsBeforeLimit() throws {
        let f = try Fixture()
        try f.sql("""
            INSERT INTO dictations VALUES(1,'2026-11-01T10:00:00Z','Some longer ordinary orchid dictation with additional words','dictation','Editor','com.test.editor',NULL);
            INSERT INTO meeting_chat_sessions VALUES('chat','{"title":"orchid"}',1793527200);
            INSERT INTO meeting_chat_turns VALUES('turn','chat','completed','{"question":"orchid","originalAnswer":"orchid"}');
            CREATE TABLE time_turner_recaps(day_key TEXT PRIMARY KEY,day_start REAL,body TEXT);
            INSERT INTO time_turner_recaps VALUES('day',1793527200,'{"version":1,"insights":[{"text":"orchid"}]}');
            """)
        let index = try GlobalSearchIndex(databaseURL: f.url)
        let query = GlobalSearchQuery(text: "orchid", limit: 1)
        #expect(try index.search(query, validateDerived: { _, _ in true }).first?.kind == .chat)
        #expect(try index.search(query).map(\.sourceID) == ["1"])
        #expect(try index.search(.init(text: "orchid", kinds: [.chat, .recap], limit: 1)).isEmpty)
    }

    @Test("Malformed JSON does not block backfill, trigger writes, or unrelated results")
    func malformedBodies() throws {
        let f = try Fixture()
        try f.sql("""
            INSERT INTO dictations VALUES(1,'2026-11-01T10:00:00Z','orchid','dictation','Editor','com.test.editor',NULL);
            INSERT INTO quill_conversations VALUES(1,'2026-11-01T10:00:00Z',NULL);
            INSERT INTO quill_conversation_turns VALUES(1,1,'{bad');
            INSERT INTO meeting_chat_sessions VALUES('chat','{bad',1793527200);
            INSERT INTO meeting_chat_turns VALUES('turn','chat','completed','{bad');
            CREATE TABLE time_turner_recaps(day_key TEXT PRIMARY KEY,day_start REAL,body TEXT);
            INSERT INTO time_turner_recaps VALUES('bad',1793527200,'{bad');
            INSERT INTO time_turner_recaps VALUES('shape',1793527200,'{"version":1,"insights":["plain text",{"text":"violet"}]}');
            """)
        let index = try GlobalSearchIndex(databaseURL: f.url)
        #expect(try index.search(.init(text: "orchid")).map(\.sourceID) == ["1"])
        #expect(try index.search(.init(text: "violet"), validateDerived: { _, _ in true }).count == 1)
        // Triggers must not turn a malformed sibling into a failure of a valid write.
        try f.sql("""
            INSERT INTO quill_conversation_turns VALUES(2,1,'{"question":"lily","answer":"answer"}');
            INSERT INTO meeting_chat_turns VALUES('good','chat','completed','{"question":"lily","originalAnswer":"answer"}');
            UPDATE quill_conversation_turns SET body='{still bad' WHERE id=1;
            UPDATE meeting_chat_sessions SET body='{still bad' WHERE id='chat';
            UPDATE meeting_chat_turns SET body='{still bad' WHERE id='turn';
            UPDATE time_turner_recaps SET body='{still bad' WHERE day_key='bad';
            INSERT INTO time_turner_recaps VALUES('anotherbad',1793527200,'{bad');
            """)
        #expect(Set(try index.search(.init(text: "lily"), validateDerived: { _, _ in true }).map(\.kind)) == [.quill, .chat])
        try f.sql("DELETE FROM quill_conversation_turns WHERE id=2; DELETE FROM meeting_chat_turns WHERE id='good';")
        #expect(try index.search(.init(text: "lily"), validateDerived: { _, _ in true }).isEmpty)
    }

    @Test("Existing JSON projection triggers are replaced and their documents backfilled")
    func upgradeJSONProjections() throws {
        let f = try Fixture()
        try f.sql("""
            INSERT INTO quill_conversations VALUES(1,'2026-11-01T10:00:00Z',NULL);
            INSERT INTO quill_conversation_turns VALUES(1,1,'{"question":"orchid","answer":"answer"}');
            CREATE TABLE time_turner_recaps(day_key TEXT PRIMARY KEY,day_start REAL,body TEXT);
            """)
        _ = try GlobalSearchIndex(databaseURL: f.url)
        let sources = [
            ("quill", ["quill_conversations", "quill_conversation_turns"], "quill_conversation_turns"),
            ("chat", ["meeting_chat_sessions", "meeting_chat_turns"], "meeting_chat_turns"),
            ("recap", ["time_turner_recaps"], "time_turner_recaps")
        ]
        for (prefix, tables, bodyTable) in sources {
            for table in tables {
                for event in ["INSERT", "UPDATE", "DELETE"] {
                    try f.sql("DROP TRIGGER global_search_\(prefix)_v2_\(table)_\(event)")
                }
            }
            try f.sql("DROP VIEW global_search_\(prefix)_v2")
            try f.sql("CREATE VIEW global_search_\(prefix)_v1 AS SELECT json_extract(body,'$.question') FROM \(bodyTable)")
            for event in ["INSERT", "UPDATE", "DELETE"] {
                let row = event == "DELETE" ? "OLD" : "NEW"
                try f.sql("CREATE TRIGGER global_search_\(prefix)_v1_\(bodyTable)_\(event) AFTER \(event) ON \(bodyTable) BEGIN SELECT json_extract(\(row).body,'$.question'); END")
            }
        }
        try f.sql("UPDATE global_search_documents SET text='obsolete', title='obsolete' WHERE kind='quill'")
        let upgraded = try GlobalSearchIndex(databaseURL: f.url)
        #expect(try upgraded.search(.init(text: "obsolete")).isEmpty)
        #expect(try upgraded.search(.init(text: "orchid")).count == 1)
        try f.sql("""
            UPDATE quill_conversation_turns SET body='{bad' WHERE id=1;
            INSERT INTO meeting_chat_sessions VALUES('chat','{bad',1793527200);
            INSERT INTO meeting_chat_turns VALUES('turn','chat','completed','{bad');
            INSERT INTO time_turner_recaps VALUES('bad',1793527200,'{bad');
            """)
        #expect(try upgraded.search(.init(text: "orchid")).isEmpty)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_prepare_v2(f.db, "SELECT count(*) FROM sqlite_master WHERE name GLOB 'global_search_quill_v1*' OR name GLOB 'global_search_chat_v1*' OR name GLOB 'global_search_recap_v1*'", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
    }

    @Test("Backfill and live mutation share an index; soft and hard deletion remove text")
    func deletionAndUpdates() throws {
        let f = try Fixture()
        try f.sql("INSERT INTO dictations VALUES(1,'2026-11-01T10:00:00Z','orchid input','dictation','Editor','com.test.editor',NULL)")
        let index = try GlobalSearchIndex(databaseURL: f.url)
        #expect(try index.search(.init(text: "orchid")).map(\.sourceID) == ["1"])
        try f.sql("UPDATE dictations SET raw_text='violet replacement' WHERE id=1")
        #expect(try index.search(.init(text: "orchid")).isEmpty)
        #expect(try index.search(.init(text: "violet")).count == 1)
        try f.sql("UPDATE dictations SET deleted_at=1 WHERE id=1")
        #expect(try index.search(.init(text: "violet")).isEmpty)
        try f.sql("INSERT INTO dictations VALUES(2,'2026-11-01T11:00:00Z','new orchid','cua','Editor','com.test.editor',NULL)")
        try f.sql("INSERT INTO computer_use_traces VALUES(2,'secret result','secret trace')")
        #expect(try index.search(.init(text: "secret")).isEmpty)
        #expect(try index.search(.init(text: "orchid", kinds: [.command])).count == 1)
        #expect(try index.search(.init(text: "orchid", kinds: [.dictation])).isEmpty)
        try f.sql("DELETE FROM dictations WHERE id=2")
        #expect(try index.search(.init(text: "orchid")).isEmpty)
    }

    @Test("Meetings deduplicate fields; filters apply before limits and FTS syntax stays literal")
    func filtersAndLiteralQuery() throws {
        let f = try Fixture()
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("""
            INSERT INTO meetings VALUES(4,'2026-11-01T10:00:00Z','Orchid review','orchid transcript','orchid written','orchid generated',NULL);
            INSERT INTO dictations VALUES(5,'2026-11-02T11:00:00Z','orchid','dictation','Browser','com.test.browser',NULL);
            INSERT INTO dictations VALUES(6,'2026-11-01T11:00:00Z','orchid','dictation','Editor','com.test.editor',NULL);
            """)
        #expect(try index.search(.init(text: "orchid", kinds: [.meeting])).count == 1)
        #expect(try index.search(.init(text: "orchid", app: "EDITOR", limit: 1)).first?.sourceID == "6")
        #expect(try index.search(.init(text: "orchid", kinds: [])).isEmpty)
        #expect(try index.search(.init(text: "orchid OR secret")).isEmpty)
        #expect(try index.search(.init(text: "\"")).isEmpty)
        let end = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!
        #expect(try index.search(.init(text: "orchid", until: end)).count == 2)
    }

    @Test("Only accepted Cotypist text and saved Quill exchanges are searchable")
    func writingSources() throws {
        let f = try Fixture()
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("""
            INSERT INTO quill_conversations VALUES(1,'2026-11-01T10:00:00Z',NULL);
            INSERT INTO quill_conversation_turns VALUES(1,1,'{"question":"orchid request","answer":"violet response"}');
            INSERT INTO cotypist_sessions VALUES(2,'2026-11-01T10:00:00Z','Editor','com.test.editor',NULL);
            INSERT INTO cotypist_suggestions VALUES(2,2,'accepted orchid','unaccepted secret');
            """)
        #expect(try index.search(.init(text: "orchid")).count == 2)
        #expect(try index.search(.init(text: "violet", kinds: [.quill])).count == 1)
        #expect(try index.search(.init(text: "secret")).isEmpty)
        try f.sql("DELETE FROM quill_conversations WHERE id=1; UPDATE cotypist_sessions SET deleted_at=1 WHERE id=2;")
        #expect(try index.search(.init(text: "orchid")).isEmpty)
    }

    @Test("Chat invalidation removes answers and excluded private model fields never enter index")
    func chatInvalidation() throws {
        let f = try Fixture()
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("""
            INSERT INTO meeting_chat_sessions VALUES('chat','{"title":"Planning"}',1793527200);
            INSERT INTO meeting_chat_turns VALUES('turn','chat','completed','{"question":"orchid question","originalAnswer":"violet answer","editableDraft":"private draft","provider":"privateprovider"}');
            """)
        #expect(try index.search(.init(text: "violet", kinds: [.chat]), validateDerived: { _, _ in true }).count == 1)
        #expect(try index.search(.init(text: "private"), validateDerived: { _, _ in true }).isEmpty)
        #expect(try index.search(.init(text: "violet", kinds: [.chat])).isEmpty)
        try f.sql("UPDATE meeting_chat_turns SET state='sourceDeleted' WHERE id='turn'")
        #expect(try index.search(.init(text: "violet"), validateDerived: { _, _ in true }).isEmpty)
        #expect(try index.search(.init(text: "orchid"), validateDerived: { _, _ in true }).isEmpty)
        try f.sql("DELETE FROM meeting_chat_sessions WHERE id='chat'")
        #expect(try index.search(.init(text: "Planning")).isEmpty)
    }

    @Test("Lazy recap discovery, required source validation, replacement and deletion")
    func recaps() throws {
        let f = try Fixture()
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("""
            CREATE TABLE time_turner_recaps(day_key TEXT PRIMARY KEY,day_start REAL,body TEXT);
            INSERT INTO time_turner_recaps VALUES('day',1793527200,'{"version":1,"insights":[{"text":"orchid insight"}],"sources":[{"excerpt":"private source snapshot"}]}');
            """)
        #expect(try index.search(.init(text: "orchid")).isEmpty)
        #expect(try index.search(.init(text: "orchid"), validateDerived: { $0 == .recap && $1 == "day" }).count == 1)
        #expect(try index.search(.init(text: "private"), validateDerived: { _, _ in true }).isEmpty)
        try f.sql("INSERT OR REPLACE INTO time_turner_recaps VALUES('day',1793527200,'{\"version\":1,\"insights\":[{\"text\":\"violet insight\"}]}')")
        #expect(try index.search(.init(text: "orchid"), validateDerived: { _, _ in true }).isEmpty)
        #expect(try index.search(.init(text: "violet"), validateDerived: { _, _ in true }).count == 1)
        try f.sql("DELETE FROM time_turner_recaps")
        #expect(try index.search(.init(text: "violet"), validateDerived: { _, _ in true }).isEmpty)
    }

    @Test("A mutation during source validation cannot publish an old excerpt")
    func mutationDuringValidation() throws {
        let f = try Fixture()
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("""
            CREATE TABLE time_turner_recaps(day_key TEXT PRIMARY KEY,day_start REAL,body TEXT);
            INSERT INTO time_turner_recaps VALUES('day',1793527200,'{"version":1,"insights":[{"text":"orchid insight"}]}');
            """)
        let hits = try index.search(.init(text: "orchid"), validateDerived: { _, _ in
            try f.sql("DELETE FROM time_turner_recaps")
            return true
        })
        #expect(hits.isEmpty)
    }

    @Test("A missing source trigger or recreated table rebuilds stale documents", arguments: [false, true])
    func repairSourceTriggers(recreateTable: Bool) throws {
        let f = try Fixture()
        try f.sql("INSERT INTO dictations VALUES(1,'2026-11-01T10:00:00Z','old orchid','dictation','Editor','com.test.editor',NULL)")
        let index = try GlobalSearchIndex(databaseURL: f.url)
        #expect(try index.search(.init(text: "orchid")).count == 1)
        if recreateTable {
            try f.sql("""
                DROP TABLE dictations;
                CREATE TABLE dictations(id INTEGER PRIMARY KEY,timestamp TEXT,raw_text TEXT,source TEXT,target_app_name TEXT,target_app_bundle_id TEXT,deleted_at REAL);
                """)
        } else {
            try f.sql("DROP TRIGGER global_search_dictation_v1_dictations_DELETE; DELETE FROM dictations")
        }
        try f.sql("INSERT INTO dictations VALUES(2,'2026-11-01T10:00:00Z','new violet','cua','Editor','com.test.editor',NULL)")
        #expect(try index.search(.init(text: "orchid")).isEmpty)
        #expect(try index.search(.init(text: "violet", kinds: [.command])).map(\.sourceID) == ["2"])
        // The repaired triggers must keep future writes searchable and deletions private.
        try f.sql("UPDATE dictations SET raw_text='lily replacement' WHERE id=2")
        #expect(try index.search(.init(text: "violet")).isEmpty)
        #expect(try index.search(.init(text: "lily")).count == 1)
        try f.sql("DELETE FROM dictations WHERE id=2")
        #expect(try index.search(.init(text: "lily")).isEmpty)
        let reopened = try GlobalSearchIndex(databaseURL: f.url)
        #expect(try reopened.search(.init(text: "orchid")).isEmpty)
    }

    @Test("Recreating a child source table restores all parent-document triggers")
    func repairChildSourceTriggers() throws {
        let f = try Fixture()
        try f.sql("""
            INSERT INTO quill_conversations VALUES(1,'2026-11-01T10:00:00Z',NULL);
            INSERT INTO quill_conversation_turns VALUES(1,1,'{"question":"orchid","answer":"old answer"}');
            """)
        let index = try GlobalSearchIndex(databaseURL: f.url)
        #expect(try index.search(.init(text: "orchid")).count == 1)
        try f.sql("""
            DROP TABLE quill_conversation_turns;
            CREATE TABLE quill_conversation_turns(id INTEGER PRIMARY KEY,conversation_id INTEGER REFERENCES quill_conversations(id) ON DELETE CASCADE,body TEXT);
            INSERT INTO quill_conversation_turns VALUES(2,1,'{"question":"violet","answer":"new answer"}');
            """)
        #expect(try index.search(.init(text: "orchid")).isEmpty)
        #expect(try index.search(.init(text: "violet")).count == 1)
        // DictationStore opens a fresh connection per mutation after migration.
        // Do not retain SQLite's pre-repair foreign-key schema on the fixture writer.
        try f.reopenWriter()
        try f.sql("INSERT INTO quill_conversation_turns VALUES(3,1,'{\"question\":\"lily\",\"answer\":\"later answer\"}')")
        #expect(try index.search(.init(text: "lily")).count == 1)
        try f.sql("DELETE FROM quill_conversations WHERE id=1")
        #expect(try index.search(.init(text: "violet")).isEmpty)
    }

    @Test("An unrelated write during validation is retried without failing search")
    func unrelatedWriteDuringValidation() throws {
        let f = try Fixture()
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("""
            INSERT INTO meeting_chat_sessions VALUES('chat','{"title":"Orchid"}',1793527200);
            INSERT INTO meeting_chat_turns VALUES('turn','chat','completed','{"question":"orchid question","originalAnswer":"orchid answer"}');
            """)
        var validations = 0
        let hits = try index.search(.init(text: "orchid", kinds: [.chat]), validateDerived: { _, _ in
            validations += 1
            if validations == 1 { try f.sql("INSERT INTO computer_use_traces VALUES(99,'unrelated result','unrelated trace')") }
            return true
        })
        #expect(hits.map(\.sourceID) == ["chat"])
        #expect(validations == 2)
    }

    @Test("Repeated writes remain bounded and fail closed after one retry")
    func repeatedWritesDuringValidation() throws {
        let f = try Fixture()
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("""
            INSERT INTO meeting_chat_sessions VALUES('chat','{"title":"Orchid"}',1793527200);
            INSERT INTO meeting_chat_turns VALUES('turn','chat','completed','{"question":"orchid","originalAnswer":"orchid answer"}');
            """)
        var validations = 0
        #expect(throws: GlobalSearchError.self) {
            try index.search(.init(text: "orchid", kinds: [.chat]), validateDerived: { _, _ in
                validations += 1
                try f.sql("UPDATE meeting_chat_sessions SET updated_at=updated_at+1 WHERE id='chat'")
                return true
            })
        }
        #expect(validations == 2)
    }

    @Test("Federated OCR remains searchable after media expiry and disappears after history deletion")
    func screenHistory() throws {
        let f = try Fixture()
        let memory = try VisualMemoryStore(root: f.root.appendingPathComponent("visual-memory"))
        let capture = VisualMemoryItem(id: "capture", kind: .moment, capturedAt: Date(), source: "Editor · Project", bundleID: "com.test.editor", text: "orchid screen", path: "capture.png", bytes: 1)
        try memory.save([capture])
        let service = try GlobalSearchService(databaseURL: f.url, screenHistory: memory)
        #expect(try service.search(.init(text: "orchid", kinds: [.screenHistory])).first?.sourceID == "capture")
        try memory.applyRetention(.init(screenshotDays: 1, historyDays: 30, mediaBudgetBytes: 100), now: Date().addingTimeInterval(2 * 86400))
        #expect(try service.search(.init(text: "orchid")).first?.mediaAvailable == false)
        try memory.delete(ids: ["capture"])
        #expect(try service.search(.init(text: "orchid")).isEmpty)
    }
}

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
                throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
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
        #expect(throws: GlobalSearchError.self) {
            try index.search(.init(text: "orchid"), validateDerived: { _, _ in
                try f.sql("DELETE FROM time_turner_recaps")
                return true
            })
        }
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

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
                CREATE TABLE meeting_participants(meeting_id INTEGER,participant_identifier TEXT,display_name TEXT,email_address TEXT,is_suppressed INTEGER NOT NULL DEFAULT 0);
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

    @Test("Participant names and email addresses follow meeting search updates")
    func meetingParticipantsAreIndexed() throws {
        let f = try Fixture()
        try f.sql("""
            INSERT INTO meetings VALUES(1,'2026-11-01T10:00:00Z','Planning','','','',NULL);
            INSERT INTO meeting_participants VALUES(1,'person:1','Amara Stone','amara@example.test',0);
            """)
        let index = try GlobalSearchIndex(databaseURL: f.url)
        #expect(try index.search(.init(text: "Amara", kinds: [.meeting])).map(\.sourceID) == ["1"])
        #expect(try index.search(.init(text: "amara@example.test", kinds: [.meeting])).map(\.sourceID) == ["1"])
        let person = MeetingParticipantDraft(participantIdentifier: "person:1", displayName: "Amara Stone", emailAddress: "amara@example.test")
        #expect(try index.search(.init(text: "", kinds: [.meeting], person: person)).map(\.sourceID) == ["1"])
        #expect(try index.search(.init(text: "absent", kinds: [.meeting], person: person)).isEmpty)
        try f.sql("UPDATE meeting_participants SET display_name='Bianca',email_address='bianca@example.test' WHERE meeting_id=1")
        #expect(try index.search(.init(text: "Amara", kinds: [.meeting])).isEmpty)
        #expect(try index.search(.init(text: "Bianca", kinds: [.meeting])).count == 1)
        try f.sql("UPDATE meeting_participants SET is_suppressed=1 WHERE meeting_id=1")
        #expect(try index.search(.init(text: "Bianca", kinds: [.meeting])).isEmpty)
        #expect(try index.search(.init(text: "", kinds: [.meeting], person: person)).isEmpty)
        try f.sql("UPDATE meeting_participants SET is_suppressed=0 WHERE meeting_id=1")
        try f.sql("DELETE FROM meeting_participants WHERE meeting_id=1")
        #expect(try index.search(.init(text: "Bianca", kinds: [.meeting])).isEmpty)
    }

    @Test("Identity-only participant updates do not rewrite meeting transcripts")
    func participantIdentityUpdatesDoNotReindex() throws {
        let f = try Fixture()
        try f.sql("""
            ALTER TABLE meeting_participants ADD COLUMN person_id TEXT;
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<250)
              INSERT INTO meetings SELECT i,'2026-11-01T10:00:00Z','Meeting',hex(zeroblob(10000)),'','',NULL FROM n;
            INSERT INTO meeting_participants SELECT id,'contact:alice','Alice',NULL,0,'before' FROM meetings;
            """)
        let index = try GlobalSearchIndex(databaseURL: f.url)
        // Simulate an installation with the older unrestricted v2 trigger.
        try f.sql("""
            DROP TRIGGER global_search_meeting_v2_meeting_participants_UPDATE;
            CREATE TRIGGER global_search_meeting_v2_meeting_participants_UPDATE AFTER UPDATE ON meeting_participants
              BEGIN DELETE FROM global_search_documents WHERE identity='meeting:' || OLD.meeting_id; END;
            """)
        let upgraded = try GlobalSearchIndex(databaseURL: f.url)
        _ = upgraded
        try f.sql("""
            CREATE TABLE search_rewrites(n INTEGER);
            CREATE TRIGGER count_search_deletes AFTER DELETE ON global_search_documents BEGIN INSERT INTO search_rewrites VALUES(1); END;
            UPDATE meeting_participants SET person_id='after';
            """)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(f.db, "SELECT count(*) FROM search_rewrites", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
        sqlite3_reset(statement)
        try f.sql("UPDATE meeting_participants SET display_name='Bianca' WHERE meeting_id=1")
        #expect(try index.search(.init(text: "Bianca", kinds: [.meeting])).map(\.sourceID) == ["1"])
    }

    @Test("Person meeting results can page through more than 100 meetings")
    func personMeetingPages() throws {
        let f = try Fixture()
        for id in 1...105 {
            try f.sql("INSERT INTO meetings VALUES(\(id),'2026-11-01T10:00:00Z','Meeting','','','',NULL)")
            try f.sql("INSERT INTO meeting_participants VALUES(\(id),'contact:alice','Alice','alice@example.test',0)")
        }
        let service = try GlobalSearchService(databaseURL: f.url)
        let person = MeetingParticipantDraft(participantIdentifier: "contact:alice", displayName: "Alice", emailAddress: "alice@example.test")
        let first = try service.search(.init(text: "", kinds: [.meeting], person: person, limit: 100))
        let second = try service.search(.init(text: "", kinds: [.meeting], person: person, limit: 100, offset: 100))
        #expect(first.count == 100)
        #expect(second.count == 5)
        #expect(Set((first + second).map(\.sourceID)).count == 105)
        // The panel requests an extra row to determine whether another page exists.
        // Text hits vary in title relevance and BM25 rank across the page boundary.
        try f.sql("UPDATE meetings SET title=CASE WHEN id % 3 = 0 THEN 'Alice meeting' ELSE 'Meeting' END")
        let preview = try service.search(.init(text: "Alice", kinds: [.meeting], person: person, limit: 101))
        let more = try service.search(.init(text: "Alice", kinds: [.meeting], person: person, limit: 100, offset: 100))
        #expect(preview.count == 101)
        #expect(more.count == 5)
        #expect(Set((Array(preview.prefix(100)) + more).map(\.sourceID)).count == 105)
    }

    @Test("Evidence failures withhold only unverifiable candidates and report partial completeness", arguments: [GlobalSearchKind.chat, .recap])
    func partialEvidence(kind: GlobalSearchKind) throws {
        let f = try Fixture()
        try f.sql("""
            INSERT INTO dictations VALUES(1,'2026-11-01T10:00:00Z','orchid','dictation','Editor','editor',NULL);
            CREATE TABLE time_turner_recaps(day_key TEXT PRIMARY KEY,day_start REAL,body TEXT);
            """)
        for id in ["unavailable", "valid"] {
            if kind == .chat {
                try f.sql("INSERT INTO meeting_chat_sessions VALUES('\(id)','{\"title\":\"orchid\"}',1793527200)")
            } else {
                try f.sql("INSERT INTO time_turner_recaps VALUES('\(id)',1793527200,'{\"version\":1,\"insights\":[{\"text\":\"orchid\"}]}')")
            }
        }
        let service = try GlobalSearchService(databaseURL: f.url)
        let query = GlobalSearchQuery(text: "orchid", kinds: [.dictation, kind])
        let partial = try service.searchResponse(query) { _, id in
            if id == "unavailable" { throw CocoaError(.fileReadUnknown) }
            return true
        }
        #expect(partial.unavailableKinds == [kind])
        #expect(Set(partial.results.map(\.sourceID)) == ["1", "valid"])
        let scoped = try service.searchResponse(.init(text: "orchid", kinds: [kind])) { _, _ in throw CocoaError(.fileReadUnknown) }
        #expect(scoped.results.isEmpty && scoped.unavailableKinds == [kind])
        #expect(throws: GlobalSearchError.self) { try scoped.matches() }
        let recovered = try service.searchResponse(query, validateDerived: { _, _ in true })
        #expect(recovered.results.count == 3 && recovered.unavailableKinds.isEmpty)
        #expect(throws: CancellationError.self) {
            try service.searchResponse(query) { _, _ in throw CancellationError() }
        }
        #expect(throws: GlobalSearchError.self) {
            try service.searchResponse(query) { _, _ in throw GlobalSearchError.changedSources }
        }
    }

    @Test("Failure querying an already-open screen catalog preserves main matches")
    func attachedCatalogQueryFailure() throws {
        let f = try Fixture()
        try f.sql("INSERT INTO dictations VALUES(1,'2026-11-01T10:00:00Z','orchid','dictation','Editor','editor',NULL)")
        let root = f.root.appendingPathComponent("screens")
        let writer = try VisualMemoryStore(root: root)
        try writer.save([.init(id: "screen", kind: .moment, source: "Editor", text: "orchid", path: "image.png")])
        let reader = try VisualMemoryStore(root: root, readOnly: true)
        let service = try GlobalSearchService(databaseURL: f.url, screenHistory: reader)
        #expect(try service.search(.init(text: "orchid")).count == 2)
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "DROP TABLE evidence_search", nil, nil, nil) == SQLITE_OK)
        let response = try service.searchResponse(.init(text: "orchid"))
        #expect(response.results.map(\.sourceID) == ["1"])
        #expect(response.unavailableKinds == [.screenHistory])
        let unrelated = try service.searchResponse(.init(text: "orchid", kinds: [.dictation]))
        #expect(unrelated.unavailableKinds.isEmpty && unrelated.results.count == 1)
    }

    @Test("FTS corruption is repaired without blocking dictation, meeting, or Chat writes")
    func sourceWritesRecoverFTS() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-repair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        let dictation = try store.insertDictation(text: "orchid dictation", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let meeting = try store.insertMeeting(title: "orchid meeting", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "orchid transcript", formattedNotes: "notes", micAudioPath: nil, systemAudioPath: nil)
        let chat = MeetingChatStore(databaseURL: url)
        let session = try chat.createSession(scope: .init(), title: "orchid chat")
        let turn = try chat.beginTurn(sessionID: session.id, question: "orchid?", scope: .init(), provider: "test", model: "test")
        let index = try GlobalSearchIndex(databaseURL: url)
        func damage() throws {
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(db, "INSERT INTO global_search_fts(global_search_fts) VALUES('delete-all')", nil, nil, nil) == SQLITE_OK)
        }
        try damage()
        try store.updateMeetingTranscript(id: meeting, rawTranscript: "violet revised transcript")
        #expect(try store.meeting(id: meeting)?.rawTranscript == "violet revised transcript")
        #expect(try index.search(.init(text: "violet", kinds: [.meeting])).count == 1)
        try damage()
        #expect(try chat.finishTurn(turnID: turn.id, answer: "violet answer", citations: [], dependencies: []))
        #expect(try chat.turns(sessionID: session.id).first?.originalAnswer == "violet answer")
        #expect(try index.search(.init(text: "violet", kinds: [.chat]), validateDerived: { _, _ in true }).count == 1)
        var metadataDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &metadataDB) == SQLITE_OK)
        #expect(sqlite3_exec(metadataDB, "UPDATE meetings SET cloud_record_name='meeting-test'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(metadataDB)
        try damage()
        // Exercise a multi-statement transaction that uses the store's exec path.
        try store.resetTextRecordCloudMetadataForZoneRecreation()
        #expect(try index.search(.init(text: "violet", kinds: [.meeting])).count == 1)
        try damage()
        try store.deleteDictation(id: dictation)
        #expect(try index.search(.init(text: "orchid", kinds: [.dictation])).isEmpty)
        #expect(try store.meeting(id: meeting) != nil)
    }

    @Test("FTS repair preserves outer transaction ownership and unrelated failures")
    func repairTransactionOwnership() throws {
        let f = try Fixture()
        try f.sql("INSERT INTO dictations VALUES(1,'2026-11-01T10:00:00Z','orchid','dictation','Editor','com.test.editor',NULL)")
        let index = try GlobalSearchIndex(databaseURL: f.url)
        try f.sql("INSERT INTO global_search_fts(global_search_fts) VALUES('delete-all'); BEGIN IMMEDIATE;")
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(f.db, "DELETE FROM dictations WHERE id=1", -1, &statement, nil) == SQLITE_OK)
        #expect(try GlobalSearchIndex.stepSourceWrite(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        #expect(sqlite3_get_autocommit(f.db) == 0)
        try f.sql("ROLLBACK")
        // Both the source deletion and the derived repair belong to the caller.
        try f.sql("INSERT INTO global_search_fts(global_search_fts) VALUES('rebuild')")
        #expect(try index.search(.init(text: "orchid")).count == 1)
        #expect(sqlite3_prepare_v2(f.db, "INSERT INTO dictations(id) VALUES(1)", -1, &statement, nil) == SQLITE_OK)
        #expect(try GlobalSearchIndex.stepSourceWrite(statement) == SQLITE_CONSTRAINT)
        sqlite3_finalize(statement)
        #expect(try index.search(.init(text: "orchid")).count == 1)
        // Corruption in another FTS table must never trigger a global-search reset.
        try f.sql("""
            CREATE TABLE other_docs(id INTEGER PRIMARY KEY,text TEXT);
            INSERT INTO other_docs VALUES(1,'other');
            CREATE VIRTUAL TABLE unrelated USING fts5(text,content='other_docs',content_rowid='id');
            CREATE TRIGGER broken BEFORE DELETE ON dictations BEGIN
                INSERT INTO unrelated(unrelated,rowid,text) VALUES('delete',1,'other');
            END;
            """)
        #expect(sqlite3_prepare_v2(f.db, "DELETE FROM dictations WHERE id=1", -1, &statement, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try GlobalSearchIndex.stepSourceWrite(statement) }
        sqlite3_finalize(statement)
        #expect(try index.search(.init(text: "orchid")).count == 1)
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

    @Test("Stale derived hits cannot hide matches beyond the first candidate batch", arguments: [GlobalSearchKind.chat, .recap])
    func refillStaleCandidates(kind: GlobalSearchKind) throws {
        let f = try Fixture()
        try f.sql("CREATE TABLE time_turner_recaps(day_key TEXT PRIMARY KEY,day_start REAL,body TEXT)")
        for i in 0..<245 {
            let id = i < 240 ? "stale-\(i)" : "valid-\(i)"
            let timestamp = 1793527200 - i
            if kind == .chat {
                try f.sql("""
                    INSERT INTO meeting_chat_sessions VALUES('\(id)','{"title":"orchid"}',\(timestamp));
                    INSERT INTO meeting_chat_turns VALUES('\(id)','\(id)','completed','{"question":"orchid","originalAnswer":"orchid"}');
                    """)
            } else {
                try f.sql("""
                    INSERT INTO time_turner_recaps VALUES('\(id)',\(timestamp),'{"version":1,"insights":[{"text":"orchid"}]}');
                    """)
            }
        }
        let index = try GlobalSearchIndex(databaseURL: f.url)
        let validator: (GlobalSearchKind, String) throws -> Bool = { _, id in id.hasPrefix("valid-") }
        #expect(try index.search(.init(text: "orchid", kinds: [kind], limit: 1), validateDerived: validator).map(\.sourceID) == ["valid-240"])
        let service = try GlobalSearchService(databaseURL: f.url)
        #expect(try service.search(.init(text: "orchid", kinds: [kind], limit: 3), validateDerived: validator).map(\.sourceID) == ["valid-240", "valid-241", "valid-242"])
        #expect(try index.search(.init(text: "orchid", kinds: [kind], limit: 200), validateDerived: validator).count == 5)
        #expect(try index.search(.init(text: "orchid", kinds: [kind]), validateDerived: { _, _ in false }).isEmpty)
    }

    @Test("Refilling after a stale candidate restarts all accepted hits on concurrent deletion")
    func refillRevalidatesEarlierHits() throws {
        let f = try Fixture()
        for (i, id) in ["first", "stale", "last"].enumerated() {
            try f.sql("""
                INSERT INTO meeting_chat_sessions VALUES('\(id)','{"title":"orchid"}',\(1793527200-i));
                INSERT INTO meeting_chat_turns VALUES('\(id)','\(id)','completed','{"question":"orchid","originalAnswer":"orchid"}');
                """)
        }
        let index = try GlobalSearchIndex(databaseURL: f.url)
        var deleted = false
        let hits = try index.search(.init(text: "orchid", kinds: [.chat], limit: 2), validateDerived: { _, id in
            if id == "stale" && !deleted {
                deleted = true
                try f.sql("DELETE FROM meeting_chat_sessions WHERE id='first'")
            }
            return id != "stale"
        })
        #expect(hits.map(\.sourceID) == ["last"])
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

    @Test func wholeDisplaySearchMatchesAnyIncludedAppWithoutDuplicatingOCR() throws {
        let f = try Fixture()
        let memory = try VisualMemoryStore(root: f.root.appendingPathComponent("visual-memory"))
        let item = VisualMemoryItem(id: "monitor", kind: .moment, source: "External · Browser · Editor",
            text: "orchid plan", path: "monitor.heic", display: .init(id: 2, uuid: "external", name: "External"),
            includedApps: [.init(bundleID: "browser", name: "Browser"), .init(bundleID: "editor", name: "Editor")])
        try memory.save([item])
        let service = try GlobalSearchService(databaseURL: f.url, screenHistory: memory)
        for app in ["browser", "EDITOR"] {
            let results = try service.search(.init(text: "orchid", kinds: [.screenHistory], app: app))
            #expect(results.map(\.sourceID) == ["monitor"])
            #expect(results.first?.appName == "Browser, Editor")
            #expect(results.first?.bundleID == "")
        }
        #expect(try service.search(.init(text: "orchid", kinds: [.screenHistory], app: "excluded")).isEmpty)
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

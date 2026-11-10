import Foundation
import Testing
import SQLite3
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Shared muesli task execution")
struct MuesliTaskRunnerTests {
    @Test func vidshotSQLHistoryInvalidatesChatWhenDeleted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db")
        try DictationStore(databaseURL: db).migrateIfNeeded()
        let captures = try FeedbackCaptureStore(databaseURL: db, support: dir)
        var capture = try captures.begin(target: feedbackTarget())
        capture.state = .ready
        capture.transcript = .init(source: "fixture", text: "Synthetic chart detail", words: [], segments: [], estimated: false)
        try captures.publish(capture)
        captures.release(id: capture.id)
        let chats = MeetingChatStore(databaseURL: db)
        let scope = MeetingChatScope(selection: .meetings([]))
        let session = try chats.createSession(scope: scope, title: "Fixture", allowsRequestedMeetingDiscovery: true)
        let turn = try chats.beginTurn(sessionID: session.id, question: "Find it", scope: scope, provider: "test", model: "test")
        let library = ChatLibraryTools(turn: turn, databaseURL: db)
        let evidence = MeetingChatEvidence(scope: scope, passages: [], dependencies: [],
            coverage: .init(eligibleMeetingCount: 0, evidenceMeetingCount: 0, isPartialRecap: false))
        let result = try await library.execute(.sql("SELECT text FROM vidshots"), evidence: evidence)
        #expect(result.documentOutput?.contains("Synthetic chart detail") == true)
        #expect(try chats.finishTurn(turnID: turn.id, answer: "Synthetic chart detail", citations: [], dependencies: []))
        try captures.save(capture)
        #expect(try chats.turns(sessionID: session.id).first?.state == .completed)
        try captures.delete(id: capture.id)
        #expect(try chats.turns(sessionID: session.id).first?.state == .sourceDeleted)
    }

    @Test func dependencyMigrationFailurePreservesExistingTrigger() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try MeetingChatSQL.execute("CREATE TABLE meeting_chat_turns(id TEXT PRIMARY KEY, session_id TEXT, state TEXT, body TEXT)", db: db)
        try MeetingChatSQL.migrateChatHistoryDependencies(db: db)
        sqlite3_set_authorizer(db, { _, operation, _, _, _, _ in
            operation == SQLITE_CREATE_TRIGGER ? SQLITE_DENY : SQLITE_OK
        }, nil)
        #expect(throws: (any Error).self) {
            try MeetingChatSQL.migrateChatHistoryDependencies(db: db)
        }
        sqlite3_set_authorizer(db, nil, nil)
        #expect(sqlite3_get_autocommit(db) == 1)
        let triggers = try MeetingChatSQL.rows("SELECT name FROM sqlite_master WHERE type='trigger' AND name='chat_history_dependency_removed'", db: db) {
            MeetingChatSQL.text($0, 0)
        }
        #expect(triggers == ["chat_history_dependency_removed"])
    }

    @Test func deletingSourceInvalidatesTransitiveChatQuotes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db")
        let rows = DictationStore(databaseURL: db)
        try rows.migrateIfNeeded()
        let source = try rows.insertDictation(text: "Synthetic secret", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let chats = MeetingChatStore(databaseURL: db)
        let scope = MeetingChatScope(selection: .meetings([]))
        var sessions: [UUID] = []
        for _ in 0..<4 {
            let session = try chats.createSession(scope: scope, title: "Fixture", allowsRequestedMeetingDiscovery: true)
            let turn = try chats.beginTurn(sessionID: session.id, question: "Summarize", scope: scope, provider: "test", model: "test")
            let ref = sessions.last.map { ChatHistoryDependency(kind: "chat", id: $0.uuidString, parent: $0.uuidString) }
                ?? .init(kind: "dictations", id: String(source), parent: String(source))
            try chats.recordHistory([ref], turn: turn) { true }
            #expect(try chats.finishTurn(turnID: turn.id, answer: "Synthetic secret", citations: [], dependencies: []))
            sessions.append(session.id)
        }
        // Production connections leave recursive_triggers disabled. The closure
        // must invalidate the full chain before mutation triggers remove edges.
        try rows.deleteDictation(id: source)
        for session in sessions {
            let turn = try #require(try chats.turns(sessionID: session).first)
            #expect(turn.state == .sourceDeleted && turn.originalAnswer == nil)
        }
    }

    @Test func sqlProjectionHonorsWholeOperationBudget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db")
        let rows = DictationStore(databaseURL: db)
        try rows.migrateIfNeeded()
        for _ in 0..<20 {
            _ = try rows.insertDictation(text: "Synthetic", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        }
        let query = try ChatHistorySQL(work: .init(maximumRows: 2))
        let tables = try query.plan("SELECT count(*) FROM dictations")
        #expect(throws: HistoryQueryWork.Limit.self) {
            try query.populate(tables, databaseURL: db, currentSession: UUID()) { _, _, _ in }
        }
        // The host copies only the allowance plus one overflow-detection row,
        // rather than materializing the archive and rejecting it afterwards.
        let payload = try #require(JSONSerialization.jsonObject(with: Data(query.run("SELECT count(*) FROM dictations").utf8)) as? [String: Any])
        #expect((payload["rows"] as? [[Int]]) == [[3]])
        #expect(throws: HistoryQueryWork.Limit.self) { try ChatHistorySQL(work: .init(seconds: 0)) }
    }

    @Test func sqlDatesUseTheSharedLegacyInterpretationAndUTCProjection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db"), rows = DictationStore(databaseURL: dir.appendingPathComponent("muesli.db"))
        try rows.migrateIfNeeded()
        let rawDates = ["2026-11-05T00:30:00+05:30", "2026-11-04T19:00:00Z", "2026-11-05T00:30:00.000000"]
        for raw in rawDates {
            let id = try rows.insertMeeting(title: raw, calendarEventID: nil, startTime: Date(), endTime: Date(),
                rawTranscript: "Synthetic", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
            try rows.withChatDatabase { connection in
                try MeetingChatSQL.execute("UPDATE meetings SET start_time=? WHERE id=?", [.text(raw), .integer(id)], db: connection)
            }
        }
        let query = try ChatHistorySQL()
        let statement = "SELECT title,date FROM meetings ORDER BY id"
        let tables = try query.plan(statement)
        try query.populate(tables, databaseURL: db, currentSession: UUID()) { _, _, _ in }
        let output = try #require(JSONSerialization.jsonObject(with: Data(query.run(statement).utf8)) as? [String: Any])
        let values = try #require(output["rows"] as? [[String]])
        #expect(values.count == 3)
        for row in values {
            let expected = try #require(MeetingChatSQL.parseDate(row[0]))
            #expect(row[1] == expected.ISO8601Format(.init(includingFractionalSeconds: true)))
        }
        let india = MeetingHistoryDateParser(timeZone: try #require(TimeZone(identifier: "Asia/Kolkata")))
        #expect(india.date(rawDates[2]) == india.date(rawDates[0]))
    }

    @Test func sqlSnapshotDriftIsRetryableButScopeAndAttemptFailuresAreNot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db"), rows = DictationStore(databaseURL: dir.appendingPathComponent("muesli.db"))
        try rows.migrateIfNeeded()
        let store = MeetingChatStore(databaseURL: db), scope = MeetingChatScope(selection: .meetings([]))
        let session = try store.createSession(scope: scope, title: "General", allowsRequestedMeetingDiscovery: true)
        let turn = try store.beginTurn(sessionID: session.id, question: "Query", scope: scope, provider: "test", model: "test")
        let evidence = MeetingChatEvidence(scope: scope, passages: [], dependencies: [],
            coverage: .init(eligibleMeetingCount: 0, evidenceMeetingCount: 0, isPartialRecap: false))
        let version = try HistorySQLVersion(url: db)
        _ = try rows.insertDictation(text: "Concurrent save", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        #expect(try !version.isCurrent())
        let tools = ChatLibraryTools(turn: turn, databaseURL: db, observeQueryVersion: { _ in { try version.isCurrent() } })
        let rejected = try await tools.execute(.sql("SELECT count(*) FROM dictations"), evidence: evidence)
        #expect(rejected.documentOutput?.contains("\"retryable\":true") == true)
        #expect(!rejected.hasLibraryEvidence)
        let retry = try await ChatLibraryTools(turn: turn, databaseURL: db).execute(.sql("SELECT count(*) FROM dictations"), evidence: evidence)
        #expect(retry.hasLibraryEvidence)
        #expect(try store.finishTurn(turnID: turn.id, answer: "Done", citations: [], dependencies: []))
        await #expect(throws: MeetingChatError.self) { try await tools.execute(.sql("SELECT count(*) FROM dictations"), evidence: evidence) }
        let scoped = try store.createSession(scope: scope, title: "Explicit empty")
        let scopedTurn = try store.beginTurn(sessionID: scoped.id, question: "Query", scope: scope, provider: "test", model: "test")
        await #expect(throws: MeetingChatError.self) {
            try await ChatLibraryTools(turn: scopedTurn, databaseURL: db).execute(.sql("SELECT count(*) FROM dictations"), evidence: evidence)
        }
    }

    @MainActor @Test func taskReconciliationBatchesAllHistoryAndUsesTheRecapModel() async throws {
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"
        let budget = MeetingChatContextBudget(config: config, contextWindowTokens: 4096)
        let tasks = (0..<150).map { TimeTurnerTaskContext(id: "task-\($0)", title: String(repeating: "Synthetic task ", count: 8) + String($0), completed: $0 % 2 == 0) }
        let batches = try TimeTurnerTaskReconciliation.batches(action: "Verify dispatch", tasks: tasks, budget: budget)
        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 }.map(\.id) == tasks.map(\.id))
        let responses = batches.map { batch in
            "{\"matches\":[\"" + batch.last!.id + "\"]}"
        }
        let generator = TaskPlainProbe(responses: responses)
        let result = try await TimeTurnerTaskReconciliation.reconcile([
            .init(section: .followUps, text: "Verify dispatch", sources: ["C1"])
        ], tasks: tasks, config: config, runtime: .init(generator: generator, budget: budget), validate: {})
        #expect(result.first?.taskID == batches.first?.last?.id)
        #expect(result.first?.duplicateTaskIDs == batches.dropFirst().compactMap { $0.last?.id })
        for request in await generator.requests {
            #expect(request.config.meetingSummaryBackend == config.meetingSummaryBackend)
            #expect(MeetingChatContextBudget.estimateTokens(request.system + request.user) <= budget.maximumInputTokens)
        }
        let invalid = TaskPlainProbe(responses: ["{\"matches\":[\"invented\"]}", "{\"matches\":[\"invented\"]}"])
        await #expect(throws: MeetingChatHarnessError.self) {
            try await TimeTurnerTaskReconciliation.reconcile([.init(section: .followUps, text: "Task", sources: ["C1"])],
                tasks: [tasks[0]], config: config, runtime: .init(generator: invalid, budget: budget), validate: {})
        }
    }

    @MainActor @Test func reconciliationNormalizesNewProposalAliasesBeforePersistence() async throws {
        actor Probe: MeetingTextGenerating {
            var calls = 0
            func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
                calls += 1
                if calls == 1 { return #"{"matches":[]}"# }
                let input = try JSONSerialization.jsonObject(with: Data(request.user.utf8)) as! [String: Any]
                let tasks = input["tasks"] as! [[String: Any]]
                return String(decoding: try JSONSerialization.data(withJSONObject: ["matches": tasks.map { $0["id"] as! String }]), as: UTF8.self)
            }
        }
        let config = AppConfig(), probe = Probe()
        let result = try await TimeTurnerTaskReconciliation.reconcile([
            .init(section: .followUps, text: "Check dispatch", sources: ["C1"]),
            .init(section: .followUps, text: "Verify dispatcher", sources: ["C1"])
        ], tasks: [.init(id: "persisted", title: "Verify CI", completed: false)], config: config,
            runtime: .init(generator: probe, budget: .init(config: config)), validate: {})
        #expect(result.map(\.taskID) == ["persisted", "persisted"])
        #expect(result.allSatisfy { $0.duplicateTaskIDs?.isEmpty == true })
    }

    @Test func unrelatedDeletionPreservesRebuiltSummaryAndItsDependents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db"), rows = DictationStore(databaseURL: dir.appendingPathComponent("muesli.db"))
        try rows.migrateIfNeeded()
        let old = try rows.insertDictation(text: "Old", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let other = try rows.insertDictation(text: "Unrelated", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let chats = MeetingChatStore(databaseURL: db), scope = MeetingChatScope(selection: .meetings([]))
        func session() throws -> MeetingChatSession { try chats.createSession(scope: scope, title: "Fixture", allowsRequestedMeetingDiscovery: true) }
        func begin(_ session: UUID) throws -> MeetingChatTurn {
            try chats.beginTurn(sessionID: session, question: "Summarize", scope: scope, provider: "test", model: "test")
        }
        func finish(_ turn: MeetingChatTurn, ref: ChatHistoryDependency? = nil) throws {
            if let ref { try chats.recordHistory([ref], turn: turn) { true } }
            #expect(try chats.finishTurn(turnID: turn.id, answer: "Synthetic answer", citations: [], dependencies: []))
        }
        let a = try session()
        try finish(begin(a.id), ref: .init(kind: "dictations", id: String(old), parent: String(old)))
        try rows.deleteDictation(id: old)
        let valid = try begin(a.id)
        try finish(valid)
        let rewrite = try begin(a.id)
        let context = try chats.historyContext(before: rewrite)
        #expect(try chats.saveRollingSummary(text: "Valid rebuilt summary", coveredTurns: context.turns, for: rewrite))
        try finish(rewrite)
        let b = try session(), dependent = try begin(b.id)
        try finish(dependent, ref: .init(kind: "chat", id: a.id.uuidString, parent: a.id.uuidString))
        let c = try session()
        try finish(begin(c.id), ref: .init(kind: "dictations", id: String(other), parent: String(other)))
        try rows.deleteDictation(id: other)
        #expect(try chats.sessions().first { $0.id == a.id }?.rollingSummary?.text == "Valid rebuilt summary")
        #expect(try chats.turns(sessionID: b.id).first?.state == .completed)
        // Its dependency must remain attached for a later real source mutation.
        try chats.saveDraft(turnID: valid.id, text: "Edited source answer")
        #expect(try chats.turns(sessionID: b.id).first?.state == .sourceDeleted)
    }

    @Test func cancellingSQLiteWorkInterruptsBulkCopy() async throws {
        let started = DispatchSemaphore(value: 0)
        let task = Task.detached {
            var db: OpaquePointer?
            guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw MeetingChatError.invalidResponse }
            defer { sqlite3_close(db) }
            let work = HistoryQueryWork()
            try work.withProgress(db: db) {
                started.signal()
                // Represents host materialization, before model SQL is authorized.
                let rc = sqlite3_exec(db, "CREATE TABLE sample(n); INSERT INTO sample WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<10000000) SELECT n FROM x", nil, nil, nil)
                guard rc == SQLITE_OK else { throw MeetingChatError.invalidResponse }
            }
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancelledDependencyPublicationRollsBackAndReleasesWriter() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db")
        let rows = DictationStore(databaseURL: db)
        try rows.migrateIfNeeded()
        let chats = MeetingChatStore(databaseURL: db)
        let scope = MeetingChatScope(selection: .meetings([]))
        let session = try chats.createSession(scope: scope, title: "Fixture", allowsRequestedMeetingDiscovery: true)
        let turn = try chats.beginTurn(sessionID: session.id, question: "Count", scope: scope, provider: "test", model: "test")
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let refs = (0..<30_000).map { ChatHistoryDependency(kind: "dictations", id: String($0), parent: String($0)) }
            try MeetingChatStore(databaseURL: db).recordHistory(refs, turn: turn) {
                entered.signal(); resume.wait(); return true
            }
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        task.cancel(); resume.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        try rows.withChatDatabase { db in
            let counts = try MeetingChatSQL.rows("SELECT count(*) FROM meeting_chat_history_dependencies", db: db) { sqlite3_column_int($0, 0) }
            #expect(counts == [0])
        }
        // A normal save must succeed immediately after the cancelled transaction.
        _ = try rows.insertDictation(text: "Still writable", durationSeconds: 1, startedAt: Date(), endedAt: Date())
    }
    @Test func taggingSkillsPreservesTheGeneralCatalog() throws {
        let expected: Set<String> = ["search_history", "read_history", "read_skill", "query_history_sql"]
        for tag: MuesliHistoryTask? in [nil, .dailyRecap] {
            let skills = ChatSkillToolSession(tag, catalog: [.dailyRecap])
            let tools = MeetingChatNativeHarness.definitions(library: true, meetings: true, skills: skills, documents: false, vision: false)
            #expect(Set(tools.compactMap { $0["name"] as? String }) == expected)
            let attached = MeetingChatNativeHarness.definitions(library: true, meetings: true, skills: skills, documents: true, vision: true)
            #expect(Set(attached.compactMap { $0["name"] as? String }) == expected.union(["read_document", "search_document", "render_document_page"]))
            #expect(attached.count == 7)
        }
    }

    private let final = #"{"insights":[{"section":"work","text":"Reviewed the checklist.","sources":["C1"]}]}"#
    private func packet(text: String = "Reviewed the release checklist") throws -> TimeTurnerRecapPacket {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let capture = VisualMemoryItem(id: "capture-one", kind: .moment, capturedAt: date,
            source: "Editor", bundleID: "test.editor", text: text, path: "one.png")
        return try TimeTurnerRecap.packet(captures: [capture], passages: [],
            interval: .init(start: date, duration: 3600), config: AppConfig())
    }

    @MainActor @Test func templatesUseSharedRuntimeAndKeepTopicOutOfInstructions() async throws {
        for template in MuesliHistoryTask.allCases {
            let probe = TaskPlainProbe(responses: [final])
            let runtime = try await MuesliTaskRunner.prepare(config: AppConfig(), generator: probe)
            _ = try await TimeTurnerRecapTask.run(packet: packet(), config: AppConfig(), runtime: runtime,
                template: template, query: "UNTRUSTED_TOPIC", validateSources: {})
            let request = try #require(await probe.requests.first)
            let instructions = try template.loadInstructions()
            #expect(request.system.contains(instructions))
            #expect(request.system.contains(MuesliHistorySkill.evidenceInstructions))
            #expect(!request.system.contains("UNTRUSTED_TOPIC"))
            #expect(request.user.contains("UNTRUSTED_TOPIC"))
        }
    }

    @MainActor @Test func deletingDayEvidenceRemovesTheSkillAnswerAndItsRewrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db)
        try store.migrateIfNeeded()
        let source = try store.insertDictation(text: "Review the synthetic launch checklist.", durationSeconds: 2, startedAt: Date(), endedAt: Date())
        var config = AppConfig()
        config.recapIncludeDictations = true
        let probe = TaskPlainProbe(responses: [
            #"{"tool":"read_skill","id":"resume-work"}"#,
            #"{"tool":"search_history","kind":"dictation","query":null}"#,
            #"{"status":"conversation","markdown":"Review the launch checklist."}"#
        ])
        let chats = MeetingChatStore(databaseURL: db)
        // Manual title keeps title generation out of this scripted provider exchange.
        let session = try chats.createSession(scope: .init(selection: .meetings([])), title: "Fixture", allowsRequestedMeetingDiscovery: true)
        try chats.updateSession(id: session.id, title: "Fixture chat", scope: nil)
        let coordinator = MeetingChatCoordinator(databaseURL: db, generator: probe)
        coordinator.selectChat(id: session.id)
        await coordinator.send(question: "$resume-work What was I dictating?", config: config)
        let deadline = Date().addingTimeInterval(10)
        while coordinator.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(try chats.turns(sessionID: session.id).first)
        #expect(first.state == .completed)
        let rewrite = try chats.beginTurn(sessionID: session.id, question: "Shorter?", scope: first.scope, provider: "test", model: "test")
        #expect(try chats.finishTurn(turnID: rewrite.id, answer: "Review checklist.", citations: [], dependencies: []))
        try store.deleteDictation(id: source)
        let invalidated = try chats.turns(sessionID: session.id)
        #expect(invalidated.count == 2)
        #expect(invalidated.allSatisfy { $0.originalAnswer == nil && $0.state == .sourceDeleted })
    }

    @MainActor @Test(arguments: [false,true])
    func generalChatSearchesAndReadsAcrossRuntimes(native: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db)
        try store.migrateIfNeeded()
        let original = "orchid handoff " + String(repeating:"界",count:1000) + " final detail"
        let id = try store.insertDictation(text:original,durationSeconds:1,startedAt:Date(),endedAt:Date())
        _ = try store.insertDictation(text:"orchid other command",durationSeconds:1,source:"cua",startedAt:Date(),endedAt:Date())
        let args = #"{"kind":"dictation","query":"orchid","app":null,"from":null,"until":null}"#
        let read = #"{"handle":"H1","offset":900}"#
        let final = #"{"status":"conversation","markdown":"The dictation ended with final detail."}"#
        let generator: any MeetingTextGenerating
        let plain = TaskPlainProbe(responses: ["{\"tool\":\"search_history\"," + args.dropFirst(),
            "{\"tool\":\"read_history\"," + read.dropFirst(), final])
        func tool(_ name: String, _ arguments: String) throws -> MeetingNativeToolResponse {
            let item = ["type":"function_call","call_id":name,"name":name,"arguments":arguments]
            return .init(outputItems:try JSONSerialization.data(withJSONObject:[item]),
                         calls:[.init(id:name,name:name,arguments:arguments)],text:"")
        }
        let nativeProbe = TaskNativeProbe(responses:[try tool("search_history",args),try tool("read_history",read),answer(final)])
        if native { generator = nativeProbe } else { generator = plain }
        let chat = MeetingChatCoordinator(databaseURL:db,generator:generator)
        await chat.send(question:"What was at the end of my orchid dictation?",config:AppConfig())
        await chat.waitForIdle()
        let session = try #require(chat.selectedSessionID)
        let history = MeetingChatStore(databaseURL:db)
        #expect(try history.turns(sessionID:session).first?.state == .completed)
        let requests: [String]
        if native { requests = await nativeProbe.requests.map { String(decoding:$0.inputItems,as:UTF8.self) } }
        else { requests = await plain.requests.map(\.user) }
        #expect(requests.last?.contains("final detail") == true)
        #expect(requests.allSatisfy { !$0.contains("other command") })
        try store.deleteDictation(id:id)
        #expect(try history.turns(sessionID:session).first?.state == .sourceDeleted)
    }

    @MainActor @Test(arguments: [false,true])
    func modelWrittenSQLJoinsClassesAcrossRuntimes(native: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL:db)
        try store.migrateIfNeeded()
        for kind in ["dictation","cua"] {
            _ = try store.insertDictation(text:"private fixture text",durationSeconds:1,source:kind,
                targetAppName:"Fixture",startedAt:Date(),endedAt:Date())
        }
        let sql = "SELECT d.app AS common_app, count(*) AS pairs FROM dictations d JOIN commands c ON c.app=d.app GROUP BY d.app"
        let args = String(decoding:try JSONEncoder().encode(["sql":sql]),as:UTF8.self)
        let final = #"{"status":"conversation","markdown":"Fixture appeared in both classes."}"#
        let plain = TaskPlainProbe(responses:["{\"tool\":\"query_history_sql\"," + args.dropFirst(), final])
        let name = "query_history_sql"
        let item = ["type":"function_call","call_id":name,"name":name,"arguments":args]
        let probe = TaskNativeProbe(responses:[.init(outputItems:try JSONSerialization.data(withJSONObject:[item]),
                                         calls:[.init(id:name,name:name,arguments:args)],text:""),answer(final)])
        let generator: any MeetingTextGenerating = native ? probe as any MeetingTextGenerating : plain
        let chat = MeetingChatCoordinator(databaseURL:db,generator:generator)
        await chat.send(question:"Which apps did I use for both?",config:AppConfig())
        await chat.waitForIdle()
        #expect(chat.turns.first?.state == .completed)
        let replay: String
        if native { replay = await probe.requests.last.map { String(decoding:$0.inputItems,as:UTF8.self) } ?? "" }
        else { replay = await plain.requests.last?.user ?? "" }
        #expect(replay.contains("Fixture"))
        #expect(!replay.contains("private fixture text"))
    }

    @Test func wordFrequencyCountsFullArchiveAndPreservesDeletion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("muesli.db")
        let rows = DictationStore(databaseURL: db)
        try rows.migrateIfNeeded()
        var last: Int64 = 0
        for i in 0..<67 {
            last = try rows.insertDictation(text: String(repeating: "the ", count: 50) + "orchid orchid", durationSeconds: 1,
                source: i == 0 ? "cua" : "dictation", startedAt: Date(), endedAt: Date())
        }
        _ = try rows.insertDictation(text:"legacy Quill", durationSeconds:1, source:"quil", startedAt:Date(), endedAt:Date())
        let store = MeetingChatStore(databaseURL: db)
        let scope = MeetingChatScope(selection: .meetings([]))
        let session = try store.createSession(scope: scope, title: "Test", allowsRequestedMeetingDiscovery: true)
        let turn = try store.beginTurn(sessionID: session.id, question: "Vocabulary?", scope: scope, provider: "test", model: "test")
        let library = ChatLibraryTools(turn: turn, databaseURL: db)
        let evidence = MeetingChatEvidence(scope:scope,passages:[],dependencies:[],coverage:.init(eligibleMeetingCount:0,evidenceMeetingCount:0,isPartialRecap:false))
        let sql = """
            WITH words AS (SELECT j.value AS word FROM dictations, json_each(tokens(text)) j)
            SELECT word,count(*) AS uses,(SELECT count(*) FROM dictations) AS records FROM words
            WHERE word NOT IN (SELECT word FROM stop_words WHERE language='en') GROUP BY word ORDER BY uses DESC
            """
        let parsed = try ChatLibraryCall.parse("query_history_sql", ["tool":"query_history_sql","sql":sql])
        let call = try #require(parsed)
        let result = try await library.execute(call,evidence:evidence)
        let payload = try #require(JSONSerialization.jsonObject(with:Data((result.documentOutput ?? "").utf8)) as? [String:Any])
        #expect(payload["query_error"] == nil)
        let values = try #require((payload["rows"] as? [[Any]])?.first)
        #expect(values[0] as? String == "orchid")
        #expect(values[1] as? Int == 132)
        #expect(values[2] as? Int == 66)
        for blocked in ["DELETE FROM dictations", "SELECT * FROM source.dictations", "SELECT * FROM sqlite_master",
                        "SELECT load_extension('bad')", "PRAGMA table_list", "ATTACH ':memory:' AS other",
                        "SELECT 1; SELECT 2", "SELECT * FROM dictations; DROP TABLE chats"] {
            let rejected = try await library.execute(.sql(blocked),evidence:evidence)
            #expect(rejected.documentOutput?.contains("query_error") == true)
        }
        try rows.deleteDictation(id:last)
        #expect(try store.turns(sessionID:session.id).first?.state == .sourceDeleted)
    }

    @Test func historyPagesAndReadsStayBoundToClassAttemptAndSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let rows = DictationStore(databaseURL:db)
        try rows.migrateIfNeeded()
        let now = Date()
        for n in 0..<7 {
            _ = try rows.insertDictation(text:"Command \(n)",durationSeconds:1,source:"cua",startedAt:now,endedAt:now)
        }
        let store = MeetingChatStore(databaseURL:db)
        let empty = MeetingChatScope(selection:.meetings([]))
        let session = try store.createSession(scope:empty,title:"Test",allowsRequestedMeetingDiscovery:true)
        let turn = try store.beginTurn(sessionID:session.id,question:"Review",scope:empty,provider:"Test",model:"test")
        let tools = ChatLibraryTools(turn:turn,databaseURL:db)
        let evidence = MeetingChatEvidence(scope:empty,passages:[],dependencies:[],coverage:.init(eligibleMeetingCount:0,evidenceMeetingCount:0,isPartialRecap:false))
        func result(_ call: ChatLibraryCall) async throws -> [String:Any] {
            let response = try await tools.execute(call,evidence:evidence)
            return try #require(JSONSerialization.jsonObject(with:Data((response.documentOutput ?? "").utf8)) as? [String:Any])
        }
        let page = try await result(.search(.init(kind:.command,phrase:"",app:nil,from:.distantPast,until:.distantFuture)))
        let token = try #require(page["next_cursor"] as? String)
        #expect((page["results"] as? [[String:Any]])?.count == 5)
        let next = try await result(.more(token))
        #expect((next["results"] as? [[String:Any]])?.count == 2)
        #expect(next["next_cursor"] is NSNull)
        await #expect(throws: MeetingChatHarnessError.self) { _ = try await tools.execute(.read("unissued",0),evidence:evidence) }
        try store.updateSession(id:session.id,title:nil,scope:.init(selection:.folder(9)))
        await #expect(throws: MeetingChatError.self) { _ = try await tools.execute(.read("H1",0),evidence:evidence) }
    }

    @Test func generalHistoryReadsVerifiedWritingScreenChatAndRecap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL:db)
        try store.migrateIfNeeded()
        let now = Date()
        try store.appendQuillTurn(sessionID:UUID(),turn:.init(id:UUID(),question:"orchid input",answer:"quill answer",timestamp:now.ISO8601Format(),backend:"fixture",model:"fixture"))
        _ = try store.recordCotypistSuggestion(.init(date:now,appBundleID:"fixture.editor",appName:"Editor",trigger:"boundary",suggestionText:"private rejected suffix",acceptedText:"orchid accepted",outcome:.partial,firstWordLogProb:nil,firstMs:nil,fullMs:nil,contextSource:"field",model:"fixture"))
        let capture = VisualMemoryItem(id:"capture",kind:.moment,capturedAt:now,source:"Editor",bundleID:"fixture.editor",text:"orchid OCR",path:"missing.png")
        try VisualMemoryStore(root:root.appendingPathComponent("visual-memory")).save([capture])
        let recaps = try TimeTurnerRecapStore(databaseURL:db)
        let recap = SavedTimeTurnerRecap(version:1,dayStart:now,dayEnd:now.addingTimeInterval(3600),timeZone:"UTC",generatedAt:now,provider:"fixture",model:"test",insights:[.init(section:.work,text:"orchid recap",sources:["C1"])],sources:[.init(id:"C1",title:"Editor",date:now,excerpt:capture.text,capture:capture,meeting:nil)])
        try recaps.save(recap)
        let chats = MeetingChatStore(databaseURL:db)
        let other = try chats.createSession(scope:.init(),title:"other")
        let old = try chats.beginTurn(sessionID:other.id,question:"orchid question",scope:.init(),provider:"fixture",model:"test")
        #expect(try chats.finishTurn(turnID:old.id,answer:"orchid saved answer",citations:[],dependencies:[]))
        let empty = MeetingChatScope(selection:.meetings([]))
        let chat = try chats.createSession(scope:empty,title:"current",allowsRequestedMeetingDiscovery:true)
        let turn = try chats.beginTurn(sessionID:chat.id,question:"search history",scope:empty,provider:"fixture",model:"test")
        let tools = ChatLibraryTools(turn:turn,databaseURL:db)
        let evidence = MeetingChatEvidence(scope:empty,passages:[],dependencies:[],coverage:.init(eligibleMeetingCount:0,evidenceMeetingCount:0,isPartialRecap:false))
        for (kind,expected): (GlobalSearchKind,String) in [(.quill,"quill answer"),(.cotypist,"orchid accepted"),(.screenHistory,"orchid OCR"),(.chat,"orchid saved answer"),(.recap,"orchid recap")] {
            let result = try await tools.execute(.search(.init(kind:kind,phrase:"orchid",app:nil,from:.distantPast,until:.distantFuture)),evidence:evidence)
            let data = Data((result.documentOutput ?? "").utf8)
            let rows = try #require((JSONSerialization.jsonObject(with:data) as? [String:Any])?["results"] as? [[String:Any]])
            let handle = try #require(rows.first?["handle"] as? String)
            let read = try await tools.execute(.read(handle,0),evidence:evidence)
            #expect(read.documentOutput?.contains(expected) == true)
            #expect(read.documentOutput?.contains("private rejected suffix") == false)
        }
        try recaps.save(recap)
        #expect(try chats.turns(sessionID:chat.id).first?.state == .sourceDeleted)
    }

    @Test func modelDateArgumentsIntersectScopeAcrossDST() throws {
        let tz = try #require(TimeZone(identifier: "America/New_York"))
        let fields: [String: Any] = ["tool":"search_history", "title":NSNull(), "from":"2026-11-01", "until":"2026-11-02", "limit":3]
        let query = try MeetingDiscoveryQuery(fields, timeZone: tz)
        #expect(try #require(query.until).timeIntervalSince(#require(query.from)) == 25 * 3600)
        let scope = MeetingChatScope(selection: .folder(4), startDate: query.from?.addingTimeInterval(3600))
        #expect(query.intersecting(scope)?.selection == .folder(4))
        #expect(query.intersecting(scope)?.startDate == scope.startDate)
        #expect(query.intersecting(.init(selection: .all, startDate: query.until)) == nil)
        for (key, value): (String, Any) in [("from","2026-02-30"), ("until","2025-01-01"), ("limit",true), ("limit",11), ("scope","all")] {
            var invalid = fields
            invalid[key] = value
            #expect(throws: MeetingChatError.self) { try MeetingDiscoveryQuery(invalid, timeZone: tz) }
        }
    }

    @MainActor @Test func lastWeekDiscoveryWorksWithAndWithoutSkillAndHonorsEmptySelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db); try store.migrateIfNeeded()
        let week = try #require(Calendar.current.dateInterval(of: .weekOfYear, for: Date()))
        for (title, start) in [("In window", week.start.addingTimeInterval(-60)), ("Outside window", week.start)] {
            _ = try store.insertMeeting(title: title, calendarEventID: nil, startTime: start,
                endTime: start.addingTimeInterval(30), rawTranscript: "Prepare the handoff.", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        }
        func tool(_ name: String, _ args: String) throws -> MeetingNativeToolResponse {
            let item = ["type": "function_call", "call_id": name, "name": name, "arguments": args]
            return .init(outputItems: try JSONSerialization.data(withJSONObject: [item]),
                calls: [.init(id: name, name: name, arguments: args)], text: "")
        }
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyy-MM-dd"
        let args = #"{"kind":"meeting","title":null,"from":"\#(format.string(from: week.start.addingTimeInterval(-3600)))","until":"\#(format.string(from: week.start))","limit":3}"#
        let probe = TaskNativeProbe(responses: [
            try tool("read_skill", #"{"id":"project-brief"}"#), try tool("search_history", args),
            try tool("read_history", #"{"offset":0,"handle":"S1"}"#),
            answer(#"{"status":"answered","markdown":"Prepare the handoff. [[S2]]"}"#),
            try tool("read_skill", #"{"id":"find-meetings"}"#), try tool("search_history", args), answer(#"{"status":"answered","markdown":"In window. [[S1]]"}"#)
        ])
        let chat = MeetingChatCoordinator(databaseURL: db, generator: probe)
        let saved = MeetingChatStore(databaseURL: db)
        func wait() async throws {
            let until = Date().addingTimeInterval(5)
            while chat.isBusy && Date() < until { try await Task.sleep(for: .milliseconds(10)) }
        }
        await chat.send(question: "$project-brief on the meeting from last week", config: AppConfig())
        try await wait()
        let id = try #require(chat.selectedSessionID)
        try saved.updateSession(id: id, title: "Fixture", scope: nil)
        await chat.send(question: "Which sessions fall inside that interval?", config: AppConfig())
        try await wait()
        let requests = await probe.requests
        let discoveryReplay = try #require(requests.first { request in
            String(decoding: request.inputItems, as: UTF8.self).contains("In window")
        })
        #expect(!String(decoding: discoveryReplay.inputItems, as: UTF8.self).contains("Prepare the handoff."))
        let turns = try saved.turns(sessionID: id)
        #expect(turns.map(\.state) == [.completed, .completed])
        #expect(turns.map { $0.citations.map(\.title) } == [["In window"], ["In window"]])
        #expect(try saved.sessions().first?.scope == MeetingChatScopePolicy.empty)
        _ = await chat.setScope(MeetingChatScopePolicy.empty)
        #expect(chat.scopeForRecentMeetingRequest == MeetingChatScopePolicy.empty)
        #expect(try saved.sessions().first?.allowsRequestedMeetingDiscovery == false)
    }

    @MainActor @Test func compatibilityModelComposesAPersonalSkillAndArbitraryDateRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db)
        try store.migrateIfNeeded()
        var config = AppConfig()
        let personal = CustomMeetingTemplate(name: "Weekly commitments", prompt: "Find promises and quote the supporting passage.")
        config.customMeetingTemplates = [personal]
        let skill = try #require(MuesliHistoryTask.catalog(custom: [personal]).first { $0.personal })
        let start = try #require(ISO8601DateFormatter().date(from: "2025-10-15T12:00:00Z"))
        _ = try store.insertMeeting(title: "Review", calendarEventID: nil, startTime: start,
            endTime: start.addingTimeInterval(60), rawTranscript: "I will deliver the draft.", formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        let probe = TaskPlainProbe(responses: [
            #"{"tool":"read_skill","id":"\#(skill.id)"}"#,
            #"{"tool":"search_history","kind":"meeting","title":null,"from":"2025-10-12","until":"2025-10-17","limit":4}"#,
            #"{"tool":"read_history","offset":0,"handle":"S1"}"#,
            #"{"status":"answered","markdown":"Deliver the draft. [[S2]]"}"#
        ])
        let chat = MeetingChatCoordinator(databaseURL: db, generator: probe)
        let question = "Del doce al dieciséis de octubre de 2025, ¿qué prometí entregar?"
        await chat.send(question: question, config: config)
        await chat.waitForIdle()
        let turn = try #require(chat.turns.first)
        #expect(turn.state == .completed)
        #expect(turn.citations.map(\.kind) == [.transcript])
        let requests = await probe.requests
        #expect(requests.first?.user.contains(question) == true)
        #expect(requests.first?.user.contains("I will deliver the draft") == false)
        #expect(requests.dropFirst().first?.user.contains("quote the supporting passage") == true)
    }

    @MainActor @Test func taggedFollowUpsAndRewriteAreTwoTurnsInOneSavedChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db)
        try store.migrateIfNeeded()
        for index in 1...4 {
            let start = Date().addingTimeInterval(-Double(index) * 86400)
            _ = try store.insertMeeting(title: "Fixture \(index)", calendarEventID: nil, startTime: start,
                endTime: start.addingTimeInterval(60), rawTranscript: "Send update number \(index).",
                formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        }
        func tool(_ name: String, _ arguments: String) throws -> MeetingNativeToolResponse {
            let item = ["type": "function_call", "call_id": name, "name": name, "arguments": arguments]
            return .init(outputItems: try JSONSerialization.data(withJSONObject: [item]),
                         calls: [.init(id: name, name: name, arguments: arguments)], text: "")
        }
        let probe = TaskNativeProbe(responses: [
            try tool("read_skill", #"{"id":"follow-ups"}"#),
            try tool("search_history", #"{"kind":"meeting","limit":3}"#),
            answer(#"{"status":"answered","markdown":"Send the project update. [[S1]]"}"#),
            answer(#"{"status":"conversation","markdown":"1. Draft it. 2. Review it. 3. Send it."}"#)
        ])
        func waitForAnswer(_ coordinator: MeetingChatCoordinator) async throws {
            let deadline = Date().addingTimeInterval(10)
            while coordinator.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!coordinator.isBusy)
        }
        let coordinator = MeetingChatCoordinator(databaseURL: db, generator: probe)
        await coordinator.send(question: "$follow-ups from my last three meetings", config: AppConfig())
        try await waitForAnswer(coordinator)
        let id = try #require(coordinator.selectedSessionID)
        let storage = MeetingChatStore(databaseURL: db)
        let first = try #require(try storage.turns(sessionID: id).first)
        #expect(first.state == .completed)
        #expect(first.skillTitle == "Possible follow-ups")
        #expect(first.citations.count == 1)
        let reopened = MeetingChatCoordinator(databaseURL: db, generator: probe)
        reopened.selectChat(id: id)
        await reopened.send(question: "Summarize in three points", config: AppConfig())
        try await waitForAnswer(reopened)
        let turns = try storage.turns(sessionID: id)
        #expect(turns.map(\.state) == [.completed, .completed])
        #expect(try storage.sessions().map(\.id) == [id])
        let requests = await probe.requests
        #expect(requests.count == 4)
        let last = try #require(requests.last)
        let input = String(decoding: last.inputItems, as: UTF8.self)
        #expect(input.contains("Send the project update"))
        #expect(String(decoding: last.tools, as: UTF8.self).contains("read_skill"))
    }

    @MainActor @Test func personalTemplateReturnsItsOwnFormatWithVerifiedSources() async throws {
        let custom = CustomMeetingTemplate(name: "Handoff", prompt: "Use the heading Handoff.")
        let skill = try #require(MuesliHistoryTask.catalog(custom: [custom]).first { $0.personal })
        let response = ###"{"answer":"## Handoff\nReview the checklist.","sources":["C1"]}"###
        let probe = TaskPlainProbe(responses: [response])
        let runtime = try await MuesliTaskRunner.prepare(config: AppConfig(), generator: probe)
        let result = try await TimeTurnerRecapTask.run(packet: packet(), config: AppConfig(), runtime: runtime,
            template: skill, validateSources: {})
        #expect(result.first?.text == "## Handoff\nReview the checklist.")
        #expect(result.first?.sources == ["C1"])
        let request = try #require(await probe.requests.first)
        #expect(request.user.contains(custom.prompt))
        #expect(!request.system.contains(custom.prompt))
    }

    @MainActor @Test(arguments: [true, false])
    func recapFindsAndPersistsMeetingOutsideOpeningSample(native: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db)
        try store.migrateIfNeeded()
        let interval = try #require(Calendar.current.dateInterval(of: .day, for: Date(timeIntervalSince1970: 1_700_000_000)))
        func insert(_ text: String, at offset: Int) throws -> Int64 {
            let date = interval.start.addingTimeInterval(Double(offset))
            return try store.insertMeeting(title: "Planning", calendarEventID: nil, startTime: date,
                endTime: date.addingTimeInterval(5), rawTranscript: text, formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        }
        let decision = try insert("Bluejay ships on Friday.", at: 1)
        for n in 1...32 { _ = try insert("Reviewed checklist number \(n).", at: 60 * n) }
        _ = try insert("Bluejay was cancelled outside this day.", at: -100)
        var config = AppConfig()
        config.recapIncludeMeetings = true
        config.recapIncludeDictations = false
        let screenRoot = directory.appendingPathComponent("visual-memory")
        let memory = try VisualMemoryStore(root: screenRoot)
        let capture = VisualMemoryItem(kind: .moment, capturedAt: interval.start.addingTimeInterval(30),
            source: "Synthetic editor", text: "Reviewed release checklist", path: "sample.png")
        try Data([1]).write(to: screenRoot.appendingPathComponent(capture.path))
        try memory.save([capture])
        let access = MuesliHistoryAccess(databaseURL: db, screenRoot: screenRoot)
        let scoped = TimeTurnerRecapSearch(access: access, interval: interval, config: config, meetingScope: nil)
        #expect(throws: MeetingChatHarnessError.self) { try scoped.parse(#"{"kind":"dictation","query":"Bluejay"}"#) }
        #expect(throws: MeetingChatHarnessError.self) { try scoped.parse(#"{"kind":"meeting","query":"Bluejay","from":"2000-01-01"}"#) }
        let initial = try access.sample(interval: interval, kinds: [.meetings])
        let opening = try TimeTurnerRecap.packet(captures: [capture], passages: initial.meetings, interval: interval, config: config)
        #expect(!opening.sources.contains { $0.meeting?.meetingID == decision })
        let handle = "R" + String(opening.sources.count + 1)
        let args = #"{"kind":"meeting","query":"Bluejay"}"#
        let final = #"{"insights":[{"section":"decisions","text":"Bluejay ships Friday.","sources":["\#(handle)"]}]}"#
        let generator: any MeetingTextGenerating
        if native {
            let item = ["type":"function_call", "call_id":"search-1", "name":"search_history", "arguments":args]
            let lookup = MeetingNativeToolResponse(outputItems: try JSONSerialization.data(withJSONObject: [item]),
                calls: [.init(id: "search-1", name: "search_history", arguments: args)], text: "")
            generator = TaskNativeProbe(responses: [lookup, try call("read-1", source: handle), answer(final)])
        } else {
            generator = TaskPlainProbe(responses: [#"{"tool":"search_history","kind":"meeting","query":"Bluejay"}"#,
                #"{"tool":"read_history","handle":"\#(handle)","offset":0}"#, final])
        }
        let model = TimeTurnerRecapModel()
        model.generate(day: interval.start, root: screenRoot, databaseURL: db, config: config, generator: generator)
        await model.waitForGeneration()
        #expect(model.error == nil)
        let disk = try TimeTurnerRecapStore(databaseURL: db)
        let key = SavedTimeTurnerRecap.key(dayStart: interval.start, timeZone: Calendar.current.timeZone.identifier)
        let saved = try #require(try disk.load(key: key))
        #expect(saved.insights.first?.sources == [handle])
        #expect(saved.sources.first { $0.id == handle }?.meeting?.meetingID == decision)
        #expect(saved.sources.allSatisfy { $0.date >= interval.start && $0.date < interval.end })
        try store.deleteMeeting(id: decision)
        #expect(try !TimeTurnerRecap.sourcesAreCurrent(saved.sources, root: screenRoot, databaseURL: db))
    }

    @MainActor @Test func recapUsesNativeCallsAndCorrelatedReplay() async throws {
        let probe = TaskNativeProbe(responses: [try call("read-1"), answer(final)])
        let runtime = try await MuesliTaskRunner.prepare(config: AppConfig(), generator: probe)
        var checks = 0
        let insights = try await TimeTurnerRecapTask.run(packet: packet(), config: AppConfig(), runtime: runtime) { checks += 1 }
        #expect(insights.count == 1)
        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.requiresMeetingAnswerFormat })
        let replay = try #require(JSONSerialization.jsonObject(with: requests[1].inputItems) as? [[String: Any]])
        #expect(replay.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "read-1" })
        #expect(String(decoding: requests[1].inputItems, as: UTF8.self).contains("release checklist"))
        #expect(checks >= 5) // Before/after inference, plus source read.
        #expect(await probe.plainCalls == 0)
    }

    @MainActor @Test func recapCompatibilityReadsThenRepairsOnceWithoutTools() async throws {
        let probe = TaskPlainProbe(responses: [#"{"tool":"read_history","handle":"C1","offset":0}"#, "malformed", final])
        let runtime = try await MuesliTaskRunner.prepare(config: AppConfig(), generator: probe)
        let insights = try await TimeTurnerRecapTask.run(packet: packet(), config: AppConfig(), runtime: runtime, validateSources: {})
        #expect(insights.count == 1)
        let requests = await probe.requests
        #expect(requests.count == 3)
        #expect(requests[1].user.contains("next_offset"))
        #expect(requests[2].system.contains("Retrieval is finished"))
    }

    @MainActor @Test func unknownSourceNeverReachesExecutor() async throws {
        let probe = TaskNativeProbe(responses: [try call("bad", source: "C999"), answer(final)])
        let runtime = try await MuesliTaskRunner.prepare(config: AppConfig(), generator: probe)
        _ = try await TimeTurnerRecapTask.run(packet: packet(), config: AppConfig(), runtime: runtime, validateSources: {})
        let requests = await probe.requests
        let replay = String(decoding: requests[1].inputItems, as: UTF8.self)
        #expect(replay.contains("Invalid function or arguments"))
        #expect(!replay.contains("next_offset"))
    }

    @MainActor @Test func duplicateNativeCallIDIsRejected() async throws {
        let probe = TaskNativeProbe(responses: [try call("same"), try call("same")])
        let runtime = try await MuesliTaskRunner.prepare(config: AppConfig(), generator: probe)
        await #expect(throws: MeetingChatHarnessError.self) {
            try await TimeTurnerRecapTask.run(packet: packet(), config: AppConfig(), runtime: runtime, validateSources: {})
        }
        #expect(await probe.requests.count == 2)
    }

    @MainActor @Test func staleSourcesAbortBeforeToolExecutionOrFinalPublication() async throws {
        let probe = TaskNativeProbe(responses: [try call("read-1")])
        let runtime = try await MuesliTaskRunner.prepare(config: AppConfig(), generator: probe)
        var checks = 0
        await #expect(throws: TimeTurnerRecapError.self) {
            try await TimeTurnerRecapTask.run(packet: packet(), config: AppConfig(), runtime: runtime) {
                checks += 1
                if checks == 2 { throw TimeTurnerRecapError.changedSources }
            }
        }
        #expect(await probe.requests.count == 1)
    }

    @MainActor @Test func cancellationIsNotRetriedAsAFormatFailure() async throws {
        var calls = 0
        await #expect(throws: CancellationError.self) {
            let _: String = try await MuesliTaskRunner.runCompatibility(maximumToolCalls: 3) { _, _, _ in
                calls += 1
                throw CancellationError()
            }
        }
        #expect(calls == 1)
    }

    @MainActor @Test func exhaustedNativeBudgetWithholdsOutputAndFinalizes() async throws {
        let probe = TaskNativeProbe(responses: [try call("large"), answer("done")])
        var accepted: Bool?
        var exhausted = false
        let task = MuesliNativeTask<String, String>(instructions: "Read source then finish.", user: "Synthetic",
            tools: [TimeTurnerRecapTask.tool], requiresMeetingAnswerFormat: false,
            parse: { _, _ in "source" }, execute: { _ in .init(text: String(repeating: "x", count: 30_000)) },
            accept: { _, value in accepted = value }, exhausted: { exhausted = true }, validate: { $0 })
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"
        let output = try await MuesliTaskRunner.runNative(task, config: config, sessionID: UUID(), generator: probe,
            budget: .init(config: config, contextWindowTokens: 8192))
        #expect(output == "done")
        #expect(accepted == false && exhausted)
        let requests = await probe.requests
        #expect(requests.last?.allowTools == false)
        #expect(String(decoding: requests.last!.inputItems, as: UTF8.self).contains("budget_exhausted"))
        #expect(requests.last!.inputItems.count < 3000)
    }

    @MainActor @Test func readsAreScopedAndUnicodePaginationIsLossless() throws {
        let text = String(repeating: "你好🙂", count: 700)
        let p = try packet(text: text)
        var offset = 0, reconstructed = ""
        while true {
            let output = try TimeTurnerRecapTask.read(.init(source: "C1", offset: offset), packet: p)
            let object = try #require(JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any])
            let chunk = try #require(object["text"] as? String)
            #expect(chunk.utf8.count <= 4000)
            reconstructed += chunk
            guard let next = object["next_offset"] as? Int else { break }
            #expect(next > offset)
            offset = next
        }
        #expect(reconstructed == text)
        for args in [#"{"source":"C99","offset":0}"#, #"{"handle":"C1","offset":true}"#,
                     #"{"handle":"C1","offset":-1}"#, #"{"handle":"C1","offset":1.5}"#,
                     #"{"handle":"C1","offset":0,"path":"/private"}"#] {
            #expect(throws: MeetingChatHarnessError.self) { try TimeTurnerRecapTask.parse(name: "read_history", arguments: args, packet: p) }
        }
    }

    @MainActor @Test func discoveredSmallLocalContextStillSupportsARecap() async throws {
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"
        let probe = TaskNativeProbe(responses: [answer(final)])
        let budget = MeetingChatContextBudget(config: config, contextWindowTokens: 4096)
        let original = try packet()
        let capture = try #require(original.sources.first?.capture)
        let p = try TimeTurnerRecap.packet(captures: [capture], passages: [],
            interval: .init(start: capture.capturedAt, duration: 3600), config: config, contextBudget: budget)
        let output = try await TimeTurnerRecapTask.run(packet: p, config: config,
            runtime: .init(generator: probe, budget: budget), validateSources: {})
        #expect(output.count == 1)
        let request = try #require(await probe.requests.first)
        let actual = request.base.system + String(decoding: request.inputItems, as: UTF8.self)
            + String(decoding: request.tools, as: UTF8.self)
        #expect(MeetingChatContextBudget.estimateTokens(actual) <= budget.maximumInputTokens)
    }

    private func answer(_ text: String) -> MeetingNativeToolResponse {
        .init(outputItems: Data("[]".utf8), calls: [], text: text)
    }
    private func call(_ id: String, source: String = "C1") throws -> MeetingNativeToolResponse {
        let arguments = "{\"handle\":\"\(source)\",\"offset\":0}"
        let item = ["type": "function_call", "call_id": id, "name": "read_history", "arguments": arguments]
        return .init(outputItems: try JSONSerialization.data(withJSONObject: [item]),
            calls: [.init(id: id, name: "read_history", arguments: arguments)], text: "")
    }
}

private actor TaskNativeProbe: MeetingTextGenerating {
    var requests: [MeetingNativeToolRequest] = []
    var plainCalls = 0
    var responses: [MeetingNativeToolResponse]
    init(responses: [MeetingNativeToolResponse]) { self.responses = responses }
    nonisolated func supportsNativeTools(config: AppConfig) -> Bool { true }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        plainCalls += 1
        throw MeetingTextGenerationError.emptyResponse
    }
    func generateNative(_ request: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw MeetingTextGenerationError.emptyResponse }
        return responses.removeFirst()
    }
}

private actor TaskPlainProbe: MeetingTextGenerating {
    var requests: [MeetingTextGenerationRequest] = []
    var responses: [String]
    init(responses: [String]) { self.responses = responses }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        requests.append(request)
        guard !responses.isEmpty else { throw MeetingTextGenerationError.emptyResponse }
        return responses.removeFirst()
    }
}

import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Global search source validation")
struct GlobalSearchWorkerTests {
    private final class OpenCounter: @unchecked Sendable {
        let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func open(_ root: URL) throws -> VisualMemoryStore {
            lock.withLock { count += 1 }
            return try VisualMemoryStore(root: root, readOnly: true)
        }
    }

    private final class RetryClock: @unchecked Sendable {
        let lock = NSLock()
        private var instant = Date()
        private var attempts = 0
        func now() -> Date { lock.withLock { instant } }
        func advance() { lock.withLock { instant = instant.addingTimeInterval(6) } }
        var count: Int { lock.withLock { attempts } }
        func open(_ root: URL) throws -> VisualMemoryStore {
            let attempt = lock.withLock { attempts += 1; return attempts }
            if attempt == 1 { throw CocoaError(.fileReadUnknown) }
            return try VisualMemoryStore(root: root, readOnly: true)
        }
    }

    @Test("A transient catalog-open failure retries with backoff even without file writes")
    func transientCatalogOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        try DictationStore(databaseURL: url).migrateIfNeeded()
        let screenRoot = root.appendingPathComponent("visual-memory")
        let memory = try VisualMemoryStore(root: screenRoot)
        try memory.save([.init(id: "capture", kind: .moment, source: "Editor", text: "orchid", path: "one.png")])
        let clock = RetryClock()
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot,
            now: { clock.now() }, openScreen: { try clock.open($0) })
        let first = try await worker.searchResponse(.init(text: "orchid"))
        #expect(first.results.isEmpty && first.unavailableKinds == [.screenHistory])
        let token = try await worker.changeToken()
        let retry = try await worker.searchResponse(.init(text: "orchid"))
        #expect(retry.results.isEmpty && retry.unavailableKinds == [.screenHistory])
        #expect(clock.count == 1)
        #expect(try await worker.changeToken() == token)
        clock.advance()
        #expect(try await worker.changeToken() != token)
        #expect(try await worker.search(.init(text: "orchid")).map(\.sourceID) == ["capture"])
        #expect(clock.count == 2)
    }

    @Test("Filter changes and captures reuse the catalog; file replacement opens the new catalog")
    func catalogLifetime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        try DictationStore(databaseURL: url).migrateIfNeeded()
        let screenRoot = root.appendingPathComponent("visual-memory")
        let memory = try VisualMemoryStore(root: screenRoot)
        try memory.save([.init(id: "one", kind: .moment, source: "Editor", text: "orchid", path: "one.png")])
        let counter = OpenCounter()
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot, openScreen: { try counter.open($0) })
        for _ in 0..<3 {
            _ = try await worker.search(.init(text: "orchid", kinds: [.meeting]))
            #expect(try await worker.search(.init(text: "orchid")).map(\.sourceID) == ["one"])
        }
        #expect(counter.value == 1)
        try memory.save([.init(id: "two", kind: .moment, source: "Editor", text: "orchid", path: "two.png")])
        #expect(try await worker.search(.init(text: "orchid")).count == 2)
        #expect(counter.value == 1)
        try FileManager.default.moveItem(at: screenRoot, to: root.appendingPathComponent("old-catalog"))
        let replacement = try VisualMemoryStore(root: screenRoot)
        try replacement.save([.init(id: "replacement", kind: .moment, source: "Editor", text: "orchid", path: "new.png")])
        #expect(try await worker.search(.init(text: "orchid")).map(\.sourceID) == ["replacement"])
        #expect(counter.value == 2)
    }

    @Test("Search opens persisted recap identity after travel and still revalidates its sources")
    @MainActor func recapNavigationAcrossTimeZones() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-travel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        try DictationStore(databaseURL: url).migrateIfNeeded()
        let screenRoot = root.appendingPathComponent("visual-memory")
        let memory = try VisualMemoryStore(root: screenRoot)
        let instant = ISO8601DateFormatter().date(from: "2026-11-02T01:00:00Z")!
        let capture = VisualMemoryItem(id: "stable-capture", kind: .moment, capturedAt: instant, source: "Editor", text: "Orchid evidence", path: "image.png")
        try memory.save([capture])
        var origin = Calendar(identifier: .gregorian)
        origin.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var destination = origin
        destination.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let interval = try #require(origin.dateInterval(of: .day, for: instant))
        let saved = SavedTimeTurnerRecap(version: 1, dayStart: interval.start, dayEnd: interval.end,
            timeZone: origin.timeZone.identifier, generatedAt: instant, provider: "test", model: "test",
            insights: [.init(section: .work, text: "Orchid recap", sources: ["C1"])],
            sources: [.init(id: "C1", title: "Editor", date: instant, excerpt: capture.text, capture: capture, meeting: nil)])
        let store = try TimeTurnerRecapStore(databaseURL: url)
        try store.save(saved)
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot)
        let hit = try #require(try await worker.search(.init(text: "orchid", kinds: [.recap])).first)
        guard case .recap(let resolved) = try await worker.destination(for: hit) else {
            Issue.record("Expected saved recap"); return
        }
        let state = AppState()
        state.openTimeTurnerRecap(resolved, calendar: destination)
        #expect(state.timeTurnerSelectedRecap?.key == saved.key)
        #expect(state.timeTurnerSelectedRecap?.interval == interval)
        #expect(state.timeTurnerSelectedRecap?.timeZone == origin.timeZone.identifier)
        let browsingDay = try #require(state.timeTurnerSelectedRecap?.browsingDay(in: destination))
        #expect(destination.component(.day, from: browsingDay) == origin.component(.day, from: interval.start))
        #expect(browsingDay != interval.start)
        #expect(state.timeTurnerDay == browsingDay)
        state.timeTurnerShowsRecap = false
        #expect(destination.component(.day, from: state.timeTurnerDay) == 2)
        #expect(state.timeTurnerSelectedRecap?.key == saved.key)
        let model = TimeTurnerRecapModel()
        await model.load(day: state.timeTurnerDay, selection: state.timeTurnerSelectedRecap,
            root: screenRoot, databaseURL: url, calendar: destination)
        #expect(model.hasGenerated)
        #expect(model.insights.first?.text == "Orchid recap")
        #expect(model.sources.first?.capture?.id == capture.id)
        // Without explicit identity, ordinary day browsing follows the new timezone.
        await model.load(day: state.timeTurnerDay, root: screenRoot, databaseURL: url, calendar: destination)
        #expect(!model.hasGenerated)
        try memory.delete(ids: [capture.id])
        await model.load(day: state.timeTurnerDay, selection: state.timeTurnerSelectedRecap,
            root: screenRoot, databaseURL: url, calendar: destination)
        #expect(!model.hasGenerated)
        #expect(try store.load(key: saved.key) == nil)
        state.timeTurnerDay = instant.addingTimeInterval(86400)
        #expect(state.timeTurnerSelectedRecap == nil)
    }

    @Test("Identical screen text at different times opens distinct stable capture IDs")
    @MainActor func captureIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-capture-id-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        try DictationStore(databaseURL: url).migrateIfNeeded()
        let screenRoot = root.appendingPathComponent("visual-memory")
        let memory = try VisualMemoryStore(root: screenRoot)
        let captures = (0..<2).map { i in
            VisualMemoryItem(id: "capture-\(i)", kind: .moment,
                capturedAt: Date(timeIntervalSince1970: 1793527200 + Double(i)*86400),
                source: "Editor", text: "Same orchid content", path: "\(i).png")
        }
        try memory.save(captures)
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot)
        let hits = try await worker.search(.init(text: "orchid", kinds: [.screenHistory]))
        #expect(hits.count == 2)
        let state = AppState()
        for hit in hits {
            guard case .capture(let capture) = try await worker.destination(for: hit) else {
                Issue.record("Expected original capture"); continue
            }
            state.openTimeTurnerCapture(capture)
            #expect(state.timeTurnerSelectedCapture?.id == hit.sourceID)
            #expect(state.timeTurnerSelectedCapture?.capturedAt == hit.date)
        }
    }

    @Test("An unreadable optional screen catalog does not block main content and can recover")
    func unreadableScreenCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Orchid review", calendarEventID: nil,
            startTime: Date(), endTime: Date(), rawTranscript: "Notes", formattedNotes: "Notes",
            micAudioPath: nil, systemAudioPath: nil)
        let screenRoot = root.appendingPathComponent("visual-memory")
        try FileManager.default.createDirectory(at: screenRoot, withIntermediateDirectories: true)
        let catalog = screenRoot.appendingPathComponent("catalog.sqlite")
        try Data("not a SQLite database".utf8).write(to: catalog)
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot)
        let corruptToken = try await worker.changeToken()
        #expect(try await worker.changeToken() == corruptToken)
        #expect(try await worker.search(.init(text: "orchid", kinds: [.meeting])).map(\.sourceID) == [String(id)])
        #expect(try await worker.search(.init(text: "orchid")).map(\.sourceID) == [String(id)])
        await #expect(throws: GlobalSearchError.self) {
            try await worker.search(.init(text: "orchid", kinds: [.screenHistory]))
        }
        try FileManager.default.removeItem(at: catalog)
        let memory = try VisualMemoryStore(root: screenRoot)
        #expect(try await worker.changeToken() != corruptToken)
        try memory.save([.init(id: "capture", kind: .moment, source: "Editor", text: "Orchid screen", path: "screen.png")])
        #expect(try await worker.search(.init(text: "orchid", kinds: [.screenHistory])).map(\.sourceID) == ["capture"])
        #expect(Set(try await worker.search(.init(text: "orchid")).map(\.kind)) == [.meeting, .screenHistory])
        let invalidMain = GlobalSearchWorker(databaseURL: root.appendingPathComponent("missing.db"), screenRoot: screenRoot)
        let partial = try await invalidMain.searchResponse(.init(text: "orchid"))
        #expect(partial.results.map(\.sourceID) == ["capture"])
        #expect(partial.unavailableKinds == Set(GlobalSearchKind.allCases).subtracting([.screenHistory]))
        await #expect(throws: GlobalSearchError.self) {
            try await invalidMain.search(.init(text: "orchid", kinds: [.meeting]))
        }
    }

    @Test("Read-only search stores cannot create missing databases or mutate existing history")
    func readOnlyStores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-readonly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        #expect(throws: (any Error).self) { try DictationStore(databaseURL: url, readOnly: true).dictation(id: 1) }
        #expect(throws: (any Error).self) { try MeetingChatStore(databaseURL: url, readOnly: true).turns(sessionID: UUID()) }
        #expect(throws: (any Error).self) { try TimeTurnerRecapStore(databaseURL: url, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let writer = DictationStore(databaseURL: url)
        try writer.migrateIfNeeded()
        let id = try writer.insertDictation(text: "orchid", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let reader = DictationStore(databaseURL: url, readOnly: true)
        #expect(try reader.dictation(id: id)?.rawText == "orchid")
        #expect(throws: (any Error).self) { try reader.deleteDictation(id: id) }
        #expect(throws: (any Error).self) {
            try MeetingChatStore(databaseURL: url, readOnly: true).createSession(scope: .init(), title: "Must not save")
        }
        #expect(try writer.dictation(id: id) != nil)
    }

    @Test("Removing a warm main database preserves screen search and recovers after restoration")
    func mainDatabaseAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-main-availability-\(UUID())")
        let mainRoot = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: mainRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = mainRoot.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        _ = try store.insertDictation(text: "orchid dictation", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let screenRoot = root.appendingPathComponent("visual-memory")
        let memory = try VisualMemoryStore(root: screenRoot)
        try memory.save([.init(id: "capture", kind: .moment, source: "Editor", text: "orchid", path: "image.png")])
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot)
        let healthy = try await worker.searchResponse(.init(text: "orchid"))
        let dictation = try #require(healthy.results.first { $0.kind == .dictation })
        let backup = root.appendingPathComponent("main-backup")
        try FileManager.default.moveItem(at: mainRoot, to: backup)
        let partial = try await worker.searchResponse(.init(text: "orchid"))
        #expect(partial.results.map(\.sourceID) == ["capture"])
        #expect(partial.unavailableKinds == Set(GlobalSearchKind.allCases).subtracting([.screenHistory]))
        guard case .unavailable = try await worker.resolveDestination(for: dictation) else {
            Issue.record("Missing database must not read an old connection or report a deleted record"); return
        }
        #expect(!FileManager.default.fileExists(atPath: mainRoot.path))
        try FileManager.default.moveItem(at: backup, to: mainRoot)
        let recovered = try await worker.searchResponse(.init(text: "orchid"))
        #expect(recovered.unavailableKinds.isEmpty)
        #expect(Set(recovered.results.map(\.id)) == Set(healthy.results.map(\.id)))
    }

    @Test("Unavailable recap evidence cannot hide independent results and recovers without reindexing", arguments: [false, true])
    func recapEvidenceAvailability(corrupt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-recap-availability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        _ = try store.insertDictation(text: "orchid dictation", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        _ = try store.insertMeeting(title: "Orchid meeting", calendarEventID: nil,
            startTime: Date(), endTime: Date(), rawTranscript: "orchid", formattedNotes: "Notes",
            micAudioPath: nil, systemAudioPath: nil)
        let screenRoot = root.appendingPathComponent("visual-memory")
        let backup = root.appendingPathComponent("catalog-backup")
        let memory = try VisualMemoryStore(root: screenRoot)
        let capture = VisualMemoryItem(id: "capture", kind: .moment, source: "Editor", text: "orchid", path: "image.png")
        try memory.save([capture])
        let saved = SavedTimeTurnerRecap(version: 1, dayStart: Date(), dayEnd: Date().addingTimeInterval(86400),
            timeZone: "UTC", generatedAt: Date(), provider: "test", model: "test",
            insights: [.init(section: .work, text: "orchid recap", sources: ["C1"])],
            sources: [.init(id: "C1", title: "Editor", date: capture.capturedAt, excerpt: capture.text, capture: capture, meeting: nil)])
        try TimeTurnerRecapStore(databaseURL: url).save(saved)
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot)
        let healthy = try await worker.searchResponse(.init(text: "orchid"))
        let recapHit = try #require(healthy.results.first { $0.kind == .recap })
        let captureHit = try #require(healthy.results.first { $0.kind == .screenHistory })
        let meetingHit = try #require(healthy.results.first { $0.kind == .meeting })
        try FileManager.default.moveItem(at: screenRoot, to: backup)
        if corrupt {
            try FileManager.default.createDirectory(at: screenRoot, withIntermediateDirectories: true)
            try Data("damaged catalog".utf8).write(to: screenRoot.appendingPathComponent("catalog.sqlite"))
        }
        let partial = try await worker.searchResponse(.init(text: "orchid"))
        #expect(Set(partial.results.map(\.kind)) == [.dictation, .meeting])
        #expect(partial.unavailableKinds == [.recap, .screenHistory])
        #expect(!partial.results.contains { $0.id == recapHit.id })
        let scoped = try await worker.searchResponse(.init(text: "orchid", kinds: [.recap]))
        #expect(scoped.results.isEmpty)
        #expect(scoped.unavailableKinds == [.recap])
        guard case .unavailable = try await worker.resolveDestination(for: recapHit),
              case .unavailable = try await worker.resolveDestination(for: captureHit),
              case .available(.meeting) = try await worker.resolveDestination(for: meetingHit) else {
            Issue.record("Unavailable evidence must stay distinct from deletion and independent destinations"); return
        }
        if corrupt { try FileManager.default.removeItem(at: screenRoot) }
        try FileManager.default.moveItem(at: backup, to: screenRoot)
        let recovered = try await worker.searchResponse(.init(text: "orchid"))
        #expect(recovered.unavailableKinds.isEmpty)
        #expect(Set(recovered.results.map(\.id)) == Set(healthy.results.map(\.id)))
        guard case .available(.recap) = try await worker.resolveDestination(for: recapHit) else {
            Issue.record("Restored evidence should resolve again"); return
        }
        // Deletion has a different result: no retryable error, and no stale recap content.
        try memory.delete(ids: [capture.id])
        let deleted = try await worker.searchResponse(.init(text: "orchid", kinds: [.recap]))
        #expect(deleted.results.isEmpty && deleted.unavailableKinds.isEmpty)
        guard case .missing = try await worker.resolveDestination(for: recapHit),
              case .missing = try await worker.resolveDestination(for: captureHit) else {
            Issue.record("Confirmed missing evidence must not look temporarily unavailable"); return
        }
    }

    @Test("Opening a result rechecks deletion rather than trusting its snippet")
    func deletedDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-open-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Orchid review", calendarEventID: nil,
            startTime: Date(), endTime: Date(), rawTranscript: "Notes", formattedNotes: "Notes",
            micAudioPath: nil, systemAudioPath: nil)
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: nil)
        let hit = try #require(try await worker.search(.init(text: "orchid")).first)
        guard case .meeting(let meeting) = try await worker.destination(for: hit) else {
            Issue.record("Expected meeting destination"); return
        }
        #expect(meeting.id == id)
        let before = try await worker.changeToken()
        #expect(try await worker.changeToken() == before)
        try store.deleteMeeting(id: id)
        #expect(try await worker.changeToken() != before)
        #expect(try await worker.destination(for: hit) == nil)
    }

    @Test("Meeting edits and deletions invalidate derived Chat search hits")
    func changedChatEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("global-worker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Planning", calendarEventID: nil,
            startTime: Date(), endTime: Date(), rawTranscript: "Ship Friday", formattedNotes: "Friday",
            micAudioPath: nil, systemAudioPath: nil)
        let chat = MeetingChatStore(databaseURL: url)
        let session = try chat.createSession(scope: .init(), title: "Launch")
        let turn = try chat.beginTurn(sessionID: session.id, question: "When?", scope: .init(), provider: "test", model: "test")
        let source = try #require(chat.sourceSnapshots(scope: .init()).first { $0.meetingID == id })
        let deps = [MeetingChatDependency(meetingID: id, revision: source.revision)]
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Orchid Friday", citations: [], dependencies: deps))
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: nil)
        #expect(try await worker.search(.init(text: "orchid", kinds: [.chat])).count == 1)
        try store.updateMeetingTranscript(id: id, rawTranscript: "Ship Monday instead")
        #expect(try await worker.search(.init(text: "orchid", kinds: [.chat])).isEmpty)
        try store.deleteMeeting(id: id)
        #expect(try await worker.search(.init(text: "orchid", kinds: [.chat])).isEmpty)
    }

    @Test("Deleting one Chat source preserves unrelated and subsequent searchable turns")
    func survivingChatTurns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-chat-survivors-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        let chat = MeetingChatStore(databaseURL: url)
        let session = try chat.createSession(scope: .init(), title: "Planning")
        var meetingIDs: [Int64] = []
        for text in ["Orchid", "Marigold"] {
            let id = try store.insertMeeting(title: text, calendarEventID: nil,
                startTime: Date(), endTime: Date(), rawTranscript: text, formattedNotes: text,
                micAudioPath: nil, systemAudioPath: nil)
            meetingIDs.append(id)
            let turn = try chat.beginTurn(sessionID: session.id, question: "Discuss this meeting",
                scope: .init(), provider: "test", model: "test")
            let source = try #require(chat.sourceSnapshots(scope: .init()).first { $0.meetingID == id })
            #expect(try chat.finishTurn(turnID: turn.id, answer: text, citations: [],
                dependencies: [.init(meetingID: id, revision: source.revision)]))
        }
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: nil)
        let hit = try #require(try await worker.search(.init(text: "marigold", kinds: [.chat])).first)
        try store.deleteMeeting(id: meetingIDs[0])
        #expect(try await worker.search(.init(text: "orchid", kinds: [.chat])).isEmpty)
        #expect(try await worker.search(.init(text: "marigold", kinds: [.chat])).count == 1)
        guard case .chat(let destination) = try await worker.destination(for: hit) else {
            Issue.record("Surviving conversation should open"); return
        }
        #expect(destination == session.id)
        let later = try chat.beginTurn(sessionID: session.id, question: "Next steps", scope: .init(), provider: "test", model: "test")
        #expect(try chat.finishTurn(turnID: later.id, answer: "Sunflower", citations: [], dependencies: []))
        #expect(try await worker.search(.init(text: "sunflower", kinds: [.chat])).count == 1)
        // A stale surviving answer is still rejected; deleted turns are the only exclusion.
        try store.updateMeetingTranscript(id: meetingIDs[1], rawTranscript: "Changed evidence")
        #expect(try await worker.search(.init(text: "marigold", kinds: [.chat])).isEmpty)
        #expect(try await worker.destination(for: hit) == nil)
    }

    @Test("Recap validation hides derived text while cross-database deletion is still pending")
    func deletedRecapEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("global-worker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        try DictationStore(databaseURL: url).migrateIfNeeded()
        let screenRoot = root.appendingPathComponent("visual-memory")
        let memory = try VisualMemoryStore(root: screenRoot)
        let item = VisualMemoryItem(id: "capture", kind: .moment, source: "Editor", text: "Evidence", path: "image.png")
        try memory.save([item])
        let recap = SavedTimeTurnerRecap(version: 1, dayStart: Date(), dayEnd: Date().addingTimeInterval(86400),
            timeZone: "UTC", generatedAt: Date(), provider: "test", model: "test",
            insights: [.init(section: .work, text: "Orchid recap", sources: ["C1"])],
            sources: [.init(id: "C1", title: "Editor", date: item.capturedAt, excerpt: item.text, capture: item, meeting: nil)])
        try TimeTurnerRecapStore(databaseURL: url).save(recap)
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: screenRoot)
        #expect(try await worker.search(.init(text: "orchid", kinds: [.recap])).count == 1)
        // Deliberately leave the recap cleanup queue pending to simulate interrupted maintenance.
        try memory.delete(ids: [item.id])
        #expect(try TimeTurnerRecapStore(databaseURL: url).load(key: recap.key) != nil)
        #expect(try await worker.search(.init(text: "orchid", kinds: [.recap])).isEmpty)
    }
}

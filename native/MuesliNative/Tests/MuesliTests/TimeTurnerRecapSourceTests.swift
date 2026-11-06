import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Daily recap source preferences")
struct TimeTurnerRecapSourceTests {
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    func fixture() throws -> (URL, URL, DictationStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db)
        try store.migrateIfNeeded()
        return (root, db, store)
    }
    func saved(_ history: TimeTurnerRecapHistorySource) -> SavedTimeTurnerRecap {
        .init(version: 1, dayStart: day, dayEnd: day.addingTimeInterval(86400), timeZone: "UTC", generatedAt: day,
              provider: "test", model: "test", insights: [], sources: [
                .init(id: "H1", title: history.title, date: history.date, excerpt: history.text,
                      capture: nil, meeting: nil, history: history)
              ], includedInputs: [history.kind])
    }
    @Test func todosSpanDaysAndKeepCompletionWhileEvidenceRemains() throws {
        let (root, db, sourceStore) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TimeTurnerRecapStore(databaseURL: db)
        func recap(_ date: Date, action: String?) throws -> (SavedTimeTurnerRecap, Int64) {
            let id = try sourceStore.insertDictation(text: "Review the draft", durationSeconds: 1, startedAt: date, endedAt: date)
            let source = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
            return (.init(version: 1, dayStart: date, dayEnd: date.addingTimeInterval(86400), timeZone: "UTC",
                generatedAt: date, provider: "test", model: "test", insights: [
                    .init(section: .work, text: "Drafted the plan", sources: ["H1"]),
                    .init(section: .followUps, text: "Review the draft", sources: ["H1"], action: action)
                ], sources: saved(source).sources), id)
        }
        let (first, firstID) = try recap(day, action: nil)
        try store.save(first)
        let initial = try #require(try store.todos(root: nil, databaseURL: db).first)
        try store.setTodo(initial.id, completed: true)
        try store.save(first)
        // A refreshed summary can omit a still-open task without resolving it.
        let refresh = SavedTimeTurnerRecap(version: 1, dayStart: first.dayStart, dayEnd: first.dayEnd,
            timeZone: first.timeZone, generatedAt: Date(), provider: "test", model: "test", insights: [], sources: [])
        try store.save(refresh)
        #expect(try store.todos(root: nil, databaseURL: db).first?.completed == true)
        let (next, secondID) = try recap(day.addingTimeInterval(86400), action: "Review the draft")
        try store.save(next)
        let reopened = try TimeTurnerRecapStore(databaseURL: db)
        let items = try reopened.todos(root: nil, databaseURL: db)
        #expect(items.count == 1 && items.first?.completed == true && items.first?.recapKey == next.key)
        try sourceStore.deleteDictation(id: secondID)
        #expect(try reopened.todos(root: nil, databaseURL: db).first?.recapKey == first.key)
        try reopened.setTodo(initial.id, completed: false)
        #expect(try reopened.todos(root: nil, databaseURL: db).first?.completed == false)
        try sourceStore.deleteDictation(id: firstID)
        #expect(try reopened.todos(root: nil, databaseURL: db).isEmpty)
    }

    @Test func deletedTodoStaysRemovedWhenRecapsAreReplayed() throws {
        let (root, db, sources) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try sources.insertDictation(text: "Review the plan", durationSeconds: 1, startedAt: day, endedAt: day)
        let source = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
        var recap = saved(source)
        recap.insights = [.init(section: .followUps, text: "Review the plan", sources: ["H1"], taskID: "review-plan")]
        let store = try TimeTurnerRecapStore(databaseURL: db)
        try store.save(recap)
        try store.snoozeTodo("review-plan", interval: 43200, now: day)
        let item = try #require(try store.todos(root: nil, databaseURL: db).first)
        try store.deleteTodo(item.id, now: day)
        try store.deleteTodo(item.id, now: day) // idempotent
        try store.deliveredTodo(item, now: day.addingTimeInterval(43200))
        try store.snoozeTodo(item.id, interval: 43200, now: day) // stale UI callback
        try store.setTodo(item.id, completed: false)
        try store.save(recap) // replay must not revive it or its reminder
        let reopened = try TimeTurnerRecapStore(databaseURL: db)
        #expect(try reopened.todos(root: nil, databaseURL: db).isEmpty)
        #expect(try !reopened.hasDueTodos(now: .distantFuture))
        #expect(try reopened.load(key: recap.key)?.insights.count == 1)
        // Completed tasks can be deleted too, without affecting another task.
        recap.insights.append(.init(section: .followUps, text: "Send the plan", sources: ["H1"], taskID: "send-plan"))
        try reopened.save(recap)
        try reopened.setTodo("send-plan", completed: true)
        #expect(try reopened.todos(root: nil, databaseURL: db).count == 1)
        try reopened.deleteTodo("send-plan")
        #expect(try reopened.todos(root: nil, databaseURL: db).isEmpty)
        try sources.deleteDictation(id: id)
        #expect(try reopened.load(key: recap.key) == nil)
    }

    @Test func taskCreationOrderingAndRepeatingRemindersSurviveReload() throws {
        let (root, db, sources) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try sources.insertDictation(text: "Review and send", durationSeconds: 1, startedAt: day, endedAt: day)
        let source = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
        let original = saved(source)
        func recap(at date: Date, titles: [String]) -> SavedTimeTurnerRecap {
            .init(version: 1, dayStart: date, dayEnd: date.addingTimeInterval(86400), timeZone: "UTC", generatedAt: date,
                provider: "test", model: "test", insights: titles.map {
                    .init(section: .followUps, text: $0, sources: ["H1"], action: $0)
                }, sources: original.sources)
        }
        let store = try TimeTurnerRecapStore(databaseURL: db)
        try store.save(recap(at: day, titles: ["Review", "Send"]))
        try store.save(recap(at: day.addingTimeInterval(3600), titles: ["Review", "Follow up"]))
        let items = try store.todos(root: nil, databaseURL: db)
        #expect(items.count == 3)
        #expect(items.first?.title == "Follow up")
        let review = try #require(items.first { $0.title == "Review" })
        #expect(review.createdAt == day) // a later recap does not change creation order
        try store.snoozeTodo(review.id, interval: 43200, now: day)
        let reopened = try TimeTurnerRecapStore(databaseURL: db)
        #expect(try !reopened.hasDueTodos(now: day.addingTimeInterval(43199)))
        #expect(try reopened.hasDueTodos(now: day.addingTimeInterval(43200)))
        let due = try #require(try reopened.todos(root: nil, databaseURL: db).first { $0.id == review.id })
        try reopened.deliveredTodo(due, now: day.addingTimeInterval(43200))
        #expect(try !reopened.hasDueTodos(now: day.addingTimeInterval(43201)))
        #expect(try reopened.hasDueTodos(now: day.addingTimeInterval(86400)))
        try reopened.snoozeTodo(review.id, interval: 86400, now: day.addingTimeInterval(86400))
        try reopened.deliveredTodo(due, now: day) // stale delivery cannot undo a new snooze
        #expect(try !reopened.hasDueTodos(now: day.addingTimeInterval(86401)))
        try reopened.setTodo(review.id, completed: true)
        #expect(try !reopened.hasDueTodos(now: .distantFuture))
        try reopened.setTodo(review.id, completed: false)
        #expect(try !reopened.hasDueTodos(now: .distantFuture))
        try reopened.snoozeTodo(review.id, interval: 43200, now: day)
        try reopened.snoozeTodo(review.id, interval: nil)
        #expect(try !reopened.hasDueTodos(now: .distantFuture))
        #expect(throws: (any Error).self) { try reopened.snoozeTodo(review.id, interval: -1) }
        try reopened.snoozeTodo(review.id, interval: 43200, now: day)
        try sources.deleteDictation(id: id)
        #expect(try reopened.todos(root: nil, databaseURL: db).isEmpty)
        #expect(try !reopened.hasDueTodos(now: .distantFuture))
    }

    @Test func modelReconciliationPreservesStateAndPurgesAllVersions() throws {
        let (root, db, sources) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try sources.insertDictation(text: "Verify the dispatcher", durationSeconds: 1, startedAt: day, endedAt: day)
        let source = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
        var first = saved(source)
        first.insights = [.init(section: .followUps, text: "Verify dispatch", sources: ["H1"], taskID: "one"),
                          .init(section: .followUps, text: "Check the dispatcher", sources: ["H1"], taskID: "two")]
        let store = try TimeTurnerRecapStore(databaseURL: db)
        try store.save(first)
        try store.setTodo("two", completed: true)
        try store.snoozeTodo("one", interval: 43200, now: day)
        let context = try store.todos(root: nil, databaseURL: db).map { TimeTurnerTaskContext(id: $0.id, title: $0.title, completed: $0.completed) }
        let updated = SavedTimeTurnerRecap(version: 1, dayStart: first.dayStart, dayEnd: first.dayEnd, timeZone: "UTC",
            generatedAt: day.addingTimeInterval(60), provider: "test", model: "test", insights: [
                .init(section: .followUps, text: "Confirm CI dispatch", sources: ["H1"], action: "Verify CI dispatch", taskID: "one", duplicateTaskIDs: ["two"])
            ], sources: first.sources, inputFingerprint: "updated")
        try TimeTurnerRetention.save(updated, root: nil, databaseURL: db, taskContext: context)
        let items = try store.todos(root: nil, databaseURL: db)
        #expect(items.count == 1)
        #expect(items.first?.id == "one" && items.first?.completed == true)
        #expect(items.first?.createdAt == day && items.first?.remindAt == nil)
        #expect(try store.versions(dayStart: first.dayStart, dayEnd: first.dayEnd, timeZone: "UTC").count == 2)
        // Concurrent user changes cannot be overwritten by a stale model decision.
        #expect(throws: (any Error).self) {
            try TimeTurnerRetention.save(updated, root: nil, databaseURL: db, taskContext: context)
        }
        try sources.deleteDictation(id: id)
        #expect(try store.todos(root: nil, databaseURL: db).isEmpty)
        #expect(try store.versions(dayStart: first.dayStart, dayEnd: first.dayEnd, timeZone: "UTC").isEmpty)
    }

    @Test func concurrentCompletionAndDeletionPreserveRecapAndUserState() throws {
        let (root, db, rows) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try rows.insertDictation(text: "Synthetic task evidence", durationSeconds: 1, startedAt: day, endedAt: day)
        let source = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
        var recap = saved(source)
        recap.insights = [.init(section: .followUps, text: "Review", sources: ["H1"], taskID: "review"),
                          .init(section: .followUps, text: "Send", sources: ["H1"], taskID: "send")]
        let store = try TimeTurnerRecapStore(databaseURL: db)
        try store.save(recap)
        let context = try store.taskContext(root: nil, databaseURL: db)
        try store.setTodo("send", completed: true)
        try store.deleteTodo("review")
        try TimeTurnerRetention.save(recap, root: nil, databaseURL: db, taskContext: context)
        let todos = try store.todos(root: nil, databaseURL: db)
        #expect(todos.count == 1 && todos.first?.id == "send" && todos.first?.completed == true)
        let current = try store.taskContext(root: nil, databaseURL: db)
        #expect(current.count == 2 && current.allSatisfy(\.completed))
        // A newly added task requires model reconciliation again, not a heuristic merge.
        recap.insights.append(.init(section: .followUps, text: "New task", sources: ["H1"], taskID: "new"))
        try store.save(recap)
        #expect(throws: TimeTurnerRecapError.self) {
            try TimeTurnerRetention.save(recap, root: nil, databaseURL: db, taskContext: context)
        }
    }

    @MainActor @Test func invalidArchivedFallbackIsRemovedByItsOwnKey() async throws {
        let (root, db, rows) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try rows.insertDictation(text: "Synthetic", durationSeconds: 1, startedAt: day, endedAt: day)
        let history = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: day)
        var recap = SavedTimeTurnerRecap(version: 1, dayStart: start, dayEnd: start.addingTimeInterval(86400),
            timeZone: "GMT", generatedAt: day, provider: "test", model: "test", insights: [], sources: [
                .init(id: "H1", title: "Missing screenshot", date: day, excerpt: "Synthetic", capture:
                    VisualMemoryItem(kind: .moment, capturedAt: day, source: "Test", text: history.text, path: "missing.png"), meeting: nil)
            ])
        recap.storageKey = recap.dayKey + "|version|archive"
        let store = try TimeTurnerRecapStore(databaseURL: db)
        try store.save(recap)
        let memory = try VisualMemoryStore(root: root.appendingPathComponent("visual"))
        let model = TimeTurnerRecapModel()
        await model.load(day: day, root: memory.root, databaseURL: db, calendar: calendar)
        #expect(model.error != nil)
        #expect(try store.load(key: recap.key) == nil)
    }

    @Test func featureModelSelectionDoesNotChangeMeetingOrComputerUseDefaults() throws {
        var config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.recapModelSelection == nil)
        #expect(config.timeTurnerGenerationConfig.meetingSummaryBackend == config.meetingSummaryBackend)
        let originalBackend = config.meetingSummaryBackend
        let originalComputerUse = config.computerUseReasoningEffort
        for provider in MeetingSummaryBackendOption.all {
            let originalModel = config[keyPath: provider.modelKeyPath]
            config.recapModelSelection = .init(backend: provider.backend, model: "independent-test-model")
            let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            let request = restored.timeTurnerGenerationConfig
            #expect(request.meetingSummaryBackend == provider.backend)
            #expect(MeetingTextGenerationClient.model(request) == "independent-test-model")
            #expect(restored.meetingSummaryBackend == originalBackend)
            #expect(restored[keyPath: provider.modelKeyPath] == originalModel)
            #expect(restored.computerUseReasoningEffort == originalComputerUse)
        }
    }

    @Test func recapScheduleUsesLocalTimeAndPreviousCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var config = AppConfig()
        config.timeTurnerEnabled = true
        let morning = try #require(calendar.date(from: .init(year: 2026, month: 3, day: 9, hour: 8)))
        #expect(TimeTurnerDailySchedule(config: config, now: morning, calendar: calendar) == nil)
        config.recapSchedule = "previous"
        #expect(TimeTurnerDailySchedule(config: config, now: morning.addingTimeInterval(-1), calendar: calendar) == nil)
        let due = try #require(TimeTurnerDailySchedule(config: config, now: morning, calendar: calendar))
        #expect(calendar.component(.day, from: due.target) == 8)
        #expect(calendar.component(.hour, from: due.target) == 0)
        #expect(TimeTurnerDailySchedule(config: config, now: morning.addingTimeInterval(3600), calendar: calendar)?.slot == due.slot)
        config.recapSchedule = "today"; config.recapScheduleHour = "18"
        let evening = morning.addingTimeInterval(10 * 3600)
        #expect(TimeTurnerDailySchedule(config: config, now: evening, calendar: calendar)?.target == calendar.startOfDay(for: morning))
        config.timeTurnerEnabled = false
        #expect(TimeTurnerDailySchedule(config: config, now: evening, calendar: calendar) == nil)
    }

    @Test func scheduledRecapFailuresRetryWithBackoffAcrossRestart() throws {
        var attempt = TimeTurnerDailyAttempt()
        let first = try #require({ attempt.begin(slot: "day-one", now: day) }())
        #expect({ attempt.begin(slot: "day-one", now: day.addingTimeInterval(60)) }() == nil)
        attempt.finish(token: first, succeeded: false, now: day)
        attempt = try JSONDecoder().decode(TimeTurnerDailyAttempt.self, from: JSONEncoder().encode(attempt))
        #expect(!attempt.completed)
        #expect({ attempt.begin(slot: "day-one", now: day.addingTimeInterval(299)) }() == nil)
        let second = try #require({ attempt.begin(slot: "day-one", now: day.addingTimeInterval(300)) }())
        attempt.finish(token: second, succeeded: true, now: day.addingTimeInterval(301))
        #expect(attempt.completed)
        #expect({ attempt.begin(slot: "day-one", now: day.addingTimeInterval(3600)) }() == nil)
        #expect({ attempt.begin(slot: "day-two", now: day.addingTimeInterval(86400)) }() != nil)
        // A cancelled older run cannot consume a newer slot's lease.
        attempt.finish(token: first, succeeded: true, now: day)
        #expect(attempt.slot == "day-two" && !attempt.completed)
    }

    @Test func abandonedScheduledRecapLeaseExpiresAndRetriesAreBounded() throws {
        var attempt = TimeTurnerDailyAttempt()
        _ = try #require({ attempt.begin(slot: "day", now: day) }())
        attempt = try JSONDecoder().decode(TimeTurnerDailyAttempt.self, from: JSONEncoder().encode(attempt))
        #expect({ attempt.begin(slot: "day", now: day.addingTimeInterval(899)) }() == nil)
        _ = try #require({ attempt.begin(slot: "day", now: day.addingTimeInterval(900)) }())
        let third = try #require({ attempt.begin(slot: "day", now: day.addingTimeInterval(1800)) }())
        attempt.finish(token: third, succeeded: false, now: day.addingTimeInterval(1800))
        #expect({ attempt.begin(slot: "day", now: day.addingTimeInterval(7200)) }() == nil)
        #expect(!attempt.completed)
    }

    @MainActor @Test func manualRecapRecoversScheduledDeliveryAfterRetryExhaustion() async throws {
        let (root, db, rows) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try rows.insertDictation(text: "Synthetic recap evidence", durationSeconds: 1, startedAt: day, endedAt: day)
        let source = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
        var attempt = TimeTurnerDailyAttempt()
        for offset in [0.0, 300.0, 900.0] {
            let token = try #require({ attempt.begin(slot: "today", now: day.addingTimeInterval(offset)) }())
            attempt.finish(token: token, succeeded: false, now: day.addingTimeInterval(offset))
        }
        #expect(!{ attempt.acceptPersisted(slot: "today", generatedAt: day.addingTimeInterval(-1)) }())
        let seed = saved(source)
        let recap = SavedTimeTurnerRecap(version: 1, dayStart: seed.dayStart, dayEnd: seed.dayEnd, timeZone: seed.timeZone,
            generatedAt: day.addingTimeInterval(1200), provider: seed.provider, model: seed.model, insights: seed.insights, sources: seed.sources)
        try TimeTurnerRecapStore(databaseURL: db).save(recap)
        let model = TimeTurnerRecapModel()
        await model.load(day: recap.dayStart, selection: TimeTurnerRecapSelection(recap), root: root, databaseURL: db)
        let generatedAt = try #require(model.generatedAt)
        #expect(model.savedKey == recap.key)
        #expect({ attempt.acceptPersisted(slot: "today", generatedAt: generatedAt) }())
        #expect(attempt.completed && attempt.attempts == 3)
        #expect({ attempt.begin(slot: "today", now: day.addingTimeInterval(7200)) }() == nil)
    }

    @Test func latestMeetingRequestSpansDaysAndHonorsSelection() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var ids: [Int64] = []
        for index in 1...4 {
            let start = day.addingTimeInterval(Double(index) * 86400)
            ids.append(try store.insertMeeting(title: "Meeting \(index)", calendarEventID: nil, startTime: start,
                endTime: start.addingTimeInterval(120), rawTranscript: "Follow up on item \(index).", formattedNotes: "",
                micAudioPath: nil, systemAudioPath: nil))
        }
        let reader = MeetingChatStore(databaseURL: db, readOnly: true)
        func newest(_ scope: MeetingChatScope) throws -> [Int64] {
            try reader.discoverMeetings(in: scope, title: "", limit: 3, asOf: day.addingTimeInterval(10 * 86400)).passages.map(\.meetingID)
        }
        #expect(try newest(.init()) == Array(ids.suffix(3).reversed()))
        #expect(try newest(.init(selection: .meetings([ids[0], ids[2]]))) == [ids[2], ids[0]])
        #expect(try newest(.init(selection: .meetings([]))).isEmpty)
    }

    @Test func preferencesPersistWithCompatibleDefaults() throws {
        var config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(TimeTurnerRecapInput.selected(config) == [.meetings])
        for kind in TimeTurnerRecapInput.allCases { config[keyPath: kind.configKey].toggle() }
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(TimeTurnerRecapInput.selected(decoded) == [.dictations, .commands, .quill, .cotypist, .chat])
    }
    @Test func packetHonorsOptInAndAlwaysIncludesScreenEvidence() throws {
        var config = AppConfig(); config.recapIncludeMeetings = false
        let capture = VisualMemoryItem(id: "screen", kind: .moment, capturedAt: day, source: "Editor",
            bundleID: "test.editor", text: "Screen evidence", path: "screen.png")
        let history = TimeTurnerRecapHistorySource(kind: .dictations, id: "1", parentID: "1", date: day,
            title: "Notes", text: "Dictation evidence", revision: "v1")
        func packet() throws -> TimeTurnerRecapPacket {
            try TimeTurnerRecap.packet(captures: [capture], passages: [], history: [history],
                interval: .init(start: day, duration: 86400), config: config)
        }
        #expect(try packet().sources.map(\.id) == ["C1"])
        config.recapIncludeDictations = true
        #expect(try packet().sources.map(\.id) == ["C1", "H-dictations-1"])
    }
    @Test func samplesUseHalfOpenTimeRangeAndSeparateCommands() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for offset in [-1.0, 10, 86400] {
            _ = try store.insertDictation(text: "text \(offset)", durationSeconds: 1,
                startedAt: day.addingTimeInterval(offset), endedAt: day.addingTimeInterval(offset))
        }
        _ = try store.insertDictation(text: "Open Notes", durationSeconds: 1, source: "cua", startedAt: day, endedAt: day)
        _ = try store.insertDictation(text: "text from legacy Quill", durationSeconds: 1, source: "quil", startedAt: day, endedAt: day)
        let reader = try TimeTurnerRecapHistory(databaseURL: db)
        let interval = DateInterval(start: day, duration: 86400)
        #expect(try reader.samples(kind: .dictations, interval: interval).map(\.text) == ["text 10.0"])
        #expect(try reader.samples(kind: .commands, interval: interval).map(\.text) == ["Open Notes"])
    }
    @Test func searchingDictationsRespectsTheSelectedDayAndClass() throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let interval = DateInterval(start: day, duration: 3600)
        _ = try store.insertDictation(text: "Orchid decision", durationSeconds: 1, startedAt: day, endedAt: day)
        _ = try store.insertDictation(text: "Orchid outside day", durationSeconds: 1, startedAt: interval.end, endedAt: interval.end)
        _ = try store.insertDictation(text: "Orchid command", durationSeconds: 1, source: "cua", startedAt: day, endedAt: day)
        var config = AppConfig()
        config.recapIncludeDictations = true
        config.recapIncludeCommands = false
        let search = TimeTurnerRecapSearch(access: .init(databaseURL: db, screenRoot: nil), interval: interval, config: config, meetingScope: nil)
        let hits = try search.results(for: search.parse(#"{"kind":"dictation","query":"Orchid"}"#))
        #expect(hits.map(\.excerpt) == ["Orchid decision"])
        #expect(throws: MeetingChatHarnessError.self) { try search.results(for: .init(kind: .command, phrase: "Orchid")) }
    }

    @Test func deletionInvalidatesRecapAndCannotRepublishStaleEvidence() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = try store.insertDictation(text: "Release plan", durationSeconds: 1, startedAt: day, endedAt: day)
        let reader = try TimeTurnerRecapHistory(databaseURL: db)
        let source = try #require(try reader.read(kind: .dictations, id: String(id)))
        let recap = saved(source)
        try TimeTurnerRetention.save(recap, root: nil, databaseURL: db)
        let reopened = try #require(try TimeTurnerRecapStore(databaseURL: db).load(key: recap.key))
        #expect(reopened.includedInputs == [.dictations])
        try store.deleteDictation(id: id)
        #expect(try TimeTurnerRecapStore(databaseURL: db).load(key: recap.key) == nil)
        #expect(throws: (any Error).self) { try TimeTurnerRetention.save(recap, root: nil, databaseURL: db) }
    }
    @Test func quillUsesTurnTimeAndEditInvalidatesRecap() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), old = UUID(), current = UUID()
        for (id, date) in [(old, day.addingTimeInterval(-86400)), (current, day)] {
            try store.appendQuillTurn(sessionID: session, turn: .init(id: id, question: "Question", answer: "Answer",
                timestamp: date.ISO8601Format(), backend: "test", model: "test"))
        }
        let reader = try TimeTurnerRecapHistory(databaseURL: db)
        let samples = try reader.samples(kind: .quill, interval: .init(start: day, duration: 86400))
        #expect(samples.map(\.id) == [current.uuidString])
        let recap = saved(try #require(samples.first))
        try TimeTurnerRetention.save(recap, root: nil, databaseURL: db)
        try store.updateQuillQuestion(turnID: current, question: "Revised")
        #expect(try TimeTurnerRecapStore(databaseURL: db).load(key: recap.key) == nil)
        #expect(try !reader.areCurrent(samples))
    }
    @Test func savedChatReadsCompletedAnswersAndDeletesDerivedRecap() throws {
        let (root, db, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let chats = MeetingChatStore(databaseURL: db)
        let session = try chats.createSession(scope: .init(), title: "Planning")
        let turn = try chats.beginTurn(sessionID: session.id, question: "What next?", scope: .init(), provider: "test", model: "test")
        #expect(try chats.finishTurn(turnID: turn.id, answer: "Review tests", citations: [], dependencies: []))
        let reader = try TimeTurnerRecapHistory(databaseURL: db)
        let source = try #require(try reader.read(kind: .chat, id: session.id.uuidString))
        #expect(source.text.contains("Review tests"))
        let recap = saved(source)
        try TimeTurnerRetention.save(recap, root: nil, databaseURL: db)
        try chats.deleteSession(id: session.id)
        #expect(try TimeTurnerRecapStore(databaseURL: db).load(key: recap.key) == nil)
    }
    @Test func cotypistIncludesOnlyAcceptedTextAndHonorsDeletion() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        func event(_ accepted: String, offset: Double) -> CotypistSuggestionEvent {
            .init(date: day.addingTimeInterval(offset), appBundleID: "test.notes", appName: "Notes", trigger: "boundary",
                suggestionText: "Full proposed sentence", acceptedText: accepted, contextBefore: "Private context",
                outcome: accepted.isEmpty ? .ignored : .partial, firstWordLogProb: nil,
                firstMs: 1, fullMs: 2, contextSource: "field", model: "test")
        }
        let session = try #require(try store.recordCotypistSuggestion(event("Full", offset: 0)))
        _ = try store.recordCotypistSuggestion(event("", offset: 5))
        let reader = try TimeTurnerRecapHistory(databaseURL: db)
        let samples = try reader.samples(kind: .cotypist, interval: .init(start: day, duration: 86400))
        #expect(samples.map(\.text) == ["Full"])
        let recap = saved(try #require(samples.first))
        try TimeTurnerRetention.save(recap, root: nil, databaseURL: db)
        try store.deleteCotypistSession(id: session)
        #expect(try TimeTurnerRecapStore(databaseURL: db).load(key: recap.key) == nil)
    }
    @Test func replacingRecapReplacesItsDependencyProjection() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.insertDictation(text: "First", durationSeconds: 1, startedAt: day, endedAt: day)
        let second = try store.insertDictation(text: "Second", durationSeconds: 1, startedAt: day, endedAt: day)
        let reader = try TimeTurnerRecapHistory(databaseURL: db)
        let old = saved(try #require(try reader.read(kind: .dictations, id: String(first))))
        let new = saved(try #require(try reader.read(kind: .dictations, id: String(second))))
        try TimeTurnerRetention.save(old, root: nil, databaseURL: db)
        try TimeTurnerRetention.save(new, root: nil, databaseURL: db)
        try store.deleteDictation(id: first)
        #expect(try TimeTurnerRecapStore(databaseURL: db).load(key: new.key) != nil)
        try store.deleteDictation(id: second)
        #expect(try TimeTurnerRecapStore(databaseURL: db).load(key: new.key) == nil)
    }
    @Test func originalTextRevisionCoversTruncatedTail() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), turn = UUID()
        let original = String(repeating: "x", count: 17000)
        try store.appendQuillTurn(sessionID: session, turn: .init(id: turn, question: original,
            answer: "Answer", timestamp: day.ISO8601Format(), backend: "test", model: "test"))
        let reader = try TimeTurnerRecapHistory(databaseURL: db)
        let before = try #require(try reader.read(kind: .quill, id: turn.uuidString))
        #expect(before.text.utf8.count == 16000)
        #expect(before.textIsTruncated)
        try store.updateQuillQuestion(turnID: turn, question: original + " changed")
        let after = try #require(try reader.read(kind: .quill, id: turn.uuidString))
        #expect(before.text == after.text)
        #expect(before.revision != after.revision)
    }
    @Test func legacyRecapBodiesStillDecode() throws {
        let source = TimeTurnerRecapSource(id: "C1", title: "Editor", date: day, excerpt: "text", capture: nil, meeting: nil)
        let recap = SavedTimeTurnerRecap(version: 1, dayStart: day, dayEnd: day.addingTimeInterval(86400),
            timeZone: "UTC", generatedAt: day, provider: "test", model: "test", insights: [], sources: [source])
        let data = try JSONEncoder().encode(recap)
        #expect(!String(decoding: data, as: UTF8.self).contains("includedInputs"))
        let decoded = try JSONDecoder().decode(SavedTimeTurnerRecap.self, from: data)
        #expect(decoded.includedInputs == nil)
        #expect(decoded.sources.first?.history == nil)
    }
}

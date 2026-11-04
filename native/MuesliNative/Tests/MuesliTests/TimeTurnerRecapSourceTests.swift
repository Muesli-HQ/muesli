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

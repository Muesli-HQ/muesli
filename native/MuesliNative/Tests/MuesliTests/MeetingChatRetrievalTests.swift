import Foundation
import Testing
@testable import MuesliCore
import SQLite3


@Suite("Meeting chat retrieval")
struct MeetingChatRetrievalTests {
    private func database() throws -> DictationStore {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("retrieval-\(UUID()).db"))
        try store.migrateIfNeeded(); return store
    }
    private func insert(_ store: DictationStore, text: String, date: Date = Date()) throws -> Int64 {
        try store.insertMeeting(title: "Planning", calendarEventID: nil, startTime: date, endTime: date.addingTimeInterval(60),
            rawTranscript: text, formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
    }

    @Test func findsMeetingBeyondBrowserWindow() throws {
        let store = try database()
        let oldest = try insert(store, text: "[00:00:05] You: The launch codeword is sunflower.")
        for _ in 0..<204 { _ = try insert(store, text: "[00:00:03] Others: Routine check-in.") }
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "sunflower", scope: .init())
        #expect(evidence.coverage.eligibleMeetingCount == 205)
        #expect(evidence.passages.contains { $0.meetingID == oldest })
    }

    @Test func directFolderExcludesDescendants() throws {
        let store = try database()
        let parent = try store.createFolder(name: "Parent")
        let child = try store.createFolder(name: "Child", parentID: parent)
        let first = try insert(store, text: "launch Friday")
        let second = try insert(store, text: "launch Monday")
        try store.moveMeeting(id: first, toFolder: parent)
        try store.moveMeeting(id: second, toFolder: child)
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "launch", scope: .init(selection: .folder(parent)))
        #expect(evidence.passages.map(\.meetingID) == [first])
    }

    @Test func fallbackEscapesWildcardsAndQuotes() throws {
        let store = try database()
        _ = try insert(store, text: "ordinary meeting")
        let target = try insert(store, text: "We agreed to 50% off.")
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL, useFTS: false).retrieve(question: "%", scope: .init())
        #expect(evidence.passages.map(\.meetingID) == [target])
        #expect(try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL, useFTS: false).retrieve(question: "\"missing\"", scope: .init()).passages.isEmpty)
    }

    @Test func unicodeExcerptOffsetsRemainExact() throws {
        let store = try database()
        let text = "[00:00:01] You: नमस्ते 🌻\n[00:00:09] Others: Friday launch."
        _ = try insert(store, text: text)
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "Friday", scope: .init())
        let passage = try #require(evidence.passages.first)
        #expect((text as NSString).substring(with: passage.range.nsRange) == passage.excerpt)
        #expect(passage.timestamp == "00:00:09")
    }

    @Test func editedSourceReindexesWithoutTimestampChange() throws {
        let store = try database(); let id = try insert(store, text: "original launch")
        let retrieval = MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL)
        #expect(try retrieval.retrieve(question: "original", scope: .init()).passages.count == 1)
        try store.updateMeetingTranscript(id: id, rawTranscript: "replacement launch")
        #expect(try retrieval.retrieve(question: "original", scope: .init()).passages.isEmpty)
        #expect(try retrieval.retrieve(question: "replacement", scope: .init()).passages.count == 1)
        try store.deleteMeeting(id: id)
        #expect(try retrieval.retrieve(question: "replacement", scope: .init()).passages.isEmpty)
    }

    @Test func broadRecapReportsPartialCoverage() throws {
        let store = try database()
        for _ in 0..<20 { _ = try insert(store, text: String(repeating: "launch discussion ", count: 100)) }
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "recap", scope: .init(), broadRecap: true)
        #expect(evidence.coverage.isPartialRecap)
        #expect(evidence.coverage.evidenceMeetingCount < 20)
        #expect(evidence.passages.reduce(0) { $0 + $1.excerpt.utf8.count } <= 12_000)
    }

    @Test func longUnbrokenTextFitsEvidenceBudget() throws {
        let store = try database(); let text = String(repeating: "🌻", count: 8_000)
        _ = try insert(store, text: text)
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "recap", scope: .init(), broadRecap: true)
        #expect(!evidence.passages.isEmpty)
        #expect(evidence.passages.reduce(0) { $0 + $1.excerpt.utf8.count } <= 12_000)
        for passage in evidence.passages { #expect((text as NSString).substring(with: passage.range.nsRange) == passage.excerpt) }
        #expect(evidence.coverage.isPartialRecap)
    }

    @Test func localDatesHandleDSTBoundaries() throws {
        let store = try database()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let selected = try insert(store, text: "launch selected", date: start)
        _ = try insert(store, text: "launch next day", date: end)
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "launch", scope: .init(startDate: start, endDateExclusive: end))
        #expect(evidence.passages.map(\.meetingID) == [selected])
    }

    @Test func keepsRelevanceAheadOfRecency() throws {
        let store = try database()
        let target = try insert(store, text: "sunflower pricing contract", date: Date(timeIntervalSince1970: 1_000))
        _ = try insert(store, text: "pricing check-in", date: Date())
        let evidence = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).retrieve(question: "sunflower pricing", scope: .init())
        #expect(evidence.passages.first?.meetingID == target)
    }

    @Test func completeSmallRecapAndHistoryWipeEraseFTS() throws {
        let store = try database()
        _ = try insert(store, text: "first launch decision")
        _ = try insert(store, text: "second launch decision")
        let retrieval = MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL)
        let evidence = try retrieval.retrieve(question: "recap", scope: .init(), broadRecap: true)
        #expect(!evidence.coverage.isPartialRecap)
        #expect(evidence.coverage.evidenceMeetingCount == 2)
        try store.clearMeetings()
        let indexed = try store.withChatDatabase { db in
            try MeetingChatSQL.rows("SELECT COUNT(*) FROM meeting_chat_fts", db: db) { sqlite3_column_int64($0, 0) }.first
        }
        #expect(indexed == 0)
    }
}

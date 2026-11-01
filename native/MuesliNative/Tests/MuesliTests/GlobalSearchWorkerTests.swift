import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Global search source validation")
struct GlobalSearchWorkerTests {
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

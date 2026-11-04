import Foundation
import Testing
import SQLite3
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Content privacy")
struct ContentPrivacyTests {
    @Test func sessionRemainsEphemeralAfterSwitchingOff() throws {
        let policy = ContentPrivacy()
        let old = policy.capture()
        #expect(policy.permits(old))
        policy.setEnabled(true)
        let privateSession = policy.capture()
        #expect(!policy.permits(old))
        policy.setEnabled(false)
        #expect(!policy.permits(old))
        #expect(!policy.permits(privateSession))
        #expect(policy.permits(policy.capture()))
        #expect(!policy.mayLogContent)
    }
    @Test func admittedWritesDoNotSerializeRecordingBehindBackgroundWork() throws {
        let policy = ContentPrivacy()
        try policy.beginWrite()
        let second = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do { try policy.beginWrite(); policy.endWrite(); second.signal() }
            catch { Issue.record("Unexpected admission failure") }
        }
        #expect(second.wait(timeout: .now() + 1) == .success)
        policy.endWrite()
    }
    @Test func enablingRevokesImmediatelyAndDrainsOffCaller() throws {
        let policy = ContentPrivacy()
        let session = policy.capture()
        try policy.beginWrite(session)
        let enabled = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            policy.setEnabled(true)
            enabled.signal()
            policy.waitForAdmittedWrites()
            drained.signal()
        }
        #expect(enabled.wait(timeout: .now() + 1) == .success)
        #expect(!policy.permits(session))
        #expect(drained.wait(timeout: .now()) == .timedOut)
        policy.endWrite()
        #expect(drained.wait(timeout: .now() + 1) == .success)
        policy.setEnabled(false)
        #expect(throws: ContentPrivacy.Failure.self) { try policy.beginWrite(session) }
    }
    private func fixture() throws -> (URL, DictationStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = DictationStore(databaseURL: folder.appendingPathComponent("fixture.db"))
        try store.migrateIfNeeded()
        return (folder, store)
    }
    @Test func privateDictationDoesNotCreateHistoryOrTriggerWordAnalytics() throws {
        let (folder, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = ContentPrivacy(enabled: true).capture()
        store.onLocalDictationWords = { _, _ in Issue.record("Private words reached analytics") }
        try ContentPrivacy.$session.withValue(token) {
            #expect(throws: ContentPrivacy.Failure.self) {
                try store.insertDictation(text: "synthetic private words", durationSeconds: 1, startedAt: Date(), endedAt: Date())
            }
            #expect(throws: ContentPrivacy.Failure.self) {
                try store.insertDictation(text: "synthetic command", durationSeconds: 1, source: "cua", startedAt: Date(), endedAt: Date())
            }
        }
        #expect(try store.dictationStats().totalWords == 0)
    }
    @Test func meetingsRemainDurableDuringPrivateSession() throws {
        let (folder, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try ContentPrivacy.$session.withValue(ContentPrivacy(enabled: true).capture()) {
            try store.insertMeeting(title: "Synthetic meeting", calendarEventID: nil,
                startTime: Date(), endTime: Date(), rawTranscript: "Synthetic transcript",
                formattedNotes: "Synthetic notes", micAudioPath: "synthetic.wav", systemAudioPath: nil)
        }
        #expect(try store.meeting(id: id)?.rawTranscript == "Synthetic transcript")
    }
    @Test func privateChatAndRetrievalUseMemoryAndKeepMeetingSourcesCurrent() throws {
        let (folder, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = try store.insertMeeting(title: "Synthetic meeting", calendarEventID: nil,
            startTime: Date(), endTime: Date(), rawTranscript: "Ship the synthetic feature Friday.",
            formattedNotes: "Friday", micAudioPath: nil, systemAudioPath: nil)
        let token = ContentPrivacy(enabled: true).capture()
        let chat = ContentPrivacy.$session.withValue(token) { MeetingChatStore(databaseURL: store.resolvedDatabaseURL) }
        let retrieval = ContentPrivacy.$session.withValue(token) { MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL) }
        let scope = MeetingChatScope(selection: .meetings([meeting]))
        let session = try chat.createSession(scope: scope, title: "Private test")
        let turn = try chat.beginTurn(sessionID: session.id, question: "When is the feature shipping?", scope: scope, provider: "test", model: "test")
        let evidence = try retrieval.retrieve(question: "Friday", scope: scope)
        #expect(!evidence.passages.isEmpty)
        #expect(try chat.finishTurn(turnID: turn.id, answer: "Friday", citations: [], dependencies: evidence.dependencies))
        #expect(try chat.turns(sessionID: session.id).first?.originalAnswer == "Friday")
        let durable = MeetingChatStore(databaseURL: store.resolvedDatabaseURL, readOnly: true)
        #expect(try durable.sessions().isEmpty)
        #expect(try durable.hasChatHistory() == false)
        try store.deleteMeeting(id: meeting)
        #expect(try chat.turns(sessionID: session.id).first?.originalAnswer == nil)
        #expect(try retrieval.retrieve(question: "Friday", scope: scope).passages.isEmpty)
    }
    @Test func privateIndexOnlyRebuildsEditedMeetings() throws {
        let (folder, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        func addMeeting(_ title: String) throws -> Int64 {
            try store.insertMeeting(title: title, calendarEventID: nil,
                startTime: Date(), endTime: Date(), rawTranscript: "Synthetic excerpt for indexing.",
                formattedNotes: "", micAudioPath: nil, systemAudioPath: nil)
        }
        let edited = try addMeeting("First")
        _ = try addMeeting("Second")
        let retrieval = ContentPrivacy.$session.withValue(ContentPrivacy(enabled: true).capture()) {
            MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL)
        }
        #expect(try retrieval.prepareIndex().reindexedMeetingCount == 2)
        try store.updateMeetingTranscript(id: edited, rawTranscript: "First edit.")
        #expect(try retrieval.prepareIndex().reindexedMeetingCount == 1)
        try store.updateMeetingTranscript(id: edited, rawTranscript: "Second edit.")
        _ = try MeetingChatRetrieval(databaseURL: store.resolvedDatabaseURL).prepareIndex()
        #expect(try retrieval.prepareIndex().reindexedMeetingCount == 1)
    }
    @Test func privateFailuresCannotCreateRecoveryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("synthetic.wav")
        try Data(repeating: 0, count: 100).write(to: wav)
        let recovery = directory.appendingPathComponent("recovery")
        let token = ContentPrivacy(enabled: true).capture()
        try ContentPrivacy.$session.withValue(token) {
            #expect(throws: ContentPrivacy.Failure.self) {
                try DictationRecoveryStore(directory: recovery).save(wavURL: wav, startedAt: Date(), durationSeconds: 1, modelName: "test", failureMessage: "Synthetic failure")
            }
            #expect(throws: ContentPrivacy.Failure.self) {
                try BufferedDictationRecovery.saveTranscript("Synthetic private text", beside: wav)
            }
            let audio = QuilRecordedAudio(url: wav)
            #expect(throws: ContentPrivacy.Failure.self) { try audio.copyForRecovery(to: recovery) }
        }
        #expect(!FileManager.default.fileExists(atPath: recovery.path))
        #expect(!FileManager.default.fileExists(atPath: wav.path))
    }
    @Test func privateQuillAndTraceWritesAreRefused() throws {
        let (folder, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = ContentPrivacy(enabled: true).capture()
        try ContentPrivacy.$session.withValue(token) {
            #expect(throws: ContentPrivacy.Failure.self) {
                try store.appendQuillTurn(sessionID: UUID(), turn: .init(id: UUID(), question: "Synthetic question", answer: "Synthetic answer", timestamp: "2026-11-04T12:00:00Z", backend: "test", model: "test"))
            }
            #expect(throws: ContentPrivacy.Failure.self) {
                try store.insertComputerUseTrace(dictationID: 1, finalStatus: "done", finalMessage: "Synthetic trace", events: [])
            }
            #expect(throws: ContentPrivacy.Failure.self) {
                try store.insertRecoveredDictation(recoveryID: UUID(), text: "Synthetic recovery", durationSeconds: 1, startedAt: Date(), endedAt: Date())
            }
        }
    }
}

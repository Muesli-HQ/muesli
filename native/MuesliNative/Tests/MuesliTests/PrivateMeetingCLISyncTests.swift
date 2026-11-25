import Foundation
import Testing
import MuesliCore
@testable import MuesliCLI
@testable import MuesliNativeApp

@Suite("Private meetings in the CLI and iCloud sync", .serialized)
struct PrivateMeetingCLISyncTests {

    private func makeStore() throws -> DictationStore {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("private-cli-\(UUID()).db"))
        try store.migrateIfNeeded()
        return store
    }

    @discardableResult
    private func completedMeeting(_ store: DictationStore, title: String = "Counsel call") throws -> Int64 {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let id = try store.createLiveMeeting(title: title, calendarEventID: nil, startTime: start)
        try store.completeLiveMeeting(
            id: id, title: title, calendarEventID: nil, startTime: start,
            endTime: start.addingTimeInterval(60), rawTranscript: "settlement terms discussed",
            formattedNotes: "## Summary\nSettlement", micAudioPath: "/tmp/mic.wav", systemAudioPath: "/tmp/system.wav"
        )
        return id
    }

    private func record(private isPrivate: Bool) -> MeetingRecord {
        MeetingRecord(
            id: 9, title: "Counsel call", startTime: "2026-03-22T10:00:00Z", durationSeconds: 60,
            rawTranscript: "settlement terms", formattedNotes: "## Summary\nSettlement", wordCount: 2, folderID: nil,
            micAudioPath: "/tmp/mic.wav", systemAudioPath: "/tmp/system.wav", manualNotes: "my private note",
            selectedTemplatePrompt: "prompt", visualContext: "on-screen text"
        )
    }

    // MARK: - CLI payloads (F20)

    @Test("a private meeting's detail payload carries no content")
    func detailRedactsContent() {
        let payload = MeetingDetailPayload(record(private: true), isPrivate: true)
        #expect(payload.isPrivate)
        #expect(payload.redacted)
        #expect(payload.rawTranscript.isEmpty)
        #expect(payload.formattedNotes.isEmpty)
        #expect(payload.manualNotes.isEmpty)
        #expect(payload.visualContext == nil)
        #expect(payload.micAudioPath == nil && payload.systemAudioPath == nil && payload.savedRecordingPath == nil)
        #expect(payload.selectedTemplatePrompt == nil)
        // Identification metadata stays so a user can still find the meeting.
        #expect(payload.id == 9)
        #expect(payload.startTime == "2026-03-22T10:00:00Z")
    }

    @Test("a private meeting's list row is flagged and carries no notes")
    func listRowRedacts() throws {
        let row = MeetingListRow(record(private: true), isPrivate: true)
        #expect(row.isPrivate)
        let text = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(!text.contains("my private note"))
    }

    @Test("a normal meeting is unchanged and not flagged")
    func normalMeetingUnchanged() {
        let payload = MeetingDetailPayload(record(private: false))
        #expect(payload.isPrivate == false)
        #expect(payload.redacted == false)
        #expect(payload.rawTranscript == "settlement terms")
        #expect(payload.manualNotes == "my private note")
        #expect(payload.micAudioPath == "/tmp/mic.wav")
        #expect(MeetingListRow(record(private: false)).isPrivate == false)
    }

    @Test("the encoded JSON of a private meeting never contains its text")
    func encodedJSONHasNoPrivateText() throws {
        let data = try JSONEncoder().encode(MeetingDetailPayload(record(private: true), isPrivate: true))
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["settlement", "Settlement", "my private note", "on-screen text", "/tmp/mic.wav", "prompt"] {
            #expect(!text.contains(secret), "leaked: \(secret)")
        }
    }

    @Test("the CLI privacy check fails closed when the lookup throws")
    func lookupFailureCountsAsPrivate() {
        let broken = DictationStore(databaseURL: URL(fileURLWithPath: "/nonexistent-dir/none.db"))
        #expect(CLIPrivacy.isPrivate(broken, id: 1) == true)
    }

    @Test("the CLI privacy check reads the store, including folder inheritance")
    func cliPrivacyReadsStore() throws {
        let store = try makeStore()
        let folder = try store.createFolder(name: "Legal")
        let id = try completedMeeting(store)
        #expect(CLIPrivacy.isPrivate(store, id: id) == false)
        try store.moveMeeting(id: id, toFolder: folder)
        try store.setFolderPrivate(id: folder, isPrivate: true)
        #expect(CLIPrivacy.isPrivate(store, id: id))
    }

    @Test("update-notes refuses a private meeting with an invalid_input error")
    func updateNotesRefused() throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        #expect(throws: CLIError.self) { try CLIPrivacy.requireNotPrivate(store, id: id) }
        try store.setMeetingPrivate(id: id, isPrivate: false)
        #expect(throws: Never.self) { try CLIPrivacy.requireNotPrivate(store, id: id) }
    }

    // MARK: - iCloud sync (F22)

    @Test("a private meeting is not offered to iCloud sync")
    func privateMeetingSkippedBySync() throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        #expect(try store.textRecordsNeedingSync().contains { $0.kind == .meeting })

        try store.setMeetingPrivate(id: id, isPrivate: true)
        #expect(try store.textRecordsNeedingSync().contains { $0.kind == .meeting } == false)
        #expect(try store.hasTextRecordsNeedingSync() == false)
    }

    @Test("a meeting private only through its folder is not offered to sync")
    func folderPrivateSkippedBySync() throws {
        let store = try makeStore()
        let root = try store.createFolder(name: "Legal")
        let child = try store.createFolder(name: "Cases", parentID: root)
        let id = try completedMeeting(store)
        try store.moveMeeting(id: id, toFolder: child)
        try store.setFolderPrivate(id: root, isPrivate: true)

        #expect(try store.textRecordsNeedingSync().contains { $0.kind == .meeting } == false)
    }

    @Test("clearing the mark lets the meeting sync again")
    func clearingMarkResumesSync() throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        #expect(try store.hasTextRecordsNeedingSync() == false)

        try store.setMeetingPrivate(id: id, isPrivate: false)
        #expect(try store.textRecordsNeedingSync().contains { $0.kind == .meeting })
    }

    @Test("a private meeting is excluded from the full sync migration export")
    func privateMeetingSkippedByMigrationExport() throws {
        let store = try makeStore()
        let normal = try completedMeeting(store, title: "Standup")
        let secret = try completedMeeting(store, title: "Counsel call")
        try store.setMeetingPrivate(id: secret, isPrivate: true)

        let exported = try store.textRecordsForSyncMigration(kind: .meeting)
        #expect(exported.contains { $0.title == "Standup" })
        #expect(exported.contains { $0.title == "Counsel call" } == false)
        _ = normal
    }

    @Test("deleting a private meeting still syncs the tombstone so a remote copy is removed")
    func deletedPrivateMeetingStillSyncsTombstone() throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        #expect(try store.hasTextRecordsNeedingSync() == false)

        try store.deleteMeeting(id: id)

        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        #expect(tombstone.isDeleted)
    }

    @Test("sync records for normal meetings are unaffected")
    func normalMeetingStillSyncs() throws {
        let store = try makeStore()
        try completedMeeting(store, title: "Standup")
        let record = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        #expect(record.title == "Standup")
    }
}

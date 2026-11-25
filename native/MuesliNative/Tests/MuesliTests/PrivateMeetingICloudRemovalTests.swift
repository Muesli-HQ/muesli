import CloudKit
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

private final class PendingState: MuesliCKSyncPendingState, @unchecked Sendable {
    private(set) var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]

    init(_ changes: [CKSyncEngine.PendingRecordZoneChange] = []) {
        pendingRecordZoneChanges = changes
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        for change in changes where !pendingRecordZoneChanges.contains(change) {
            pendingRecordZoneChanges.append(change)
        }
    }

    func remove(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        pendingRecordZoneChanges.removeAll { changes.contains($0) }
    }
}

/// Marking a meeting private must take its copy out of iCloud (F1 in the egress inventory).
/// Muesli removes a remote copy by uploading a tombstone, the same way a delete does.
@Suite("Private meetings leave iCloud", .serialized)
struct PrivateMeetingICloudRemovalTests {
    private static let secrets = ["settlement terms discussed", "Settlement", "Counsel call", "my private note"]

    private func makeStore() throws -> DictationStore {
        let store = DictationStore(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("private-icloud-\(UUID()).db"))
        try store.migrateIfNeeded()
        return store
    }

    private func completedMeeting(_ store: DictationStore, title: String = "Counsel call") throws -> Int64 {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        let id = try store.createLiveMeeting(title: title, calendarEventID: nil, startTime: start)
        try store.completeLiveMeeting(
            id: id, title: title, calendarEventID: nil, startTime: start,
            endTime: start.addingTimeInterval(60), rawTranscript: "settlement terms discussed",
            formattedNotes: "## Summary\nSettlement", micAudioPath: nil, systemAudioPath: nil
        )
        try store.updateMeetingManualNotes(id: id, manualNotes: "my private note")
        return id
    }

    /// Simulates a finished upload of whatever the outbox currently holds for this meeting.
    @discardableResult
    private func sync(_ store: DictationStore, title: String = "Counsel call") throws -> SyncTextRecord {
        let record = try #require(try store.textRecordsNeedingSync().first { $0.title == title })
        #expect(try store.markTextRecordSynced(
            kind: .meeting, recordName: record.id, changeTag: "tag-1",
            systemFields: Data([0x01]), recordUpdatedAt: record.updatedAt
        ))
        return record
    }

    private func pending(_ recordName: String) -> CKSyncEngine.PendingRecordZoneChange {
        .saveRecord(CKRecord.ID(recordName: recordName, zoneID: MuesliICloudSyncEngine.Schema.syncZoneID))
    }

    private func expectContentFreeTombstone(_ record: SyncTextRecord?, id: String) {
        guard let record else {
            Issue.record("no tombstone queued for \(id)")
            return
        }
        #expect(record.id == id)
        #expect(record.isDeleted)
        let fields = [record.title ?? "", record.text, record.summaryText ?? "", record.manualNotes ?? ""]
        for secret in Self.secrets {
            #expect(!fields.contains { $0.contains(secret) }, "leaked: \(secret)")
        }
    }

    private func expectLocalContentIntact(_ store: DictationStore, id: Int64) throws {
        let local = try #require(try store.meeting(id: id))
        #expect(local.rawTranscript == "settlement terms discussed")
        #expect(local.manualNotes == "my private note")
        #expect(local.title == "Counsel call")
    }

    // Row: marked private after synced -> delete (tombstone) queued.
    @Test("marking a synced meeting private queues a content-free tombstone and keeps the local copy")
    func privateAfterSyncQueuesTombstone() async throws {
        let store = try makeStore()
        let state = PendingState()
        let engine = MuesliCKSyncEngine(store: store)
        // Sign in while the store is empty, so the account needs no CloudKit verification.
        #expect(try await engine.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "local-only-owner"),
            state: state
        ))
        let id = try completedMeeting(store)
        let synced = try sync(store)
        #expect(try store.hasTextRecordsNeedingSync() == false)

        try store.setMeetingPrivate(id: id, isPrivate: true)

        #expect(try store.hasTextRecordsNeedingSync())
        let tombstone = try store.textRecordsNeedingSync().first { $0.id == synced.id }
        expectContentFreeTombstone(tombstone, id: synced.id)
        #expect((tombstone?.updatedAt ?? .distantPast) > synced.updatedAt)

        _ = try await engine.registerNextDirtyBatch(state: state)
        #expect(state.pendingRecordZoneChanges == [pending(synced.id)])
        let batch = await engine.makeRecordBatch(pendingChanges: state.pendingRecordZoneChanges)
        #expect(batch.recordsToSave.count == 1)
        #expect(batch.recordsToSave.first?["isDeleted"] as? Bool == true)
        for secret in Self.secrets {
            let values = batch.recordsToSave.first.map { r in r.allKeys().compactMap { r[$0] as? String } } ?? []
            #expect(!values.contains { $0.contains(secret) }, "leaked to CKRecord: \(secret)")
        }
        try expectLocalContentIntact(store, id: id)
    }

    // Row: marked private while queued -> not uploaded.
    @Test("a never-synced meeting queued before it was marked private is dropped, not uploaded")
    func queuedNeverSyncedPrivateIsDropped() async throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let record = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        try store.setMeetingPrivate(id: id, isPrivate: true)

        #expect(try store.textRecordsForSync(recordNames: [record.id]).isEmpty)
        let batch = await MuesliCKSyncEngine(store: store).makeRecordBatch(pendingChanges: [pending(record.id)])
        #expect(batch.recordsToSave.isEmpty)
        #expect(batch.staleChanges == [pending(record.id)])
    }

    @Test("a synced meeting queued before it was marked private uploads only a tombstone")
    func queuedSyncedPrivateUploadsTombstone() async throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let synced = try sync(store)
        try store.updateMeetingManualNotes(id: id, manualNotes: "my private note, edited")
        try store.setMeetingPrivate(id: id, isPrivate: true)

        expectContentFreeTombstone(try store.textRecordsForSync(recordNames: [synced.id])[synced.id], id: synced.id)
        let batch = await MuesliCKSyncEngine(store: store).makeRecordBatch(pendingChanges: [pending(synced.id)])
        #expect(batch.recordsToSave.count == 1)
        let text = batch.recordsToSave.first.map { r in r.allKeys().compactMap { r[$0] as? String } } ?? []
        #expect(!text.contains { $0.contains("my private note") })
    }

    @Test("an upload that lands after the meeting went private still leads to a tombstone")
    func inFlightUploadThenPrivate() throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let inFlight = try #require(try store.textRecordsNeedingSync().first { $0.kind == .meeting })
        try store.setMeetingPrivate(id: id, isPrivate: true)

        // The content save that was already in flight completes now.
        #expect(try store.markTextRecordSynced(
            kind: .meeting, recordName: inFlight.id, changeTag: "tag-1",
            systemFields: Data([0x01]), recordUpdatedAt: inFlight.updatedAt
        ) == false)

        expectContentFreeTombstone(try store.textRecordsNeedingSync().first { $0.id == inFlight.id }, id: inFlight.id)
    }

    // Row: folder marked private -> all its meetings deleted remotely.
    @Test("marking a folder private tombstones every synced meeting under it, subfolders included")
    func folderPrivateTombstonesSubtree() throws {
        let store = try makeStore()
        let root = try store.createFolder(name: "Legal")
        let child = try store.createFolder(name: "Cases", parentID: root)
        let a = try completedMeeting(store, title: "Counsel call")
        let b = try completedMeeting(store, title: "Counsel call 2")
        let outside = try completedMeeting(store, title: "Standup")
        try store.moveMeeting(id: a, toFolder: root)
        try store.moveMeeting(id: b, toFolder: child)
        let syncedA = try sync(store, title: "Counsel call")
        let syncedB = try sync(store, title: "Counsel call 2")
        try sync(store, title: "Standup")

        try store.setFolderPrivate(id: root, isPrivate: true)

        let dirty = try store.textRecordsNeedingSync()
        expectContentFreeTombstone(dirty.first { $0.id == syncedA.id }, id: syncedA.id)
        expectContentFreeTombstone(dirty.first { $0.id == syncedB.id }, id: syncedB.id)
        #expect(dirty.count == 2, "only the two meetings that became private are queued")
        try expectLocalContentIntact(store, id: a)
        _ = outside
    }

    // Row: meeting moved into private folder -> deleted.
    @Test("moving a synced meeting into a private folder queues a tombstone")
    func moveIntoPrivateFolder() throws {
        let store = try makeStore()
        let folder = try store.createFolder(name: "Legal")
        try store.setFolderPrivate(id: folder, isPrivate: true)
        let id = try completedMeeting(store)
        let synced = try sync(store)

        try store.moveMeeting(id: id, toFolder: folder)

        expectContentFreeTombstone(try store.textRecordsNeedingSync().first { $0.id == synced.id }, id: synced.id)
    }

    @Test("moving a folder under a private parent tombstones its synced meetings")
    func moveFolderUnderPrivateParent() throws {
        let store = try makeStore()
        let privateParent = try store.createFolder(name: "Legal")
        try store.setFolderPrivate(id: privateParent, isPrivate: true)
        let folder = try store.createFolder(name: "Cases")
        let id = try completedMeeting(store)
        try store.moveMeeting(id: id, toFolder: folder)
        let synced = try sync(store)

        try store.moveFolder(id: folder, toParent: privateParent)

        expectContentFreeTombstone(try store.textRecordsNeedingSync().first { $0.id == synced.id }, id: synced.id)
    }

    @Test("deleting a private folder re-queues the meetings it stops covering")
    func deletePrivateFolderRequeues() throws {
        let store = try makeStore()
        let folder = try store.createFolder(name: "Legal")
        let id = try completedMeeting(store)
        try store.moveMeeting(id: id, toFolder: folder)
        let synced = try sync(store)
        try store.setFolderPrivate(id: folder, isPrivate: true)
        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        _ = try store.markTextRecordSynced(
            kind: .meeting, recordName: tombstone.id, changeTag: "tag-2",
            systemFields: Data([0x02]), recordUpdatedAt: tombstone.updatedAt
        )

        try store.deleteFolder(id: folder)

        let revived = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        #expect(revived.isDeleted == false)
        #expect(revived.text == "settlement terms discussed")
    }

    // Row: un-private -> re-queued.
    @Test("clearing the mark re-queues the full meeting, newer than the tombstone")
    func unPrivateRequeues() throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let synced = try sync(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        #expect(try store.markTextRecordSynced(
            kind: .meeting, recordName: tombstone.id, changeTag: "tag-2",
            systemFields: Data([0x02]), recordUpdatedAt: tombstone.updatedAt
        ))
        #expect(try store.hasTextRecordsNeedingSync() == false)

        try store.setMeetingPrivate(id: id, isPrivate: false)

        let revived = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        #expect(revived.isDeleted == false)
        #expect(revived.text == "settlement terms discussed")
        #expect(revived.manualNotes == "my private note")
        #expect(revived.updatedAt > tombstone.updatedAt)
    }

    // Data-loss guard: the tombstone coming back from CloudKit must not wipe the local meeting.
    @Test("fetching the meeting's own tombstone back does not delete the local private meeting")
    func echoedTombstoneKeepsLocalMeeting() async throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let synced = try sync(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        #expect(try store.markTextRecordSynced(
            kind: .meeting, recordName: tombstone.id, changeTag: "tag-2",
            systemFields: Data([0x02]), recordUpdatedAt: tombstone.updatedAt
        ))

        let echo = MuesliICloudSyncEngine.syncZoneCloudRecord(from: tombstone)
        try await MuesliCKSyncEngine(store: store).handleFetchedRecords([echo], state: PendingState())

        try expectLocalContentIntact(store, id: id)
        #expect(try store.isMeetingPrivate(id: id))
        let local = try #require(try store.meeting(id: id))
        #expect(local.title == "Counsel call")
    }

    /// A content record for this meeting as another device would have saved it after `after`.
    private func newerRemoteContent(_ tombstone: SyncTextRecord, after: Date) -> CKRecord {
        MuesliICloudSyncEngine.syncZoneCloudRecord(from: SyncTextRecord(
            id: tombstone.id, kind: .meeting, title: "Counsel call", text: "settlement terms discussed",
            source: "ios", meetingStatus: .completed, createdAt: tombstone.createdAt,
            updatedAt: after.addingTimeInterval(60), startedAt: tombstone.startedAt,
            endedAt: tombstone.endedAt, durationSeconds: 60, wordCount: 3, isDeleted: false
        ))
    }

    @Test("a tombstone save that loses a conflict to newer server content is retried as a tombstone")
    func tombstoneConflictWithNewerServerContentRetries() async throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let synced = try sync(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        let server = newerRemoteContent(tombstone, after: tombstone.updatedAt)
        let client = MuesliICloudSyncEngine.syncZoneCloudRecord(from: tombstone)
        let error = CKError(.serverRecordChanged, userInfo: [
            CKRecordChangedErrorServerRecordKey: server,
            CKRecordChangedErrorClientRecordKey: client,
        ])
        let state = PendingState()
        let engine = MuesliCKSyncEngine(store: store)

        try await engine.handleSentRecordChanges(
            savedRecords: [],
            failedRecordSaves: [MuesliCKSyncFailedRecordSave(record: client, error: error)],
            state: state
        )

        try expectLocalContentIntact(store, id: id)
        let retry = try store.textRecordsNeedingSync().first { $0.id == synced.id }
        expectContentFreeTombstone(retry, id: synced.id)
        #expect((retry?.updatedAt ?? .distantPast) > (server["updatedAt"] as? Date ?? .distantFuture))
    }

    @Test("newer content fetched for a private meeting is refused and re-tombstoned")
    func newerFetchedContentIsRetombstoned() async throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let synced = try sync(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        #expect(try store.markTextRecordSynced(
            kind: .meeting, recordName: tombstone.id, changeTag: "tag-2",
            systemFields: Data([0x02]), recordUpdatedAt: tombstone.updatedAt
        ))
        let fetched = newerRemoteContent(tombstone, after: tombstone.updatedAt)

        try await MuesliCKSyncEngine(store: store).handleFetchedRecords([fetched], state: PendingState())

        try expectLocalContentIntact(store, id: id)
        let retry = try store.textRecordsNeedingSync().first { $0.id == synced.id }
        expectContentFreeTombstone(retry, id: synced.id)
        #expect((retry?.updatedAt ?? .distantPast) > (fetched["updatedAt"] as? Date ?? .distantFuture))
    }

    // Row: delete fails offline -> retried by the engine's normal pending mechanism.
    @Test("a tombstone save that fails offline stays pending and dirty")
    func offlineTombstoneFailureRetries() async throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        let synced = try sync(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        let tombstone = try #require(try store.textRecordsNeedingSync().first { $0.id == synced.id })
        let client = MuesliICloudSyncEngine.syncZoneCloudRecord(from: tombstone)
        let state = PendingState()
        let engine = MuesliCKSyncEngine(store: store)

        try await engine.handleSentRecordChanges(
            savedRecords: [],
            failedRecordSaves: [MuesliCKSyncFailedRecordSave(record: client, error: CKError(.networkUnavailable))],
            state: state
        )

        #expect(state.pendingRecordZoneChanges == [pending(synced.id)])
        #expect(try store.hasTextRecordsNeedingSync())
        let retry = await engine.makeRecordBatch(pendingChanges: state.pendingRecordZoneChanges)
        #expect(retry.recordsToSave.count == 1)
    }

    // Row: sync disabled -> nothing queued and no crash. The store only flags the row, which every
    // local edit does; the controller's `config.iCloudSyncEnabled` guard keeps it from the engine.
    @Test("flagging privacy without any sync engine running is a local-only change")
    func privacyChangeWithoutSync() throws {
        let store = try makeStore()
        let id = try completedMeeting(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        #expect(try store.hasTextRecordsNeedingSync() == false, "a never-synced private meeting offers nothing")
        try store.setMeetingPrivate(id: id, isPrivate: false)
        #expect(try store.hasTextRecordsNeedingSync())
    }
}

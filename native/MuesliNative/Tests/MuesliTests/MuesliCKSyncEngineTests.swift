import CloudKit
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

private final class TestCKSyncPendingState: MuesliCKSyncPendingState, @unchecked Sendable {
    private(set) var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]

    init(_ changes: [CKSyncEngine.PendingRecordZoneChange] = []) {
        self.pendingRecordZoneChanges = changes
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

private actor TestCKSyncCycleLog {
    private(set) var events: [String] = []
    private(set) var uploaded = 0
    private var registrationResults: [Int]

    init(registrationResults: [Int]) {
        self.registrationResults = registrationResults
    }

    func append(_ event: String) {
        events.append(event)
    }

    func register() -> Int {
        events.append("register")
        return registrationResults.isEmpty ? 0 : registrationResults.removeFirst()
    }

    func send(makesProgress: Bool) {
        events.append("send")
        if makesProgress { uploaded += 1 }
    }
}

@Suite("Muesli CKSyncEngine", .serialized)
struct MuesliCKSyncEngineTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cksyncengine-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func makeCloudRecord(
        from record: SyncTextRecord,
        updatedAt: Date,
        text: String
    ) -> CKRecord {
        let cloud = MuesliICloudSyncEngine.syncZoneCloudRecord(from: SyncTextRecord(
            id: record.id,
            kind: record.kind,
            title: record.title,
            text: text,
            source: record.source,
            localSource: record.localSource,
            meetingStatus: record.meetingStatus,
            createdAt: record.createdAt,
            updatedAt: updatedAt,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            wordCount: DictationStore.countWords(in: text),
            isDeleted: record.isDeleted
        ))
        return cloud
    }

    @Test("sync cycle fetches before registering and sending")
    func fetchBeforeSendOrdering() async throws {
        let log = TestCKSyncCycleLog(registrationResults: [1, 0])

        try await MuesliCKSyncCycle.run(
            maximumUploadBatches: 5,
            fetch: { await log.append("fetch") },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: true) }
        )

        #expect(await log.events == ["fetch", "register", "send", "register"])
    }

    @Test("sync cycle stops immediately when a send makes no progress")
    func noProgressStopsRetryLoop() async throws {
        let log = TestCKSyncCycleLog(registrationResults: [1, 1, 1])

        try await MuesliCKSyncCycle.run(
            maximumUploadBatches: 5,
            fetch: { await log.append("fetch") },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: false) }
        )

        #expect(await log.events == ["fetch", "register", "send"])
    }

    @Test("restored pending save rebuilds its CKRecord from SQLite")
    func restoredPendingChangeUsesDurableOutbox() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Durable pending text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let dirty = try #require(try store.textRecordsNeedingSync().first)
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(
            recordName: dirty.id,
            zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
        ))
        let state = TestCKSyncPendingState([pending])
        let coordinator = MuesliCKSyncEngine(store: store)

        #expect(try await coordinator.registerNextDirtyBatch(state: state) == 1)
        #expect(state.pendingRecordZoneChanges == [pending])

        let batch = await coordinator.makeRecordBatch(pendingChanges: state.pendingRecordZoneChanges)
        #expect(batch.recordsToSave.count == 1)
        #expect(batch.recordsToSave.first?["text"] as? String == "Durable pending text")
        #expect(batch.staleChanges.isEmpty)
    }

    @Test("restored pending save for a missing local row is discarded")
    func staleRestoredPendingChangeIsDiscarded() async throws {
        let store = try makeStore()
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(
            recordName: "missing-local-row",
            zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
        ))
        let coordinator = MuesliCKSyncEngine(store: store)

        let batch = await coordinator.makeRecordBatch(pendingChanges: [pending])
        #expect(batch.recordsToSave.isEmpty)
        #expect(batch.staleChanges == [pending])
    }

    @Test("local batch read failure preserves pending saves for retry")
    func localBatchReadFailurePreservesPendingSave() async throws {
        struct TestReadError: Error {}

        let store = try makeStore()
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(
            recordName: "pending-local-row",
            zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
        ))
        let coordinator = MuesliCKSyncEngine(store: store)

        let batch = await coordinator.makeRecordBatch(
            pendingChanges: [pending],
            loadRecords: { _ in throw TestReadError() }
        )

        #expect(batch.recordsToSave.isEmpty)
        #expect(batch.staleChanges.isEmpty)
    }

    @Test("newer fetched server record replaces local row and pending save")
    func newerFetchedRecordWins() async throws {
        let store = try makeStore()
        let endedAt = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try store.insertDictation(
            text: "Older local text",
            durationSeconds: 2,
            startedAt: endedAt.addingTimeInterval(-2),
            endedAt: endedAt
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let cloud = makeCloudRecord(
            from: local,
            updatedAt: local.updatedAt.addingTimeInterval(60),
            text: "Newer server text"
        )
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(cloud.recordID)
        let state = TestCKSyncPendingState([pending])
        let coordinator = MuesliCKSyncEngine(store: store)

        try await coordinator.handleFetchedRecords([cloud], state: state)

        let resolved = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(resolved.text == "Newer server text")
        #expect(try store.hasTextRecordsNeedingSync() == false)
        #expect(state.pendingRecordZoneChanges.isEmpty)
    }

    @Test("older fetched server record hydrates metadata but preserves local dirty edit")
    func newerLocalEditWinsFetchedRecord() async throws {
        let store = try makeStore()
        let endedAt = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try store.insertDictation(
            text: "Newer local text",
            durationSeconds: 2,
            startedAt: endedAt.addingTimeInterval(-2),
            endedAt: endedAt
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let cloud = makeCloudRecord(
            from: local,
            updatedAt: local.updatedAt.addingTimeInterval(-60),
            text: "Older server text"
        )
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(cloud.recordID)
        let state = TestCKSyncPendingState([pending])
        let coordinator = MuesliCKSyncEngine(store: store)

        try await coordinator.handleFetchedRecords([cloud], state: state)

        let resolved = try #require(try store.textRecordsNeedingSync().first { $0.id == local.id })
        #expect(resolved.text == "Newer local text")
        #expect(resolved.cloudSystemFields != nil)
        #expect(state.pendingRecordZoneChanges == [pending])
    }

    @Test("saved record clears the durable outbox and pending state")
    func savedRecordCompletesUpload() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Saved text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let saved = makeCloudRecord(from: local, updatedAt: local.updatedAt, text: local.text)
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(saved.recordID)
        let state = TestCKSyncPendingState([pending])
        let coordinator = MuesliCKSyncEngine(store: store)

        try await coordinator.handleSentRecordChanges(
            savedRecords: [saved],
            failedRecordSaves: [],
            state: state
        )

        #expect(try store.hasTextRecordsNeedingSync() == false)
        #expect(try store.textRecordForSync(recordName: local.id)?.cloudSystemFields != nil)
    }

    @Test("local winner of server conflict retries using the server CKRecord")
    func localConflictWinnerUsesServerBase() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Newer local text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let server = makeCloudRecord(
            from: local,
            updatedAt: local.updatedAt.addingTimeInterval(-60),
            text: "Older server text"
        )
        let client = makeCloudRecord(from: local, updatedAt: local.updatedAt, text: local.text)
        let error = CKError(.serverRecordChanged, userInfo: [
            CKRecordChangedErrorServerRecordKey: server,
            CKRecordChangedErrorClientRecordKey: client,
        ])
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(client.recordID)
        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(store: store)

        try await coordinator.handleSentRecordChanges(
            savedRecords: [],
            failedRecordSaves: [MuesliCKSyncFailedRecordSave(record: client, error: error)],
            state: state
        )
        let batch = await coordinator.makeRecordBatch(pendingChanges: state.pendingRecordZoneChanges)

        #expect(state.pendingRecordZoneChanges == [pending])
        #expect(batch.recordsToSave.count == 1)
        #expect(batch.recordsToSave.first === server)
        #expect(batch.recordsToSave.first?["text"] as? String == "Newer local text")
    }

    @Test("server winner of a conflict replaces local row and removes pending save")
    func serverConflictWinnerAppliesLocally() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Older local text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let server = makeCloudRecord(
            from: local,
            updatedAt: local.updatedAt.addingTimeInterval(60),
            text: "Newer server text"
        )
        let client = makeCloudRecord(from: local, updatedAt: local.updatedAt, text: local.text)
        let error = CKError(.serverRecordChanged, userInfo: [
            CKRecordChangedErrorServerRecordKey: server,
            CKRecordChangedErrorClientRecordKey: client,
        ])
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(client.recordID)
        let state = TestCKSyncPendingState([pending])
        let coordinator = MuesliCKSyncEngine(store: store)

        try await coordinator.handleSentRecordChanges(
            savedRecords: [],
            failedRecordSaves: [MuesliCKSyncFailedRecordSave(record: client, error: error)],
            state: state
        )

        let resolved = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(resolved.text == "Newer server text")
        #expect(try store.hasTextRecordsNeedingSync() == false)
        #expect(state.pendingRecordZoneChanges.isEmpty)
    }

    @Test("transient failed save remains pending and durable")
    func transientFailureRemainsPending() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Retry this text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let client = makeCloudRecord(from: local, updatedAt: local.updatedAt, text: local.text)
        let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(client.recordID)
        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(store: store)

        try await coordinator.handleSentRecordChanges(
            savedRecords: [],
            failedRecordSaves: [
                MuesliCKSyncFailedRecordSave(record: client, error: CKError(.networkUnavailable)),
            ],
            state: state
        )

        #expect(state.pendingRecordZoneChanges == [pending])
        #expect(try store.hasTextRecordsNeedingSync())
    }

    @Test("account switch clears only CloudKit metadata and preserves local text")
    func accountSwitchPreservesLocalData() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Keep this local text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "account-one-tag",
            systemFields: Data([0x01, 0x02]),
            recordUpdatedAt: local.updatedAt
        ))
        let coordinator = MuesliCKSyncEngine(store: store)
        try store.saveCloudSyncStateData(
            Data("account-one-state".utf8),
            forKey: MuesliCKSyncEngine.stateKey
        )

        try await coordinator.handleAccountChange(requiresMetadataReset: true)

        let reset = try #require(try store.textRecordsNeedingSync().first { $0.id == local.id })
        #expect(reset.text == "Keep this local text")
        #expect(reset.cloudChangeTag == nil)
        #expect(reset.cloudSystemFields == nil)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
    }
}

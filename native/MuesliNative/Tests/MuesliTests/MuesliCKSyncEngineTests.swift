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

private actor TestCKSyncPreparationProbe {
    private var state = MuesliCKSyncPreparationState()
    private(set) var preflightCount = 0

    func prepare() {
        guard state.requiresPreparation else { return }
        preflightCount += 1
        state.markPrepared()
    }

    func invalidate() {
        state.invalidate()
    }
}

private actor TestCKSyncCancellationProbe {
    private(set) var count = 0

    func record() {
        count += 1
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

    @Test("local changes prepare and send without fetching first")
    func localChangeSendsWithoutFetch() async throws {
        let log = TestCKSyncCycleLog(registrationResults: [1, 0])

        try await MuesliCKSyncOperation.run(
            intent: .outgoing,
            maximumUploadBatches: 5,
            prepare: { await log.append("prepare") },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: true) },
            fetch: { await log.append("fetch") }
        )

        #expect(await log.events == ["prepare", "register", "send", "register"])
    }

    @Test("incoming changes prepare and fetch without sending")
    func incomingChangeFetchesWithoutSend() async throws {
        let log = TestCKSyncCycleLog(registrationResults: [1])

        try await MuesliCKSyncOperation.run(
            intent: .incoming,
            maximumUploadBatches: 5,
            prepare: { await log.append("prepare") },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: true) },
            fetch: { await log.append("fetch") }
        )

        #expect(await log.events == ["prepare", "fetch"])
    }

    @Test("manual sync sends then fetches exactly once")
    func manualSyncSendsThenFetches() async throws {
        let log = TestCKSyncCycleLog(registrationResults: [1, 0])

        try await MuesliCKSyncOperation.run(
            intent: .manual,
            maximumUploadBatches: 5,
            prepare: { await log.append("prepare") },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: true) },
            fetch: { await log.append("fetch") }
        )

        #expect(await log.events == ["prepare", "register", "send", "register", "fetch"])
    }

    @Test("coalesced outgoing and incoming intent runs both directions once")
    func coalescedIntentRunsBothDirectionsOnce() async throws {
        var requests = MuesliCKSyncRequestQueue()
        requests.enqueue(intent: .outgoing, userInitiated: false)
        requests.enqueue(intent: .incoming, userInitiated: true)
        requests.enqueue(intent: .outgoing, userInitiated: false)
        requests.enqueue(intent: .incoming, userInitiated: false)
        let consumedRequest = requests.consume()
        let request = try #require(consumedRequest)
        let log = TestCKSyncCycleLog(registrationResults: [1, 0])

        try await MuesliCKSyncOperation.run(
            intent: request.intent,
            maximumUploadBatches: 5,
            prepare: { await log.append("prepare") },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: true) },
            fetch: { await log.append("fetch") }
        )

        #expect(request == MuesliCKSyncRequest(intent: .manual, userInitiated: true))
        let nextRequest = requests.consume()
        #expect(nextRequest == nil)
        #expect(await log.events == ["prepare", "register", "send", "register", "fetch"])
    }

    @Test("a failed cycle drains only intent queued while it was active")
    func failedCyclePreservesOnlyNewFollowUpIntent() throws {
        var requests = MuesliCKSyncRequestQueue()
        requests.enqueue(intent: .outgoing, userInitiated: false)
        let failedRequest = requests.consume()
        #expect(failedRequest == MuesliCKSyncRequest(intent: .outgoing, userInitiated: false))

        requests.enqueue(intent: .incoming, userInitiated: true)
        let followUpRequest = requests.consume()
        #expect(followUpRequest == MuesliCKSyncRequest(intent: .incoming, userInitiated: true))
        #expect(requests.isEmpty)
    }

    @Test("sync cycle stops immediately when a send makes no progress")
    func noProgressStopsRetryLoop() async throws {
        let log = TestCKSyncCycleLog(registrationResults: [1, 1, 1])

        try await MuesliCKSyncOperation.run(
            intent: .outgoing,
            maximumUploadBatches: 5,
            prepare: { await log.append("prepare") },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: false) },
            fetch: { await log.append("fetch") }
        )

        #expect(await log.events == ["prepare", "register", "send"])
    }

    @Test("successful preparation is reused until recovery invalidates it")
    func preparationStateIsExplicitlyInvalidated() async throws {
        let preparation = TestCKSyncPreparationProbe()
        let log = TestCKSyncCycleLog(registrationResults: [0, 0, 0])

        for _ in 0..<2 {
            try await MuesliCKSyncOperation.run(
                intent: .outgoing,
                maximumUploadBatches: 5,
                prepare: { await preparation.prepare() },
                registerNextBatch: { await log.register() },
                uploadedCount: { await log.uploaded },
                send: { await log.send(makesProgress: true) },
                fetch: { await log.append("fetch") }
            )
        }
        #expect(await preparation.preflightCount == 1)

        await preparation.invalidate()
        try await MuesliCKSyncOperation.run(
            intent: .outgoing,
            maximumUploadBatches: 5,
            prepare: { await preparation.prepare() },
            registerNextBatch: { await log.register() },
            uploadedCount: { await log.uploaded },
            send: { await log.send(makesProgress: true) },
            fetch: { await log.append("fetch") }
        )
        #expect(await preparation.preflightCount == 2)
    }

    @Test("account and zone failures invalidate the matching preparation context")
    func preparationRecoveryErrorsAreClassified() {
        #expect(MuesliICloudSyncEngine.isICloudAccountContextError(CKError(.notAuthenticated)))
        #expect(MuesliICloudSyncEngine.isSyncZoneRecoveryError(CKError(.zoneNotFound)))
        #expect(MuesliICloudSyncEngine.isSyncZoneRecoveryError(CKError(.userDeletedZone)))
        #expect(!MuesliICloudSyncEngine.isSyncZoneRecoveryError(CKError(.networkUnavailable)))
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
        let cancellationProbe = TestCKSyncCancellationProbe()
        let coordinator = MuesliCKSyncEngine(
            store: store,
            engineCancellationObserver: { await cancellationProbe.record() }
        )
        let stalePending = CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(
            recordName: local.id,
            zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
        ))
        let state = TestCKSyncPendingState([stalePending])
        try store.saveCloudSyncStateData(
            Data("account-one-state".utf8),
            forKey: MuesliCKSyncEngine.stateKey
        )

        try await coordinator.handleAccountChange(
            requiresMetadataReset: true,
            state: state
        )

        let reset = try #require(try store.textRecordsNeedingSync().first { $0.id == local.id })
        #expect(reset.text == "Keep this local text")
        #expect(reset.cloudChangeTag == nil)
        #expect(reset.cloudSystemFields == nil)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(await cancellationProbe.count == 0)
    }
}

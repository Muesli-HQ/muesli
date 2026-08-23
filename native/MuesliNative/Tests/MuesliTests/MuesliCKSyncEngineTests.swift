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
        #expect(MuesliICloudSyncEngine.isICloudAccountContextError(CKError(.permissionFailure)))
        let nestedPermission = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                CKRecord.ID(recordName: "opaque-test-id"): CKError(.permissionFailure),
            ],
        ])
        #expect(MuesliICloudSyncEngine.isICloudAccountContextError(nestedPermission))
        let underlyingAuthentication = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [NSUnderlyingErrorKey: CKError(.notAuthenticated)]
        )
        #expect(MuesliICloudSyncEngine.isICloudAccountContextError(underlyingAuthentication))
        var overDepthLimit: Error = CKError(.permissionFailure)
        for _ in 0..<9 {
            overDepthLimit = NSError(
                domain: NSCocoaErrorDomain,
                code: 1,
                userInfo: [NSUnderlyingErrorKey: overDepthLimit]
            )
        }
        #expect(!MuesliICloudSyncEngine.isICloudAccountContextError(overDepthLimit))
        #expect(MuesliICloudSyncEngine.isSyncZoneRecoveryError(CKError(.zoneNotFound)))
        #expect(MuesliICloudSyncEngine.isSyncZoneRecoveryError(CKError(.userDeletedZone)))
        #expect(!MuesliICloudSyncEngine.isSyncZoneRecoveryError(CKError(.networkUnavailable)))
    }

    @Test("provenance treats only uniformly missing nested records as a safe non-match")
    func provenanceMissingErrorsAreBoundedAndStrict() {
        let recordID = CKRecord.ID(recordName: "opaque-test-id")
        let allMissing = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [recordID: CKError(.unknownItem)],
        ])
        let mixed = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [recordID: CKError(.networkUnavailable)],
        ])

        #expect(MuesliICloudSyncEngine.isMissingProvenanceRecord(allMissing))
        #expect(!MuesliICloudSyncEngine.isMissingProvenanceRecord(mixed))
    }

    @Test("provenance classification returns only requested correctly typed stable IDs")
    func provenanceClassificationIsExactAndContentFree() throws {
        let zoneID = MuesliICloudSyncEngine.Schema.syncZoneID
        let firstID = CKRecord.ID(recordName: "stable-first", zoneID: zoneID)
        let secondID = CKRecord.ID(recordName: "stable-second", zoneID: zoneID)
        let missingID = CKRecord.ID(recordName: "stable-missing", zoneID: zoneID)
        let unexpectedID = CKRecord.ID(recordName: "stable-unexpected", zoneID: zoneID)
        let first = CKRecord(
            recordType: MuesliICloudSyncEngine.Schema.textRecordType,
            recordID: firstID
        )
        let wrongType = CKRecord(recordType: "MuesliBridgeDevice", recordID: secondID)
        let unexpected = CKRecord(
            recordType: MuesliICloudSyncEngine.Schema.textRecordType,
            recordID: unexpectedID
        )

        let matches = try MuesliICloudSyncEngine.matchingProvenanceRecordNames(
            expectedRecordIDs: [firstID, secondID, missingID],
            results: [
                firstID: .success(first),
                secondID: .success(wrongType),
                missingID: .failure(CKError(.unknownItem)),
                unexpectedID: .success(unexpected),
            ]
        )

        #expect(matches == Set([firstID.recordName]))
        #expect(first.allKeys().isEmpty)
        #expect(wrongType.allKeys().isEmpty)
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
        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(store: store)

        #expect(try await coordinator.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "local-only-owner"),
            state: state
        ))
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

    @Test("record provider materializes one bounded SQLite page")
    func recordProviderMaterializesOneBoundedPage() async throws {
        let store = try makeStore()
        for index in 0..<205 {
            _ = try store.insertDictation(
                text: "Batch \(index)",
                durationSeconds: 1,
                startedAt: Date().addingTimeInterval(-1),
                endedAt: Date()
            )
        }
        let page = try store.textRecordsNeedingSync(limit: 200)
        #expect(page.count == 200)
        let pending = page.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(
                recordName: $0.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            ))
        }
        let coordinator = MuesliCKSyncEngine(store: store)
        var readCount = 0
        var requestedNames = Set<String>()

        let batch = await coordinator.makeRecordBatch(
            pendingChanges: pending,
            loadRecords: { names in
                readCount += 1
                requestedNames = Set(names)
                return try store.textRecordsForSync(recordNames: names)
            }
        )

        #expect(readCount == 1)
        #expect(requestedNames.count == 200)
        #expect(batch.recordsToSave.count == 200)
        #expect(batch.staleChanges.isEmpty)
        #expect(try store.textRecordsNeedingSync(limit: 201).count == 201)
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

    @Test("account scope diagnostics are stable hashes without CloudKit user IDs")
    func accountScopeIsContentFree() {
        let first = CKRecord.ID(recordName: "private-user-a")
        let second = CKRecord.ID(recordName: "private-user-b")
        let firstScope = MuesliCKSyncEngine.accountScope(for: first)

        #expect(firstScope == MuesliCKSyncEngine.accountScope(for: first))
        #expect(firstScope != MuesliCKSyncEngine.accountScope(for: second))
        #expect(!firstScope.contains(first.recordName))
        #expect(firstScope.hasPrefix("sha256:"))
    }

    @Test("account boundary errors are actionable and do not expose implementation names")
    func accountBoundaryErrorsAreActionable() {
        let reconnectMessage = MuesliCKSyncError.legacyAccountNeedsReconnection.localizedDescription
        let mismatchMessage = MuesliCKSyncError.differentProductionAccount.localizedDescription

        #expect(reconnectMessage.localizedCaseInsensitiveContains("reconnect"))
        #expect(mismatchMessage.contains("different iCloud account"))
        #expect(!reconnectMessage.contains("MuesliCKSyncError"))
        #expect(!mismatchMessage.contains("MuesliCKSyncError"))
    }

    @Test("CloudKit runtime requires both the private container and an explicit environment")
    func cloudEntitlementContractRejectsUnspecifiedEnvironment() {
        let container = MuesliICloudSyncEngine.Schema.containerIdentifier
        #expect(MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: [container],
            environment: "Production"
        ))
        #expect(MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: container,
            environment: "Development"
        ))
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: [container],
            environment: ""
        ))
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: [container],
            environment: "unspecified"
        ))
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: ["iCloud.example.wrong"],
            environment: "Production"
        ))
    }

    @Test("legacy provenance requires the exact complete stable-ID set")
    func accountProvenanceRequiresEveryRecord() {
        let required = Set(["stable-a", "stable-b"])

        #expect(MuesliCKSyncEngine.hasExactAccountProvenance(
            requiredRecordNames: required,
            matchingRecordNames: required
        ))
        #expect(!MuesliCKSyncEngine.hasExactAccountProvenance(
            requiredRecordNames: required,
            matchingRecordNames: Set(["stable-a"])
        ))
        #expect(!MuesliCKSyncEngine.hasExactAccountProvenance(
            requiredRecordNames: required,
            matchingRecordNames: required.union(["unrequested"])
        ))
        #expect(!MuesliCKSyncEngine.hasExactAccountProvenance(
            requiredRecordNames: [],
            matchingRecordNames: []
        ))
    }

    @Test("first local-only library claims the current account and registers dirty text")
    func firstLocalOnlyLibraryClaimsCurrentAccount() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Private local-only text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let state = TestCKSyncPendingState()
        let owner = CKRecord.ID(recordName: "first-owner")
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { _ in
                Issue.record("Local-only rows must not require legacy CloudKit proof")
                return []
            }
        )

        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(MuesliCKSyncEngine.accountScope(for: owner).utf8))
        #expect(state.pendingRecordZoneChanges == [
            .saveRecord(CKRecord.ID(
                recordName: local.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )),
        ])
    }

    @Test("unscoped legacy library claims only a verified current account")
    func verifiedLegacyLibraryClaimsCurrentAccount() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "First legacy synced text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let first = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: first.kind,
            recordName: first.id,
            changeTag: "first-legacy-tag",
            systemFields: Data([0x01]),
            recordUpdatedAt: first.updatedAt
        ))
        _ = try store.insertDictation(
            text: "Second legacy synced text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let second = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: second.kind,
            recordName: second.id,
            changeTag: "second-legacy-tag",
            systemFields: Data([0x02]),
            recordUpdatedAt: second.updatedAt
        ))
        let owner = CKRecord.ID(recordName: "verified-owner")
        let state = TestCKSyncPendingState()
        let expectedNames = Set([first.id, second.id])
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { names in
                #expect(names == expectedNames)
                return names
            }
        )

        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(MuesliCKSyncEngine.accountScope(for: owner).utf8))
        #expect(state.pendingRecordZoneChanges.isEmpty)
    }

    @Test("matching unspecified owner safely migrates and requeues for Production")
    func matchingUnspecifiedOwnerMigratesToProduction() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Keep authored text private during environment repair",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "existing-production-tag",
            systemFields: Data([0x01, 0x02]),
            recordUpdatedAt: local.updatedAt
        ))

        let owner = CKRecord.ID(recordName: "same-private-owner")
        let scope = MuesliCKSyncEngine.accountScope(for: owner)
        let migration = MuesliCKSyncLegacyScopeMigration(
            accountScopeKey: "test.unspecified.owner",
            stateKey: "test.unspecified.state"
        )
        try store.saveCloudSyncStateData(Data(scope.utf8), forKey: migration.accountScopeKey)
        try store.saveCloudSyncStateData(Data("obsolete-cursor".utf8), forKey: migration.stateKey)

        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { _ in
                Issue.record("An exact legacy owner match must not query authored records")
                return []
            },
            legacyScopeMigration: migration
        )

        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(scope.utf8))
        #expect(try store.cloudSyncStateData(forKey: migration.accountScopeKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: migration.stateKey) == nil)
        #expect(state.pendingRecordZoneChanges == [
            .saveRecord(CKRecord.ID(
                recordName: local.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )),
        ])

        let preserved = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(preserved.text == "Keep authored text private during environment repair")
        #expect(preserved.cloudChangeTag == nil)
        #expect(preserved.cloudSystemFields == nil)
        #expect(try store.hasTextRecordsNeedingSync())
    }

    @Test("unspecified migration clears in-progress meeting metadata without uploading it")
    func matchingUnspecifiedOwnerRepairsInProgressMeetingMetadata() async throws {
        let store = try makeStore()
        let meetingID = try store.insertMeeting(
            title: "Private in-progress meeting",
            calendarEventID: nil,
            startTime: Date().addingTimeInterval(-60),
            endTime: Date(),
            rawTranscript: "Keep the local transcript untouched",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "obsolete-unspecified-tag",
            systemFields: Data([0x04, 0x05]),
            recordUpdatedAt: local.updatedAt
        ))
        try store.updateMeetingStatus(id: meetingID, status: .processing)

        let owner = CKRecord.ID(recordName: "same-private-owner-in-progress")
        let scope = MuesliCKSyncEngine.accountScope(for: owner)
        let migration = MuesliCKSyncLegacyScopeMigration(
            accountScopeKey: "test.unspecified.owner.in-progress",
            stateKey: "test.unspecified.state.in-progress"
        )
        try store.saveCloudSyncStateData(Data(scope.utf8), forKey: migration.accountScopeKey)
        try store.saveCloudSyncStateData(Data("obsolete-cursor".utf8), forKey: migration.stateKey)

        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { _ in
                Issue.record("An exact legacy owner match must not query authored records")
                return []
            },
            legacyScopeMigration: migration
        )

        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(try store.textRecordsNeedingSync().isEmpty)

        let repaired = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(repaired.text == "Keep the local transcript untouched")
        #expect(repaired.meetingStatus == .processing)
        #expect(repaired.cloudChangeTag == nil)
        #expect(repaired.cloudSystemFields == nil)

        try store.updateMeetingStatus(id: meetingID, status: .completed)
        let eligible = try #require(try store.textRecordsNeedingSync().first)
        #expect(eligible.id == local.id)
        #expect(eligible.cloudChangeTag == nil)
        #expect(eligible.cloudSystemFields == nil)
    }

    @Test("mismatched legacy owner stays blocked until explicit sync reset")
    func mismatchedUnspecifiedOwnerDoesNotMigrate() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Never cross an account boundary",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "other-account-tag",
            systemFields: Data([0x03]),
            recordUpdatedAt: local.updatedAt
        ))

        let migration = MuesliCKSyncLegacyScopeMigration(
            accountScopeKey: "test.unspecified.owner.mismatch",
            stateKey: "test.unspecified.state.mismatch"
        )
        let oldScope = MuesliCKSyncEngine.accountScope(
            for: CKRecord.ID(recordName: "old-private-owner")
        )
        try store.saveCloudSyncStateData(Data(oldScope.utf8), forKey: migration.accountScopeKey)
        try store.saveCloudSyncStateData(Data("keep-cursor".utf8), forKey: migration.stateKey)

        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { names in
                #expect(names == Set([local.id]))
                return []
            },
            legacyScopeMigration: migration
        )

        #expect(try await coordinator.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "different-private-owner"),
            state: state
        ) == false)
        #expect(try store.cloudSyncStateData(forKey: migration.accountScopeKey)
            == Data(oldScope.utf8))
        #expect(try store.cloudSyncStateData(forKey: migration.stateKey)
            == Data("keep-cursor".utf8))
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey) == nil)
        #expect(try !store.hasTextRecordsNeedingSync())
        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(await coordinator.currentAccountBoundaryError() == .legacyAccountNeedsReconnection)

        #expect(try await coordinator.resetCloudSyncAccount())
        #expect(try store.cloudSyncStateData(forKey: migration.accountScopeKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: migration.stateKey) == nil)
        let reset = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(reset.text == "Never cross an account boundary")
        #expect(reset.cloudChangeTag == nil)
        #expect(reset.cloudSystemFields == nil)
        #expect(try store.hasTextRecordsNeedingSync())

        let replacementOwner = CKRecord.ID(recordName: "different-private-owner")
        #expect(try await coordinator.handleAccountChange(
            currentUser: replacementOwner,
            state: state
        ))
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(MuesliCKSyncEngine.accountScope(for: replacementOwner).utf8))
        #expect(state.pendingRecordZoneChanges == [
            .saveRecord(CKRecord.ID(
                recordName: local.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )),
        ])
    }

    @Test("explicit reconnect adopts an ambiguous legacy library without changing authored data")
    func explicitReconnectPreservesAndRequeuesLegacyLibrary() async throws {
        let store = try makeStore()
        let endedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let dictationID = try store.insertDictation(
            text: "Keep the original dictation exactly",
            durationSeconds: 3,
            startedAt: endedAt.addingTimeInterval(-3),
            endedAt: endedAt
        )
        let originalDictation = try #require(try store.dictation(id: dictationID))
        let dictation = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: dictation.kind,
            recordName: dictation.id,
            changeTag: "ambiguous-dictation-tag",
            systemFields: Data([0x01, 0x02]),
            recordUpdatedAt: dictation.updatedAt
        ))

        let meetingID = try store.insertMeeting(
            title: "Keep meeting and audio",
            calendarEventID: nil,
            startTime: endedAt.addingTimeInterval(-60),
            endTime: endedAt,
            rawTranscript: "Keep the original meeting transcript exactly",
            formattedNotes: "Keep the original notes exactly",
            micAudioPath: "/private/audio/mic.wav",
            systemAudioPath: "/private/audio/system.wav",
            savedRecordingPath: "/private/audio/combined.wav"
        )
        let meetingText = try #require(
            try store.textRecordsNeedingSync().first { $0.kind == .meeting }
        )
        #expect(try store.markTextRecordSynced(
            kind: meetingText.kind,
            recordName: meetingText.id,
            changeTag: "ambiguous-meeting-tag",
            systemFields: Data([0x03, 0x04]),
            recordUpdatedAt: meetingText.updatedAt
        ))
        try store.updateMeetingStatus(id: meetingID, status: .processing)

        let migration = MuesliCKSyncLegacyScopeMigration(
            accountScopeKey: "test.reconnect.legacy.owner",
            stateKey: "test.reconnect.legacy.state"
        )
        try store.saveCloudSyncStateData(
            Data(MuesliCKSyncEngine.accountScope(
                for: CKRecord.ID(recordName: "unknown-legacy-owner")
            ).utf8),
            forKey: migration.accountScopeKey
        )
        try store.saveCloudSyncStateData(
            Data("obsolete-legacy-cursor".utf8),
            forKey: migration.stateKey
        )
        try store.saveCloudSyncStateData(
            Data("obsolete-production-cursor".utf8),
            forKey: MuesliCKSyncEngine.stateKey
        )

        let currentUser = CKRecord.ID(recordName: "confirmed-current-owner")
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { _ in [] },
            legacyScopeMigration: migration
        )
        let state = TestCKSyncPendingState()

        #expect(try await coordinator.handleAccountChange(
            currentUser: currentUser,
            state: state
        ) == false)
        #expect(await coordinator.currentAccountBoundaryError() == .legacyAccountNeedsReconnection)
        try store.saveCloudSyncStateData(
            Data("stale-cursor-created-before-confirmation".utf8),
            forKey: MuesliCKSyncEngine.stateKey
        )

        #expect(try await coordinator.reconnectLegacyLibrary(currentUser: currentUser))
        #expect(await coordinator.currentAccountBoundaryError() == nil)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(MuesliCKSyncEngine.accountScope(for: currentUser).utf8))
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: migration.accountScopeKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: migration.stateKey) == nil)

        let preservedDictation = try #require(try store.dictation(id: dictationID))
        #expect(preservedDictation.rawText == "Keep the original dictation exactly")
        #expect(preservedDictation.timestamp == originalDictation.timestamp)
        let preservedMeeting = try #require(try store.meeting(id: meetingID))
        #expect(preservedMeeting.rawTranscript == "Keep the original meeting transcript exactly")
        #expect(preservedMeeting.formattedNotes == "Keep the original notes exactly")
        #expect(preservedMeeting.micAudioPath == "/private/audio/mic.wav")
        #expect(preservedMeeting.systemAudioPath == "/private/audio/system.wav")
        #expect(preservedMeeting.savedRecordingPath == "/private/audio/combined.wav")
        #expect(preservedMeeting.status == .processing)

        let requeued = try store.textRecordsNeedingSync()
        #expect(requeued.map(\.id) == [dictation.id])
        #expect(requeued.allSatisfy {
            $0.cloudChangeTag == nil && $0.cloudSystemFields == nil
        })
        let heldMeeting = try #require(try store.textRecordForSync(recordName: meetingText.id))
        #expect(heldMeeting.cloudChangeTag == nil)
        #expect(heldMeeting.cloudSystemFields == nil)

        try store.updateMeetingStatus(id: meetingID, status: .completed)
        #expect(Set(try store.textRecordsNeedingSync().map(\.id))
            == Set([dictation.id, meetingText.id]))

        // A repeated confirmation of the same Production owner is a no-op.
        #expect(try await coordinator.reconnectLegacyLibrary(currentUser: currentUser))
        #expect(try store.dictation(id: dictationID)?.rawText
            == "Keep the original dictation exactly")
        #expect(try store.meeting(id: meetingID)?.micAudioPath == "/private/audio/mic.wav")
    }

    @Test("partial legacy overlap cannot claim or upload the unscoped library")
    func partialLegacyOverlapStaysBlocked() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "First private legacy note",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let first = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: first.kind,
            recordName: first.id,
            changeTag: "first-account-tag",
            systemFields: Data([0x01]),
            recordUpdatedAt: first.updatedAt
        ))
        _ = try store.insertDictation(
            text: "Second private legacy note",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let second = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: second.kind,
            recordName: second.id,
            changeTag: "second-account-tag",
            systemFields: Data([0x02]),
            recordUpdatedAt: second.updatedAt
        ))
        let expectedNames = Set([first.id, second.id])
        let state = TestCKSyncPendingState([
            .saveRecord(CKRecord.ID(
                recordName: first.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )),
        ])
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { names in
                #expect(names == expectedNames)
                #expect(!names.contains("First private legacy note"))
                #expect(!names.contains("Second private legacy note"))
                return Set([first.id])
            }
        )

        #expect(try await coordinator.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "partially-overlapping-owner"),
            state: state
        ) == false)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey) == nil)
        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(try !store.hasTextRecordsNeedingSync())
        #expect(try await coordinator.registerNextDirtyBatch(state: state) == 0)
        let preservedFirst = try #require(try store.textRecordForSync(recordName: first.id))
        let preservedSecond = try #require(try store.textRecordForSync(recordName: second.id))
        #expect(preservedFirst.text == "First private legacy note")
        #expect(preservedFirst.cloudChangeTag == "first-account-tag")
        #expect(preservedSecond.text == "Second private legacy note")
        #expect(preservedSecond.cloudChangeTag == "second-account-tag")
        #expect(await coordinator.currentAccountBoundaryError() == .legacyAccountNeedsReconnection)
    }

    @Test("unverified legacy account is blocked without requeue or metadata loss")
    func unverifiedLegacyLibraryStaysLocal() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Legacy authored text stays local",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "legacy-account-tag",
            systemFields: Data([0x01, 0x02]),
            recordUpdatedAt: local.updatedAt
        ))
        let pending: CKSyncEngine.PendingRecordZoneChange = .saveRecord(CKRecord.ID(
            recordName: local.id,
            zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
        ))
        let state = TestCKSyncPendingState([pending])
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyAccountRecordVerifier: { names in
                #expect(names == Set([local.id]))
                return []
            }
        )

        #expect(try await coordinator.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "unverified-owner"),
            state: state
        ) == false)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey) == nil)
        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(try !store.hasTextRecordsNeedingSync())
        #expect(try await coordinator.registerNextDirtyBatch(state: state) == 0)
        let preserved = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(preserved.text == "Legacy authored text stays local")
        #expect(preserved.cloudChangeTag == "legacy-account-tag")
        #expect(preserved.cloudSystemFields == Data([0x01, 0x02]))
        #expect(await coordinator.currentAccountBoundaryError() == .legacyAccountNeedsReconnection)
    }

    @Test("orphaned engine state can be reset repeatedly before account setup")
    func orphanedEngineStateResetIsIdempotent() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Keep this locally while repairing setup",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "orphaned-state-tag",
            systemFields: Data([0x09, 0x0A]),
            recordUpdatedAt: local.updatedAt
        ))
        try store.saveCloudSyncStateData(
            Data("orphaned-engine-state".utf8),
            forKey: MuesliCKSyncEngine.stateKey
        )

        let coordinator = MuesliCKSyncEngine(store: store, legacyScopeMigration: nil)
        #expect(try await coordinator.resetCloudSyncAccount())
        #expect(try await coordinator.resetCloudSyncAccount())
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
        let reset = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(reset.text == "Keep this locally while repairing setup")
        #expect(reset.cloudChangeTag == nil)
        #expect(reset.cloudSystemFields == nil)
        #expect(try store.hasTextRecordsNeedingSync())

        let owner = CKRecord.ID(recordName: "new-account-after-orphaned-state")
        let state = TestCKSyncPendingState()
        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        #expect(state.pendingRecordZoneChanges == [
            .saveRecord(CKRecord.ID(
                recordName: local.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )),
        ])
    }

    @Test("healthy account can reset and set up the same account again")
    func healthyAccountResetPreservesAndRequeuesLocalData() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Resync this text without changing it",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "healthy-account-tag",
            systemFields: Data([0x07, 0x08]),
            recordUpdatedAt: local.updatedAt
        ))

        let owner = CKRecord.ID(recordName: "healthy-account")
        #expect(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: owner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))
        let cancellationProbe = TestCKSyncCancellationProbe()
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyScopeMigration: nil,
            engineCancellationObserver: { await cancellationProbe.record() }
        )
        let state = TestCKSyncPendingState()
        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        try store.saveCloudSyncStateData(
            Data("healthy-engine-state".utf8),
            forKey: MuesliCKSyncEngine.stateKey
        )

        #expect(try await coordinator.resetCloudSyncAccount())
        #expect(await cancellationProbe.count == 1)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
        let reset = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(reset.text == "Resync this text without changing it")
        #expect(reset.cloudChangeTag == nil)
        #expect(reset.cloudSystemFields == nil)
        #expect(try store.hasTextRecordsNeedingSync())

        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        #expect(state.pendingRecordZoneChanges == [
            .saveRecord(CKRecord.ID(
                recordName: local.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )),
        ])
    }

    @Test("account switch stays blocked until explicit sync reset and setup")
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
        let meetingID = try store.insertMeeting(
            title: "Keep private account-switch audio",
            calendarEventID: nil,
            startTime: Date().addingTimeInterval(-60),
            endTime: Date(),
            rawTranscript: "Keep the processing transcript local",
            formattedNotes: "",
            micAudioPath: "/private/audio/account-switch-mic.wav",
            systemAudioPath: "/private/audio/account-switch-system.wav"
        )
        let meetingText = try #require(
            try store.textRecordsNeedingSync().first { $0.kind == .meeting }
        )
        #expect(try store.markTextRecordSynced(
            kind: meetingText.kind,
            recordName: meetingText.id,
            changeTag: "account-one-meeting-tag",
            systemFields: Data([0x03, 0x04]),
            recordUpdatedAt: meetingText.updatedAt
        ))
        try store.updateMeetingStatus(id: meetingID, status: .processing)
        let cancellationProbe = TestCKSyncCancellationProbe()
        let originalOwner = CKRecord.ID(recordName: "account-one")
        #expect(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: originalOwner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))
        let migration = MuesliCKSyncLegacyScopeMigration(
            accountScopeKey: "test.account-switch.legacy.owner",
            stateKey: "test.account-switch.legacy.state"
        )
        let coordinator = MuesliCKSyncEngine(
            store: store,
            legacyScopeMigration: migration,
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
        try store.saveCloudSyncStateData(
            Data("obsolete-legacy-owner".utf8),
            forKey: migration.accountScopeKey
        )
        try store.saveCloudSyncStateData(
            Data("obsolete-legacy-state".utf8),
            forKey: migration.stateKey
        )

        #expect(try await coordinator.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "account-two"),
            state: state
        ) == false)

        let preserved = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(preserved.text == "Keep this local text")
        #expect(preserved.cloudChangeTag == "account-one-tag")
        #expect(preserved.cloudSystemFields == Data([0x01, 0x02]))
        #expect(try !store.hasTextRecordsNeedingSync())
        #expect(try await coordinator.registerNextDirtyBatch(state: state) == 0)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(await cancellationProbe.count == 0)
        #expect(await coordinator.currentAccountBoundaryError() == .differentProductionAccount)

        do {
            _ = try await coordinator.reconnectLegacyLibrary(
                currentUser: CKRecord.ID(recordName: "account-two")
            )
            Issue.record("A confirmed Production owner must never be overwritten")
        } catch let error as MuesliCKSyncError {
            #expect(error == .differentProductionAccount)
        }
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(MuesliCKSyncEngine.accountScope(for: originalOwner).utf8))
        let stillPreserved = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(stillPreserved.text == "Keep this local text")
        #expect(stillPreserved.cloudChangeTag == "account-one-tag")
        #expect(stillPreserved.cloudSystemFields == Data([0x01, 0x02]))

        #expect(try await coordinator.resetCloudSyncAccount())
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: migration.accountScopeKey) == nil)
        #expect(try store.cloudSyncStateData(forKey: migration.stateKey) == nil)
        let reset = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(reset.text == "Keep this local text")
        #expect(reset.cloudChangeTag == nil)
        #expect(reset.cloudSystemFields == nil)
        #expect(try store.hasTextRecordsNeedingSync())
        let heldMeeting = try #require(try store.textRecordForSync(recordName: meetingText.id))
        #expect(heldMeeting.cloudChangeTag == nil)
        #expect(heldMeeting.cloudSystemFields == nil)
        #expect(try store.meeting(id: meetingID)?.micAudioPath
            == "/private/audio/account-switch-mic.wav")
        #expect(try store.meeting(id: meetingID)?.systemAudioPath
            == "/private/audio/account-switch-system.wav")
        #expect(try store.textRecordsNeedingSync().map(\.id) == [local.id])

        let replacementOwner = CKRecord.ID(recordName: "account-two")
        #expect(try await coordinator.handleAccountChange(
            currentUser: replacementOwner,
            state: state
        ))
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(MuesliCKSyncEngine.accountScope(for: replacementOwner).utf8))
        #expect(state.pendingRecordZoneChanges == [
            .saveRecord(CKRecord.ID(
                recordName: local.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )),
        ])

        #expect(try await coordinator.handleAccountChange(
            currentUser: CKRecord.ID(recordName: "account-three"),
            state: state
        ) == false)
        #expect(await coordinator.currentAccountBoundaryError() == .differentProductionAccount)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.accountScopeKey)
            == Data(MuesliCKSyncEngine.accountScope(for: replacementOwner).utf8))
    }

    @Test("account identity failure blocks automatic upload and clears stale pending state")
    func accountIdentityFailureFailsClosed() async throws {
        struct IdentityFailure: Error {}

        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Keep this private after identity lookup fails",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let originalOwner = CKRecord.ID(recordName: "original-owner")
        #expect(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: originalOwner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))
        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(store: store)
        #expect(try await coordinator.handleAccountChange(
            currentUser: originalOwner,
            state: state
        ))
        #expect(!state.pendingRecordZoneChanges.isEmpty)
        try store.saveCloudSyncStateData(
            Data("original-account-engine-state".utf8),
            forKey: MuesliCKSyncEngine.stateKey
        )

        do {
            _ = try await coordinator.handleSignedInAccountChange(state: state) {
                throw IdentityFailure()
            }
            Issue.record("Expected the account identity lookup to fail")
        } catch is IdentityFailure {
            // Expected: the engine must remain blocked after lookup failure.
        }

        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(try store.cloudSyncStateData(forKey: MuesliCKSyncEngine.stateKey) == nil)
        #expect(try store.hasTextRecordsNeedingSync())
        #expect(try await coordinator.registerNextDirtyBatch(state: state) == 0)
    }

    @Test("sign-out leaves dirty local text durable but impossible to register")
    func signOutBlocksDirtyOutbox() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Never upload while signed out",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        let owner = CKRecord.ID(recordName: "signed-in-owner")
        #expect(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: owner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))
        let pending: CKSyncEngine.PendingRecordZoneChange = .saveRecord(CKRecord.ID(
            recordName: local.id,
            zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
        ))
        let state = TestCKSyncPendingState([pending])
        let coordinator = MuesliCKSyncEngine(store: store)

        #expect(try await coordinator.handleAccountChange(currentUser: nil, state: state) == false)
        #expect(state.pendingRecordZoneChanges.isEmpty)
        #expect(try store.hasTextRecordsNeedingSync())
        #expect(try await coordinator.registerNextDirtyBatch(state: state) == 0)
    }

    @Test("same-account zone recreation builds fresh records from requeued local text")
    func sameAccountZoneRecreationRequeuesFreshRecords() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Preserve me across zone recreation",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "deleted-zone-tag",
            systemFields: Data([0x01, 0x02]),
            recordUpdatedAt: local.updatedAt
        ))
        let owner = CKRecord.ID(recordName: "same-owner")
        #expect(try store.claimCloudSyncAccountScope(
            MuesliCKSyncEngine.accountScope(for: owner),
            forKey: MuesliCKSyncEngine.accountScopeKey
        ))
        try store.resetTextRecordCloudMetadataForZoneRecreation()

        let state = TestCKSyncPendingState()
        let coordinator = MuesliCKSyncEngine(store: store)
        #expect(try await coordinator.handleAccountChange(currentUser: owner, state: state))
        let batch = await coordinator.makeRecordBatch(pendingChanges: state.pendingRecordZoneChanges)

        let rebuilt = try #require(batch.recordsToSave.first)
        #expect(rebuilt.recordID.recordName == local.id)
        #expect(rebuilt["text"] as? String == "Preserve me across zone recreation")
        let requeued = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(requeued.cloudChangeTag == nil)
        #expect(requeued.cloudSystemFields == nil)
        #expect(try store.hasTextRecordsNeedingSync())
    }

    @Test("zone recreation repairs metadata even after legacy migration completed")
    func migratedLibraryStillRepairsZoneRecreationDuringPreparation() async throws {
        let store = try makeStore()
        _ = try store.insertDictation(
            text: "Preserve migrated local text",
            durationSeconds: 2,
            startedAt: Date().addingTimeInterval(-2),
            endedAt: Date()
        )
        let local = try #require(try store.textRecordsNeedingSync().first)
        #expect(try store.markTextRecordSynced(
            kind: local.kind,
            recordName: local.id,
            changeTag: "deleted-zone-tag",
            systemFields: Data([0x03, 0x04]),
            recordUpdatedAt: local.updatedAt
        ))
        let suiteName = "MuesliCKSyncEngineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: MuesliICloudSyncEngine.Schema.migratedDefaultZoneKey)
        var migrationRuns = 0

        let recreated = try await MuesliICloudSyncEngine.prepareForCKSyncEngine(
            store: store,
            ensureZone: { true },
            migrate: {
                guard !defaults.bool(
                    forKey: MuesliICloudSyncEngine.Schema.migratedDefaultZoneKey
                ) else { return }
                migrationRuns += 1
            }
        )

        #expect(recreated)
        #expect(migrationRuns == 0)
        let repaired = try #require(try store.textRecordForSync(recordName: local.id))
        #expect(repaired.text == "Preserve migrated local text")
        #expect(repaired.cloudChangeTag == nil)
        #expect(repaired.cloudSystemFields == nil)
        #expect(try store.hasTextRecordsNeedingSync())
    }
}

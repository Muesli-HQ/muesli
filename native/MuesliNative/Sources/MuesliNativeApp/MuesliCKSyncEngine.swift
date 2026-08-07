import CloudKit
import Foundation
import MuesliCore

protocol MuesliCKSyncPendingState: AnyObject, Sendable {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
}

extension CKSyncEngine.State: MuesliCKSyncPendingState {}

enum MuesliCKSyncCycle {
    static func run(
        maximumUploadBatches: Int,
        fetch: () async throws -> Void,
        registerNextBatch: () async throws -> Int,
        uploadedCount: () async -> Int,
        send: () async throws -> Void
    ) async throws {
        try await fetch()

        for _ in 0..<max(maximumUploadBatches, 0) {
            let registered = try await registerNextBatch()
            guard registered > 0 else { break }
            let uploadedBeforeSend = await uploadedCount()
            try await send()
            guard await uploadedCount() > uploadedBeforeSend else { break }
        }
    }
}

struct MuesliCKSyncFailedRecordSave: Sendable {
    let record: CKRecord
    let error: CKError
}

struct MuesliCKSyncRecordBatch: Sendable {
    let recordsToSave: [CKRecord]
    let staleChanges: [CKSyncEngine.PendingRecordZoneChange]
}

/// Owns the single CKSyncEngine instance for Muesli's private text-record zone.
///
/// SQLite's `sync_dirty` flags remain the durable outbox. Before every send we
/// rediscover dirty rows and add their stable record IDs to CKSyncEngine state,
/// so a crash between a local edit and state serialization cannot lose work.
actor MuesliCKSyncEngine: CKSyncEngineDelegate {
    private static var stateKey: String {
        "cksyncengine.private.MuesliSyncZone.\(MuesliICloudSyncEngine.cloudKitEnvironmentKeyComponent).v1"
    }
    private static let subscriptionID = "muesli-cksyncengine-private-v1"
    private static let uploadBatchSize = 200
    private static let maximumUploadBatchesPerSync = 50

    private let store: DictationStore
    private var container: CKContainer?
    private var preflight: MuesliICloudSyncEngine?
    private var engine: CKSyncEngine?
    private var conflictBaseRecords: [CKRecord.ID: CKRecord] = [:]
    private var uploaded = ICloudSyncKindCounts()
    private var downloaded = ICloudSyncKindCounts()

    nonisolated static func isSyncNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }
        return notification.subscriptionID == subscriptionID
    }

    init(
        store: DictationStore,
        container: CKContainer? = nil
    ) {
        self.store = store
        self.container = container
    }

    func sync(forceBridgeDeviceRefresh: Bool = false) async throws -> ICloudSyncResult {
        uploaded = ICloudSyncKindCounts()
        downloaded = ICloudSyncKindCounts()

        let syncZoneWasRecreated = try await prepare(
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )

        let syncEngine = try makeEngineIfNeeded()
        try await MuesliCKSyncCycle.run(
            maximumUploadBatches: Self.maximumUploadBatchesPerSync,
            fetch: {
                let options = CKSyncEngine.FetchChangesOptions(
                    scope: .zoneIDs([MuesliICloudSyncEngine.Schema.syncZoneID])
                )
                try await syncEngine.fetchChanges(options)
            },
            registerNextBatch: {
                try self.registerNextDirtyBatch(state: syncEngine.state)
            },
            uploadedCount: { self.uploaded.total },
            send: {
                let options = CKSyncEngine.SendChangesOptions(
                    scope: .zoneIDs([MuesliICloudSyncEngine.Schema.syncZoneID])
                )
                try await syncEngine.sendChanges(options)
            }
        )

        return ICloudSyncResult(
            uploaded: uploaded,
            downloaded: downloaded,
            hasPendingUploads: try store.hasTextRecordsNeedingSync(),
            syncZoneWasRecreated: syncZoneWasRecreated,
            syncedAt: Date()
        )
    }

    @discardableResult
    func prepare(forceBridgeDeviceRefresh: Bool = false) async throws -> Bool {
        let preflight: MuesliICloudSyncEngine
        if let existing = self.preflight {
            preflight = existing
        } else {
            let created = MuesliICloudSyncEngine(container: resolvedContainer())
            self.preflight = created
            preflight = created
        }
        let syncZoneWasRecreated = try await preflight.prepareForCKSyncEngine(
            store: store,
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
        if syncZoneWasRecreated {
            try store.clearCloudSyncStateData(forKey: Self.stateKey)
            engine = nil
        }

        _ = try makeEngineIfNeeded()
        return syncZoneWasRecreated
    }

    func cancel() async {
        await engine?.cancelOperations()
    }

    private func makeEngineIfNeeded() throws -> CKSyncEngine {
        if let engine { return engine }

        let serialization: CKSyncEngine.State.Serialization?
        if let data = try store.cloudSyncStateData(forKey: Self.stateKey) {
            do {
                serialization = try PropertyListDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } catch {
                // A corrupt engine cursor is recoverable: starting with nil causes a
                // complete private-database replay, while local rows remain intact.
                try store.clearCloudSyncStateData(forKey: Self.stateKey)
                serialization = nil
            }
        } else {
            serialization = nil
        }

        var configuration = CKSyncEngine.Configuration(
            database: resolvedContainer().privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = Self.subscriptionID
        let created = CKSyncEngine(configuration)
        engine = created
        return created
    }

    private func resolvedContainer() -> CKContainer {
        if let container { return container }
        let created = CKContainer(identifier: MuesliICloudSyncEngine.Schema.containerIdentifier)
        container = created
        return created
    }

    func registerNextDirtyBatch(state: any MuesliCKSyncPendingState) throws -> Int {
        let dirtyRecords = try store.textRecordsNeedingSync(limit: Self.uploadBatchSize)
        guard !dirtyRecords.isEmpty else { return 0 }

        let alreadyPending = Set(state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
            guard case .saveRecord(let recordID) = change else { return nil }
            return recordID
        })
        let additions = dirtyRecords.compactMap { record -> CKSyncEngine.PendingRecordZoneChange? in
            let recordID = CKRecord.ID(
                recordName: record.id,
                zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
            )
            guard !alreadyPending.contains(recordID) else { return nil }
            return .saveRecord(recordID)
        }
        state.add(pendingRecordZoneChanges: additions)
        return dirtyRecords.count
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        let batch = makeRecordBatch(pendingChanges: pending)
        if !batch.staleChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: batch.staleChanges)
        }
        guard !batch.recordsToSave.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.recordsToSave)
    }

    func makeRecordBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
    ) -> MuesliCKSyncRecordBatch {
        var recordsToSave: [CKRecord] = []
        var staleChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        for change in pendingChanges {
            guard case .saveRecord(let recordID) = change,
                  recordID.zoneID == MuesliICloudSyncEngine.Schema.syncZoneID else {
                continue
            }
            guard let localRecord = try? store.textRecordForSync(recordName: recordID.recordName) else {
                staleChanges.append(change)
                continue
            }
            let cloudRecord = MuesliICloudSyncEngine.syncZoneCloudRecord(
                from: localRecord,
                baseRecord: conflictBaseRecords[recordID]
            )
            recordsToSave.append(cloudRecord)
        }
        return MuesliCKSyncRecordBatch(
            recordsToSave: recordsToSave,
            staleChanges: staleChanges
        )
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try PropertyListEncoder().encode(update.stateSerialization)
                try store.saveCloudSyncStateData(data, forKey: Self.stateKey)

            case .fetchedRecordZoneChanges(let changes):
                try handleFetchedRecords(
                    changes.modifications.map(\.record),
                    state: syncEngine.state
                )
                // Muesli represents deletion as a saved tombstone. Hard-deletion
                // notifications are intentionally ignored for this record contract.

            case .sentRecordZoneChanges(let changes):
                try handleSentRecordChanges(
                    savedRecords: changes.savedRecords,
                    failedRecordSaves: changes.failedRecordSaves.map {
                        MuesliCKSyncFailedRecordSave(record: $0.record, error: $0.error)
                    },
                    state: syncEngine.state
                )

            case .accountChange(let change):
                conflictBaseRecords.removeAll()
                switch change.changeType {
                case .signIn, .switchAccounts:
                    try handleAccountChange(requiresMetadataReset: true)
                case .signOut:
                    try handleAccountChange(requiresMetadataReset: false)
                @unknown default:
                    break
                }

            case .fetchedDatabaseChanges,
                 .sentDatabaseChanges,
                 .willFetchChanges,
                 .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges,
                 .didFetchChanges,
                 .willSendChanges,
                 .didSendChanges:
                break

            @unknown default:
                break
            }
        } catch {
            // Delegate callbacks cannot throw. Emit only the failure category; no
            // record identifiers or user-authored fields enter diagnostics.
            fputs("[muesli-native] CKSyncEngine event failed: \(String(describing: type(of: error)))\n", stderr)
        }
    }

    func handleFetchedRecords(
        _ cloudRecords: [CKRecord],
        state: any MuesliCKSyncPendingState
    ) throws {
        let records = cloudRecords
            .filter {
                $0.recordID.zoneID == MuesliICloudSyncEngine.Schema.syncZoneID
                    && $0.recordType == MuesliICloudSyncEngine.Schema.textRecordType
            }
            .compactMap(MuesliICloudSyncEngine.syncTextRecord(from:))
        let appliedRecordIDs = Set(try store.upsertSyncedTextRecords(records).map(\.id))
        for record in records {
            if !appliedRecordIDs.contains(record.id) {
                try store.updateTextRecordCloudMetadata(
                    kind: record.kind,
                    recordName: record.id,
                    changeTag: record.cloudChangeTag,
                    systemFields: record.cloudSystemFields
                )
                continue
            }
            downloaded.increment(record.kind)
            state.remove(pendingRecordZoneChanges: [
                .saveRecord(CKRecord.ID(
                    recordName: record.id,
                    zoneID: MuesliICloudSyncEngine.Schema.syncZoneID
                )),
            ])
        }
    }

    func handleSentRecordChanges(
        savedRecords: [CKRecord],
        failedRecordSaves: [MuesliCKSyncFailedRecordSave],
        state: any MuesliCKSyncPendingState
    ) throws {
        for savedRecord in savedRecords {
            guard let syncRecord = MuesliICloudSyncEngine.syncTextRecord(from: savedRecord) else { continue }
            if try store.markTextRecordSynced(
                kind: syncRecord.kind,
                recordName: syncRecord.id,
                changeTag: savedRecord.recordChangeTag,
                systemFields: MuesliICloudSyncEngine.encodedSystemFields(for: savedRecord),
                recordUpdatedAt: syncRecord.updatedAt
            ) {
                uploaded.increment(syncRecord.kind)
            }
            state.remove(pendingRecordZoneChanges: [.saveRecord(savedRecord.recordID)])
            conflictBaseRecords[savedRecord.recordID] = nil
        }

        for failure in failedRecordSaves {
            let recordID = failure.record.recordID
            guard recordID.zoneID == MuesliICloudSyncEngine.Schema.syncZoneID else { continue }
            let pending = CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)

            if failure.error.code == .serverRecordChanged,
               let serverRecord = failure.error.serverRecord,
               let remote = MuesliICloudSyncEngine.syncTextRecord(from: serverRecord),
               let local = try store.textRecordForSync(recordName: recordID.recordName) {
                // The serverRecordChanged error itself proves the saved version is
                // stale, so last-write-wins depends only on Muesli's updatedAt field.
                if remote.updatedAt > local.updatedAt {
                    _ = try store.upsertSyncedTextRecord(remote)
                    state.remove(pendingRecordZoneChanges: [pending])
                } else {
                    conflictBaseRecords[recordID] = serverRecord
                    state.add(pendingRecordZoneChanges: [pending])
                }
            } else {
                // CKSyncEngine decides scheduling/backoff; the durable outbox makes
                // the save discoverable again even if this pending change is dropped.
                state.add(pendingRecordZoneChanges: [pending])
            }
        }
    }

    func handleAccountChange(requiresMetadataReset: Bool) throws {
        conflictBaseRecords.removeAll()
        if requiresMetadataReset {
            try store.resetTextRecordCloudMetadataForAccountChange()
        }
    }
}

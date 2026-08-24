import CloudKit
import CryptoKit
import Foundation
import MuesliCore

protocol MuesliCKSyncPendingState: AnyObject, Sendable {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
}

extension CKSyncEngine.State: MuesliCKSyncPendingState {}

struct MuesliCKSyncIntent: OptionSet, Sendable {
    let rawValue: UInt8

    static let outgoing = Self(rawValue: 1 << 0)
    static let incoming = Self(rawValue: 1 << 1)
    static let manual: Self = [.outgoing, .incoming]
}

struct MuesliCKSyncRequest: Sendable, Equatable {
    let intent: MuesliCKSyncIntent
    let userInitiated: Bool
}

struct MuesliCKSyncRequestQueue: Sendable {
    private(set) var intent: MuesliCKSyncIntent = []
    private(set) var isUserInitiated = false

    var isEmpty: Bool { intent.isEmpty }

    mutating func enqueue(intent: MuesliCKSyncIntent, userInitiated: Bool) {
        self.intent.formUnion(intent)
        isUserInitiated = isUserInitiated || userInitiated
    }

    mutating func consume() -> MuesliCKSyncRequest? {
        guard !intent.isEmpty else { return nil }
        let request = MuesliCKSyncRequest(
            intent: intent,
            userInitiated: isUserInitiated
        )
        reset()
        return request
    }

    mutating func reset() {
        intent = []
        isUserInitiated = false
    }
}

enum MuesliCKSyncOperation {
    static func run(
        intent: MuesliCKSyncIntent,
        maximumUploadBatches: Int,
        prepare: () async throws -> Void,
        registerNextBatch: () async throws -> Int,
        uploadedCount: () async -> Int,
        send: () async throws -> Void,
        fetch: () async throws -> Void
    ) async throws {
        guard !intent.isEmpty else { return }
        try await prepare()

        if intent.contains(.outgoing) {
            for _ in 0..<max(maximumUploadBatches, 0) {
                let registered = try await registerNextBatch()
                guard registered > 0 else { break }
                let uploadedBeforeSend = await uploadedCount()
                try await send()
                guard await uploadedCount() > uploadedBeforeSend else { break }
            }
        }

        if intent.contains(.incoming) {
            try await fetch()
        }
    }
}

struct MuesliCKSyncPreparationState: Sendable {
    private(set) var isPrepared = false

    var requiresPreparation: Bool { !isPrepared }

    mutating func markPrepared() {
        isPrepared = true
    }

    mutating func invalidate() {
        isPrepared = false
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

enum MuesliCKSyncError: Error, Equatable, LocalizedError {
    case differentProductionAccount
    case legacyAccountNeedsReconnection

    var errorDescription: String? {
        switch self {
        case .differentProductionAccount:
            return "This Mac was synced with a different iCloud account. Return to that account, or reset iCloud sync and set it up again."
        case .legacyAccountNeedsReconnection:
            return "This Mac's older sync history needs to be reconnected before it can use your current iCloud account."
        }
    }
}

struct MuesliCKSyncLegacyScopeMigration: Sendable, Equatable {
    let accountScopeKey: String
    let stateKey: String
}

/// Owns the single CKSyncEngine instance for Muesli's private text-record zone.
///
/// SQLite's `sync_dirty` flags remain the durable outbox. Before every send we
/// rediscover dirty rows and add their stable record IDs to CKSyncEngine state,
/// so a crash between a local edit and state serialization cannot lose work.
actor MuesliCKSyncEngine: CKSyncEngineDelegate {
    static var stateKey: String {
        "cksyncengine.private.MuesliSyncZone.\(MuesliICloudSyncEngine.cloudKitEnvironmentKeyComponent).v1"
    }
    static var accountScopeKey: String {
        "cksyncengine.private.MuesliSyncZone.\(MuesliICloudSyncEngine.cloudKitEnvironmentKeyComponent).account-owner.v1"
    }
    static var productionLegacyScopeMigration: MuesliCKSyncLegacyScopeMigration? {
        guard MuesliICloudSyncEngine.cloudKitEnvironmentKeyComponent == "production" else {
            return nil
        }
        return MuesliCKSyncLegacyScopeMigration(
            accountScopeKey: "cksyncengine.private.MuesliSyncZone.unspecified.account-owner.v1",
            stateKey: "cksyncengine.private.MuesliSyncZone.unspecified.v1"
        )
    }
    private static let subscriptionID = "muesli-cksyncengine-private-v1"
    private static let uploadBatchSize = 200
    private static let maximumUploadBatchesPerSync = 50

    private let store: DictationStore
    private let legacyAccountRecordVerifier: (@Sendable (Set<String>) async throws -> Set<String>)?
    private let legacyScopeMigration: MuesliCKSyncLegacyScopeMigration?
    private var container: CKContainer?
    private var preflight: MuesliICloudSyncEngine?
    private var engine: CKSyncEngine?
    private var preparationState = MuesliCKSyncPreparationState()
    private var preparationTask: Task<Bool, Error>?
    private var preparationTaskID: UUID?
    private var preparationGeneration = 0
    private var accountBoundaryBlocked = true
    private var accountBoundaryError = MuesliCKSyncError.differentProductionAccount
    private var conflictBaseRecords: [CKRecord.ID: CKRecord] = [:]
    private var uploaded = ICloudSyncKindCounts()
    private var downloaded = ICloudSyncKindCounts()
    private var bridgeRefreshTask: Task<Void, Never>?
    private var bridgeRefreshForceRequested = false
    private let bridgeRefreshDidFinish: (@MainActor @Sendable () -> Void)?
    private let engineCancellationObserver: @Sendable () async -> Void

    nonisolated static func isSyncNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }
        return notification.subscriptionID == subscriptionID
    }

    init(
        store: DictationStore,
        container: CKContainer? = nil,
        legacyAccountRecordVerifier: (@Sendable (Set<String>) async throws -> Set<String>)? = nil,
        legacyScopeMigration: MuesliCKSyncLegacyScopeMigration? = MuesliCKSyncEngine.productionLegacyScopeMigration,
        bridgeRefreshDidFinish: (@MainActor @Sendable () -> Void)? = nil,
        engineCancellationObserver: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.container = container
        self.legacyAccountRecordVerifier = legacyAccountRecordVerifier
        self.legacyScopeMigration = legacyScopeMigration
        self.bridgeRefreshDidFinish = bridgeRefreshDidFinish
        self.engineCancellationObserver = engineCancellationObserver
    }

    func sendLocalChanges(
        forceBridgeDeviceRefresh: Bool = false
    ) async throws -> ICloudSyncResult {
        try await perform(
            intent: .outgoing,
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
    }

    func fetchRemoteChanges(
        forceBridgeDeviceRefresh: Bool = false
    ) async throws -> ICloudSyncResult {
        try await perform(
            intent: .incoming,
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
    }

    func syncManually(
        forceBridgeDeviceRefresh: Bool = false
    ) async throws -> ICloudSyncResult {
        try await perform(
            intent: .manual,
            forceBridgeDeviceRefresh: forceBridgeDeviceRefresh
        )
    }

    private func perform(
        intent: MuesliCKSyncIntent,
        forceBridgeDeviceRefresh: Bool
    ) async throws -> ICloudSyncResult {
        uploaded = ICloudSyncKindCounts()
        downloaded = ICloudSyncKindCounts()

        try await MuesliCKSyncOperation.run(
            intent: intent,
            maximumUploadBatches: Self.maximumUploadBatchesPerSync,
            prepare: {
                try await self.prepare()
            },
            registerNextBatch: {
                let syncEngine = try self.makeEngineIfNeeded()
                return try self.registerNextDirtyBatch(state: syncEngine.state)
            },
            uploadedCount: { self.uploaded.total },
            send: {
                try await self.runWithZoneRecovery { syncEngine in
                    // Re-registering is a no-op in steady state and restores the
                    // durable SQLite outbox if zone recovery replaced the engine.
                    _ = try self.registerNextDirtyBatch(state: syncEngine.state)
                    let options = CKSyncEngine.SendChangesOptions(
                        scope: .zoneIDs([MuesliICloudSyncEngine.Schema.syncZoneID])
                    )
                    try await syncEngine.sendChanges(options)
                }
            },
            fetch: {
                try await self.runWithZoneRecovery { syncEngine in
                    let options = CKSyncEngine.FetchChangesOptions(
                        scope: .zoneIDs([MuesliICloudSyncEngine.Schema.syncZoneID])
                    )
                    try await syncEngine.fetchChanges(options)
                }
            }
        )
        let result = ICloudSyncResult(
            uploaded: uploaded,
            downloaded: downloaded,
            hasPendingUploads: try store.hasTextRecordsNeedingSync(),
            syncedAt: Date()
        )
        scheduleBridgeDeviceRefresh(forceRefresh: forceBridgeDeviceRefresh)
        return result
    }

    private func runWithZoneRecovery(
        operation: (CKSyncEngine) async throws -> Void
    ) async throws {
        do {
            let syncEngine = try await prepareEngine()
            try await operation(syncEngine)
        } catch {
            if MuesliICloudSyncEngine.isICloudAccountContextError(error) {
                await invalidatePreparation(cancelEngine: true)
                throw error
            }
            guard MuesliICloudSyncEngine.isSyncZoneRecoveryError(error) else {
                throw error
            }

            // The private zone can be deleted while Muesli is running. Recreate it
            // once and retry once; subsequent failures remain CKSyncEngine-managed.
            await invalidatePreparation(cancelEngine: true)
            let syncEngine = try await prepareEngine()
            do {
                try await operation(syncEngine)
            } catch {
                if MuesliICloudSyncEngine.isICloudAccountContextError(error)
                    || MuesliICloudSyncEngine.isSyncZoneRecoveryError(error) {
                    await invalidatePreparation(cancelEngine: true)
                }
                throw error
            }
        }
    }

    func prepare() async throws {
        _ = try await prepareEngine()
    }

    private func prepareEngine() async throws -> CKSyncEngine {
        if !preparationState.requiresPreparation {
            return try makeEngineIfNeeded()
        }

        let generation = preparationGeneration
        let task: Task<Bool, Error>
        let taskID: UUID
        if let existingTask = preparationTask,
           let existingTaskID = preparationTaskID {
            task = existingTask
            taskID = existingTaskID
        } else {
            let preflight: MuesliICloudSyncEngine
            if let existing = self.preflight {
                preflight = existing
            } else {
                let created = MuesliICloudSyncEngine(container: resolvedContainer())
                self.preflight = created
                preflight = created
            }
            let createdTaskID = UUID()
            let createdTask = Task {
                try await self.performPreparation(preflight: preflight)
            }
            preparationTask = createdTask
            preparationTaskID = createdTaskID
            task = createdTask
            taskID = createdTaskID
        }

        do {
            let syncZoneWasRecreated = try await task.value
            guard preparationGeneration == generation else {
                throw CancellationError()
            }
            if preparationTaskID == taskID {
                preparationTask = nil
                preparationTaskID = nil
                if syncZoneWasRecreated {
                    let engineToCancel = engine
                    engine = nil
                    await engineToCancel?.cancelOperations()
                    try store.clearCloudSyncStateData(forKey: Self.stateKey)
                }
                preparationState.markPrepared()
            }
            guard preparationState.isPrepared else {
                throw CancellationError()
            }
            return try makeEngineIfNeeded()
        } catch {
            if preparationTaskID == taskID {
                preparationTask = nil
                preparationTaskID = nil
            }
            if MuesliICloudSyncEngine.isICloudAccountContextError(error)
                || MuesliICloudSyncEngine.isSyncZoneRecoveryError(error) {
                await invalidatePreparation(cancelEngine: true)
            } else {
                preparationState.invalidate()
            }
            throw error
        }
    }

    private func performPreparation(preflight: MuesliICloudSyncEngine) async throws -> Bool {
        let currentUser = try await resolvedContainer().userRecordID()
        guard try await authorizeAccount(currentUser, preflight: preflight) else {
            if let engine {
                engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
            }
            try store.clearCloudSyncStateData(forKey: Self.stateKey)
            throw accountBoundaryError
        }
        return try await preflight.prepareForCKSyncEngine(store: store)
    }

    /// Explicitly adopts the current private iCloud account for an ambiguous
    /// pre-0.8.3 library. The store transaction preserves authored content and
    /// audio while clearing only account-scoped CloudKit metadata and requeueing
    /// eligible text. A definite Production-owner mismatch remains blocked.
    func reconnectLegacyLibrary() async throws {
        let currentUser = try await resolvedContainer().userRecordID()
        try await reconnectLegacyLibrary(currentUser: currentUser)
        try await prepare()
    }

    @discardableResult
    func reconnectLegacyLibrary(currentUser: CKRecord.ID) async throws -> Bool {
        guard let legacyScopeMigration else {
            throw MuesliCKSyncError.legacyAccountNeedsReconnection
        }

        await invalidatePreparation(cancelEngine: true)
        try Task.checkCancellation()
        let requestedScope = Self.accountScope(for: currentUser)
        let reconnected = try store.reconnectCloudSyncAccountScope(
            expectedScope: requestedScope,
            accountScopeKey: Self.accountScopeKey,
            stateKey: Self.stateKey,
            legacyAccountScopeKey: legacyScopeMigration.accountScopeKey,
            legacyStateKey: legacyScopeMigration.stateKey
        )
        guard reconnected else {
            accountBoundaryBlocked = true
            accountBoundaryError = .differentProductionAccount
            throw accountBoundaryError
        }

        accountBoundaryBlocked = false
        return true
    }

    /// Resets local account ownership and engine metadata after explicit user
    /// confirmation. This is valid for healthy, mismatched, and legacy state:
    /// setup must explicitly claim the currently signed-in account afterward.
    @discardableResult
    func resetCloudSyncAccount() async throws -> Bool {
        await invalidatePreparation(cancelEngine: true)
        try Task.checkCancellation()
        let reset = try store.resetCloudSyncAccountLink(
            accountScopeKey: Self.accountScopeKey,
            stateKey: Self.stateKey,
            legacyAccountScopeKey: legacyScopeMigration?.accountScopeKey,
            legacyStateKey: legacyScopeMigration?.stateKey
        )
        guard reset else { throw accountBoundaryError }

        accountBoundaryBlocked = true
        accountBoundaryError = .legacyAccountNeedsReconnection
        return true
    }

    private func invalidatePreparation(cancelEngine: Bool) async {
        preparationGeneration += 1
        preparationState.invalidate()
        preparationTask?.cancel()
        preparationTask = nil
        preparationTaskID = nil
        guard cancelEngine else { return }
        await engineCancellationObserver()
        let engineToCancel = engine
        engine = nil
        await engineToCancel?.cancelOperations()
    }

    func cancel() async {
        let bridgeTaskToCancel = bridgeRefreshTask
        bridgeRefreshTask = nil
        bridgeRefreshForceRequested = false
        bridgeTaskToCancel?.cancel()
        await invalidatePreparation(cancelEngine: true)
        await bridgeTaskToCancel?.value
    }

    /// Companion-device identity powers onboarding and linked-device labels, but it
    /// is not part of text delivery. Keep its legacy CloudKit operations coalesced
    /// and cancellable without making a successful CKSyncEngine cycle wait for them.
    private func scheduleBridgeDeviceRefresh(forceRefresh: Bool) {
        bridgeRefreshForceRequested = bridgeRefreshForceRequested || forceRefresh
        guard bridgeRefreshTask == nil else { return }

        bridgeRefreshTask = Task { [weak self] in
            await self?.runBridgeDeviceRefreshes()
        }
    }

    func requestBridgeDeviceRefresh() {
        scheduleBridgeDeviceRefresh(forceRefresh: true)
    }

    private func runBridgeDeviceRefreshes() async {
        while !Task.isCancelled {
            let forceRefresh = bridgeRefreshForceRequested
            bridgeRefreshForceRequested = false
            guard let preflight else { break }

            await preflight.refreshBridgeDeviceLink(forceRefresh: forceRefresh)
            guard !Task.isCancelled else { break }
            await bridgeRefreshDidFinish?()
            guard bridgeRefreshForceRequested else { break }
        }
        bridgeRefreshTask = nil
    }

    private func makeEngineIfNeeded() throws -> CKSyncEngine {
        if let engine { return engine }
        guard !accountBoundaryBlocked else { throw accountBoundaryError }

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
        guard !accountBoundaryBlocked else { return 0 }
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
        guard !accountBoundaryBlocked else { return nil }
        let pending = Array(syncEngine.state.pendingRecordZoneChanges.lazy.filter {
            context.options.scope.contains($0)
        }.prefix(Self.uploadBatchSize))
        let batch = makeRecordBatch(pendingChanges: pending)
        if !batch.staleChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: batch.staleChanges)
        }
        guard !batch.recordsToSave.isEmpty else { return nil }
        let recordsByID = Dictionary(
            uniqueKeysWithValues: batch.recordsToSave.map { ($0.recordID, $0) }
        )
        let saveChanges = batch.recordsToSave.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: saveChanges,
            recordProvider: { recordsByID[$0] }
        )
    }

    func makeRecordBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
    ) -> MuesliCKSyncRecordBatch {
        makeRecordBatch(
            pendingChanges: pendingChanges,
            loadRecords: { try store.textRecordsForSync(recordNames: $0) }
        )
    }

    func makeRecordBatch(
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        loadRecords: ([String]) throws -> [String: SyncTextRecord]
    ) -> MuesliCKSyncRecordBatch {
        var recordsToSave: [CKRecord] = []
        var staleChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        let relevantChanges: [(CKSyncEngine.PendingRecordZoneChange, CKRecord.ID)] =
            pendingChanges.compactMap { change in
                guard case .saveRecord(let recordID) = change,
                      recordID.zoneID == MuesliICloudSyncEngine.Schema.syncZoneID else {
                    return nil
                }
                return (change, recordID)
            }
        let localRecords: [String: SyncTextRecord]
        do {
            localRecords = try loadRecords(relevantChanges.map { $0.1.recordName })
        } catch {
            // A transient SQLite read failure must not turn durable pending saves into
            // stale changes. Keep the outbox intact so CKSyncEngine can retry later.
            fputs(
                "[muesli-native] CKSyncEngine local batch read failed: \(String(describing: type(of: error)))\n",
                stderr
            )
            return MuesliCKSyncRecordBatch(recordsToSave: [], staleChanges: [])
        }

        for (change, recordID) in relevantChanges {
            guard let localRecord = localRecords[recordID.recordName] else {
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
                guard !accountBoundaryBlocked else {
                    try store.clearCloudSyncStateData(forKey: Self.stateKey)
                    break
                }
                let data = try PropertyListEncoder().encode(update.stateSerialization)
                try store.saveCloudSyncStateData(data, forKey: Self.stateKey)

            case .fetchedRecordZoneChanges(let changes):
                guard !accountBoundaryBlocked else { break }
                try handleFetchedRecords(
                    changes.modifications.map(\.record),
                    state: syncEngine.state
                )
                // Muesli represents deletion as a saved tombstone. Hard-deletion
                // notifications are intentionally ignored for this record contract.

            case .sentRecordZoneChanges(let changes):
                guard !accountBoundaryBlocked else { break }
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
                    _ = try await handleSignedInAccountChange(state: syncEngine.state) {
                        try await self.resolvedContainer().userRecordID()
                    }
                case .signOut:
                    _ = try await handleAccountChange(
                        currentUser: nil,
                        state: syncEngine.state
                    )
                @unknown default:
                    break
                }

            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: {
                    $0.zoneID == MuesliICloudSyncEngine.Schema.syncZoneID
                }) {
                    // The next external trigger recreates the zone through preflight.
                    // Do not launch sync recursively from a delegate callback.
                    await invalidatePreparation(cancelEngine: false)
                }

            case .didFetchRecordZoneChanges(let changes):
                if changes.zoneID == MuesliICloudSyncEngine.Schema.syncZoneID,
                   let error = changes.error,
                   MuesliICloudSyncEngine.isSyncZoneRecoveryError(error) {
                    await invalidatePreparation(cancelEngine: false)
                }

            case .sentDatabaseChanges,
                 .willFetchChanges,
                 .willFetchRecordZoneChanges,
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

    @discardableResult
    func handleSignedInAccountChange(
        state: any MuesliCKSyncPendingState,
        currentUserProvider: @Sendable () async throws -> CKRecord.ID
    ) async throws -> Bool {
        // CKSyncEngine may continue automatic work while account identity is
        // resolving. Block record provision immediately, then clear old pending
        // state before any fallible CloudKit lookup can suspend or throw.
        accountBoundaryBlocked = true
        _ = try await handleAccountChange(currentUser: nil, state: state)
        let currentUser = try await currentUserProvider()
        return try await handleAccountChange(currentUser: currentUser, state: state)
    }

    @discardableResult
    func handleAccountChange(
        currentUser: CKRecord.ID?,
        state: any MuesliCKSyncPendingState
    ) async throws -> Bool {
        // CKSyncEngine forbids invoking its sync/cancellation methods recursively
        // from a delegate callback. Invalidate preflight only and let this engine
        // finish its account transition; SQLite remains the durable source of work.
        await invalidatePreparation(cancelEngine: false)
        let stalePendingChanges = state.pendingRecordZoneChanges
        if !stalePendingChanges.isEmpty {
            state.remove(pendingRecordZoneChanges: stalePendingChanges)
        }
        try store.clearCloudSyncStateData(forKey: Self.stateKey)
        conflictBaseRecords.removeAll()
        guard let currentUser else {
            accountBoundaryBlocked = true
            return false
        }
        guard try await authorizeAccount(currentUser) else { return false }
        _ = try registerNextDirtyBatch(state: state)
        return true
    }

    /// Hashes the account identifier before it reaches local persistence or logs.
    static func accountScope(for userRecordID: CKRecord.ID) -> String {
        let digest = SHA256.hash(data: Data(userRecordID.recordName.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hasExactAccountProvenance(
        requiredRecordNames: Set<String>,
        matchingRecordNames: Set<String>
    ) -> Bool {
        !requiredRecordNames.isEmpty && matchingRecordNames == requiredRecordNames
    }

    private func authorizeAccount(
        _ userRecordID: CKRecord.ID,
        preflight: MuesliICloudSyncEngine? = nil
    ) async throws -> Bool {
        accountBoundaryBlocked = true
        accountBoundaryError = .legacyAccountNeedsReconnection
        let requestedScope = Self.accountScope(for: userRecordID)

        if let persistedScope = try store.cloudSyncStateData(forKey: Self.accountScopeKey) {
            let matches = persistedScope == Data(requestedScope.utf8)
            accountBoundaryBlocked = !matches
            if !matches {
                accountBoundaryError = .differentProductionAccount
                fputs("[muesli-native] CKSyncEngine account boundary blocked\n", stderr)
            }
            return matches
        }

        if let legacyScopeMigration,
           try store.migrateCloudSyncAccountScope(
               expectedScope: requestedScope,
               fromKey: legacyScopeMigration.accountScopeKey,
               legacyStateKey: legacyScopeMigration.stateKey,
               toKey: Self.accountScopeKey
           ) {
            accountBoundaryBlocked = false
            fputs("[muesli-native] CKSyncEngine repaired legacy environment scope\n", stderr)
            return true
        }

        let legacyRecordNames = try store.textRecordNamesRequiringAccountVerification()
        if !legacyRecordNames.isEmpty {
            let matchingRecordNames: Set<String>
            if let legacyAccountRecordVerifier {
                matchingRecordNames = try await legacyAccountRecordVerifier(legacyRecordNames)
            } else if let preflight {
                matchingRecordNames = try await preflight.matchingSyncZoneTextRecordNames(
                    named: legacyRecordNames
                )
            } else {
                let resolved = self.preflight
                    ?? MuesliICloudSyncEngine(container: resolvedContainer())
                self.preflight = resolved
                matchingRecordNames = try await resolved.matchingSyncZoneTextRecordNames(
                    named: legacyRecordNames
                )
            }
            // One shared stable ID does not prove that the rest of an unscoped
            // library belongs to this account. Every row carrying prior CloudKit
            // evidence must be present as a text record in the current private
            // zone before this process may claim or upload the library.
            guard Self.hasExactAccountProvenance(
                requiredRecordNames: legacyRecordNames,
                matchingRecordNames: matchingRecordNames
            ) else {
                fputs("[muesli-native] CKSyncEngine account provenance unverified\n", stderr)
                return false
            }
        }

        let matches = try store.claimCloudSyncAccountScope(
            requestedScope,
            forKey: Self.accountScopeKey
        )
        accountBoundaryBlocked = !matches
        if !matches {
            accountBoundaryError = .differentProductionAccount
            fputs("[muesli-native] CKSyncEngine account boundary blocked\n", stderr)
        }
        return matches
    }

    func currentAccountBoundaryError() -> MuesliCKSyncError? {
        accountBoundaryBlocked ? accountBoundaryError : nil
    }
}

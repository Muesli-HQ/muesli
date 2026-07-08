import CloudKit
import Foundation
import MuesliCore
import Security

struct ICloudSyncKindCounts: Equatable {
    private(set) var dictations = 0
    private(set) var meetings = 0

    var total: Int {
        dictations + meetings
    }

    mutating func increment(_ kind: SyncTextRecordKind) {
        switch kind {
        case .dictation:
            dictations += 1
        case .meeting:
            meetings += 1
        }
    }
}

struct ICloudSyncResult: Equatable {
    let uploaded: ICloudSyncKindCounts
    let downloaded: ICloudSyncKindCounts
    let hasPendingUploads: Bool
    let syncZoneWasRecreated: Bool
    let syncedAt: Date
}

private struct ICloudZoneChangesPage {
    let records: [CKRecord]
    let serverChangeToken: CKServerChangeToken
    let moreComing: Bool
}

private struct ICloudQueryPage {
    let records: [CKRecord]
    let cursor: CKQueryOperation.Cursor?
}

private struct ICloudChangedRecords {
    let records: [CKRecord]
    let finalToken: CKServerChangeToken?
}

protocol ICloudChangeTokenStore {
    func loadToken() -> CKServerChangeToken?
    func saveToken(_ token: CKServerChangeToken)
    func clearToken()
}

final class UserDefaultsICloudChangeTokenStore: ICloudChangeTokenStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "muesli.icloud.textRecords.MuesliSyncZone.serverChangeToken.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    func saveToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else { return }
        defaults.set(data, forKey: key)
    }

    func clearToken() {
        defaults.removeObject(forKey: key)
    }
}

struct MuesliBridgeDeviceSnapshot: Equatable {
    let deviceID: String
    let platform: String
    let deviceName: String
    let appVersion: String
    let lastSeenAt: Date
}

enum MuesliBridgeDeviceIdentity {
    private static let localDeviceIDKey = "muesli.sync.bridge.localDeviceID.v1"
    private static let localDeviceNameKey = "muesli.sync.bridge.localDeviceName.v1"
    private static let remoteDeviceIDKey = "muesli.sync.bridge.remoteDeviceID.v1"
    private static let remoteDeviceNameKey = "muesli.sync.bridge.remoteDeviceName.v1"
    private static let remoteDevicePlatformKey = "muesli.sync.bridge.remoteDevicePlatform.v1"
    private static let remoteDeviceLastSeenAtKey = "muesli.sync.bridge.remoteDeviceLastSeenAt.v1"
    private static let lastRefreshKey = "muesli.sync.bridge.lastRefreshed.v1"
    private static let lastRefreshFailureKey = "muesli.sync.bridge.lastRefreshFailure.v1"
    private static let linkedRefreshInterval: TimeInterval = 60 * 60
    private static let unlinkedRefreshInterval: TimeInterval = 60
    private static let failureRetryInterval: TimeInterval = 15

    static func local(defaults: UserDefaults = .standard) -> MuesliBridgeDeviceSnapshot {
        let deviceID: String
        if let persisted = defaults.string(forKey: localDeviceIDKey), !persisted.isEmpty {
            deviceID = persisted
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: localDeviceIDKey)
        }

        let deviceName = currentDeviceName()
        if defaults.string(forKey: localDeviceNameKey) != deviceName {
            defaults.set(deviceName, forKey: localDeviceNameKey)
        }
        return MuesliBridgeDeviceSnapshot(
            deviceID: deviceID,
            platform: "macOS",
            deviceName: deviceName,
            appVersion: appVersion(),
            lastSeenAt: Date()
        )
    }

    static var localDeviceDisplayName: String {
        UserDefaults.standard.string(forKey: localDeviceNameKey) ?? currentDeviceName()
    }

    static var remoteDeviceDisplayName: String? {
        UserDefaults.standard.string(forKey: remoteDeviceNameKey)
    }

    static var remoteDevicePlatform: String? {
        UserDefaults.standard.string(forKey: remoteDevicePlatformKey)
    }

    static func shouldRefresh(
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        forceRefresh: Bool = false
    ) -> Bool {
        if forceRefresh {
            return true
        }
        if let lastFailure = defaults.object(forKey: lastRefreshFailureKey) as? Date {
            let lastSuccess = defaults.object(forKey: lastRefreshKey) as? Date
            if lastSuccess.map({ lastFailure > $0 }) ?? true {
                return now.timeIntervalSince(lastFailure) >= failureRetryInterval
            }
        }
        guard let lastRefresh = defaults.object(forKey: lastRefreshKey) as? Date else {
            return true
        }
        let interval = hasCompanionRemoteDevice(defaults: defaults) ? linkedRefreshInterval : unlinkedRefreshInterval
        return now.timeIntervalSince(lastRefresh) >= interval
    }

    static func markRefreshed(defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date, forKey: lastRefreshKey)
        defaults.removeObject(forKey: lastRefreshFailureKey)
    }

    static func markRefreshFailed(defaults: UserDefaults = .standard, at date: Date = Date()) {
        defaults.set(date, forKey: lastRefreshFailureKey)
    }

    static func updateRemoteDevices(from records: [CKRecord], defaults: UserDefaults = .standard) {
        let localID = defaults.string(forKey: localDeviceIDKey) ?? ""
        let remoteDevices = records
            .compactMap(Self.snapshot(from:))
            .filter { $0.deviceID != localID }

        let latestRemote = remoteDevices
            .filter { isCompanionPlatform($0.platform) }
            .max { $0.lastSeenAt < $1.lastSeenAt }

        guard let latestRemote else {
            defaults.removeObject(forKey: remoteDeviceIDKey)
            defaults.removeObject(forKey: remoteDeviceNameKey)
            defaults.removeObject(forKey: remoteDevicePlatformKey)
            defaults.removeObject(forKey: remoteDeviceLastSeenAtKey)
            return
        }

        defaults.set(latestRemote.deviceID, forKey: remoteDeviceIDKey)
        defaults.set(latestRemote.deviceName, forKey: remoteDeviceNameKey)
        defaults.set(latestRemote.platform, forKey: remoteDevicePlatformKey)
        defaults.set(latestRemote.lastSeenAt, forKey: remoteDeviceLastSeenAtKey)
    }

    static func hasCompanionRemoteDevice(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: remoteDeviceIDKey) != nil,
              let platform = defaults.string(forKey: remoteDevicePlatformKey) else {
            return false
        }
        return isCompanionPlatform(platform)
    }

    private static func isCompanionPlatform(_ platform: String) -> Bool {
        switch platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios", "ipados":
            return true
        default:
            return false
        }
    }

    static func snapshot(from record: CKRecord) -> MuesliBridgeDeviceSnapshot? {
        guard let deviceID = record["deviceID"] as? String,
              let platform = record["platform"] as? String,
              let deviceName = record["deviceName"] as? String,
              let lastSeenAt = record["lastSeenAt"] as? Date else {
            return nil
        }
        return MuesliBridgeDeviceSnapshot(
            deviceID: deviceID,
            platform: platform,
            deviceName: deviceName,
            appVersion: record["appVersion"] as? String ?? "unknown",
            lastSeenAt: lastSeenAt
        )
    }

    private static func currentDeviceName() -> String {
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            return name
        }
        let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? "This Mac" : hostName
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? "unknown"
    }
}

private enum ICloudSyncAccountError: LocalizedError {
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    var errorDescription: String? {
        switch self {
        case .noAccount:
            return "Sign in to iCloud on this Mac to sync text records."
        case .restricted:
            return "iCloud is restricted for this Mac."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable. Try syncing again shortly."
        case .couldNotDetermine:
            return "Couldn't determine iCloud account status."
        }
    }
}

final class MuesliICloudSyncEngine {
    private enum Schema {
        static let containerIdentifier = "iCloud.com.mueslihq.muesli"
        static let syncZoneName = "MuesliSyncZone"
        static let textRecordType = "MuesliTextRecord"
        static let bridgeDeviceRecordType = "MuesliBridgeDevice"
        static let textSubscriptionID = "muesli-text-records-sync-zone-v1"
        static let migratedDefaultZoneKey = "muesli.icloud.textRecords.defaultToSyncZoneMigrated.v1"

        static var syncZoneID: CKRecordZone.ID {
            CKRecordZone.ID(zoneName: syncZoneName, ownerName: CKCurrentUserDefaultName)
        }
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let changeTokenStore: ICloudChangeTokenStore
    private let defaults: UserDefaults
    private static let dirtyUploadBatchSize = 200
    private static let maxDirtyUploadBatchesPerSync = 50

    static var hasRequiredEntitlement: Bool {
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
            )
        else {
            return false
        }

        if let containers = value as? [String] {
            return containers.contains(Schema.containerIdentifier)
        }
        if let container = value as? String {
            return container == Schema.containerIdentifier
        }
        return false
    }

    init(
        container: CKContainer = CKContainer(identifier: Schema.containerIdentifier),
        changeTokenStore: ICloudChangeTokenStore = UserDefaultsICloudChangeTokenStore(),
        defaults: UserDefaults = .standard
    ) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.changeTokenStore = changeTokenStore
        self.defaults = defaults
    }

    func sync(
        store: DictationStore,
        forceBridgeDeviceRefresh: Bool = false
    ) async throws -> ICloudSyncResult {
        try await verifyAccountAvailable()
        let syncZoneWasRecreated = try await ensureSyncZone()
        await refreshBridgeDeviceLink(forceRefresh: forceBridgeDeviceRefresh)
        try await migrateDefaultZoneIfNeeded(store: store)

        let remoteChanges = try await fetchChangedTextRecords()
        var downloaded = ICloudSyncKindCounts()
        for record in remoteChanges.records {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            if try store.upsertSyncedTextRecord(syncRecord) {
                downloaded.increment(syncRecord.kind)
            }
        }
        if let finalToken = remoteChanges.finalToken {
            changeTokenStore.saveToken(finalToken)
        }

        let uploadResult = try await uploadDirtyTextRecords(store: store)

        return ICloudSyncResult(
            uploaded: uploadResult.uploaded,
            downloaded: downloaded,
            hasPendingUploads: uploadResult.hasPendingUploads,
            syncZoneWasRecreated: syncZoneWasRecreated,
            syncedAt: Date()
        )
    }

    func ensureTextRecordSubscription() async throws {
        try await verifyAccountAvailable()
        _ = try await ensureSyncZone()
        do {
            _ = try await fetchSubscription(id: Schema.textSubscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            let subscription = CKRecordZoneSubscription(
                zoneID: Schema.syncZoneID,
                subscriptionID: Schema.textSubscriptionID,
            )
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo
            _ = try await save(subscription: subscription)
        }
    }

    static func isTextRecordSubscriptionNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }
        return notification.subscriptionID == Schema.textSubscriptionID
    }

    static func isICloudAccountAvailabilityError(_ error: Error) -> Bool {
        error is ICloudSyncAccountError
    }

    @discardableResult
    func ensureSyncZone() async throws -> Bool {
        do {
            _ = try await fetchZone(id: Schema.syncZoneID)
            return false
        } catch {
            guard Self.isSyncZoneMissing(error) else { throw error }
            _ = try await save(zone: CKRecordZone(zoneName: Schema.syncZoneName))
            changeTokenStore.clearToken()
            defaults.set(false, forKey: Schema.migratedDefaultZoneKey)
            return true
        }
    }

    private func verifyAccountAvailable() async throws {
        let status = try await accountStatus()
        switch status {
        case .available:
            return
        case .noAccount:
            throw ICloudSyncAccountError.noAccount
        case .restricted:
            throw ICloudSyncAccountError.restricted
        case .temporarilyUnavailable:
            throw ICloudSyncAccountError.temporarilyUnavailable
        case .couldNotDetermine:
            throw ICloudSyncAccountError.couldNotDetermine
        @unknown default:
            throw ICloudSyncAccountError.couldNotDetermine
        }
    }

    private func refreshBridgeDeviceLink(forceRefresh: Bool = false) async {
        guard MuesliBridgeDeviceIdentity.shouldRefresh(
            defaults: defaults,
            forceRefresh: forceRefresh
        ) else { return }
        do {
            try await upsertLocalBridgeDeviceRecord()
            let records = try await fetchBridgeDeviceRecords()
            MuesliBridgeDeviceIdentity.updateRemoteDevices(from: records, defaults: defaults)
            MuesliBridgeDeviceIdentity.markRefreshed(defaults: defaults)
        } catch {
            fputs("Failed to refresh iCloud bridge device identity: \(error)\n", stderr)
            MuesliBridgeDeviceIdentity.markRefreshFailed(defaults: defaults)
        }
    }

    private func upsertLocalBridgeDeviceRecord() async throws {
        let snapshot = MuesliBridgeDeviceIdentity.local(defaults: defaults)
        let recordID = CKRecord.ID(
            recordName: "bridge-device-\(snapshot.deviceID)",
            zoneID: Schema.syncZoneID
        )
        let existingRecords = try await fetchExistingRecords(recordIDs: [recordID])
        let record = existingRecords[recordID]
            ?? CKRecord(recordType: Schema.bridgeDeviceRecordType, recordID: recordID)
        if record["createdAt"] == nil {
            record["createdAt"] = Date() as NSDate
        }
        record["deviceID"] = snapshot.deviceID as NSString
        record["platform"] = snapshot.platform as NSString
        record["deviceName"] = snapshot.deviceName as NSString
        record["appVersion"] = snapshot.appVersion as NSString
        record["lastSeenAt"] = snapshot.lastSeenAt as NSDate
        _ = try await save(records: [record])
    }

    private func fetchBridgeDeviceRecords() async throws -> [CKRecord] {
        let query = CKQuery(recordType: Schema.bridgeDeviceRecordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let page = try await fetchBridgeDeviceRecordsPage(query: query, cursor: cursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        } while cursor != nil

        return records
    }

    private func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func fetchChangedTextRecords() async throws -> ICloudChangedRecords {
        try await fetchChangedTextRecordsUsingStoredToken()
    }

    private func fetchChangedTextRecordsUsingStoredToken() async throws -> ICloudChangedRecords {
        var previousToken = changeTokenStore.loadToken()
        var records: [CKRecord] = []
        var finalToken: CKServerChangeToken?
        var retriedExpiredToken = false

        while true {
            let page: ICloudZoneChangesPage
            do {
                page = try await fetchZoneChangesPage(
                    zoneID: Schema.syncZoneID,
                    previousServerChangeToken: previousToken
                )
            } catch {
                guard !retriedExpiredToken, Self.isChangeTokenExpired(error) else { throw error }
                retriedExpiredToken = true
                changeTokenStore.clearToken()
                previousToken = nil
                records.removeAll()
                finalToken = nil
                continue
            }
            records.append(contentsOf: page.records)
            previousToken = page.serverChangeToken
            finalToken = page.serverChangeToken
            if !page.moreComing {
                break
            }
        }

        return ICloudChangedRecords(records: records, finalToken: finalToken)
    }

    private func migrateDefaultZoneIfNeeded(store: DictationStore) async throws {
        guard !defaults.bool(forKey: Schema.migratedDefaultZoneKey) else { return }

        let legacyDefaultZoneRecords = try await fetchAllDefaultZoneTextRecords()
        for record in legacyDefaultZoneRecords {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            _ = try store.upsertSyncedTextRecord(syncRecord)
        }

        changeTokenStore.clearToken()
        let existingSyncZoneChanges = try await fetchChangedTextRecordsUsingStoredToken()
        for record in existingSyncZoneChanges.records {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            _ = try store.upsertSyncedTextRecord(syncRecord)
        }
        if let finalToken = existingSyncZoneChanges.finalToken {
            changeTokenStore.saveToken(finalToken)
        }

        try await uploadLocalMigrationRecords(store: store)

        changeTokenStore.clearToken()
        let primedSyncZoneChanges = try await fetchChangedTextRecordsUsingStoredToken()
        for record in primedSyncZoneChanges.records {
            guard let syncRecord = Self.syncTextRecord(from: record) else { continue }
            _ = try store.upsertSyncedTextRecord(syncRecord)
        }
        if let finalToken = primedSyncZoneChanges.finalToken {
            changeTokenStore.saveToken(finalToken)
        }

        defaults.set(true, forKey: Schema.migratedDefaultZoneKey)
    }

    private func fetchAllDefaultZoneTextRecords() async throws -> [CKRecord] {
        do {
            var cursor: CKQueryOperation.Cursor?
            var records: [CKRecord] = []

            repeat {
                let page = try await fetchTextRecordsPage(cursor: cursor)
                records.append(contentsOf: page.records)
                cursor = page.cursor
            } while cursor != nil

            return records
        } catch {
            guard Self.isMissingLegacyDefaultZoneRecords(error) else { throw error }
            return []
        }
    }

    private func uploadLocalMigrationRecords(store: DictationStore) async throws {
        let batchSize = 500
        for kind in [SyncTextRecordKind.dictation, .meeting] {
            var offset = 0
            while true {
                let records = try store.textRecordsForSyncMigration(
                    kind: kind,
                    limit: batchSize,
                    offset: offset
                )
                guard !records.isEmpty else { break }
                _ = try await saveInBatches(records: records.map { Self.syncZoneCloudRecord(from: $0) })
                offset += records.count
            }
        }
    }

    private func uploadDirtyTextRecords(store: DictationStore) async throws -> (
        uploaded: ICloudSyncKindCounts,
        hasPendingUploads: Bool
    ) {
        var uploaded = ICloudSyncKindCounts()

        for _ in 0..<Self.maxDirtyUploadBatchesPerSync {
            let dirtyRecords = try store.textRecordsNeedingSync(limit: Self.dirtyUploadBatchSize)
            guard !dirtyRecords.isEmpty else {
                return (uploaded, false)
            }

            let uploadRecords = try await cloudRecordsForDirtyUpload(dirtyRecords, store: store)
            let uploadResult = try await saveDirtyUploadRecords(
                uploadRecords,
                originalDirtyRecords: dirtyRecords,
                store: store
            )
            let savedRecords = uploadResult.savedRecords
            let dirtyRecordsByName = uploadResult.dirtyRecordsByName
            guard !savedRecords.isEmpty else {
                return (uploaded, try store.hasTextRecordsNeedingSync())
            }

            var markedRecordCount = 0
            for savedRecord in savedRecords {
                let recordName = savedRecord.recordID.recordName
                guard let kind = Self.kind(from: savedRecord),
                      let dirtyRecord = dirtyRecordsByName[recordName] else { continue }
                uploaded.increment(kind)
                if try store.markTextRecordSynced(
                    kind: kind,
                    recordName: recordName,
                    changeTag: savedRecord.recordChangeTag,
                    recordUpdatedAt: dirtyRecord.updatedAt
                ) {
                    markedRecordCount += 1
                }
            }

            guard markedRecordCount > 0 else {
                return (uploaded, try store.hasTextRecordsNeedingSync())
            }
        }

        return (uploaded, try store.hasTextRecordsNeedingSync())
    }

    private func saveDirtyUploadRecords(
        _ uploadRecords: [CKRecord],
        originalDirtyRecords: [SyncTextRecord],
        store: DictationStore
    ) async throws -> (savedRecords: [CKRecord], dirtyRecordsByName: [String: SyncTextRecord]) {
        do {
            return (
                try await saveInBatches(records: uploadRecords),
                Self.recordsByName(originalDirtyRecords)
            )
        } catch {
            guard Self.isServerRecordChangedError(error) else { throw error }
        }

        let originalRecordIDs = Set(originalDirtyRecords.map(\.id))
        let retryDirtyRecords = try store.textRecordsNeedingSync(limit: Self.dirtyUploadBatchSize)
            .filter { originalRecordIDs.contains($0.id) }
        guard !retryDirtyRecords.isEmpty else {
            return ([], [:])
        }

        let retryUploadRecords = try await cloudRecordsForDirtyUpload(retryDirtyRecords, store: store)
        guard !retryUploadRecords.isEmpty else {
            return ([], Self.recordsByName(retryDirtyRecords))
        }

        return (
            try await saveInBatches(records: retryUploadRecords),
            Self.recordsByName(retryDirtyRecords)
        )
    }

    private func cloudRecordsForDirtyUpload(_ dirtyRecords: [SyncTextRecord], store: DictationStore) async throws -> [CKRecord] {
        let recordIDs = dirtyRecords.map { CKRecord.ID(recordName: $0.id, zoneID: Schema.syncZoneID) }
        let existingRecords = try await fetchExistingRecords(recordIDs: recordIDs)
        var uploadRecords: [CKRecord] = []
        for dirtyRecord in dirtyRecords {
            let recordID = CKRecord.ID(recordName: dirtyRecord.id, zoneID: Schema.syncZoneID)
            guard let existingRecord = existingRecords[recordID] else {
                uploadRecords.append(Self.syncZoneCloudRecord(from: dirtyRecord))
                continue
            }

            if let remoteRecord = Self.syncTextRecord(from: existingRecord),
               Self.shouldApplyFetchedRemoteBeforeDirtyUpload(
                   local: dirtyRecord,
                   remote: remoteRecord,
                   fetchedChangeTag: existingRecord.recordChangeTag
               ) {
                _ = try store.upsertSyncedTextRecord(remoteRecord)
                continue
            }

            uploadRecords.append(Self.syncZoneCloudRecord(from: dirtyRecord, baseRecord: existingRecord))
        }
        return uploadRecords
    }

    private func fetchTextRecordsPage(cursor: CKQueryOperation.Cursor?) async throws -> ICloudQueryPage {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: CKQuery(
                    recordType: Schema.textRecordType,
                    predicate: NSPredicate(value: true)
                ))
            }
            operation.desiredKeys = Self.desiredTextRecordKeys
            operation.resultsLimit = 200

            let lock = NSLock()
            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result {
                    lock.lock()
                    records.append(record)
                    lock.unlock()
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    lock.lock()
                    let pageRecords = records
                    lock.unlock()
                    continuation.resume(returning: ICloudQueryPage(records: pageRecords, cursor: cursor))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchBridgeDeviceRecordsPage(
        query: CKQuery,
        cursor: CKQueryOperation.Cursor?
    ) async throws -> ICloudQueryPage {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: query)
                operation.zoneID = Schema.syncZoneID
            }
            operation.desiredKeys = Self.desiredBridgeDeviceKeys
            operation.resultsLimit = 100

            let lock = NSLock()
            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in
                if case .success(let record) = result,
                   record.recordType == Schema.bridgeDeviceRecordType {
                    lock.lock()
                    records.append(record)
                    lock.unlock()
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    lock.lock()
                    let pageRecords = records
                    lock.unlock()
                    continuation.resume(returning: ICloudQueryPage(records: pageRecords, cursor: cursor))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchZoneChangesPage(
        zoneID: CKRecordZone.ID,
        previousServerChangeToken: CKServerChangeToken?
    ) async throws -> ICloudZoneChangesPage {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousServerChangeToken,
                resultsLimit: nil,
                desiredKeys: Self.desiredTextRecordKeys
            )
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration]
            )
            let lock = NSLock()
            var records: [CKRecord] = []
            var zoneResult: Result<(serverChangeToken: CKServerChangeToken, moreComing: Bool), Error>?

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result,
                   record.recordType == Schema.textRecordType {
                    lock.lock()
                    records.append(record)
                    lock.unlock()
                }
            }
            operation.recordWithIDWasDeletedBlock = { _, _ in
                // Sync contract: Muesli clients must delete text records by writing
                // isDeleted tombstones. Hard CloudKit deletes do not include enough
                // metadata to resolve local conflict state safely, so they are ignored.
            }
            operation.recordZoneFetchResultBlock = { _, result in
                lock.lock()
                defer { lock.unlock() }
                switch result {
                case .success(let page):
                    zoneResult = .success((page.serverChangeToken, page.moreComing))
                case .failure(let error):
                    zoneResult = .failure(error)
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    lock.lock()
                    let pageRecords = records
                    let pageResult = zoneResult
                    lock.unlock()
                    switch pageResult {
                    case .success(let page):
                        continuation.resume(returning: ICloudZoneChangesPage(
                            records: pageRecords,
                            serverChangeToken: page.serverChangeToken,
                            moreComing: page.moreComing
                        ))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .none:
                        continuation.resume(throwing: CKError(.internalError))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchSubscription(id: String) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withSubscriptionID: id) { subscription, error in
                if let subscription {
                    continuation.resume(returning: subscription)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
        }
    }

    private func fetchZone(id: CKRecordZone.ID) async throws -> CKRecordZone {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordZoneID: id) { zone, error in
                if let zone {
                    continuation.resume(returning: zone)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
        }
    }

    private func fetchExistingRecords(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        guard !recordIDs.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            let lock = NSLock()
            var fetchedRecords: [CKRecord.ID: CKRecord] = [:]
            var nonMissingError: Error?

            operation.perRecordResultBlock = { recordID, result in
                lock.lock()
                defer { lock.unlock() }
                switch result {
                case .success(let record):
                    fetchedRecords[recordID] = record
                case .failure(let error):
                    if !Self.isUnknownItemError(error), nonMissingError == nil {
                        nonMissingError = error
                    }
                }
            }

            operation.fetchRecordsResultBlock = { result in
                lock.lock()
                let records = fetchedRecords
                let firstNonMissingError = nonMissingError
                lock.unlock()

                if let firstNonMissingError {
                    continuation.resume(throwing: firstNonMissingError)
                    return
                }

                switch result {
                case .success:
                    continuation.resume(returning: records)
                case .failure(let error):
                    if Self.containsOnlyUnknownItemErrors(error) {
                        continuation.resume(returning: records)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }
    }

    private func save(records: [CKRecord]) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            let lock = NSLock()
            var savedRecords: [CKRecord] = []
            operation.perRecordSaveBlock = { _, result in
                if case .success(let record) = result {
                    lock.lock()
                    savedRecords.append(record)
                    lock.unlock()
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    lock.lock()
                    let records = savedRecords
                    lock.unlock()
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func saveInBatches(records: [CKRecord], batchSize: Int = 200) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }
        var savedRecords: [CKRecord] = []
        var start = records.startIndex
        while start < records.endIndex {
            let end = records.index(start, offsetBy: batchSize, limitedBy: records.endIndex) ?? records.endIndex
            savedRecords.append(contentsOf: try await save(records: Array(records[start..<end])))
            start = end
        }
        return savedRecords
    }

    private func save(subscription: CKSubscription) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.save(subscription) { savedSubscription, error in
                if let savedSubscription {
                    continuation.resume(returning: savedSubscription)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.internalError))
                }
            }
        }
    }

    private func save(zone: CKRecordZone) async throws -> CKRecordZone {
        try await withCheckedThrowingContinuation { continuation in
            database.save(zone) { savedZone, error in
                if let savedZone {
                    continuation.resume(returning: savedZone)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: CKError(.internalError))
                }
            }
        }
    }

    static func syncZoneCloudRecord(from record: SyncTextRecord, baseRecord: CKRecord? = nil) -> CKRecord {
        let recordID = CKRecord.ID(recordName: record.id, zoneID: Schema.syncZoneID)
        let cloud = baseRecord ?? CKRecord(recordType: Schema.textRecordType, recordID: recordID)
        cloud["kind"] = record.kind.rawValue as NSString
        cloud["source"] = record.source as NSString?
        cloud["localSource"] = record.localSource as NSString?
        cloud["meetingStatus"] = record.meetingStatus?.rawValue as NSString?
        cloud["engineIdentifier"] = record.engineIdentifier as NSString?
        cloud["createdAt"] = record.createdAt as NSDate
        cloud["updatedAt"] = record.updatedAt as NSDate
        cloud["startedAt"] = record.startedAt as NSDate?
        cloud["endedAt"] = record.endedAt as NSDate?
        cloud["durationSeconds"] = record.durationSeconds as NSNumber
        cloud["wordCount"] = record.wordCount as NSNumber
        cloud["isDeleted"] = record.isDeleted as NSNumber
        cloud["schemaVersion"] = 1 as NSNumber
        guard !record.isDeleted else {
            cloud["title"] = nil as NSString?
            cloud["text"] = nil as NSString?
            cloud["speakerTranscript"] = nil as NSString?
            cloud["summaryText"] = nil as NSString?
            cloud["manualNotes"] = nil as NSString?
            return cloud
        }
        cloud["title"] = record.title as NSString?
        cloud["text"] = record.text as NSString
        cloud["speakerTranscript"] = record.speakerTranscript as NSString?
        cloud["summaryText"] = record.summaryText as NSString?
        cloud["manualNotes"] = record.manualNotes as NSString?
        return cloud
    }

    static func shouldApplyFetchedRemoteBeforeDirtyUpload(
        local: SyncTextRecord,
        remote: SyncTextRecord,
        fetchedChangeTag: String?
    ) -> Bool {
        fetchedChangeTag != local.cloudChangeTag && remote.updatedAt > local.updatedAt
    }

    private static func syncTextRecord(from record: CKRecord) -> SyncTextRecord? {
        guard let kind = kind(from: record),
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else {
            return nil
        }
        let isDeleted = (record["isDeleted"] as? NSNumber)?.boolValue ?? false
        guard isDeleted || record["text"] is String else {
            return nil
        }
        return SyncTextRecord(
            id: record.recordID.recordName,
            kind: kind,
            title: record["title"] as? String,
            text: (record["text"] as? String) ?? "",
            speakerTranscript: record["speakerTranscript"] as? String,
            summaryText: record["summaryText"] as? String,
            manualNotes: record["manualNotes"] as? String,
            source: record["source"] as? String,
            localSource: record["localSource"] as? String,
            meetingStatus: (record["meetingStatus"] as? String).flatMap(MeetingStatus.init(rawValue:)),
            engineIdentifier: record["engineIdentifier"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: record["startedAt"] as? Date,
            endedAt: record["endedAt"] as? Date,
            durationSeconds: (record["durationSeconds"] as? NSNumber)?.doubleValue ?? 0,
            wordCount: (record["wordCount"] as? NSNumber)?.intValue ?? 0,
            isDeleted: isDeleted,
            cloudChangeTag: record.recordChangeTag
        )
    }

    private static func kind(from record: CKRecord) -> SyncTextRecordKind? {
        guard let raw = record["kind"] as? String else { return nil }
        return SyncTextRecordKind(rawValue: raw)
    }

    private static func isSyncZoneMissing(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            if ckError.code == .unknownItem {
                return true
            }
            if ckError.code == .partialFailure,
               ckError.partialErrorsByItemID?.values.contains(where: { partialError in
                   (partialError as? CKError)?.code == .unknownItem
               }) == true {
                return true
            }
        }

        let nsError = error as NSError
        let message = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion,
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return message.contains(Schema.syncZoneName.lowercased())
            && (message.contains("zone not found") || message.contains("zone does not exist"))
    }

    private static func isUnknownItemError(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            return ckError.code == .unknownItem
        }
        return false
    }

    private static func containsOnlyUnknownItemErrors(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .unknownItem {
            return true
        }
        if ckError.code == .partialFailure,
           let partialErrors = ckError.partialErrorsByItemID,
           !partialErrors.isEmpty {
            return partialErrors.values.allSatisfy(isUnknownItemError)
        }
        return false
    }

    private static func recordsByName(_ records: [SyncTextRecord]) -> [String: SyncTextRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    static func isServerRecordChangedError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .serverRecordChanged {
            return true
        }
        if ckError.code == .partialFailure,
           ckError.partialErrorsByItemID?.values.contains(where: isServerRecordChangedError) == true {
            return true
        }
        return false
    }

    static func isChangeTokenExpired(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            if ckError.code == .changeTokenExpired {
                return true
            }
            if ckError.code == .partialFailure,
               ckError.partialErrorsByItemID?.values.contains(where: isChangeTokenExpired) == true {
                return true
            }
        }
        let nsError = error as NSError
        return nsError.domain == CKError.errorDomain
            && nsError.code == CKError.Code.changeTokenExpired.rawValue
    }

    private static func isMissingLegacyDefaultZoneRecords(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            if isIgnorableLegacyDefaultZoneCode(ckError.code) {
                return true
            }
            if ckError.code == .partialFailure,
               ckError.partialErrorsByItemID?.values.contains(where: isMissingLegacyDefaultZoneRecords) == true {
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain,
           isIgnorableLegacyDefaultZoneCode(CKError.Code(rawValue: nsError.code)) {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingLegacyDefaultZoneRecords(underlyingError)
        }
        return false
    }

    private static func isIgnorableLegacyDefaultZoneCode(_ code: CKError.Code?) -> Bool {
        switch code {
        case .unknownItem, .serverRejectedRequest, .invalidArguments, .zoneNotFound:
            return true
        default:
            return false
        }
    }

    private static var desiredTextRecordKeys: [CKRecord.FieldKey] {
        [
            "kind",
            "title",
            "text",
            "speakerTranscript",
            "summaryText",
            "manualNotes",
            "source",
            "localSource",
            "meetingStatus",
            "engineIdentifier",
            "createdAt",
            "updatedAt",
            "startedAt",
            "endedAt",
            "durationSeconds",
            "wordCount",
            "isDeleted",
            "schemaVersion",
        ]
    }

    private static var desiredBridgeDeviceKeys: [CKRecord.FieldKey] {
        [
            "deviceID",
            "platform",
            "deviceName",
            "appVersion",
            "lastSeenAt",
        ]
    }
}

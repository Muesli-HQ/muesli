import Foundation
import MuesliCore

struct MeetingSpeakerLabelingTracks: Sendable {
    let channels: [MeetingSpeakerKey.Channel: [MeetingLiveSpeakerSegment]]
    let ownerCluster: String?
}
enum MeetingSpeakerLabelingPolicy {
    static func shouldStage(diarizerAvailable: Bool, sourceCount: Int) -> Bool {
        diarizerAvailable && sourceCount > 0
    }
}

struct MeetingSpeakerLabelingStartRequest: Sendable, Equatable {
    let meetingID: Int64
    let retry: Bool
}
struct MeetingSpeakerLabelingStartQueue {
    private var retriesByMeetingID: [Int64: Bool] = [:]
    var hasPending: Bool { !retriesByMeetingID.isEmpty }

    mutating func enqueue(meetingID: Int64, retry: Bool) {
        retriesByMeetingID[meetingID] = (retriesByMeetingID[meetingID] ?? false) || retry
    }

    mutating func takeReady(
        captureIsActive: Bool,
        interactiveAudioIsActive: Bool,
        activeMeetingIDs: Set<Int64> = []
    ) -> [MeetingSpeakerLabelingStartRequest] {
        guard !captureIsActive, !interactiveAudioIsActive, activeMeetingIDs.isEmpty,
              let meetingID = retriesByMeetingID.keys.min(),
              let retry = retriesByMeetingID.removeValue(forKey: meetingID) else { return [] }
        return [MeetingSpeakerLabelingStartRequest(meetingID: meetingID, retry: retry)]
    }
}

enum MeetingSpeakerLabelingOutcome: Sendable { case complete(MeetingSpeakerLabelingTracks), failed, timedOut }

struct MeetingSpeakerRecoveryRecord: Codable, Sendable, Equatable {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    let meetingID: Int64
    let sourcePaths: [String]
    let stagedDescriptor: MeetingSpeakerBacklogDescriptor?
    let expiresAt: Date?

    init(meetingID: Int64, sourcePaths: [String], stagedDescriptor: MeetingSpeakerBacklogDescriptor? = nil,
         expiresAt: Date? = nil) {
        self.meetingID = meetingID
        self.sourcePaths = sourcePaths
        self.stagedDescriptor = stagedDescriptor
        self.expiresAt = expiresAt
    }

    var urls: [URL] { sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var hasRecoverableAudio: Bool { !sourcePaths.isEmpty || stagedDescriptor != nil }
    func isExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } == true }

    func preserves(_ candidate: URL) -> Bool {
        Self.preserves(candidate, sourceURLs: urls)
    }

    static func preserves(_ candidate: URL, sourceURLs: [URL]) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return sourceURLs.contains { source in
            let sourceComponents = source.pathComponents
            return candidateComponents.count <= sourceComponents.count
                && sourceComponents.starts(with: candidateComponents)
        }
    }
}

/// One unstructured worker per descriptor. A timeout removes only its waiter; it never joins native cancellation.
actor MeetingSpeakerLabelingService {
    static let shared = MeetingSpeakerLabelingService()
    private struct Entry {
        var result: MeetingSpeakerLabelingOutcome?
        var waiters: [UUID: CheckedContinuation<MeetingSpeakerLabelingOutcome, Never>] = [:]
        var retire: (@Sendable () -> Void)?
    }
    private var entries: [UUID: Entry] = [:]
    func wait(id: UUID, timeout: Duration? = nil, retry: Bool = false,
              operation: @escaping @Sendable () async throws -> MeetingSpeakerLabelingTracks) async -> MeetingSpeakerLabelingOutcome {
        if retry, case .failed? = entries[id]?.result { entries[id] = nil }
        if entries[id] == nil {
            entries[id] = Entry()
            Task { [weak self] in
                let result: MeetingSpeakerLabelingOutcome
                do { result = .complete(try await operation()) } catch { result = .failed }
                await self?.completed(id: id, result: result)
            }
        }
        if let result = entries[id]?.result { return result }
        let waiter = UUID()
        return await withCheckedContinuation { continuation in
            entries[id]?.waiters[waiter] = continuation
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expire(id: id, waiter: waiter)
                }
            }
        }
    }
    func retire(id: UUID, cleanup: @escaping @Sendable () -> Void) {
        guard var entry = entries[id] else { cleanup(); return }
        for waiter in entry.waiters.values { waiter.resume(returning: .failed) }; entry.waiters.removeAll()
        if entry.result != nil { entries[id] = nil; cleanup() }
        else {
            if let existing = entry.retire {
                entry.retire = { existing(); cleanup() }
            } else { entry.retire = cleanup }
            entries[id] = entry
        }
    }
    func retire(ids: Set<UUID>, cleanup: @escaping @Sendable () -> Void) {
        guard !ids.isEmpty else { cleanup(); return }
        let barrier = MeetingSpeakerRetirementBarrier(count: ids.count, cleanup: cleanup)
        for id in ids { retire(id: id) { barrier.finish() } }
    }
    func retireUnreferencedStaging(_ audio: MeetingSpeakerBacklogAudio, preserving ids: Set<UUID>, olderThan cutoff: Date) {
        for descriptor in audio.storedStagedDescriptors(olderThan: cutoff) where !ids.contains(descriptor.id) {
            retire(id: descriptor.id) { audio.discard(descriptor) }
        }
    }
    private func completed(id: UUID, result: MeetingSpeakerLabelingOutcome) {
        guard let entry = entries[id] else { return }
        for waiter in entry.waiters.values { waiter.resume(returning: result) }
        if let cleanup = entry.retire { entries[id] = nil; cleanup() }
        else { entries[id]?.result = result; entries[id]?.waiters.removeAll() }
    }
    private func expire(id: UUID, waiter: UUID) { entries[id]?.waiters.removeValue(forKey: waiter)?.resume(returning: .timedOut) }
}

private final class MeetingSpeakerRetirementBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let cleanup: @Sendable () -> Void
    init(count: Int, cleanup: @escaping @Sendable () -> Void) { remaining = count; self.cleanup = cleanup }
    func finish() {
        let shouldClean = lock.withLock { () -> Bool in
            remaining -= 1
            return remaining == 0
        }
        if shouldClean { cleanup() }
    }
}

func retireDeletedSpeakerLabelingJobs(_ jobs: [MeetingSpeakerLabelingJob]) {
    for (meetingID, meetingJobs) in Dictionary(grouping: jobs, by: \.meetingID) {
        let audio = MeetingSpeakerBacklogAudio()
        let descriptors = meetingJobs.map(\.pending.audio)
        Task {
            await MeetingSpeakerLabelingService.shared.retire(ids: Set(descriptors.map(\.id)), cleanup: {
                for descriptor in descriptors { audio.discard(descriptor) }
                try? audio.discardRecoverySources(meetingID: meetingID, fallbackDescriptors: descriptors)
            })
        }
    }
}

func retireDeletedSpeakerRecoveryRecords(_ records: [MeetingSpeakerRecoveryRecord]) {
    for recovery in records {
        let audio = MeetingSpeakerBacklogAudio()
        let descriptors = recovery.stagedDescriptor.map { [$0] } ?? []
        Task {
            await MeetingSpeakerLabelingService.shared.retire(ids: Set(descriptors.map(\.id)), cleanup: {
                try? audio.discardRecoverySources(meetingID: recovery.meetingID,
                                                  fallbackSources: recovery.urls,
                                                  fallbackDescriptors: descriptors)
            })
        }
    }
}

struct MeetingSpeakerBacklogAudio: Sendable {
    let root: URL
    let allowedRecoveryRoots: [URL]
    init(
        root: URL = AppIdentity.supportDirectoryURL.appendingPathComponent("SpeakerBacklog", isDirectory: true),
        allowedRecoveryRoots: [URL] = MeetingSpeakerBacklogAudio.defaultRecoveryRoots
    ) {
        self.root = root.standardizedFileURL
        self.allowedRecoveryRoots = allowedRecoveryRoots.map(\.standardizedFileURL)
    }
    static var defaultRecoveryRoots: [URL] {
        [
            FileManager.default.temporaryDirectory.appendingPathComponent("muesli-system-audio", isDirectory: true),
            FileManager.default.temporaryDirectory.appendingPathComponent(MeetingSession.micDiarizationDirectoryName, isDirectory: true)
        ]
    }

    func recordRecoverySources(
        meetingID: Int64,
        sources: [URL],
        now: Date = Date()
    ) throws -> MeetingSpeakerRecoveryRecord {
        guard meetingID > 0, !sources.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let validated = try sources.map(validateRecoverySource).sorted { $0.path < $1.path }
        guard Set(validated.map(\.path)).count == validated.count else { throw CocoaError(.fileReadCorruptFile) }
        let existing = readRecoveryRecord(meetingID: meetingID)
        let existingSources = existing?.urls.compactMap { try? validateRecoverySource($0) } ?? []
        let existingDescriptor = existing?.stagedDescriptor
            .flatMap { isStoredBacklogDescriptor($0) ? $0 : nil }
        return try writeRecoveryRecord(.init(
            meetingID: meetingID,
            sourcePaths: Array(Set(existingSources + validated).map(\.path)).sorted(),
            stagedDescriptor: existingDescriptor,
            expiresAt: existing?.expiresAt ?? now.addingTimeInterval(MeetingSpeakerRecoveryRecord.retentionInterval)
        ))
    }

    func recordRecoveryDescriptor(
        meetingID: Int64,
        descriptor: MeetingSpeakerBacklogDescriptor,
        now: Date = Date()
    ) throws -> MeetingSpeakerRecoveryRecord {
        guard meetingID > 0, isStoredBacklogDescriptor(descriptor) else { throw CocoaError(.fileReadCorruptFile) }
        let existing = readRecoveryRecord(meetingID: meetingID)
        let sources = existing?.urls.compactMap { try? validateRecoverySource($0) } ?? []
        return try writeRecoveryRecord(.init(
            meetingID: meetingID,
            sourcePaths: Array(Set(sources.map(\.path))).sorted(),
            stagedDescriptor: descriptor,
            expiresAt: existing?.expiresAt ?? now.addingTimeInterval(MeetingSpeakerRecoveryRecord.retentionInterval)
        ))
    }

    func recoveryRecords() -> [MeetingSpeakerRecoveryRecord] {
        (try? recoveryRecordsThrowing()) ?? []
    }

    func recoveryRecordsThrowing() throws -> [MeetingSpeakerRecoveryRecord] {
        do {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink == false else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard values.isDirectory == true, attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        } catch {
            if isConfirmedMissingPath(error) { return [] }
            throw error
        }
        let manifests = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var records: [MeetingSpeakerRecoveryRecord] = []
        for manifest in manifests where manifest.lastPathComponent.hasPrefix("recovery-sources-") && manifest.pathExtension == "json" {
            guard isRegularNonSymlink(manifest) else { throw CocoaError(.fileReadUnsupportedScheme) }
            let decoded = try JSONDecoder().decode(MeetingSpeakerRecoveryRecord.self, from: Data(contentsOf: manifest))
            let record = try applyingLegacyExpiry(to: decoded, manifest: manifest)
            guard record.meetingID > 0,
                  manifest.lastPathComponent == recoveryManifestURL(meetingID: record.meetingID).lastPathComponent else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let candidates = record.sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            guard Set(candidates.map(\.path)).count == candidates.count else { throw CocoaError(.fileReadCorruptFile) }
            let validated = try candidates.compactMap { try validateRecoverySourceIfPresent($0) }
            let stagedDescriptor: MeetingSpeakerBacklogDescriptor?
            if let candidate = record.stagedDescriptor {
                stagedDescriptor = try storedBacklogDescriptorIfPresent(candidate)
            } else {
                stagedDescriptor = nil
            }
            // Discard may remove an audio file before it removes its manifest.
            // Keep an empty record so history cleanup can retire the stale manifest.
            records.append(.init(meetingID: record.meetingID, sourcePaths: validated.map(\.path),
                                 stagedDescriptor: stagedDescriptor, expiresAt: record.expiresAt))
        }
        return records.sorted { $0.meetingID < $1.meetingID }
    }

    func discardRecoverySources(
        meetingID: Int64,
        fallbackSources: [URL] = [],
        fallbackDescriptors: [MeetingSpeakerBacklogDescriptor] = []
    ) throws {
        if FileManager.default.fileExists(atPath: root.path), !isDirectoryNonSymlink(root) {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let manifest = recoveryManifestURL(meetingID: meetingID)
        var sources = fallbackSources
        var descriptors = fallbackDescriptors
        if let record = readRecoveryRecord(meetingID: meetingID) {
            sources.append(contentsOf: record.urls)
            if let descriptor = record.stagedDescriptor { descriptors.append(descriptor) }
        }
        for candidate in Set(sources.map(\.standardizedFileURL)) {
            guard let source = try? validateRecoverySource(candidate) else { continue }
            try FileManager.default.removeItem(at: source)
        }
        var discardedIDs: Set<UUID> = []
        for descriptor in descriptors where discardedIDs.insert(descriptor.id).inserted {
            try removeBacklogFolder(descriptor)
        }
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard isRegularNonSymlink(manifest) else { throw CocoaError(.fileReadUnsupportedScheme) }
            try FileManager.default.removeItem(at: manifest)
        }
    }

    private func ensureRoot() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            guard isDirectoryNonSymlink(root) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func validateRecoverySource(_ candidate: URL) throws -> URL {
        let source = candidate.standardizedFileURL
        guard allowedRecoveryRoots.contains(where: { $0.path == source.deletingLastPathComponent().path }),
              isRegularNonSymlink(source) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return source
    }

    private func validateRecoverySourceIfPresent(_ candidate: URL) throws -> URL? {
        let source = candidate.standardizedFileURL
        guard allowedRecoveryRoots.contains(where: { $0.path == source.deletingLastPathComponent().path }) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard values.isRegularFile == true, attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return source
        } catch {
            if isConfirmedMissingPath(error) { return nil }
            throw error
        }
    }

    private func storedBacklogDescriptorIfPresent(_ descriptor: MeetingSpeakerBacklogDescriptor) throws -> MeetingSpeakerBacklogDescriptor? {
        guard !descriptor.channels.isEmpty, !descriptor.channels.contains(.imported) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = folder(descriptor)
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink == false else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard values.isDirectory == true, attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        } catch {
            if isConfirmedMissingPath(error) { return nil }
            throw error
        }
        let marker = directory.appendingPathComponent("recovery.json")
        guard isRegularNonSymlink(marker) else { throw CocoaError(.fileReadCorruptFile) }
        let stored: MeetingSpeakerBacklogDescriptor
        do {
            stored = try JSONDecoder().decode(MeetingSpeakerBacklogDescriptor.self, from: Data(contentsOf: marker))
        } catch {
            if isConfirmedMissingPath(error) { throw CocoaError(.fileReadCorruptFile) }
            throw error
        }
        guard stored == descriptor else { throw CocoaError(.fileReadCorruptFile) }
        return descriptor
    }

    private func isConfirmedMissingPath(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 2 { return true } // ENOENT
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return isConfirmedMissingPath(underlying)
        }
        return false
    }

    private func isRegularNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func isDirectoryNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isSymbolicLink == false, values.isDirectory == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private func recoveryManifestURL(meetingID: Int64) -> URL {
        root.appendingPathComponent("recovery-sources-\(meetingID).json")
    }

    private func readRecoveryRecord(meetingID: Int64) -> MeetingSpeakerRecoveryRecord? {
        let manifest = recoveryManifestURL(meetingID: meetingID)
        guard isDirectoryNonSymlink(root), FileManager.default.fileExists(atPath: manifest.path), isRegularNonSymlink(manifest),
              let record = try? JSONDecoder().decode(MeetingSpeakerRecoveryRecord.self, from: Data(contentsOf: manifest)),
              record.meetingID == meetingID else { return nil }
        return try? applyingLegacyExpiry(to: record, manifest: manifest)
    }

    private func applyingLegacyExpiry(
        to record: MeetingSpeakerRecoveryRecord,
        manifest: URL
    ) throws -> MeetingSpeakerRecoveryRecord {
        guard record.expiresAt == nil else { return record }
        let attributes = try FileManager.default.attributesOfItem(atPath: manifest.path)
        guard let modified = attributes[.modificationDate] as? Date else { throw CocoaError(.fileReadCorruptFile) }
        return .init(
            meetingID: record.meetingID,
            sourcePaths: record.sourcePaths,
            stagedDescriptor: record.stagedDescriptor,
            expiresAt: modified.addingTimeInterval(MeetingSpeakerRecoveryRecord.retentionInterval)
        )
    }

    private func writeRecoveryRecord(_ record: MeetingSpeakerRecoveryRecord) throws -> MeetingSpeakerRecoveryRecord {
        try ensureRoot()
        let manifest = recoveryManifestURL(meetingID: record.meetingID)
        if FileManager.default.fileExists(atPath: manifest.path), !isRegularNonSymlink(manifest) {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try JSONEncoder().encode(record).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        return record
    }

    private func isStoredBacklogDescriptor(_ descriptor: MeetingSpeakerBacklogDescriptor) -> Bool {
        guard !descriptor.channels.isEmpty, !descriptor.channels.contains(.imported) else { return false }
        let directory = folder(descriptor)
        guard isDirectoryNonSymlink(root), isDirectoryNonSymlink(directory) else { return false }
        let marker = directory.appendingPathComponent("recovery.json")
        guard isRegularNonSymlink(marker),
              let stored = try? JSONDecoder().decode(MeetingSpeakerBacklogDescriptor.self, from: Data(contentsOf: marker)) else { return false }
        return stored == descriptor
    }

    private func removeBacklogFolder(_ descriptor: MeetingSpeakerBacklogDescriptor) throws {
        let directory = folder(descriptor)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard isDirectoryNonSymlink(root), isDirectoryNonSymlink(directory) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try FileManager.default.removeItem(at: directory)
    }
    func stage(_ sources: [MeetingSpeakerKey.Channel: URL]) throws -> MeetingSpeakerBacklogDescriptor {
        guard !sources.isEmpty, sources.keys.allSatisfy({ $0 != .imported }) else { throw CocoaError(.fileNoSuchFile) }
        try ensureRoot()
        let descriptor = MeetingSpeakerBacklogDescriptor(channels: Set(sources.keys))
        let directory = folder(descriptor)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        do {
            try JSONEncoder().encode(descriptor).write(to: directory.appendingPathComponent("recovery.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("recovery.json").path)
            for (channel, source) in sources {
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
                let target = directory.appendingPathComponent(channel.rawValue + ".wav")
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
                defer { try? input.close(); try? output.close() }
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
                try output.synchronize()
            }
        } catch {
            discard(descriptor)
            throw error
        }
        return descriptor
    }
    func urls(_ descriptor: MeetingSpeakerBacklogDescriptor) throws -> [MeetingSpeakerKey.Channel: URL] {
        guard !descriptor.channels.isEmpty, !descriptor.channels.contains(.imported) else { throw CocoaError(.fileReadCorruptFile) }
        for directory in [root, folder(descriptor)] {
            guard isDirectoryNonSymlink(directory) else { throw CocoaError(.fileReadUnsupportedScheme) }
        }
        return try Dictionary(uniqueKeysWithValues: descriptor.channels.map { channel in
            let url = folder(descriptor).appendingPathComponent(channel.rawValue + ".wav")
            guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnsupportedScheme) }
            return (channel, url)
        })
    }
    func cleanAbandonedStaging(now: Date = Date()) {
        guard isDirectoryNonSymlink(root),
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for child in children {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  isDirectoryNonSymlink(child),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) > 86_400,
                  !FileManager.default.fileExists(atPath: child.appendingPathComponent("recovery.json").path) else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
    func storedStagedDescriptors(olderThan cutoff: Date? = nil) -> [MeetingSpeakerBacklogDescriptor] {
        guard isDirectoryNonSymlink(root),
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return children.compactMap { child in
            guard let id = UUID(uuidString: child.lastPathComponent), isDirectoryNonSymlink(child) else { return nil }
            if let cutoff {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                      let modified = attributes[.modificationDate] as? Date, modified < cutoff else { return nil }
            }
            let marker = child.appendingPathComponent("recovery.json")
            guard isRegularNonSymlink(marker),
                  let descriptor = try? JSONDecoder().decode(MeetingSpeakerBacklogDescriptor.self, from: Data(contentsOf: marker)),
                  descriptor.id == id, isStoredBacklogDescriptor(descriptor) else { return nil }
            return descriptor
        }
    }
    func discard(_ descriptor: MeetingSpeakerBacklogDescriptor) {
        discard(id: descriptor.id)
    }
    func discard(id: UUID) {
        // Descriptor UUIDs cannot escape this owned directory. Refuse replaced directory symlinks.
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard isDirectoryNonSymlink(root), isDirectoryNonSymlink(directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    private func folder(_ descriptor: MeetingSpeakerBacklogDescriptor) -> URL { root.appendingPathComponent(descriptor.id.uuidString, isDirectory: true) }
}

struct MeetingSpeakerRecoverySnapshot: Sendable {
    let jobs: [MeetingSpeakerLabelingJob]
    let expired: [MeetingSpeakerLabelingJob]
    let liveMeetingIDs: Set<Int64>
    let recoveries: [MeetingSpeakerRecoveryRecord]
    let expiredRecoveries: [MeetingSpeakerRecoveryRecord]

    static func load(databaseURL: URL, audio: MeetingSpeakerBacklogAudio, now: Date = Date()) throws -> Self {
        let store = DictationStore(databaseURL: databaseURL)
        // Complete every fallible read before expiring rows or allowing cleanup.
        let originalJobs = try store.meetingSpeakerLabelingJobs()
        let liveMeetingIDs = try store.undeletedMeetingIDs()
        let allRecoveries = try audio.recoveryRecordsThrowing()
        let expiredRecoveries = allRecoveries.filter { $0.isExpired(at: now) }
        let recoveries = allRecoveries.filter { !$0.isExpired(at: now) }
        let expired = try store.expireStaleMeetingSpeakerLabelingJobs(now: now)
        let expiredByID = Dictionary(uniqueKeysWithValues: expired.map { ($0.pending.audio.id, $0) })
        let jobs = originalJobs.map { expiredByID[$0.pending.audio.id] ?? $0 }
        return Self(jobs: jobs, expired: expired, liveMeetingIDs: liveMeetingIDs,
                    recoveries: recoveries, expiredRecoveries: expiredRecoveries)
    }
}

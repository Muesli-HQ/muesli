import CoreML
import CryptoKit
import FluidAudio
import Foundation
import MuesliCore

/// Installs the portable Orukeet preview in its own cache. Network access happens only on installation.
enum OrukeetModelStore {
    static let revision = "43142dd1897f9ddadcd70173fcb5ff45c08aa951"
    static let archiveSHA256 = "b2a6efc4ed3280c860f29b3e2e2ea242ade14c6482c94f1c8d3e8551d5edb626"
    static let archiveBytes = 466_579_851
    static let components = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
    static let modelID = "oruk/orukeet"
    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/orukeet-coreml-43142dd1", isDirectory: true)
    }
    static var directory: URL { cacheDirectory.appendingPathComponent("compiled", isDirectory: true) }
    static var plan: ManagedASRModelPlan {
        ManagedASRModelPlan(
            modelID: modelID, repository: modelID, revision: revision,
            cacheDirectory: cacheDirectory.appendingPathComponent("download", isDirectory: true),
            selections: [.init(remoteDirectory: "coreml", includedPaths: [
                "manifest.json", "orukeet-r3-coreml-baseline.zip",
            ], recursive: false)],
            requiredArtifactAlternatives: [["manifest.json"], ["orukeet-r3-coreml-baseline.zip"]],
            maximumConcurrency: 1)
    }

    static var isInstalled: Bool {
        installed(at: directory)
    }

    static func installed(at directory: URL) -> Bool {
        let stamp = try? String(
            contentsOf: directory.appendingPathComponent(".revision"), encoding: .utf8)
        return stamp == revision
            && components.allSatisfy { name in
                let compiled = directory.appendingPathComponent("\(name).mlmodelc")
                return fileHasContents(compiled.appendingPathComponent("coremldata.bin"))
                    && fileHasContents(compiled.appendingPathComponent("weights/weight.bin"))
            } && fileHasContents(directory.appendingPathComponent("parakeet_vocab.json"))
    }

    private static func fileHasContents(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    struct Manifest: Decodable {
        struct Archive: Decodable {
            let filename: String
            let bytes: Int
            let sha256: String
        }
        let archives: [String: Archive]
    }

    static func prepare(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> AsrModels {
        if !isInstalled {
            try await OrukeetInstallation.shared.install(progress: progress, progressSnapshot: progressSnapshot)
        }
        try Task.checkCancellation()
        let preparing = ModelDownloadProgress.preparing(modelID: modelID, message: "Loading Orukeet into Core ML...")
        progress?(0.98, preparing.message)
        progressSnapshot?(preparing)
        return try load(from: directory)
    }

    static func install(
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) async throws {
        // The real JSON integrity manifest is part of the managed installation,
        // so Hugging Face records the acquisition without inference-time requests.
        let downloaded = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan, progress: progress, progressSnapshot: progressSnapshot)
        let archive = try validatedArchive(in: downloaded)
        try Task.checkCancellation()
        let preparing = ModelDownloadProgress.preparing(modelID: modelID, message: "Compiling Orukeet for this Mac...")
        progress?(0.95, preparing.message)
        progressSnapshot?(preparing)
        try await compileArchive(at: archive, to: directory)
    }

    static func cancelAndWait() async {
        await OrukeetInstallation.shared.cancelAndWait()
    }

    static func validateManifest(_ data: Data) throws -> Manifest.Archive {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let archive = manifest.archives["baseline"],
              archive.filename == "orukeet-r3-coreml-baseline.zip",
              archive.bytes == archiveBytes, archive.sha256 == archiveSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive
    }

    /// The managed downloader records transfer sizes before these content checks.
    /// Invalidate only its download directory on corruption so Retry reacquires it.
    static func validatedArchive(in downloaded: URL) throws -> URL {
        do {
            let archive = try validateManifest(Data(contentsOf: downloaded.appendingPathComponent("manifest.json")))
            let url = downloaded.appendingPathComponent(archive.filename)
            try validateArchive(at: url)
            return url
        } catch {
            if error is CancellationError { throw error }
            try FileManager.default.removeItem(at: downloaded)
            throw error
        }
    }

    private static func validateArchive(at archive: URL) throws {
        try Task.checkCancellation()
        guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == archiveBytes,
            try checksum(of: archive) == archiveSHA256
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// Separate from acquisition so the exact installer can be regression-tested with the pinned archive offline.
    static func installArchive(at archive: URL, to destination: URL) async throws {
        try validateArchive(at: archive)
        try await compileArchive(at: archive, to: destination)
    }

    static func compileArchive(
        at archive: URL, to destination: URL,
        extract: (URL, URL) async throws -> Void = extractArchive
    ) async throws {
        try Task.checkCancellation()
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        try await extract(archive, staging)
        try Task.checkCancellation()
        let bundle = staging.appendingPathComponent("orukeet-r3-coreml-baseline", isDirectory: true)
        for name in components {
            try Task.checkCancellation()
            let compiled = try await MLModel.compileModel(
                at: bundle.appendingPathComponent("\(name).mlpackage"))
            defer { try? files.removeItem(at: compiled) }
            try files.moveItem(at: compiled, to: bundle.appendingPathComponent("\(name).mlmodelc"))
            try files.removeItem(at: bundle.appendingPathComponent("\(name).mlpackage"))
        }
        // Reject an incompatible vocabulary before making the install visible.
        _ = try vocabulary(in: bundle)
        try revision.write(
            to: bundle.appendingPathComponent(".revision"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        try commitInstallation(from: bundle, to: destination)
    }

    private static func extractArchive(at archive: URL, to staging: URL) async throws {
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", archive.path, staging.path]
        try await OrukeetArchiveProcess(unpack).run()
    }

    /// Use the same atomic replacement primitive as the managed downloader.
    static func commitInstallation(from bundle: URL, to destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: bundle,
                                        backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: bundle, to: destination)
        }
    }

    static func load(from directory: URL) throws -> AsrModels {
        let vocabulary = try vocabulary(in: directory)
        func component(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(
                contentsOf: directory.appendingPathComponent("\(name).mlmodelc"),
                configuration: configuration)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try AsrModels(
            encoder: component("Encoder", .cpuAndNeuralEngine),
            preprocessor: component("Preprocessor", .cpuOnly),
            decoder: component("Decoder", .cpuAndNeuralEngine),
            joint: component("JointDecisionv3", .cpuAndNeuralEngine),
            configuration: configuration, vocabulary: vocabulary, version: .v3)
    }

    private static func vocabulary(in directory: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var result: [Int: String] = [:]
        for (key, token) in raw {
            guard let id = Int(key), (0..<8192).contains(id), result[id] == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result[id] = token
        }
        guard result.count == 8192 else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private static func checksum(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }


}

/// Coalesce model preparation so selecting a model during a download cannot start
/// another transfer or replace a directory while the first install is compiling.
actor OrukeetInstallation {
    static let shared = OrukeetInstallation()

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let progress: ((Double, String?) -> Void)?
        let progressSnapshot: ModelDownloadProgressHandler?
    }
    private struct Operation {
        let id: UUID
        let task: Task<Void, Error>
        var cancelling = false
        var progress: (Double, String?)?
        var snapshot: ModelDownloadProgress?
    }
    private var operation: Operation?
    private var waiters: [UUID: Waiter] = [:]

    func cancelAndWait() async {
        guard var active = operation else { return }
        active.cancelling = true
        operation = active
        active.task.cancel()
        finish(id: active.id, result: await active.task.result)
    }

    func install(
        progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?
    ) async throws {
        try await run(progress: progress, progressSnapshot: progressSnapshot) { report, snapshot in
            guard !OrukeetModelStore.isInstalled else { return }
            try await OrukeetModelStore.install(progress: report, progressSnapshot: snapshot)
        }
    }

    func run(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil,
        _ work: @escaping (
            _ progress: @escaping @Sendable (Double, String?) -> Void,
            _ snapshot: @escaping ModelDownloadProgressHandler
        ) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        while let active = operation, active.cancelling {
            finish(id: active.id, result: await active.task.result)
        }
        try Task.checkCancellation()
        let callerID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[callerID] = Waiter(
                    continuation: continuation, progress: progress, progressSnapshot: progressSnapshot)
                if let active = operation {
                    if let (fraction, message) = active.progress { progress?(fraction, message) }
                    if let snapshot = active.snapshot { progressSnapshot?(snapshot) }
                    return
                }
                let id = UUID()
                let task = Task {
                    try await work({ fraction, message in
                        Task { await self.reportProgress(fraction, message: message, id: id) }
                    }, { snapshot in
                        Task { await self.reportSnapshot(snapshot, id: id) }
                    })
                }
                operation = Operation(id: id, task: task)
                Task { self.finish(id: id, result: await task.result) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(callerID) }
        }
        try Task.checkCancellation()
    }

    private func reportProgress(_ fraction: Double, message: String?, id: UUID) {
        guard operation?.id == id else { return }
        operation?.progress = (fraction, message)
        for waiter in waiters.values { waiter.progress?(fraction, message) }
    }

    private func reportSnapshot(_ snapshot: ModelDownloadProgress, id: UUID) {
        guard operation?.id == id else { return }
        operation?.snapshot = snapshot
        for waiter in waiters.values { waiter.progressSnapshot?(snapshot) }
    }

    private func cancelWaiter(_ callerID: UUID) {
        waiters.removeValue(forKey: callerID)?.continuation.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, result: Result<Void, Error>) {
        guard operation?.id == id else { return }
        operation = nil
        let completed = waiters
        waiters.removeAll()
        for waiter in completed.values { waiter.continuation.resume(with: result) }
    }
}

/// A Retry must not start while an earlier UI cancellation is still stopping
/// the managed download and compilation. Repeated Cancel actions stay ordered.
struct OrukeetCancellationBarrier {
    private(set) var pending: Task<Void, Never>?

    mutating func enqueue(_ cancel: @escaping () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await cancel()
        }
    }
}

/// Serializes launch with cancellation so cancellation cannot miss a process
/// that has not started yet. Completion waits for actual exit before the caller
/// removes its staging directory; no cooperative-executor thread blocks on it.
final class OrukeetArchiveProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false

    init(_ process: Process) {
        self.process = process
    }

    func run() async throws {
        let status = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            self.cancel()
        }
        try Task.checkCancellation()
        guard status == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func start(_ continuation: CheckedContinuation<Int32, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        process.terminationHandler = { process in
            continuation.resume(returning: process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }

    private func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

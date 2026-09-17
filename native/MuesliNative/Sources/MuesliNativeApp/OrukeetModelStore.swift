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
        let archive = try validateManifest(Data(contentsOf: downloaded.appendingPathComponent("manifest.json")))
        try Task.checkCancellation()
        let preparing = ModelDownloadProgress.preparing(modelID: modelID, message: "Compiling Orukeet for this Mac...")
        progress?(0.95, preparing.message)
        progressSnapshot?(preparing)
        try installArchive(at: downloaded.appendingPathComponent(archive.filename), to: directory)
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

    /// Separate from acquisition so the exact installer can be regression-tested with the pinned archive offline.
    static func installArchive(at archive: URL, to destination: URL) throws {
        guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == archiveBytes,
            try checksum(of: archive) == archiveSHA256
        else { throw CocoaError(.fileReadCorruptFile) }
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", archive.path, staging.path]
        try unpack.run()
        unpack.waitUntilExit()
        guard unpack.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let bundle = staging.appendingPathComponent("orukeet-r3-coreml-baseline", isDirectory: true)
        for name in components {
            try Task.checkCancellation()
            let compiled = try MLModel.compileModel(
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

    /// Keep the previous installation available for rollback if the final rename fails.
    static func commitInstallation(from bundle: URL, to destination: URL) throws {
        let files = FileManager.default
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = files.fileExists(atPath: destination.path)
        if hadPrevious { try files.moveItem(at: destination, to: backup) }
        do {
            try files.moveItem(at: bundle, to: destination)
        } catch {
            if hadPrevious { try files.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? files.removeItem(at: backup) }
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
private actor OrukeetInstallation {
    static let shared = OrukeetInstallation()
    private var task: Task<Void, Error>?

    func cancelAndWait() async {
        let active = task
        active?.cancel()
        _ = try? await active?.value
    }

    func install(
        progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?
    ) async throws {
        if let task { return try await task.value }
        guard !OrukeetModelStore.isInstalled else { return }
        let task = Task { try await OrukeetModelStore.install(progress: progress, progressSnapshot: progressSnapshot) }
        self.task = task
        defer { self.task = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

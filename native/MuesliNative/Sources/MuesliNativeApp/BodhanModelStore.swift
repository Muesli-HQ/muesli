import Foundation
import CryptoKit
import MuesliCore

enum BodhanModel: String, CaseIterable, Sendable {
    case core = "phequals/indic-transcribe-core-coreml"
    case flex = "phequals/indic-transcribe-flex-coreml"

    case coreInt8 = "phequals/indic-transcribe-core-coreml-int8"
    case flexInt8 = "phequals/indic-transcribe-flex-coreml-int8"

    var isInt8: Bool { self == .coreInt8 || self == .flexInt8 }
    var isCore: Bool { self == .core || self == .coreInt8 }
    var repository: String { isCore ? Self.core.rawValue : Self.flex.rawValue }
    var revision: String { isCore ? "65a3980ce14b240c3de15ce50c3d12986c413a33" : "226cf58626c3718fd9c2849e7ad6f522ecc432d6" }
    var name: String { (isCore ? "Bodhan Core" : "Bodhan Flex") + (isInt8 ? " INT8" : " FP16") }
    var mixedScript: Bool { !isCore }
    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/\(rawValue.split(separator: "/").last!)")
    }
    var localOverride: URL? {
        let key = isCore ? "MUESLI_BODHAN_CORE_MODEL_DIR" : "MUESLI_BODHAN_FLEX_MODEL_DIR"
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    var directory: URL { localOverride ?? cacheDirectory }
    var requiredFiles: [String] {
        let encoder = isInt8 ? "variants/int8/encoder" : "coreml/encoder"
        let decoder = isInt8 ? "variants/mlx-decoder-int8" : "variants/mlx-decoder"
        return ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map {
            encoder + ".mlpackage/" + $0
        } + [decoder + "/decoder.safetensors", "native-assets/frontend.bin", "native-assets/tokenizer.json"]
          + (isInt8 ? [decoder + "/config.json"] : [])
    }
    struct DecoderManifest: Decodable {
        let bytes: Int64
        let sha256: String
    }
    struct Artifact: Codable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    struct Artifacts: Codable { let files: [Artifact] }
    // Core's pinned upstream manifest omits these two required native assets.
    var nativeAssetSupplement: [Artifact] { isCore ? [
        Artifact(path: "native-assets/frontend.bin", bytes: 133184, sha256: "0990b36ae69ea276f6bc6ecbaec23821cc257d18713fa67702ac68131e21afc8"),
        Artifact(path: "native-assets/tokenizer.json", bytes: 88084, sha256: "42e7186b747c8d30c59de0b7bbc794f53e78621554a9989d0da954a138499ecc")
    ] : [] }
    var isDownloaded: Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("artifacts.json")),
              let manifest = try? JSONDecoder().decode(Artifacts.self, from: data) else { return false }
        let sizes = Dictionary((manifest.files + nativeAssetSupplement).map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        guard requiredFiles.allSatisfy({ sizes[$0] != nil }) else { return false }
        return requiredFiles.allSatisfy { path in
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)[.size]) as? NSNumber)?.int64Value ?? 0
            return sizes[path].map { bytes == $0 } ?? (bytes > 0)
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    /// Runs only when preparing an unloaded runtime, never from the UI status getter.
    /// The coordinator remains responsible for repairing invalid files and validating downloads.
    static func invalidCachedArtifacts(_ artifacts: [Artifact], at directory: URL) async throws -> [String] {
        let verification = Task.detached(priority: .utility) {
            var invalid: [String] = []
            for artifact in artifacts {
                try Task.checkCancellation()
                let url = directory.appendingPathComponent(artifact.path)
                do {
                    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                    guard size == artifact.bytes, artifact.bytes > 0, Self.isSHA256(artifact.sha256) else {
                        invalid.append(artifact.path)
                        continue
                    }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                        try Task.checkCancellation()
                        hasher.update(data: chunk)
                    }
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    if digest.caseInsensitiveCompare(artifact.sha256) != .orderedSame { invalid.append(artifact.path) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    invalid.append(artifact.path)
                }
            }
            return invalid
        }
        return try await withTaskCancellationHandler {
            let invalid = try await verification.value
            try Task.checkCancellation()
            return invalid
        } onCancel: {
            verification.cancel()
        }
    }

    func download(progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?) async throws {
        func invalidateCompiledEncoder() throws {
            guard localOverride == nil else { return }
            let encoder = isInt8 ? "variants/int8/encoder" : "coreml/encoder"
            let compiled = directory.appendingPathComponent(encoder + ".mlmodelc")
            if FileManager.default.fileExists(atPath: compiled.path) {
                try FileManager.default.removeItem(at: compiled)
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("artifacts.json")),
           let manifest = try? JSONDecoder().decode(Artifacts.self, from: data) {
            let entries = Dictionary((manifest.files + nativeAssetSupplement).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let missing = requiredFiles.filter { entries[$0] == nil }
            let invalid = try await Self.invalidCachedArtifacts(requiredFiles.compactMap { entries[$0] }, at: directory) + missing
            if invalid.isEmpty { return }
            // Compiled Core ML models are derived from the package. A repaired package
            // must not silently keep using a compiled copy of the corrupt weights.
            if invalid.contains(where: { $0.contains("encoder.mlpackage/") }) {
                try invalidateCompiledEncoder()
            }
        } else {
            // Without integrity metadata, any existing compiled copy cannot be
            // trusted to match the package that the coordinator will repair.
            try invalidateCompiledEncoder()
        }
        try Task.checkCancellation()
        if localOverride != nil {
            throw NSError(domain: "BodhanASR", code: 100, userInfo: [NSLocalizedDescriptionKey: "The local \(name) model folder is incomplete or failed its integrity check."])
        }
        func fetchManifest<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "BodhanASR", code: 101, userInfo: [NSLocalizedDescriptionKey: "Could not load the model download manifest."])
            }
            return try JSONDecoder().decode(type, from: data)
        }
        var artifacts = try await fetchManifest("artifacts.json", as: Artifacts.self).files
        artifacts += nativeAssetSupplement
        if isInt8 { artifacts += try await fetchManifest("variants/int8/full-int8-backup-manifest.json", as: Artifacts.self).files }
        if !isInt8 {
            let decoder = try await fetchManifest("variants/mlx-decoder/manifest.json", as: DecoderManifest.self)
            artifacts.append(Artifact(path: "variants/mlx-decoder/decoder.safetensors", bytes: decoder.bytes, sha256: decoder.sha256))
        }
        let entries = Dictionary(artifacts.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard requiredFiles.allSatisfy({ entries[$0]?.bytes ?? 0 > 0 && entries[$0].map { Self.isSHA256($0.sha256) } == true }) else {
            throw NSError(domain: "BodhanASR", code: 102, userInfo: [NSLocalizedDescriptionKey: "The model download manifest is incomplete."])
        }
        let selectedArtifacts = requiredFiles.compactMap { entries[$0] }
        let data = try JSONEncoder().encode(Artifacts(files: selectedArtifacts))
        let files = selectedArtifacts.map { entry in
            ModelDownloadFile(relativePath: entry.path, remoteURL: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(entry.path)")!, expectedByteCount: entry.bytes, sha256: entry.sha256)
        }
        let manifest = ModelDownloadManifest(id: rawValue, version: revision, files: files, maximumConcurrency: 2)
        try await ModelDownloadCoordinator.shared.download(manifest, to: directory) { snapshot in
            progress?(snapshot.fractionCompleted ?? 0, "Downloading \(name)...")
            progressSnapshot?(snapshot)
        }
        try data.write(to: directory.appendingPathComponent("artifacts.json"), options: .atomic)
    }
}

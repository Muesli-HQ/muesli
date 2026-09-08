import Foundation
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
    static let packageFiles = ["encoder", "cross", "decoder"].flatMap { name in
        ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map { "coreml/\(name).mlpackage/\($0)" }
    }
    static let requiredFiles = packageFiles + ["native-assets/frontend.bin", "native-assets/tokenizer.json"]
    var requiredFiles: [String] {
        if !isInt8 { return Self.requiredFiles }
        return ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map {
            "variants/int8/encoder.mlpackage/" + $0
        } + ["variants/mlx-decoder-int8/decoder.safetensors", "variants/mlx-decoder-int8/config.json",
             "native-assets/frontend.bin", "native-assets/tokenizer.json"]
    }
    struct Artifact: Codable {
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

    func download(progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?) async throws {
        if isDownloaded { return }
        if localOverride != nil {
            throw NSError(domain: "BodhanASR", code: 10, userInfo: [NSLocalizedDescriptionKey: "The local \(name) model folder is incomplete."])
        }
        func fetchManifest(_ path: String) async throws -> Artifacts {
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "BodhanASR", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not load the model download manifest."])
            }
            return try JSONDecoder().decode(Artifacts.self, from: data)
        }
        var artifacts = try await fetchManifest("artifacts.json").files
        artifacts += nativeAssetSupplement
        if isInt8 { artifacts += try await fetchManifest("variants/int8/full-int8-backup-manifest.json").files }
        let entries = Dictionary(artifacts.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard requiredFiles.allSatisfy({ entries[$0]?.bytes ?? 0 > 0 && entries[$0]?.sha256.count == 64 }) else {
            throw NSError(domain: "BodhanASR", code: 12, userInfo: [NSLocalizedDescriptionKey: "The model download manifest is incomplete."])
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

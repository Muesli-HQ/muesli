import Foundation
import MuesliCore

enum BodhanModel: String, CaseIterable, Sendable {
    case core = "phequals/indic-transcribe-core-coreml"
    case flex = "phequals/indic-transcribe-flex-coreml"

    var name: String { self == .core ? "Bodhan Core" : "Bodhan Flex" }
    var mixedScript: Bool { self == .flex }
    var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/\(rawValue.split(separator: "/").last!)")
    }
    var localOverride: URL? {
        let key = self == .core ? "MUESLI_BODHAN_CORE_MODEL_DIR" : "MUESLI_BODHAN_FLEX_MODEL_DIR"
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    var directory: URL { localOverride ?? cacheDirectory }
    static let packageFiles = ["encoder", "cross", "decoder"].flatMap { name in
        ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map { "coreml/\(name).mlpackage/\($0)" }
    }
    static let requiredFiles = packageFiles + ["native-assets/frontend.bin", "native-assets/tokenizer.json"]
    private struct Artifact: Decodable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    private struct Artifacts: Decodable { let files: [Artifact] }
    var isDownloaded: Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("artifacts.json")),
              let manifest = try? JSONDecoder().decode(Artifacts.self, from: data) else { return false }
        let sizes = Dictionary(manifest.files.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        guard Self.packageFiles.allSatisfy({ sizes[$0] != nil }) else { return false }
        return Self.requiredFiles.allSatisfy { path in
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)[.size]) as? NSNumber)?.int64Value ?? 0
            return sizes[path].map { bytes == $0 } ?? (bytes > 0)
        }
    }

    func download(progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?) async throws {
        if isDownloaded { return }
        if localOverride != nil {
            throw NSError(domain: "BodhanASR", code: 10, userInfo: [NSLocalizedDescriptionKey: "The local \(name) model folder is incomplete."])
        }
        let manifestURL = URL(string: "https://huggingface.co/\(rawValue)/resolve/main/artifacts.json")!
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "BodhanASR", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not load the model download manifest."])
        }
        let artifacts = try JSONDecoder().decode(Artifacts.self, from: data)
        let entries = Dictionary(artifacts.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        guard Self.packageFiles.allSatisfy({ entries[$0] != nil }) else {
            throw NSError(domain: "BodhanASR", code: 12, userInfo: [NSLocalizedDescriptionKey: "The model download manifest is incomplete."])
        }
        let files = Self.requiredFiles.map { path in
            ModelDownloadFile(relativePath: path, remoteURL: URL(string: "https://huggingface.co/\(rawValue)/resolve/main/\(path)")!, expectedByteCount: entries[path]?.bytes, sha256: entries[path]?.sha256)
        }
        let manifest = ModelDownloadManifest(id: rawValue, version: "coreml-v1", files: files, maximumConcurrency: 2)
        try await ModelDownloadCoordinator.shared.download(manifest, to: directory) { snapshot in
            progress?(snapshot.fractionCompleted ?? 0, "Downloading \(name)...")
            progressSnapshot?(snapshot)
        }
        try data.write(to: directory.appendingPathComponent("artifacts.json"), options: .atomic)
    }
}

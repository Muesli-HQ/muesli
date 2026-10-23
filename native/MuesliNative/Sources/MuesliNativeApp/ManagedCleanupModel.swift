import CryptoKit
import Foundation
import MuesliCore

/// Immutable Hugging Face artifacts. Validation also applies to local testing overrides.
struct ManagedCleanupModel: Sendable {
    let repoID: String
    let revision: String
    let files: [ModelDownloadFile]
    let modelByteCount: Int64

    var modelFilename: String { files[0].relativePath }
    var sizeLabel: String { "~" + ByteCountFormatter.string(fromByteCount: modelByteCount, countStyle: .file) }

    init(_ repoID: String, _ revision: String, _ artifacts: [(String, Int64, String)]) {
        precondition(!artifacts.isEmpty, "A cleanup release must include its model artifact first.")
        modelByteCount = artifacts[0].1
        self.repoID = repoID
        self.revision = revision
        files = artifacts.map { name, size, hash in
            ModelDownloadFile(relativePath: name,
                remoteURL: URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(name)?download=1")!,
                expectedByteCount: size, sha256: hash)
        }
    }

    func manifest(id: String) -> ModelDownloadManifest {
        ModelDownloadManifest(id: id, version: revision, files: files, maximumConcurrency: 1)
    }

    func isPresent(at directory: URL) -> Bool {
        files.allSatisfy { file in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.relativePath).path),
                  attrs[.type] as? FileAttributeType == .typeRegular else { return false }
            return (attrs[.size] as? NSNumber)?.int64Value == file.expectedByteCount
        }
    }

    func validate(modelURL: URL) throws {
        for (index, file) in files.enumerated() {
            let url = index == 0 ? modelURL : modelURL.deletingLastPathComponent().appendingPathComponent(file.relativePath)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value == file.expectedByteCount else {
                throw NSError(domain: "ManagedCleanupModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid size or file type: \(file.relativePath)"])
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw NSError(domain: "ManagedCleanupModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "SHA-256 mismatch: \(file.relativePath)"])
            }
        }
    }

    static let gemma = Self("phequals/gemma4-e2b-muesli-cleanup-v12-litert", "ce4656b3be4788e48d7b8e2b4fbfaef77c31d939", [
        ("gemma4-e2b-muesli-v12-mtp.litertlm", 2_946_098_832, "4d907d149a49c6b25c388b54e2e6b86bf34d50ba7f5bc78182ddf6350a1a7230")
    ])
    static let lfm = Self("phequals/lfm25-1.2b-muesli-cleanup-v12-gguf", "9f8b4e25", [
        ("lfm25-muesli-v12-Q4_K_M.gguf", 730_898_432, "da13d32708d27d29446c895314e50aa7fb700b76460057fed2ad773e9fa9c258"),
        ("LICENSE", 10_644, "61d7e939a05911c765b7e98ffaa1ab5ca6c0174a65350766c25cb10197d19fc8")
    ])
    static let qwen = Self("phequals/qwen35-2b-muesli-cleanup-v12-gguf", "e35af097", [
        ("qwen35-2b-muesli-v12-Q4_K_M.gguf", 1_274_396_096, "2d59d2118170e0170fa294d71eba0a701c4f26063f284f68a8bed880322c4143")
    ])
}

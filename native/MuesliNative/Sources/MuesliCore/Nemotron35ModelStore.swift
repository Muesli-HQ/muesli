import Foundation

public enum Nemotron35ModelStoreError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse(String)
    case httpError(Int, String)
    case retriesExhausted(String, Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid Nemotron model URL: \(value)"
        case .invalidResponse(let value):
            return "Invalid Nemotron model response: \(value)"
        case .httpError(let code, let path):
            return "HTTP \(code) downloading Nemotron model file \(path)"
        case .retriesExhausted(let path, let underlying):
            return "Failed to download Nemotron model file \(path) after retries: \(underlying.localizedDescription)"
        }
    }
}

/// The shared on-disk Nemotron 3.5 model store used by the app and CLI.
///
/// The app's RNNT engine and FluidAudio's multilingual manager can both load
/// this top-level CoreML layout. Keeping the downloader and path here prevents
/// the two products from maintaining separate copies of the same model.
public enum Nemotron35ModelStore {
    public static let repoID = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    public static let variantPath = "multilingual/2240ms"
    public static let cacheRelativePath = ".cache/muesli/models/nemotron35-multilingual-2240ms"
    public static let requiredFileRelativePath = "encoder.mlmodelc/coremldata.bin"
    public static let requiredFileRelativePaths = [
        "encoder.mlmodelc/analytics/coremldata.bin",
        "encoder.mlmodelc/coremldata.bin",
        "encoder.mlmodelc/model.mil",
        "encoder.mlmodelc/weights/weight.bin",
        "decoder.mlmodelc/analytics/coremldata.bin",
        "decoder.mlmodelc/coremldata.bin",
        "decoder.mlmodelc/model.mil",
        "decoder.mlmodelc/weights/weight.bin",
        "joint.mlmodelc/analytics/coremldata.bin",
        "joint.mlmodelc/coremldata.bin",
        "joint.mlmodelc/model.mil",
        "joint.mlmodelc/weights/weight.bin",
        "preprocessor.mlmodelc/analytics/coremldata.bin",
        "preprocessor.mlmodelc/coremldata.bin",
        "preprocessor.mlmodelc/model.mil",
        "preprocessor.mlmodelc/weights/weight.bin",
        "metadata.json",
        "tokenizer.json",
    ]

    public static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
    }

    public static func revisionFileURL(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent(".revision")
    }

    public static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        let directory = cacheDirectory(fileManager: fileManager)
        return requiredFileRelativePaths.allSatisfy { relativePath in
            let url = directory.appendingPathComponent(relativePath)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular else {
                return false
            }
            return true
        }
    }

    /// Ensure the app-compatible multilingual/2240ms model exists locally.
    /// Existing files are reused, so an interrupted download can resume.
    @discardableResult
    public static func ensureDownloaded(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> URL {
        let directory = cacheDirectory()
        if isModelDownloaded() {
            return directory
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress?(0.0, "Downloading Nemotron 3.5 model...")

        let apiURL = "https://huggingface.co/api/models/\(repoID)/tree/main/\(variantPath)"
        let files = try await collectFiles(
            apiURL: apiURL,
            remotePath: variantPath,
            skipRelativePrefix: "decoder_joint.mlmodelc"
        )
        guard !files.isEmpty else {
            throw Nemotron35ModelStoreError.invalidResponse(apiURL)
        }

        let manifest = ModelDownloadManifest(
            id: repoID,
            version: "main:\(variantPath)",
            files: files,
            maximumConcurrency: 2
        )
        try await ModelDownloadCoordinator.shared.download(manifest, to: directory) { snapshot in
            progress?(snapshot.fractionCompleted ?? 0, "Downloading Nemotron 3.5 model...")
            progressSnapshot?(snapshot)
        }

        if let revision = await fetchRemoteRevision() {
            recordInstalledRevision(revision)
        }
        progress?(1.0, "Nemotron 3.5 model ready")
        return directory
    }

    /// The Hugging Face commit currently backing the shared model repository.
    /// A failed lookup is intentionally non-fatal to model downloads.
    public static func fetchRemoteRevision() async -> String? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = object["sha"] as? String
        else {
            return nil
        }
        return revision
    }

    public static func installedRevision(fileManager: FileManager = .default) -> String? {
        guard let value = try? String(
            contentsOf: revisionFileURL(fileManager: fileManager),
            encoding: .utf8
        ) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func recordInstalledRevision(
        _ revision: String,
        fileManager: FileManager = .default
    ) {
        try? revision.write(
            to: revisionFileURL(fileManager: fileManager),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func collectFiles(
        apiURL: String,
        remotePath: String,
        skipRelativePrefix: String?
    ) async throws -> [ModelDownloadFile] {
        guard let url = URL(string: apiURL) else {
            throw Nemotron35ModelStoreError.invalidURL(apiURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw Nemotron35ModelStoreError.httpError(httpResponse.statusCode, apiURL)
        }

        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Nemotron35ModelStoreError.invalidResponse(apiURL)
        }

        var files: [ModelDownloadFile] = []
        for entry in entries {
            guard let path = entry["path"] as? String,
                  let type = entry["type"] as? String,
                  path.hasPrefix(remotePath + "/")
            else {
                continue
            }

            let relativePath = String(path.dropFirst(remotePath.count + 1))
            if let skipRelativePrefix, relativePath.hasPrefix(skipRelativePrefix) {
                continue
            }

            if type == "directory" {
                let subAPI = "https://huggingface.co/api/models/\(repoID)/tree/main/\(path)"
                files.append(contentsOf: try await collectFiles(
                    apiURL: subAPI,
                    remotePath: remotePath,
                    skipRelativePrefix: skipRelativePrefix
                ))
            } else if type == "file" {
                guard let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(path)") else {
                    throw Nemotron35ModelStoreError.invalidURL(path)
                }
                let expectedByteCount = (entry["size"] as? NSNumber)?.int64Value
                files.append(ModelDownloadFile(
                    relativePath: relativePath,
                    remoteURL: fileURL,
                    expectedByteCount: expectedByteCount
                ))
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}

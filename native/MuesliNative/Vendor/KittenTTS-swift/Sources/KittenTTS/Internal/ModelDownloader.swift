import Foundation

/// Downloads and caches KittenTTS model files from Hugging Face.
enum ModelDownloader {

    // MARK: - Cache check

    /// Returns `true` if both the ONNX model and voices file are present on disk.
    static func isModelCached(for config: KittenTTSConfig) -> Bool {
        let dir = config.resolvedStorageDirectory
        return FileManager.default.fileExists(atPath: onnxURL(in: dir, model: config.model).path) &&
               FileManager.default.fileExists(atPath: voicesURL(in: dir, model: config.model).path)
    }

    // MARK: - Download

    /// Download the model and voices files for `config` if they are not already cached.
    ///
    /// - Parameters:
    ///   - config: The ``KittenTTSConfig`` that identifies which model to download.
    ///   - progressHandler: Optional closure called with overall download progress [0, 1].
    /// - Returns: A tuple of `(onnxURL, voicesURL)` pointing to the cached files.
    /// - Throws: ``KittenTTSError/downloadFailed(_:)`` or
    ///   ``KittenTTSError/invalidModelData(_:)`` on failure.
    @discardableResult
    static func downloadModelIfNeeded(
        for config: KittenTTSConfig,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> (onnx: URL, voices: URL) {
        let dir       = config.resolvedStorageDirectory
        let onnxDst   = onnxURL(in: dir, model: config.model)
        let voicesDst = voicesURL(in: dir, model: config.model)

        let onnxExists   = FileManager.default.fileExists(atPath: onnxDst.path)
        let voicesExists = FileManager.default.fileExists(atPath: voicesDst.path)

        if onnxExists && voicesExists {
            progressHandler?(1.0)
            return (onnxDst, voicesDst)
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw KittenTTSError.downloadFailed("Cannot create storage directory: \(error.localizedDescription)")
        }

        // Download ONNX (85% of progress budget)
        if !onnxExists {
            let onnxSrc = config.model.huggingFaceBaseURL.appendingPathComponent(config.model.onnxFileName)
            try await downloadFile(from: onnxSrc, to: onnxDst) { p in
                progressHandler?(p * 0.85)
            }
        }

        // Download voices (remaining 15%)
        if !voicesExists {
            let voicesSrc = config.model.huggingFaceBaseURL.appendingPathComponent(config.model.voicesFileName)
            try await downloadFile(from: voicesSrc, to: voicesDst) { p in
                progressHandler?(0.85 + p * 0.15)
            }
        }

        progressHandler?(1.0)
        return (onnxDst, voicesDst)
    }

    // MARK: - File URLs

    static func onnxURL(for config: KittenTTSConfig) -> URL {
        onnxURL(in: config.resolvedStorageDirectory, model: config.model)
    }

    static func voicesURL(for config: KittenTTSConfig) -> URL {
        voicesURL(in: config.resolvedStorageDirectory, model: config.model)
    }

    // MARK: - Private

    private static func onnxURL(in dir: URL, model: KittenModel) -> URL {
        dir.appendingPathComponent(model.onnxFileName)
    }

    private static func voicesURL(in dir: URL, model: KittenModel) -> URL {
        dir.appendingPathComponent(model.voicesFileName)
    }

    private static func downloadFile(
        from src: URL,
        to dst: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(dst: dst, progress: progressHandler) { error in
                if let error {
                    cont.resume(throwing: KittenTTSError.downloadFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: src).resume()
            delegate.session = session   // retain until completion
        }
    }
}

// MARK: - Download delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let dst: URL
    let progress: (Double) -> Void
    let completion: (Error?) -> Void
    var session: URLSession?    // retained until completion

    init(dst: URL, progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        self.dst        = dst
        self.progress   = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.moveItem(at: location, to: dst)
            completion(nil)
        } catch {
            completion(error)
        }
        self.session = nil
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            completion(error)
            self.session = nil
        }
    }
}

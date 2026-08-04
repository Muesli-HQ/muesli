import CryptoKit
import Foundation

/// The lifecycle phase reported for a model download.
public enum ModelDownloadPhase: String, Codable, Sendable {
    /// One or more model files are being transferred.
    case downloading
    /// The downloaded files are being compiled or otherwise prepared.
    case preparing
    /// All files passed validation and the model is ready to use.
    case ready
    /// The transfer is not currently active and can be resumed.
    case paused
    /// The transfer or preparation failed and can be retried.
    case failed
}

/// A single file required by a model manifest.
public struct ModelDownloadFile: Codable, Hashable, Sendable {
    /// The path relative to the model directory.
    public let relativePath: String
    /// The Hugging Face or other artifact URL for this file.
    public let remoteURL: URL
    /// The expected final size, when published by the model owner.
    public let expectedByteCount: Int64?
    /// An optional lowercase or uppercase-insensitive SHA-256 digest.
    public let sha256: String?

    /// Creates a manifest entry for one model file.
    public init(relativePath: String, remoteURL: URL, expectedByteCount: Int64? = nil, sha256: String? = nil) {
        self.relativePath = relativePath
        self.remoteURL = remoteURL
        self.expectedByteCount = expectedByteCount
        self.sha256 = sha256
    }
}

/// The complete set of files and policies needed to install one model revision.
public struct ModelDownloadManifest: Sendable {
    /// A stable identifier used to deduplicate jobs and persist state.
    public let id: String
    /// The revision represented by this manifest.
    public let version: String
    /// Required files in the order used for progress presentation.
    public let files: [ModelDownloadFile]
    /// Maximum number of files transferred at the same time.
    public let maximumConcurrency: Int

    /// Creates a model manifest. Concurrency is clamped to at least one file.
    public init(id: String, version: String, files: [ModelDownloadFile], maximumConcurrency: Int = 2) {
        self.id = id
        self.version = version
        self.files = files
        self.maximumConcurrency = max(1, maximumConcurrency)
    }

    /// The total size when every manifest entry publishes an expected size.
    public var totalExpectedByteCount: Int64? {
        let sizes = files.compactMap(\.expectedByteCount)
        guard sizes.count == files.count else { return nil }
        return sizes.reduce(0, +)
    }
}

/// A point-in-time progress report for a model download or preparation job.
public struct ModelDownloadProgress: Sendable {
    /// The stable model identifier associated with this snapshot.
    public let modelID: String
    /// The current transfer or preparation phase.
    public let phase: ModelDownloadPhase
    /// The stable user-facing file. Other files may continue downloading in parallel.
    public let currentFile: String?
    /// Bytes completed across all files.
    public let completedBytes: Int64
    /// Expected bytes across all files, when known.
    public let totalBytes: Int64?
    /// Bytes completed for the featured file.
    public let currentFileCompletedBytes: Int64
    /// Expected bytes for the featured file, when known.
    public let currentFileTotalBytes: Int64?
    /// Recent aggregate transfer rate in bytes per second.
    public let bytesPerSecond: Double
    /// Estimated seconds until all known bytes are complete.
    public let estimatedSecondsRemaining: Double?
    /// Number of retry attempts used by the currently featured file.
    public let retryCount: Int
    /// Number of required files finalized so far.
    public let completedFileCount: Int
    /// Number of required files in the manifest.
    public let totalFileCount: Int
    /// A user-readable status or error detail.
    public let message: String?

    /// Creates a progress snapshot.
    public init(
        modelID: String,
        phase: ModelDownloadPhase,
        currentFile: String?,
        completedBytes: Int64,
        totalBytes: Int64?,
        currentFileCompletedBytes: Int64,
        currentFileTotalBytes: Int64?,
        bytesPerSecond: Double,
        estimatedSecondsRemaining: Double?,
        retryCount: Int,
        completedFileCount: Int = 0,
        totalFileCount: Int = 0,
        message: String?
    ) {
        self.modelID = modelID
        self.phase = phase
        self.currentFile = currentFile
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentFileCompletedBytes = currentFileCompletedBytes
        self.currentFileTotalBytes = currentFileTotalBytes
        self.bytesPerSecond = bytesPerSecond
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.retryCount = retryCount
        self.completedFileCount = completedFileCount
        self.totalFileCount = totalFileCount
        self.message = message
    }

    /// Overall progress as a value between zero and one when a size is known.
    public var fractionCompleted: Double? {
        if let totalBytes, totalBytes > 0 {
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }
        guard let currentFileTotalBytes, currentFileTotalBytes > 0 else { return nil }
        return min(max(Double(currentFileCompletedBytes) / Double(currentFileTotalBytes), 0), 1)
    }

    /// Creates a snapshot for a model preparation phase.
    public static func preparing(
        modelID: String,
        message: String,
        completedFileCount: Int = 0,
        totalFileCount: Int = 0
    ) -> Self {
        Self(
            modelID: modelID,
            phase: .preparing,
            currentFile: nil,
            completedBytes: 0,
            totalBytes: nil,
            currentFileCompletedBytes: 0,
            currentFileTotalBytes: nil,
            bytesPerSecond: 0,
            estimatedSecondsRemaining: nil,
            retryCount: 0,
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount,
            message: message
        )
    }

    /// Copies this snapshot while changing its phase and message.
    public func replacing(phase: ModelDownloadPhase, message: String?) -> Self {
        Self(
            modelID: modelID,
            phase: phase,
            currentFile: currentFile,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            currentFileCompletedBytes: currentFileCompletedBytes,
            currentFileTotalBytes: currentFileTotalBytes,
            bytesPerSecond: bytesPerSecond,
            estimatedSecondsRemaining: estimatedSecondsRemaining,
            retryCount: retryCount,
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount,
            message: message
        )
    }
}

/// Receives progress snapshots on the coordinator's actor context.
public typealias ModelDownloadProgressHandler = @Sendable (ModelDownloadProgress) -> Void

/// Errors surfaced by the model download coordinator.
public enum ModelDownloadError: Error, LocalizedError, Sendable {
    /// The manifest has no files to download.
    case emptyManifest(String)
    /// A manifest path would escape the model directory.
    case invalidRelativePath(String)
    /// The server returned an HTTP response that cannot be used for this file.
    case invalidHTTPStatus(Int, String)
    /// No bytes arrived before the transfer watchdog or request timeout fired.
    case stalled(String)
    /// The server's reported response length did not match the manifest.
    case invalidContentLength(String, expected: Int64, actual: Int64)
    /// The final file size did not match the manifest.
    case sizeMismatch(String, expected: Int64, actual: Int64)
    /// The final file failed its optional SHA-256 validation.
    case checksumMismatch(String)
    /// The server's ETag changed while resuming a partial file.
    case etagMismatch(String)
    /// The destination volume does not have the required safety margin.
    case insufficientDiskSpace(required: Int64, available: Int64)
    /// The destination volume's free space could not be determined.
    case diskSpaceUnavailable(String)
    /// All retryable attempts were exhausted.
    case retriesExhausted(String, String)

    /// A user-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case .emptyManifest(let modelID):
            return "No files were specified for model download \(modelID)"
        case .invalidRelativePath(let path):
            return "The model contains an invalid relative path: \(path)"
        case .invalidHTTPStatus(let status, let path):
            return "HTTP " + String(status) + " while downloading " + path
        case .stalled(let path):
            return "Download stalled while receiving " + path
        case .invalidContentLength(let path, let expected, let actual):
            return "The server reported an invalid size for " + path + " (expected " + String(expected) + " bytes, reported " + String(actual) + ")"
        case .sizeMismatch(let path, let expected, let actual):
            return "Downloaded " + path + " is incomplete (expected " + String(expected) + " bytes, received " + String(actual) + ")"
        case .checksumMismatch(let path):
            return "Downloaded " + path + " failed integrity validation"
        case .etagMismatch(let path):
            return "The partial download for " + path + " is from an older model revision"
        case .insufficientDiskSpace(let required, let available):
            return "Not enough disk space (need " + String(required) + " bytes, have " + String(available) + ")"
        case .diskSpaceUnavailable(let path):
            return "Could not determine available disk space for " + path
        case .retriesExhausted(let path, let detail):
            return "Could not download " + path + " after three attempts: " + detail
        }
    }
}

private struct PersistedDownloadState: Codable, Sendable {
    var modelID: String
    var version: String
    var etags: [String: String]
}

/// Shared resumable downloader for Muesli-owned model artifacts.
public actor ModelDownloadCoordinator {
    /// The process-wide coordinator used by model backends and the UI.
    public static let shared = ModelDownloadCoordinator()

    private var inFlight: [String: Task<Void, Error>] = [:]
    private var progressHandlers: [String: [ModelDownloadProgressHandler]] = [:]
    private var fileProgress: [String: Int64] = [:]
    private var fileTotals: [String: Int64] = [:]
    // Keep one featured file stable while the bounded parallel batch advances.
    private var featuredFile: [String: String] = [:]
    private var completedFiles: [String: Set<String>] = [:]
    private var startedAt: [String: Date] = [:]
    private var lastProgressEmissionAt: [String: Date] = [:]
    private var initialProgressBytes: [String: Int64] = [:]
    private let sessionDelegate: ModelDownloadSessionDelegate
    private let session: URLSession

    /// Creates a coordinator using the standard model-download URL session configuration.
    public init() {
        self.init(configuration: .modelDownload)
    }

    /// Creates a coordinator with a custom URL session configuration, primarily for tests.
    public init(configuration: URLSessionConfiguration) {
        let delegate = ModelDownloadSessionDelegate()
        sessionDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Cancels active transfers for a model while retaining completed and partial files.
    ///
    /// A model may have more specific in-flight IDs while its manifest is being
    /// assembled, so matching the model prefix keeps cancellation reliable
    /// across callers.
    public func cancel(modelID: String) {
        for (id, task) in inFlight where id == modelID || id.hasPrefix(modelID + ":") {
            task.cancel()
        }
    }

    /// Downloads, validates, and atomically installs every file in a manifest.
    ///
    /// Requests for the same manifest ID share one in-flight job and each caller
    /// receives its own progress callbacks.
    public func download(
        _ manifest: ModelDownloadManifest,
        to directory: URL,
        progress: ModelDownloadProgressHandler? = nil
    ) async throws {
        guard !manifest.files.isEmpty else {
            throw ModelDownloadError.emptyManifest(manifest.id)
        }
        try validateManifestPaths(manifest, in: directory)
        if let existing = inFlight[manifest.id] {
            if let progress {
                progressHandlers[manifest.id, default: []].append(progress)
            }
            try await existing.value
            return
        }

        try checkDiskSpace(for: manifest, at: directory)
        progressHandlers[manifest.id] = progress.map { [$0] } ?? []
        let task = Task { [manifest, directory] in
            try await self.performDownload(manifest, to: directory)
        }
        inFlight[manifest.id] = task
        defer {
            inFlight[manifest.id] = nil
            progressHandlers[manifest.id] = nil
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Explicitly removes a model's completed files, partial files, and persisted state.
    public func removeDownload(_ manifest: ModelDownloadManifest, at directory: URL) throws {
        let paths = try manifest.files.map { file in
            try validatedURL(for: file.relativePath, in: directory)
        }
        guard inFlight[manifest.id] == nil else { return }
        let fm = FileManager.default
        for path in paths {
            try? fm.removeItem(at: path.appendingPathExtension("part"))
            try? fm.removeItem(at: path)
        }
        try? fm.removeItem(at: stateURL(for: directory))
    }

    private func performDownload(
        _ manifest: ModelDownloadManifest,
        to directory: URL
    ) async throws {
        let fm = FileManager.default
        defer { cleanup(manifest.id) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateManifestPaths(manifest, in: directory)
        let state = loadState(for: directory, manifest: manifest)
        lastProgressEmissionAt[manifest.id] = nil
        for file in manifest.files {
            let url = try validatedURL(for: file.relativePath, in: directory)
            let key = manifest.id + ":" + file.relativePath
            fileProgress[key] = ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
            if let expected = file.expectedByteCount { fileTotals[key] = expected }
        }
        var completed = Set<String>()
        for file in manifest.files {
            let url = try validatedURL(for: file.relativePath, in: directory)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let expected = file.expectedByteCount else {
                completed.insert(file.relativePath)
                continue
            }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if size == expected { completed.insert(file.relativePath) }
        }
        completedFiles[manifest.id] = completed
        featuredFile[manifest.id] = nextIncompleteFile(for: manifest)
        initialProgressBytes[manifest.id] = manifest.files.reduce(Int64(0)) {
            $0 + fileProgress["\(manifest.id):\($1.relativePath)", default: 0]
        }
        startedAt[manifest.id] = Date()
        emit(manifest, phase: .downloading, message: "Starting download")

        var pending: [ModelDownloadFile] = []
        for file in manifest.files {
            let destination = try validatedURL(for: file.relativePath, in: directory)
            guard fm.fileExists(atPath: destination.path) else {
                pending.append(file)
                continue
            }
            do {
                try validate(file, at: destination)
            } catch {
                // A stale or corrupt final file must not block a fresh
                // download merely because its path exists.
                try? fm.removeItem(at: destination)
                pending.append(file)
            }
        }

        while !pending.isEmpty {
            let batch = Array(pending.prefix(manifest.maximumConcurrency))
            pending.removeFirst(min(batch.count, pending.count))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for file in batch {
                    group.addTask {
                        try await self.downloadFile(file, manifest: manifest, directory: directory, etag: state.etags[file.relativePath])
                    }
                }
                try await group.waitForAll()
            }
        }

        for file in manifest.files {
            let destination = try validatedURL(for: file.relativePath, in: directory)
            guard fm.fileExists(atPath: destination.path) else { throw ModelDownloadError.sizeMismatch(file.relativePath, expected: file.expectedByteCount ?? 1, actual: 0) }
            do {
                try validate(file, at: destination)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
        }
        try? fm.removeItem(at: stateURL(for: directory))
        emit(manifest, phase: .ready, message: "Model ready")
    }

    private func downloadFile(
        _ file: ModelDownloadFile,
        manifest: ModelDownloadManifest,
        directory: URL,
        etag: String?
    ) async throws {
        let fm = FileManager.default
        let destination = try validatedURL(for: file.relativePath, in: directory)
        let partURL = destination.appendingPathExtension("part")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error?
        var didResetPartialForAttempt = false

        var attempt = 0
        while attempt < 3 {
            if attempt > 0 {
                let base = UInt64(1 << (attempt - 1)) * 1_000_000_000
                let jitter = UInt64.random(in: 0...250_000_000)
                try await Task.sleep(nanoseconds: base + jitter)
            }
            do {
                try Task.checkCancellation()
                try await stream(file, manifest: manifest, directory: directory, partURL: partURL, etag: etag, attempt: attempt)
                try moveAtomically(partURL, to: destination)
                completedFiles[manifest.id, default: []].insert(file.relativePath)
                if featuredFile[manifest.id] == file.relativePath {
                    featuredFile[manifest.id] = nextIncompleteFile(for: manifest)
                }
                emit(manifest, phase: .downloading, file: file.relativePath, retry: attempt, force: true)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                lastError = ModelDownloadError.stalled(file.relativePath)
                didResetPartialForAttempt = false
                attempt += 1
            } catch let error as ModelDownloadError {
                lastError = error
                switch error {
                case .invalidHTTPStatus(let status, _)
                    where (400..<500).contains(status) && status != 416:
                    throw error
                case .invalidHTTPStatus(416, _):
                    // A stale or oversized partial file cannot be resumed.
                    // Reset it and immediately retry the same attempt from
                    // byte zero, including when the 416 arrived on the final
                    // normal retry. This keeps stale-part recovery distinct
                    // from ordinary transient retries.
                    try? fm.removeItem(at: partURL)
                    guard !didResetPartialForAttempt else {
                        didResetPartialForAttempt = false
                        attempt += 1
                        continue
                    }
                    didResetPartialForAttempt = true
                    continue
                case .etagMismatch:
                    try? fm.removeItem(at: partURL)
                    didResetPartialForAttempt = false
                    attempt += 1
                case .invalidContentLength, .sizeMismatch, .checksumMismatch, .insufficientDiskSpace, .diskSpaceUnavailable:
                    throw error
                default:
                    didResetPartialForAttempt = false
                    attempt += 1
                }
            } catch {
                lastError = error
                didResetPartialForAttempt = false
                attempt += 1
            }
        }
        throw ModelDownloadError.retriesExhausted(file.relativePath, lastError?.localizedDescription ?? "unknown error")
    }

    private func stream(
        _ file: ModelDownloadFile,
        manifest: ModelDownloadManifest,
        directory: URL,
        partURL: URL,
        etag: String?,
        attempt: Int
    ) async throws {
        let fm = FileManager.default
        let offset = (try? fm.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: file.remoteURL)
        request.timeoutInterval = 60
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }
        }

        let sink = ModelDownloadTaskSink()
        let task = session.dataTask(with: request)
        sessionDelegate.register(sink, for: task.taskIdentifier)
        task.resume()

        var completed = false
        defer {
            sessionDelegate.unregister(task.taskIdentifier)
            if !completed { task.cancel() }
        }

        var append = false
        var expected: Int64?
        var handle: FileHandle?
        defer { try? handle?.close() }
        var initial: Int64 = 0
        let key = "\(manifest.id):\(file.relativePath)"
        var written: Int64 = 0
        try await withTaskCancellationHandler(operation: {
            for try await event in sink.events {
                try Task.checkCancellation()
                switch event {
            case .response(let response):
                guard (200..<300).contains(response.statusCode) else {
                    throw ModelDownloadError.invalidHTTPStatus(response.statusCode, file.relativePath)
                }

                append = offset > 0 && response.statusCode == 206
                if append, let etag, let responseETag = response.etag, etag != responseETag {
                    throw ModelDownloadError.etagMismatch(file.relativePath)
                }
                if let expected = file.expectedByteCount, response.expectedContentLength > 0 {
                    let expectedResponseLength = append ? max(0, expected - offset) : expected
                    guard response.expectedContentLength == expectedResponseLength else {
                        throw ModelDownloadError.invalidContentLength(
                            file.relativePath,
                            expected: expectedResponseLength,
                            actual: response.expectedContentLength
                        )
                    }
                }
                if !append {
                    try? fm.removeItem(at: partURL)
                    fm.createFile(atPath: partURL.path, contents: nil)
                }
                let newHandle = try FileHandle(forWritingTo: partURL)
                if append { try newHandle.seek(toOffset: UInt64(offset)) }
                handle = newHandle

                expected = file.expectedByteCount
                    ?? (response.expectedContentLength > 0
                        ? response.expectedContentLength + (append ? offset : 0)
                        : nil)
                initial = append ? offset : 0
                written = initial
                fileProgress[key] = initial
                if let expected { fileTotals[key] = expected }
                if let responseETag = response.etag {
                    persistETag(responseETag, for: file.relativePath, directory: directory, manifest: manifest)
                }

            case .data(let data):
                guard let handle else { continue }
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                fileProgress[key] = written
                emit(manifest, phase: .downloading, file: file.relativePath, retry: attempt)

            case .finished:
                completed = true
                }
            }
        }, onCancel: {
            task.cancel()
            sink.finish(throwing: CancellationError())
        })
        guard completed else {
            if Task.isCancelled { throw CancellationError() }
            throw URLError(.networkConnectionLost)
        }
        fileProgress[key] = written
        if let expected, written != expected {
            throw ModelDownloadError.sizeMismatch(file.relativePath, expected: expected, actual: written)
        }
        emit(manifest, phase: .downloading, file: file.relativePath, retry: attempt, force: true)
    }

    private func validate(_ file: ModelDownloadFile, at url: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expected = file.expectedByteCount, size != expected {
            throw ModelDownloadError.sizeMismatch(file.relativePath, expected: expected, actual: size)
        }
        if let expectedHash = file.sha256 {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                throw ModelDownloadError.checksumMismatch(file.relativePath)
            }
        }
    }

    private func checkDiskSpace(for manifest: ModelDownloadManifest, at directory: URL) throws {
        guard let total = manifest.totalExpectedByteCount else { return }
        let fm = FileManager.default
        var volumeURL = directory
        while !fm.fileExists(atPath: volumeURL.path) {
            let parent = volumeURL.deletingLastPathComponent()
            guard parent.path != volumeURL.path else {
                throw ModelDownloadError.diskSpaceUnavailable(directory.path)
            }
            volumeURL = parent
        }
        guard let available = (try? fm.attributesOfFileSystem(forPath: volumeURL.path)[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw ModelDownloadError.diskSpaceUnavailable(volumeURL.path)
        }
        let (required, overflow) = total.addingReportingOverflow(512 * 1024 * 1024)
        guard !overflow else { throw ModelDownloadError.diskSpaceUnavailable(volumeURL.path) }
        guard available >= required else { throw ModelDownloadError.insufficientDiskSpace(required: required, available: available) }
    }

    private func emit(
        _ manifest: ModelDownloadManifest,
        phase: ModelDownloadPhase,
        file: String? = nil,
        retry: Int = 0,
        message: String? = nil,
        force: Bool = false
    ) {
        guard !progressHandlers[manifest.id, default: []].isEmpty else { return }
        let now = Date()
        if !force, phase == .downloading, message == nil,
           let previous = lastProgressEmissionAt[manifest.id], now.timeIntervalSince(previous) < 0.1 {
            return
        }
        lastProgressEmissionAt[manifest.id] = now
        let completed = manifest.files.reduce(Int64(0)) { $0 + fileProgress["\(manifest.id):\($1.relativePath)", default: 0] }
        let total = manifest.totalExpectedByteCount ?? dynamicTotal(for: manifest)
        let displayFile = focusedFile(for: manifest, eventFile: file)
        let current = displayFile.flatMap { fileProgress["\(manifest.id):\($0)", default: 0] } ?? 0
        let currentTotal = displayFile.flatMap { fileTotals["\(manifest.id):\($0)"] }
        let elapsed = Date().timeIntervalSince(startedAt[manifest.id] ?? Date())
        let transferred = max(0, completed - initialProgressBytes[manifest.id, default: 0])
        let speed = elapsed > 0 ? Double(transferred) / elapsed : 0
        let remainingBytes = total.map { max(0, $0 - completed) }
            ?? currentTotal.map { max(0, $0 - current) }
        let remaining = remainingBytes.flatMap { speed > 0 ? Double($0) / speed : nil }
        let completedFileCount = completedFiles[manifest.id]?.count ?? 0
        let snapshot = ModelDownloadProgress(modelID: manifest.id, phase: phase, currentFile: displayFile, completedBytes: completed, totalBytes: total, currentFileCompletedBytes: current, currentFileTotalBytes: currentTotal, bytesPerSecond: speed, estimatedSecondsRemaining: remaining, retryCount: retry, completedFileCount: completedFileCount, totalFileCount: manifest.files.count, message: message)
        for handler in progressHandlers[manifest.id, default: []] {
            handler(snapshot)
        }
    }

    private func focusedFile(for manifest: ModelDownloadManifest, eventFile: String?) -> String? {
        let completed = completedFiles[manifest.id, default: []]
        if let current = featuredFile[manifest.id], !completed.contains(current) {
            return current
        }
        let next = nextIncompleteFile(for: manifest)
        featuredFile[manifest.id] = next
        return next ?? eventFile.flatMap { completed.contains($0) ? nil : $0 }
    }

    private func nextIncompleteFile(for manifest: ModelDownloadManifest) -> String? {
        let completed = completedFiles[manifest.id, default: []]
        return manifest.files.first { !completed.contains($0.relativePath) }?.relativePath
    }

    private func dynamicTotal(for manifest: ModelDownloadManifest) -> Int64? {
        let totals = manifest.files.compactMap { fileTotals["\(manifest.id):\($0.relativePath)"] }
        guard totals.count == manifest.files.count else { return nil }
        return totals.reduce(0, +)
    }

    private func validateManifestPaths(_ manifest: ModelDownloadManifest, in directory: URL) throws {
        for file in manifest.files {
            _ = try validatedURL(for: file.relativePath, in: directory)
        }
    }

    /// Resolve a manifest path and prove that it remains inside the model
    /// directory. Manifests are maintainer-owned today, but keeping this
    /// boundary defensive prevents a malformed or compromised manifest from
    /// writing or deleting arbitrary files.
    private func validatedURL(for relativePath: String, in directory: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              components.allSatisfy({ component in
                  let component = String(component)
                  return !component.isEmpty && component != "." && component != ".."
              }) else {
            throw ModelDownloadError.invalidRelativePath(relativePath)
        }

        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedCandidate = directory
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        // Resolving only the full path is insufficient when the final file
        // does not exist yet. Resolve its parent first so an existing
        // symlinked directory cannot redirect a new download outside base.
        let resolvedParent = normalizedCandidate
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let candidate = resolvedParent
            .appendingPathComponent(normalizedCandidate.lastPathComponent)
            .resolvingSymlinksInPath()
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else {
            throw ModelDownloadError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    private func moveAtomically(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    private func stateURL(for directory: URL) -> URL { directory.appendingPathComponent(".muesli-download-state.json") }

    private func loadState(for directory: URL, manifest: ModelDownloadManifest) -> PersistedDownloadState {
        guard let data = try? Data(contentsOf: stateURL(for: directory)),
              let state = try? JSONDecoder().decode(PersistedDownloadState.self, from: data),
              state.modelID == manifest.id, state.version == manifest.version else {
            return PersistedDownloadState(modelID: manifest.id, version: manifest.version, etags: [:])
        }
        return state
    }

    private func persistETag(_ etag: String, for path: String, directory: URL, manifest: ModelDownloadManifest) {
        var state = loadState(for: directory, manifest: manifest)
        state.etags[path] = etag
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL(for: directory), options: .atomic) }
    }

    private func cleanup(_ modelID: String) {
        fileProgress = fileProgress.filter { !$0.key.hasPrefix(modelID + ":") }
        fileTotals = fileTotals.filter { !$0.key.hasPrefix(modelID + ":") }
        featuredFile[modelID] = nil
        completedFiles[modelID] = nil
        startedAt[modelID] = nil
        lastProgressEmissionAt[modelID] = nil
        initialProgressBytes[modelID] = nil
    }
}

private struct ModelDownloadResponse: Sendable {
    let statusCode: Int
    let expectedContentLength: Int64
    let etag: String?
}

private enum ModelDownloadEvent: Sendable {
    case response(ModelDownloadResponse)
    case data(Data)
    case finished
}

private final class ModelDownloadTaskSink: @unchecked Sendable {
    let events: AsyncThrowingStream<ModelDownloadEvent, Error>
    private let continuation: AsyncThrowingStream<ModelDownloadEvent, Error>.Continuation

    init() {
        var captured: AsyncThrowingStream<ModelDownloadEvent, Error>.Continuation?
        events = AsyncThrowingStream { continuation in
            captured = continuation
        }
        continuation = captured!
    }

    func yield(_ event: ModelDownloadEvent) {
        continuation.yield(event)
    }

    func finish(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }
}

private final class ModelDownloadSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: ModelDownloadTaskSink] = [:]

    func register(_ sink: ModelDownloadTaskSink, for taskIdentifier: Int) {
        lock.lock()
        sinks[taskIdentifier] = sink
        lock.unlock()
    }

    func unregister(_ taskIdentifier: Int) {
        lock.lock()
        sinks.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              let sink = sink(for: dataTask.taskIdentifier)
        else {
            completionHandler(.cancel)
            return
        }
        sink.yield(.response(ModelDownloadResponse(
            statusCode: response.statusCode,
            expectedContentLength: response.expectedContentLength,
            etag: response.value(forHTTPHeaderField: "ETag")
        )))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        sink(for: dataTask.taskIdentifier)?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let sink = sink(for: task.taskIdentifier) else { return }
        if let error {
            sink.finish(throwing: error)
        } else {
            sink.yield(.finished)
            sink.finish()
        }
    }

    private func sink(for taskIdentifier: Int) -> ModelDownloadTaskSink? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[taskIdentifier]
    }
}

private extension URLSessionConfiguration {
    static var modelDownload: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 4
        return configuration
    }
}

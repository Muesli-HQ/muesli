import CryptoKit
import Foundation

public enum ModelDownloadPhase: String, Codable, Sendable {
    case downloading
    case preparing
    case ready
    case paused
    case failed
}

public struct ModelDownloadFile: Codable, Hashable, Sendable {
    public let relativePath: String
    public let remoteURL: URL
    public let expectedByteCount: Int64?
    public let sha256: String?

    public init(relativePath: String, remoteURL: URL, expectedByteCount: Int64? = nil, sha256: String? = nil) {
        self.relativePath = relativePath
        self.remoteURL = remoteURL
        self.expectedByteCount = expectedByteCount
        self.sha256 = sha256
    }
}

public struct ModelDownloadManifest: Sendable {
    public let id: String
    public let version: String
    public let files: [ModelDownloadFile]
    public let maximumConcurrency: Int

    public init(id: String, version: String, files: [ModelDownloadFile], maximumConcurrency: Int = 2) {
        self.id = id
        self.version = version
        self.files = files
        self.maximumConcurrency = max(1, maximumConcurrency)
    }

    public var totalExpectedByteCount: Int64? {
        let sizes = files.compactMap(\.expectedByteCount)
        guard sizes.count == files.count else { return nil }
        return sizes.reduce(0, +)
    }
}

public struct ModelDownloadProgress: Sendable {
    public let modelID: String
    public let phase: ModelDownloadPhase
    /// The stable user-facing file. Other files may continue downloading in parallel.
    public let currentFile: String?
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let currentFileCompletedBytes: Int64
    public let currentFileTotalBytes: Int64?
    public let bytesPerSecond: Double
    public let estimatedSecondsRemaining: Double?
    public let retryCount: Int
    public let completedFileCount: Int
    public let totalFileCount: Int
    public let message: String?

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

    public var fractionCompleted: Double? {
        if let totalBytes, totalBytes > 0 {
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }
        guard let currentFileTotalBytes, currentFileTotalBytes > 0 else { return nil }
        return min(max(Double(currentFileCompletedBytes) / Double(currentFileTotalBytes), 0), 1)
    }

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

public typealias ModelDownloadProgressHandler = @Sendable (ModelDownloadProgress) -> Void

public enum ModelDownloadError: Error, LocalizedError, Sendable {
    case invalidHTTPStatus(Int, String)
    case stalled(String)
    case sizeMismatch(String, expected: Int64, actual: Int64)
    case checksumMismatch(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case retriesExhausted(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let status, let path):
            return "HTTP " + String(status) + " while downloading " + path
        case .stalled(let path):
            return "Download stalled while receiving " + path
        case .sizeMismatch(let path, let expected, let actual):
            return "Downloaded " + path + " is incomplete (expected " + String(expected) + " bytes, received " + String(actual) + ")"
        case .checksumMismatch(let path):
            return "Downloaded " + path + " failed integrity validation"
        case .insufficientDiskSpace(let required, let available):
            return "Not enough disk space (need " + String(required) + " bytes, have " + String(available) + ")"
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
    public static let shared = ModelDownloadCoordinator()

    private var inFlight: [String: Task<Void, Error>] = [:]
    private var fileProgress: [String: Int64] = [:]
    private var fileTotals: [String: Int64] = [:]
    // Keep one featured file stable while the bounded parallel batch advances.
    private var featuredFile: [String: String] = [:]
    private var completedFiles: [String: Set<String>] = [:]
    private var startedAt: [String: Date] = [:]
    private var lastProgressEmissionAt: [String: Date] = [:]
    private var initialProgressBytes: [String: Int64] = [:]

    public init() {}

    public func download(
        _ manifest: ModelDownloadManifest,
        to directory: URL,
        progress: ModelDownloadProgressHandler? = nil
    ) async throws {
        if let existing = inFlight[manifest.id] {
            try await existing.value
            return
        }

        try checkDiskSpace(for: manifest, at: directory)
        let task = Task { [manifest, directory] in
            try await self.performDownload(manifest, to: directory, progress: progress)
        }
        inFlight[manifest.id] = task
        defer { inFlight[manifest.id] = nil }
        try await task.value
    }

    public func removeDownload(_ manifest: ModelDownloadManifest, at directory: URL) throws {
        guard inFlight[manifest.id] == nil else { return }
        let fm = FileManager.default
        for file in manifest.files {
            try? fm.removeItem(at: directory.appendingPathComponent(file.relativePath + ".part"))
            try? fm.removeItem(at: directory.appendingPathComponent(file.relativePath))
        }
        try? fm.removeItem(at: stateURL(for: directory))
    }

    private func performDownload(
        _ manifest: ModelDownloadManifest,
        to directory: URL,
        progress: ModelDownloadProgressHandler?
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = loadState(for: directory, manifest: manifest)
        lastProgressEmissionAt[manifest.id] = nil
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.relativePath)
            let key = manifest.id + ":" + file.relativePath
            fileProgress[key] = ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
            if let expected = file.expectedByteCount { fileTotals[key] = expected }
        }
        completedFiles[manifest.id] = Set(
            manifest.files.compactMap { file in
                let url = directory.appendingPathComponent(file.relativePath)
                guard fm.fileExists(atPath: url.path) else { return nil }
                guard let expected = file.expectedByteCount else { return file.relativePath }
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                return size == expected ? file.relativePath : nil
            }
        )
        featuredFile[manifest.id] = nextIncompleteFile(for: manifest)
        initialProgressBytes[manifest.id] = manifest.files.reduce(Int64(0)) {
            $0 + fileProgress["\(manifest.id):\($1.relativePath)", default: 0]
        }
        startedAt[manifest.id] = Date()
        emit(manifest, phase: .downloading, progress: progress, message: "Starting download")

        var pending = manifest.files.filter { file in
            !fm.fileExists(atPath: directory.appendingPathComponent(file.relativePath).path)
        }

        while !pending.isEmpty {
            let batch = Array(pending.prefix(manifest.maximumConcurrency))
            pending.removeFirst(min(batch.count, pending.count))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for file in batch {
                    group.addTask {
                        try await self.downloadFile(file, manifest: manifest, directory: directory, etag: state.etags[file.relativePath], progress: progress)
                    }
                }
                try await group.waitForAll()
            }
        }

        for file in manifest.files {
            let destination = directory.appendingPathComponent(file.relativePath)
            guard fm.fileExists(atPath: destination.path) else { throw ModelDownloadError.sizeMismatch(file.relativePath, expected: file.expectedByteCount ?? 1, actual: 0) }
            try validate(file, at: destination)
        }
        try? fm.removeItem(at: stateURL(for: directory))
        emit(manifest, phase: .ready, progress: progress, message: "Model ready")
    }

    private func downloadFile(
        _ file: ModelDownloadFile,
        manifest: ModelDownloadManifest,
        directory: URL,
        etag: String?,
        progress: ModelDownloadProgressHandler?
    ) async throws {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(file.relativePath)
        let partURL = directory.appendingPathComponent(file.relativePath + ".part")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error?

        for attempt in 0..<3 {
            if attempt > 0 {
                let base = UInt64(1 << (attempt - 1)) * 1_000_000_000
                let jitter = UInt64.random(in: 0...250_000_000)
                try await Task.sleep(nanoseconds: base + jitter)
            }
            do {
                try Task.checkCancellation()
                try await stream(file, manifest: manifest, directory: directory, partURL: partURL, etag: etag, attempt: attempt, progress: progress)
                try moveAtomically(partURL, to: destination)
                completedFiles[manifest.id, default: []].insert(file.relativePath)
                if featuredFile[manifest.id] == file.relativePath {
                    featuredFile[manifest.id] = nextIncompleteFile(for: manifest)
                }
                emit(manifest, phase: .downloading, file: file.relativePath, retry: attempt, progress: progress, force: true)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                lastError = ModelDownloadError.stalled(file.relativePath)
                if attempt == 2 { throw lastError! }
            } catch let error as ModelDownloadError {
                lastError = error
                switch error {
                case .invalidHTTPStatus(let status, _)
                    where (400..<500).contains(status) || status == 416:
                    throw error
                case .sizeMismatch, .checksumMismatch, .insufficientDiskSpace:
                    throw error
                default:
                    if attempt == 2 { throw error }
                }
            } catch {
                lastError = error
                if attempt == 2 { throw error }
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
        attempt: Int,
        progress: ModelDownloadProgressHandler?
    ) async throws {
        let fm = FileManager.default
        let offset = (try? fm.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: file.remoteURL)
        request.timeoutInterval = 60
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }
        }

        let (bytes, response) = try await URLSession(configuration: .modelDownload).bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelDownloadError.invalidHTTPStatus(-1, file.relativePath) }
        guard (200..<300).contains(http.statusCode) else { throw ModelDownloadError.invalidHTTPStatus(http.statusCode, file.relativePath) }

        let append = offset > 0 && http.statusCode == 206
        if !append {
            try? fm.removeItem(at: partURL)
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        if append { try handle.seek(toOffset: UInt64(offset)) }

        let expected = file.expectedByteCount ?? (http.expectedContentLength > 0 ? http.expectedContentLength + (append ? offset : 0) : nil)
        let initial = append ? offset : 0
        let key = "\(manifest.id):\(file.relativePath)"
        fileProgress[key] = initial
        if let expected { fileTotals[key] = expected }
        if let responseETag = http.value(forHTTPHeaderField: "ETag") {
            persistETag(responseETag, for: file.relativePath, directory: directory, manifest: manifest)
        }

        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        var written = initial
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: Data(buffer))
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                fileProgress[key] = written
                emit(manifest, phase: .downloading, file: file.relativePath, retry: attempt, progress: progress)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: Data(buffer))
            written += Int64(buffer.count)
        }
        fileProgress[key] = written
        if let expected, written != expected {
            throw ModelDownloadError.sizeMismatch(file.relativePath, expected: expected, actual: written)
        }
        emit(manifest, phase: .downloading, file: file.relativePath, retry: attempt, progress: progress, force: true)
    }

    private func validate(_ file: ModelDownloadFile, at url: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let expected = file.expectedByteCount, size != expected {
            throw ModelDownloadError.sizeMismatch(file.relativePath, expected: expected, actual: size)
        }
        if let expectedHash = file.sha256 {
            let data = try Data(contentsOf: url)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                throw ModelDownloadError.checksumMismatch(file.relativePath)
            }
        }
    }

    private func checkDiskSpace(for manifest: ModelDownloadManifest, at directory: URL) throws {
        guard let total = manifest.totalExpectedByteCount else { return }
        let filesystemPath = directory.deletingLastPathComponent().path
        let available = (try? FileManager.default.attributesOfFileSystem(forPath: filesystemPath)[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
        let required = total + 512 * 1024 * 1024
        guard available >= required else { throw ModelDownloadError.insufficientDiskSpace(required: required, available: available) }
    }

    private func emit(
        _ manifest: ModelDownloadManifest,
        phase: ModelDownloadPhase,
        file: String? = nil,
        retry: Int = 0,
        progress: ModelDownloadProgressHandler?,
        message: String? = nil,
        force: Bool = false
    ) {
        guard let progress else { return }
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
        progress(ModelDownloadProgress(modelID: manifest.id, phase: phase, currentFile: displayFile, completedBytes: completed, totalBytes: total, currentFileCompletedBytes: current, currentFileTotalBytes: currentTotal, bytesPerSecond: speed, estimatedSecondsRemaining: remaining, retryCount: retry, completedFileCount: completedFileCount, totalFileCount: manifest.files.count, message: message))
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

    private func moveAtomically(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
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

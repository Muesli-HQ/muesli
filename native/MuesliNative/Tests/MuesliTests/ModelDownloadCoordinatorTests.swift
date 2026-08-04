import Foundation
import Testing
import MuesliCore

private final class DownloadTestTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var requestCount = 0

    func started() {
        lock.lock()
        active += 1
        requestCount += 1
        maximumActive = max(maximumActive, active)
        lock.unlock()
    }

    func finished() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}

private final class ModelDownloadTestURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
        let chunkSize: Int
        let delay: TimeInterval
        let tracker: DownloadTestTracker?

        init(
            statusCode: Int = 200,
            data: Data = Data(),
            headers: [String: String] = [:],
            chunkSize: Int = 64 * 1024,
            delay: TimeInterval = 0,
            tracker: DownloadTestTracker? = nil
        ) {
            self.statusCode = statusCode
            self.data = data
            self.headers = headers
            self.chunkSize = chunkSize
            self.delay = delay
            self.tracker = tracker
        }
    }

    private static let lock = NSLock()
    private static var provider: ((URLRequest) -> Response)?
    private var stopped = false

    static func install(_ provider: @escaping (URLRequest) -> Response) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    static func uninstall() {
        lock.lock()
        provider = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: Response? = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return Self.provider?(request)
        }()
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        response.tracker?.started()
        defer { response.tracker?.finished() }
        var headers = response.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(response.data.count)
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

        guard response.statusCode != 416 else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let chunkSize = max(1, response.chunkSize)
        var offset = 0
        while offset < response.data.count && !stopped {
            let end = min(offset + chunkSize, response.data.count)
            client?.urlProtocol(self, didLoad: response.data.subdata(in: offset..<end))
            offset = end
            if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
        }
        if !stopped {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped = true
    }
}

@Suite("ModelDownloadCoordinator", .serialized)
struct ModelDownloadCoordinatorTests {
    @Test("manifest totals known file sizes")
    func manifestTotalsKnownFileSizes() throws {
        let manifest = ModelDownloadManifest(
            id: "test-model",
            version: "v1",
            files: [
                ModelDownloadFile(relativePath: "a.bin", remoteURL: try #require(URL(string: "https://example.com/a")), expectedByteCount: 10),
                ModelDownloadFile(relativePath: "b.bin", remoteURL: try #require(URL(string: "https://example.com/b")), expectedByteCount: 30),
            ]
        )

        #expect(manifest.totalExpectedByteCount == 40)
        #expect(manifest.maximumConcurrency == 2)
    }

    @Test("manifest total is unknown when a file has no size")
    func manifestTotalUnknownWithoutSizes() throws {
        let manifest = ModelDownloadManifest(
            id: "test-model",
            version: "v1",
            files: [ModelDownloadFile(relativePath: "a.bin", remoteURL: try #require(URL(string: "https://example.com/a")))]
        )

        #expect(manifest.totalExpectedByteCount == nil)
    }

    @Test("progress reports current-file progress when overall size is unknown")
    func progressUsesCurrentFileFallback() {
        let progress = ModelDownloadProgress(
            modelID: "test-model",
            phase: .downloading,
            currentFile: "weights.bin",
            completedBytes: 0,
            totalBytes: nil,
            currentFileCompletedBytes: 25,
            currentFileTotalBytes: 100,
            bytesPerSecond: 10,
            estimatedSecondsRemaining: 7.5,
            retryCount: 0,
            completedFileCount: 2,
            totalFileCount: 12,
            message: nil
        )

        #expect(progress.fractionCompleted == 0.25)
        #expect(progress.completedFileCount == 2)
        #expect(progress.totalFileCount == 12)
    }

    @Test("preparation and pause snapshots preserve useful transfer context")
    func snapshotsPreserveTransferContext() {
        let downloading = ModelDownloadProgress(
            modelID: "test-model",
            phase: .downloading,
            currentFile: "weights.bin",
            completedBytes: 25,
            totalBytes: 100,
            currentFileCompletedBytes: 25,
            currentFileTotalBytes: 100,
            bytesPerSecond: 10,
            estimatedSecondsRemaining: 7.5,
            retryCount: 1,
            completedFileCount: 3,
            totalFileCount: 12,
            message: "Downloading weights.bin"
        )

        let paused = downloading.replacing(phase: .paused, message: "Paused")
        #expect(paused.phase == .paused)
        #expect(paused.completedBytes == 25)
        #expect(paused.currentFile == "weights.bin")
        #expect(paused.bytesPerSecond == 10)
        #expect(paused.completedFileCount == 3)
        #expect(paused.totalFileCount == 12)

        let preparing = ModelDownloadProgress.preparing(modelID: "test-model", message: "Preparing")
        #expect(preparing.phase == .preparing)
        #expect(preparing.message == "Preparing")
    }

    @Test("download errors are user-readable")
    func downloadErrorsAreUserReadable() {
        let error = ModelDownloadError.stalled("encoder/weights.bin")
        #expect(error.localizedDescription.contains("encoder/weights.bin"))
        #expect(error.localizedDescription.contains("stalled"))
    }

    @Test("downloads multiple files with bounded concurrency")
    func downloadsMultipleFilesWithBoundedConcurrency() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x41, count: 32 * 1024),
                chunkSize: 4 * 1024,
                delay: 0.002,
                tracker: tracker
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (1...5).map { index in
            ModelDownloadFile(
                relativePath: "file-\(index).bin",
                remoteURL: try #require(URL(string: "https://example.com/file-\(index)")),
                expectedByteCount: 32 * 1024
            )
        }
        let manifest = ModelDownloadManifest(id: "bounded", version: "1", files: files, maximumConcurrency: 2)

        try await coordinator.download(manifest, to: directory)

        #expect(tracker.maximumActive <= 2)
        #expect(tracker.requestCount == 5)
        for file in files {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file.relativePath).path))
        }
    }

    @Test("duplicate requests share the transfer and both receive progress")
    func duplicateRequestsShareTransfer() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x42, count: 128 * 1024),
                chunkSize: 4 * 1024,
                delay: 0.002,
                tracker: tracker
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = ModelDownloadManifest(
            id: "duplicate",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 128 * 1024)],
            maximumConcurrency: 1
        )
        let firstProgress = DownloadTestTracker()
        let secondProgress = DownloadTestTracker()
        let first = Task {
            try await coordinator.download(manifest, to: directory) { _ in firstProgress.started() }
        }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task {
            try await coordinator.download(manifest, to: directory) { _ in secondProgress.started() }
        }
        try await first.value
        try await second.value

        #expect(tracker.requestCount == 1)
        #expect(firstProgress.requestCount > 0)
        #expect(secondProgress.requestCount > 0)
    }

    @Test("resumes a partial file with a 206 response")
    func resumesPartialFile() async throws {
        ModelDownloadTestURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=2-")
            return ModelDownloadTestURLProtocol.Response(statusCode: 206, data: Data("llo".utf8), headers: ["ETag": "etag-1"])
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partURL = directory.appendingPathComponent("model.bin.part")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("he".utf8).write(to: partURL)
        let manifest = ModelDownloadManifest(
            id: "resume",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 5)],
            maximumConcurrency: 1
        )

        try await coordinator.download(manifest, to: directory)
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    @Test("falls back to a full response when the server ignores Range")
    func rangeFallbackReplacesPartial() async throws {
        ModelDownloadTestURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=2-")
            return ModelDownloadTestURLProtocol.Response(statusCode: 200, data: Data("hello".utf8))
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("he".utf8).write(to: directory.appendingPathComponent("model.bin.part"))
        let manifest = ModelDownloadManifest(
            id: "range-fallback",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 5)],
            maximumConcurrency: 1
        )

        try await coordinator.download(manifest, to: directory)
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == Data("hello".utf8))
    }

    @Test("restarts a partial file when its ETag changes")
    func etagMismatchRestartsPartial() async throws {
        ModelDownloadTestURLProtocol.install { request in
            if request.value(forHTTPHeaderField: "Range") != nil {
                #expect(request.value(forHTTPHeaderField: "If-Range") == "old-etag")
                return ModelDownloadTestURLProtocol.Response(
                    statusCode: 206,
                    data: Data("llo".utf8),
                    headers: ["ETag": "new-etag"]
                )
            }
            return ModelDownloadTestURLProtocol.Response(
                statusCode: 200,
                data: Data("hello".utf8),
                headers: ["ETag": "new-etag"]
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("he".utf8).write(to: directory.appendingPathComponent("model.bin.part"))
        let state = Data("{\"modelID\":\"etag\",\"version\":\"1\",\"etags\":{\"model.bin\":\"old-etag\"}}".utf8)
        try state.write(to: directory.appendingPathComponent(".muesli-download-state.json"))
        let manifest = ModelDownloadManifest(
            id: "etag",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 5)],
            maximumConcurrency: 1
        )

        try await coordinator.download(manifest, to: directory)
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == Data("hello".utf8))
    }

    @Test("rejects an incorrect HTTP content length")
    func rejectsIncorrectContentLength() async throws {
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data("hello".utf8),
                headers: ["Content-Length": "4"]
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = ModelDownloadManifest(
            id: "bad-length",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 5)],
            maximumConcurrency: 1
        )

        await #expect(throws: ModelDownloadError.self) {
            try await coordinator.download(manifest, to: directory)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.bin").path))
    }

    @Test("resets an oversized partial file after HTTP 416")
    func oversizedPartialResetsAfter416() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            if request.value(forHTTPHeaderField: "Range") != nil {
                return ModelDownloadTestURLProtocol.Response(statusCode: 416, tracker: tracker)
            }
            return ModelDownloadTestURLProtocol.Response(data: Data("hello".utf8), tracker: tracker)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("too-large".utf8).write(to: directory.appendingPathComponent("model.bin.part"))
        let manifest = ModelDownloadManifest(
            id: "stale-range",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 5)],
            maximumConcurrency: 1
        )

        try await coordinator.download(manifest, to: directory)
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == Data("hello".utf8))
        #expect(tracker.requestCount == 2)
    }

    @Test("cancellation preserves the partial file and does not finalize it")
    func cancellationPreservesPartialFile() async throws {
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x43, count: 512 * 1024),
                chunkSize: 4 * 1024,
                delay: 0.01
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = ModelDownloadManifest(
            id: "cancel",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 512 * 1024)],
            maximumConcurrency: 1
        )
        let task = Task { try await coordinator.download(manifest, to: directory) }
        try await Task.sleep(for: .milliseconds(60))
        await coordinator.cancel(modelID: manifest.id)
        do {
            try await task.value
            Issue.record("Cancellation unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        let partURL = directory.appendingPathComponent("model.bin.part")
        #expect(FileManager.default.fileExists(atPath: partURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.bin").path))
    }

    private func makeCoordinator() -> ModelDownloadCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadTestURLProtocol.self]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 30
        return ModelDownloadCoordinator(configuration: configuration)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-download-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

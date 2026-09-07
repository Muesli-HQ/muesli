import CryptoKit
import Foundation
import Testing
import MuesliCore

private final class DownloadTestTracker: @unchecked Sendable {
    private let lock = NSCondition()
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var requestCount = 0

    func started() {
        lock.lock()
        active += 1
        requestCount += 1
        maximumActive = max(maximumActive, active)
        lock.broadcast()
        lock.unlock()
    }

    func finished() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }

    func waitUntilRequestStarts(timeout: TimeInterval = 2) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while requestCount == 0 {
            guard lock.wait(until: deadline) else { return false }
        }
        return true
    }
}

private final class DownloadResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class DownloadCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
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
    private let stateLock = NSLock()
    private var stoppedStorage = false
    private var stopped: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return stoppedStorage
        }
        set {
            stateLock.lock()
            stoppedStorage = newValue
            stateLock.unlock()
        }
    }

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

    @Test("manifest paths cannot escape the model directory")
    func manifestPathsStayInsideModelDirectory() async throws {
        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, relativePath) in [
            "../escaped.bin",
            "/tmp/escaped.bin",
            "nested/../escaped.bin",
            "nested/./escaped.bin",
            "",
        ].enumerated() {
            let manifest = ModelDownloadManifest(
                id: "unsafe-path-\(index)",
                version: "1",
                files: [ModelDownloadFile(
                    relativePath: relativePath,
                    remoteURL: try #require(URL(string: "https://example.com/model"))
                )]
            )

            await #expect(throws: ModelDownloadError.self) {
                try await coordinator.download(manifest, to: directory)
            }
            await #expect(throws: ModelDownloadError.self) {
                try await coordinator.removeDownload(manifest, at: directory)
            }
        }

        let escapedDirectory = directory.deletingLastPathComponent().appendingPathComponent("escape-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: escapedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: escapedDirectory) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked"),
            withDestinationURL: escapedDirectory
        )
        let symlinkManifest = ModelDownloadManifest(
            id: "unsafe-symlink",
            version: "1",
            files: [ModelDownloadFile(
                relativePath: "linked/escaped.bin",
                remoteURL: try #require(URL(string: "https://example.com/model"))
            )]
        )
        await #expect(throws: ModelDownloadError.self) {
            try await coordinator.download(symlinkManifest, to: directory)
        }

        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escaped.bin").path))
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

    @Test("Hugging Face trees become size-aware filtered manifests")
    func huggingFaceTreeResolution() async throws {
        let tracker = DownloadTestTracker()
        let firstPage = try JSONSerialization.data(withJSONObject: [
            [
                "type": "file",
                "path": "int8/Encoder.mlmodelc/coremldata.bin",
                "size": 7,
                "oid": "encoder-oid",
            ],
            [
                "type": "file",
                "path": "int8/ignored.txt",
                "size": 100,
                "oid": "ignored-oid",
            ],
        ])
        let secondPage = try JSONSerialization.data(withJSONObject: [[
            "type": "file",
            "path": "int8/Decoder.mlmodelc/coremldata.bin",
            "size": 9,
            "oid": "decoder-oid",
        ]])
        ModelDownloadTestURLProtocol.install { request in
            let isSecondPage = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            }?.queryItems?.contains(URLQueryItem(name: "cursor", value: "next")) == true
            let data: Data
            let headers: [String: String]
            if isSecondPage {
                data = secondPage
                headers = [:]
            } else {
                #expect(request.url?.path.hasSuffix("/tree/main/int8") == true)
                #expect(request.url?.query?.contains("recursive=true") == true)
                data = firstPage
                headers = [
                    "Link": "</api/models/acme/asr/tree/main/int8?cursor=next>; rel=\"next\""
                ]
            }
            return ModelDownloadTestURLProtocol.Response(
                data: data,
                headers: headers,
                tracker: tracker
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        let manifest = try await resolver.resolve(
            modelID: "acme/asr",
            repository: "acme/asr",
            selections: [HuggingFaceModelSelection(
                remoteDirectory: "int8",
                includedPaths: ["Encoder.mlmodelc", "Decoder.mlmodelc"]
            )]
        )

        #expect(tracker.requestCount == 2)
        #expect(manifest.files.map(\.relativePath) == [
            "Decoder.mlmodelc/coremldata.bin",
            "Encoder.mlmodelc/coremldata.bin",
        ])
        #expect(manifest.totalExpectedByteCount == 16)
        #expect(manifest.files[0].remoteURL.absoluteString.contains("/acme/asr/resolve/main/int8/Decoder.mlmodelc/coremldata.bin"))
        #expect(manifest.version.hasPrefix("main-"))
    }

    @Test("Hugging Face pagination rejects cross-host next links")
    func huggingFacePaginationRejectsCrossHostLinks() async throws {
        let tracker = DownloadTestTracker()
        let page = try JSONSerialization.data(withJSONObject: [[
            "type": "file",
            "path": "int8/Encoder.mlmodelc/coremldata.bin",
            "size": 7,
            "oid": "encoder-oid",
        ]])
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: page,
                headers: ["Link": "<https://example.com/steal-token>; rel=\"next\""],
                tracker: tracker
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        await #expect(throws: HuggingFaceModelManifestError.self) {
            try await resolver.resolve(
                modelID: "acme/asr",
                repository: "acme/asr",
                selections: [HuggingFaceModelSelection(remoteDirectory: "int8")]
            )
        }
        #expect(tracker.requestCount == 1)
    }

    @Test("Muesli mirror manifests become checksum-validated downloader manifests")
    func muesliMirrorManifestResolution() async throws {
        let data = Data("mirror".utf8)
        let manifestData = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "acme/asr",
            "version": "mirror-v1",
            "files": [[
                "relativePath": "models/model.bin",
                "objectKey": "models/acme/asr/mirror-v1/files/models/model.bin",
                "bytes": data.count,
                "sha256": sha256(data),
            ]],
        ])
        ModelDownloadTestURLProtocol.install { request in
            #expect(request.url?.host == "assets.muesli.works")
            #expect(request.url?.lastPathComponent == "manifest.json")
            return ModelDownloadTestURLProtocol.Response(data: manifestData)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let resolver = MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration())
        let manifest = try await resolver.resolve(
            modelID: "acme/asr",
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )

        #expect(manifest.id == "acme/asr")
        #expect(manifest.version == "mirror-v1")
        #expect(manifest.files.map(\.relativePath) == ["models/model.bin"])
        #expect(manifest.files[0].remoteURL.absoluteString == "https://assets.muesli.works/models/acme/asr/mirror-v1/files/models/model.bin")
        #expect(manifest.files[0].sha256 == sha256(data))
    }

    @Test("Muesli mirror manifests reject an untrusted origin")
    func muesliMirrorManifestRejectsUntrustedOrigin() async throws {
        let resolver = MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration())

        await #expect(throws: MuesliModelMirrorManifestError.self) {
            try await resolver.resolve(
                modelID: "acme/asr",
                mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://example.com/models/acme/asr/mirror-v1/manifest.json")))
            )
        }
    }

    @Test("Muesli mirror manifests reject unsafe entries")
    func muesliMirrorManifestRejectsUnsafeEntries() async throws {
        let manifestURL = try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json"))
        let validSHA256 = String(repeating: "a", count: 64)
        let cases: [(name: String, files: [[String: Any]])] = [
            (
                "path traversal",
                [[
                    "relativePath": "../escape.bin",
                    "objectKey": "models/acme/asr/mirror-v1/files/escape.bin",
                    "bytes": 1,
                    "sha256": validSHA256,
                ]]
            ),
            (
                "cross-release object key",
                [[
                    "relativePath": "model.bin",
                    "objectKey": "models/acme/other/mirror-v1/files/model.bin",
                    "bytes": 1,
                    "sha256": validSHA256,
                ]]
            ),
            (
                "invalid checksum",
                [[
                    "relativePath": "model.bin",
                    "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                    "bytes": 1,
                    "sha256": "not-a-sha256",
                ]]
            ),
            (
                "duplicate path",
                [
                    [
                        "relativePath": "model.bin",
                        "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                        "bytes": 1,
                        "sha256": validSHA256,
                    ],
                    [
                        "relativePath": "model.bin",
                        "objectKey": "models/acme/asr/mirror-v1/files/second.bin",
                        "bytes": 1,
                        "sha256": validSHA256,
                    ],
                ]
            ),
        ]

        for testCase in cases {
            let manifestData = try JSONSerialization.data(withJSONObject: [
                "format": "muesli-r2-model-manifest-v1",
                "modelID": "acme/asr",
                "version": "mirror-v1",
                "files": testCase.files,
            ])
            ModelDownloadTestURLProtocol.install { _ in
                ModelDownloadTestURLProtocol.Response(data: manifestData)
            }
            let resolver = MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration())
            await #expect(throws: MuesliModelMirrorManifestError.self) {
                try await resolver.resolve(
                    modelID: "acme/asr",
                    mirror: MuesliModelMirror(manifestURL: manifestURL)
                )
            }
            ModelDownloadTestURLProtocol.uninstall()
        }
    }

    @Test("managed downloads prefer the Muesli mirror without contacting Hugging Face")
    func managedDownloadPrefersMuesliMirror() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("mirror".utf8)
        let manifestData = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "acme/asr",
            "version": "mirror-v1",
            "files": [[
                "relativePath": "model.bin",
                "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                "bytes": data.count,
                "sha256": sha256(data),
            ]],
        ])
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(data: manifestData)
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/model.bin") {
                return ModelDownloadTestURLProtocol.Response(data: data)
            }
            Issue.record("Mirror-backed download unexpectedly requested \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "acme/asr",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let directory = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            resolver: HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration()),
            mirrorResolver: MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration()),
            coordinator: makeCoordinator()
        )

        #expect(directory == plan.cacheDirectory)
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == data)
        #expect(plan.isComplete())
    }

    @Test("managed downloads fall back to Hugging Face when the Muesli mirror is unavailable")
    func managedDownloadFallsBackWhenMuesliMirrorFails() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("fallback".utf8)
        let tree = try JSONSerialization.data(withJSONObject: [[
            "type": "file",
            "path": "model.bin",
            "size": data.count,
            "oid": "fallback-oid",
        ]])
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works" {
                return ModelDownloadTestURLProtocol.Response(statusCode: 503)
            }
            if url.path.contains("/tree/") {
                return ModelDownloadTestURLProtocol.Response(data: tree)
            }
            if url.path.contains("/resolve/") {
                return ModelDownloadTestURLProtocol.Response(data: data)
            }
            Issue.record("Unexpected fallback request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "acme/asr",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let directory = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            resolver: HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration()),
            mirrorResolver: MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration()),
            coordinator: makeCoordinator()
        )

        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == data)
        #expect(plan.isComplete())
    }

    @Test("managed downloads fall back to Hugging Face after a mirror transfer failure")
    func managedDownloadFallsBackWhenMuesliMirrorTransferFails() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mirroredData = Data("mirror".utf8)
        let fallbackData = Data("fallback".utf8)
        let fallbackOnlyData = Data("fallback-only".utf8)
        let mirrorOnlyData = Data("mirror-only".utf8)
        let mirrorManifest = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "acme/asr",
            "version": "mirror-v1",
            "files": [
                [
                    "relativePath": "a-mirror-only.bin",
                    "objectKey": "models/acme/asr/mirror-v1/files/a-mirror-only.bin",
                    "bytes": mirrorOnlyData.count,
                    "sha256": sha256(mirrorOnlyData),
                ],
                [
                    "relativePath": "model.bin",
                    "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                    "bytes": mirroredData.count,
                    "sha256": sha256(mirroredData),
                ],
            ],
        ])
        let tree = try JSONSerialization.data(withJSONObject: [[
            "type": "file",
            "path": "fallback-only.bin",
            "size": fallbackOnlyData.count,
            "oid": "fallback-only-oid",
        ], [
            "type": "file",
            "path": "model.bin",
            "size": fallbackData.count,
            "oid": "fallback-oid",
        ]])
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(data: mirrorManifest)
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/a-mirror-only.bin") {
                return ModelDownloadTestURLProtocol.Response(data: mirrorOnlyData)
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/model.bin") {
                return ModelDownloadTestURLProtocol.Response(statusCode: 400)
            }
            if url.path.contains("/tree/") {
                return ModelDownloadTestURLProtocol.Response(data: tree)
            }
            if url.path.contains("/resolve/") {
                if url.lastPathComponent == "fallback-only.bin" {
                    #expect(request.value(forHTTPHeaderField: "Range") == nil)
                    return ModelDownloadTestURLProtocol.Response(data: fallbackOnlyData)
                }
                return ModelDownloadTestURLProtocol.Response(data: fallbackData)
            }
            Issue.record("Unexpected transfer fallback request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "acme/asr",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin", "fallback-only.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let staleFallbackPartialURL = plan.cacheDirectory.appendingPathComponent("fallback-only.bin.part")
        try FileManager.default.createDirectory(at: plan.cacheDirectory, withIntermediateDirectories: true)
        try Data("stale fallback bytes".utf8).write(to: staleFallbackPartialURL)

        let directory = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            resolver: HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration()),
            mirrorResolver: MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration()),
            coordinator: makeCoordinator()
        )

        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == fallbackData)
        #expect(try Data(contentsOf: directory.appendingPathComponent("fallback-only.bin")) == fallbackOnlyData)
        #expect(!FileManager.default.fileExists(atPath: staleFallbackPartialURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("a-mirror-only.bin").path
        ))
        #expect(plan.isComplete())
    }

    @Test("failed fallback restores reused files from a mirror cache")
    func failedFallbackRestoresReusedMirrorCache() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reusedData = Data("reused mirror artifact".utf8)
        let mirrorData = Data("mirror model".utf8)
        let mirrorManifest = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "acme/asr",
            "version": "mirror-v1",
            "files": [
                [
                    "relativePath": "a-reused.bin",
                    "objectKey": "models/acme/asr/mirror-v1/files/a-reused.bin",
                    "bytes": reusedData.count,
                    "sha256": sha256(reusedData),
                ],
                [
                    "relativePath": "model.bin",
                    "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                    "bytes": mirrorData.count,
                    "sha256": sha256(mirrorData),
                ],
            ],
        ])
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(data: mirrorManifest)
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/model.bin") {
                return ModelDownloadTestURLProtocol.Response(statusCode: 503)
            }
            if url.path.contains("/tree/") {
                return ModelDownloadTestURLProtocol.Response(statusCode: 503)
            }
            Issue.record("Unexpected failed fallback request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "acme/asr",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let reusedURL = plan.cacheDirectory.appendingPathComponent("a-reused.bin")
        try FileManager.default.createDirectory(at: plan.cacheDirectory, withIntermediateDirectories: true)
        try reusedData.write(to: reusedURL)

        await #expect(throws: Error.self) {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration()),
                mirrorResolver: MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration()),
                coordinator: makeCoordinator()
            )
        }

        #expect(try Data(contentsOf: reusedURL) == reusedData)
        #expect(!FileManager.default.fileExists(
            atPath: plan.cacheDirectory.appendingPathComponent("model.bin").path
        ))
    }

    @Test("interrupted fallback restores its mirror cache before retrying")
    func interruptedFallbackRestoresMirrorCacheBeforeRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mirrorData = Data("mirror model".utf8)
        let mirrorManifest = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "acme/asr",
            "version": "mirror-v1",
            "files": [[
                "relativePath": "model.bin",
                "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                "bytes": mirrorData.count,
                "sha256": sha256(mirrorData),
            ]],
        ])
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(data: mirrorManifest)
            }
            // A restored, verified mirror file needs no second transfer. If
            // the interrupted Hugging Face cache were used instead, both
            // origins are deliberately unavailable and this retry would fail.
            if url.host == "assets.muesli.works" || url.path.contains("/tree/") {
                return ModelDownloadTestURLProtocol.Response(statusCode: 503)
            }
            Issue.record("Unexpected interrupted-fallback request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "acme/asr",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let interruptedFallback = root.appendingPathComponent(
            ".model.muesli-mirror-fallback-interrupted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: interruptedFallback, withIntermediateDirectories: true)
        try mirrorData.write(to: interruptedFallback.appendingPathComponent("model.bin"))

        try FileManager.default.createDirectory(at: plan.cacheDirectory, withIntermediateDirectories: true)
        try Data("partial Hugging Face bytes".utf8).write(
            to: plan.cacheDirectory.appendingPathComponent("model.bin.part")
        )
        try Data("{}".utf8).write(
            to: plan.cacheDirectory.appendingPathComponent(".muesli-download-state.json")
        )

        let directory = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            resolver: HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration()),
            mirrorResolver: MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration()),
            coordinator: makeCoordinator()
        )

        #expect(directory == plan.cacheDirectory)
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == mirrorData)
        #expect(plan.isComplete())
        #expect(!FileManager.default.fileExists(atPath: interruptedFallback.path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("model.bin.part").path
        ))
    }

    @Test("same-model callers share one mirror and fallback operation")
    func sameModelCallersShareOneDownloadOperation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("shared model".utf8)
        let mirrorManifest = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "acme/asr",
            "version": "mirror-v1",
            "files": [[
                "relativePath": "model.bin",
                "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                "bytes": data.count,
                "sha256": sha256(data),
            ]],
        ])
        let mirrorManifestTracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(
                    data: mirrorManifest,
                    chunkSize: 1,
                    delay: 0.001,
                    tracker: mirrorManifestTracker
                )
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/model.bin") {
                return ModelDownloadTestURLProtocol.Response(data: data)
            }
            Issue.record("Unexpected shared-operation request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "acme/asr",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        let mirrorResolver = MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration())
        let coordinator = makeCoordinator()
        let first = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
        }
        #expect(mirrorManifestTracker.waitUntilRequestStarts())
        let second = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
        }

        let firstDirectory = try await first.value
        let secondDirectory = try await second.value
        #expect(firstDirectory == plan.cacheDirectory)
        #expect(secondDirectory == plan.cacheDirectory)
        #expect(mirrorManifestTracker.requestCount == 1)
        #expect(try Data(contentsOf: plan.cacheDirectory.appendingPathComponent("model.bin")) == data)
    }

    @Test("cancelling the owner caller preserves a shared model operation")
    func cancellingOwnerCallerPreservesSharedModelOperation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x42, count: 512 * 1024)
        let mirrorManifest = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "owner-cancellation",
            "version": "mirror-v1",
            "files": [[
                "relativePath": "model.bin",
                "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                "bytes": data.count,
                "sha256": sha256(data),
            ]],
        ])
        let modelTracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(data: mirrorManifest)
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/model.bin") {
                return ModelDownloadTestURLProtocol.Response(
                    data: data,
                    chunkSize: 4 * 1024,
                    delay: 0.002,
                    tracker: modelTracker
                )
            }
            Issue.record("Unexpected owner-cancellation request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "owner-cancellation",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        let mirrorResolver = MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration())
        let coordinator = makeCoordinator()
        let firstReturned = DownloadCompletionFlag()
        let first = Task {
            do {
                let directory = try await ManagedASRModelDownloader.downloadIfNeeded(
                    plan,
                    resolver: resolver,
                    mirrorResolver: mirrorResolver,
                    coordinator: coordinator
                )
                firstReturned.markCompleted()
                return directory
            } catch {
                firstReturned.markCompleted()
                throw error
            }
        }
        #expect(modelTracker.waitUntilRequestStarts())
        let second = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()

        try await Task.sleep(for: .milliseconds(20))
        #expect(firstReturned.isCompleted)
        let secondDirectory = try await second.value
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(secondDirectory == plan.cacheDirectory)
        #expect(modelTracker.requestCount == 1)
        #expect(try Data(contentsOf: plan.cacheDirectory.appendingPathComponent("model.bin")) == data)
    }

    @Test("cancelling a model permits an immediate fresh retry")
    func cancellingModelPermitsImmediateFreshRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x7F, count: 512 * 1024)
        let mirrorManifest = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "cancel-and-immediate-retry",
            "version": "mirror-v1",
            "files": [[
                "relativePath": "model.bin",
                "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                "bytes": data.count,
                "sha256": sha256(data),
            ]],
        ])
        let modelTracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(data: mirrorManifest)
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/model.bin") {
                return ModelDownloadTestURLProtocol.Response(
                    data: data,
                    chunkSize: 4 * 1024,
                    delay: 0.002,
                    tracker: modelTracker
                )
            }
            Issue.record("Unexpected immediate-cancellation-retry request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "cancel-and-immediate-retry",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        let mirrorResolver = MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration())
        let coordinator = makeCoordinator()
        let first = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
        }
        #expect(modelTracker.waitUntilRequestStarts())

        await ManagedASRModelDownloader.cancel(
            modelID: plan.modelID,
            coordinator: coordinator
        )

        let retry = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        let directory = try await retry.value
        #expect(directory == plan.cacheDirectory)
        #expect(modelTracker.requestCount == 2)
        #expect(try Data(contentsOf: plan.cacheDirectory.appendingPathComponent("model.bin")) == data)
    }

    @Test("cancelling and waiting permits an immediate fresh model retry")
    func cancellingAndWaitingPermitsImmediateFreshModelRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 0x7F, count: 512 * 1024)
        let mirrorManifest = try JSONSerialization.data(withJSONObject: [
            "format": "muesli-r2-model-manifest-v1",
            "modelID": "cancel-and-wait-retry",
            "version": "mirror-v1",
            "files": [[
                "relativePath": "model.bin",
                "objectKey": "models/acme/asr/mirror-v1/files/model.bin",
                "bytes": data.count,
                "sha256": sha256(data),
            ]],
        ])
        let modelTracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            guard let url = request.url else { fatalError("Expected request URL") }
            if url.host == "assets.muesli.works", url.lastPathComponent == "manifest.json" {
                return ModelDownloadTestURLProtocol.Response(data: mirrorManifest)
            }
            if url.host == "assets.muesli.works", url.path.hasSuffix("/files/model.bin") {
                return ModelDownloadTestURLProtocol.Response(
                    data: data,
                    chunkSize: 4 * 1024,
                    delay: 0.002,
                    tracker: modelTracker
                )
            }
            Issue.record("Unexpected cancellation-wait-retry request \(url.absoluteString)")
            return ModelDownloadTestURLProtocol.Response(statusCode: 500)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let plan = ManagedASRModelPlan(
            modelID: "cancel-and-wait-retry",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        let mirrorResolver = MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration())
        let coordinator = makeCoordinator()
        let first = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                mirrorResolver: mirrorResolver,
                coordinator: coordinator
            )
        }
        #expect(modelTracker.waitUntilRequestStarts())

        await ManagedASRModelDownloader.cancelAndWait(
            modelID: plan.modelID,
            coordinator: coordinator
        )
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }

        let directory = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            resolver: resolver,
            mirrorResolver: mirrorResolver,
            coordinator: coordinator
        )
        #expect(directory == plan.cacheDirectory)
        #expect(modelTracker.requestCount == 2)
        #expect(try Data(contentsOf: plan.cacheDirectory.appendingPathComponent("model.bin")) == data)
    }

    @Test("cancelling mirror manifest resolution does not fall back to Hugging Face")
    func cancellingMirrorManifestResolutionDoesNotFallBack() async throws {
        let mirrorTracker = DownloadTestTracker()
        let fallbackTracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            if request.url?.host == "assets.muesli.works" {
                return ModelDownloadTestURLProtocol.Response(
                    data: Data(repeating: 0x7B, count: 512 * 1024),
                    chunkSize: 128,
                    delay: 0.002,
                    tracker: mirrorTracker
                )
            }
            return ModelDownloadTestURLProtocol.Response(tracker: fallbackTracker)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlan(
            modelID: "mirror-manifest-cancel",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]],
            mirror: MuesliModelMirror(manifestURL: try #require(URL(string: "https://assets.muesli.works/models/acme/asr/mirror-v1/manifest.json")))
        )
        let coordinator = makeCoordinator()
        let task = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration()),
                mirrorResolver: MuesliModelMirrorManifestResolver(configuration: makeSessionConfiguration()),
                coordinator: coordinator
            )
        }
        #expect(mirrorTracker.waitUntilRequestStarts())

        await ManagedASRModelDownloader.cancel(modelID: plan.modelID, coordinator: coordinator)
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(fallbackTracker.requestCount == 0)
    }

    @Test("managed ASR plans require complete compiled artifacts")
    func managedASRPlanCompleteness() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlans.qwen3ASRInt8(modelsRoot: root)
        #expect(plan.cacheDirectory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))

        try FileManager.default.createDirectory(
            at: plan.cacheDirectory.appendingPathComponent("qwen3_asr_audio_encoder_v2.mlmodelc"),
            withIntermediateDirectories: true
        )
        #expect(!plan.isComplete())

        for relativePath in [
            "qwen3_asr_audio_encoder_v2.mlmodelc/coremldata.bin",
            "qwen3_asr_audio_encoder_v2.mlmodelc/weights/weight.bin",
            "qwen3_asr_decoder_stateful.mlmodelc/coremldata.bin",
            "qwen3_asr_decoder_stateful.mlmodelc/weights/weight.bin",
            "qwen3_asr_embeddings.bin",
            "vocab.json",
        ] {
            let url = plan.cacheDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x01]).write(to: url)
        }

        #expect(!plan.isComplete())
        #expect(plan.isAvailableLocally())
        let partialState = plan.cacheDirectory.appendingPathComponent(".muesli-download-state.json")
        try Data("{}".utf8).write(to: partialState)
        #expect(!plan.isAvailableLocally())
        try FileManager.default.removeItem(at: partialState)
        let partialFile = plan.cacheDirectory.appendingPathComponent("pending.bin.part")
        try Data([0x01]).write(to: partialFile)
        #expect(!plan.isAvailableLocally())
        try FileManager.default.removeItem(at: partialFile)

        try plan.recordValidatedLegacyInstallationIfNeeded()
        #expect(plan.isComplete())

        try FileManager.default.removeItem(
            at: plan.cacheDirectory.appendingPathComponent(
                "qwen3_asr_audio_encoder_v2.mlmodelc/weights/weight.bin"
            )
        )
        #expect(!plan.isComplete())
        #expect(!plan.isAvailableLocally())
        #expect(plan.modelID == "FluidInference/qwen3-asr-0.6b-coreml")
        #expect(plan.cacheDirectory.path.hasSuffix("qwen3-asr-0.6b/int8"))
        #expect(plan.selections.count == 1)
        #expect(plan.selections[0].remoteDirectory == "int8")
        #expect(plan.selections[0].includedPaths.contains("vocab.json"))

        let parakeet = ManagedASRModelPlans.parakeetV2(modelsRoot: root)
        #expect(parakeet.mirror?.manifestURL.absoluteString == "https://assets.muesli.works/models/fluidaudio/parakeet-tdt-0.6b-v2/legacy-local-v1/manifest.json")

        let parakeetV3 = ManagedASRModelPlans.parakeetV3(modelsRoot: root)
        #expect(parakeetV3.mirror?.manifestURL.absoluteString == "https://assets.muesli.works/models/fluidaudio/parakeet-tdt-0.6b-v3/legacy-local-v1/manifest.json")

        let unified = ManagedASRModelPlans.parakeetUnified(modelsRoot: root)
        #expect(unified.mirror?.manifestURL.absoluteString == "https://assets.muesli.works/models/fluidaudio/parakeet-unified-en-0.6b/legacy-local-v1/manifest.json")

        let whisper = ManagedASRModelPlans.whisperKit(modelName: "tiny", downloadRoot: root)
        #expect(whisper.selections[0].includedPaths.contains("AudioEncoder.mlmodelc"))
        #expect(whisper.selections[0].includedPaths.contains("config.json"))
        #expect(whisper.selections[0].includedPaths.contains("generation_config.json"))
        #expect(!whisper.selections[0].includedPaths.contains("AudioEncoder.mlpackage"))
        #expect(whisper.mirror?.manifestURL.absoluteString == "https://assets.muesli.works/models/whisperkit/openai_whisper-tiny/legacy-local-v1/manifest.json")
    }

    @Test("supported WhisperKit variants have immutable Muesli mirrors")
    func mirroredWhisperKitVariants() {
        let expectedPaths = [
            "tiny": "openai_whisper-tiny",
            "tiny.en": "openai_whisper-tiny.en",
            "small": "openai_whisper-small",
            "small.en": "openai_whisper-small.en",
            "medium.en": "openai_whisper-medium.en",
            "large-v3-v20240930_626MB": "openai_whisper-large-v3-v20240930_626MB",
        ]

        for (modelName, remoteDirectory) in expectedPaths {
            let plan = ManagedASRModelPlans.whisperKit(modelName: modelName)
            #expect(plan.mirror?.manifestURL.absoluteString == "https://assets.muesli.works/models/whisperkit/\(remoteDirectory)/legacy-local-v1/manifest.json")
        }

        #expect(ManagedASRModelPlans.whisperKit(modelName: "distil-large-v3").mirror == nil)
    }

    @Test("English-only Whisper checkpoints use their exact downloadable cache identities")
    func englishWhisperCheckpointAvailability() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for modelName in ["tiny.en", "small.en", "medium.en"] {
            let plan = ManagedASRModelPlans.whisperKit(modelName: modelName, downloadRoot: root)
            #expect(plan.modelID == modelName)
            #expect(plan.cacheDirectory.lastPathComponent == "openai_whisper-\(modelName)")
            #expect(plan.selections[0].remoteDirectory == "openai_whisper-\(modelName)")

            for model in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
                for artifact in ["coremldata.bin", "weights/weight.bin"] {
                    let url = plan.cacheDirectory
                        .appendingPathComponent(model, isDirectory: true)
                        .appendingPathComponent(artifact)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data([0x01]).write(to: url)
                }
            }
            try Data("{}".utf8).write(
                to: plan.cacheDirectory.appendingPathComponent("config.json")
            )
            try Data("{}".utf8).write(
                to: plan.cacheDirectory.appendingPathComponent("generation_config.json")
            )

            #expect(plan.isAvailableLocally())
        }

        let incompleteSmall = ManagedASRModelPlans.whisperKit(
            modelName: "small.en",
            downloadRoot: root
        )
        try FileManager.default.removeItem(
            at: incompleteSmall.cacheDirectory
                .appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")
        )
        #expect(!incompleteSmall.isAvailableLocally())
    }

    @Test("legacy ASR installs stay available without manifest discovery")
    func legacyASRInstallSkipsNetworkResolution() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { _ in
            Issue.record("Legacy installation unexpectedly requested the network")
            return ModelDownloadTestURLProtocol.Response(tracker: tracker)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlans.qwen3ASRInt8(modelsRoot: root)
        for relativePath in [
            "qwen3_asr_audio_encoder_v2.mlmodelc/coremldata.bin",
            "qwen3_asr_audio_encoder_v2.mlmodelc/weights/weight.bin",
            "qwen3_asr_decoder_stateful.mlmodelc/coremldata.bin",
            "qwen3_asr_decoder_stateful.mlmodelc/weights/weight.bin",
            "qwen3_asr_embeddings.bin",
            "vocab.json",
        ] {
            let url = plan.cacheDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0x01]).write(to: url)
        }

        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        let directory = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            resolver: resolver,
            coordinator: makeCoordinator()
        )
        #expect(directory == plan.cacheDirectory)
        #expect(tracker.requestCount == 0)
        #expect(!plan.isComplete())
        #expect(plan.isAvailableLocally())
    }

    @Test("invalid legacy ASR installs are replaced after runtime validation fails")
    func invalidLegacyASRInstallIsRepaired() async throws {
        let tracker = DownloadTestTracker()
        let tree = try JSONSerialization.data(withJSONObject: [[
            "type": "file",
            "path": "model.bin",
            "size": 4,
            "oid": "model-oid",
        ]])
        ModelDownloadTestURLProtocol.install { request in
            let data = request.url?.path.contains("/resolve/") == true
                ? Data("good".utf8)
                : tree
            return ModelDownloadTestURLProtocol.Response(data: data, tracker: tracker)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlan(
            modelID: "legacy-repair",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]]
        )
        try FileManager.default.createDirectory(at: plan.cacheDirectory, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: plan.cacheDirectory.appendingPathComponent("model.bin"))
        #expect(plan.requiresRuntimeValidation())

        let attempts = DownloadResponseSequence()
        let value = try await ManagedASRModelDownloader.loadValidated(
            plan,
            resolver: HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration()),
            coordinator: makeCoordinator()
        ) { directory in
            let data = try Data(contentsOf: directory.appendingPathComponent("model.bin"))
            guard data == Data("good".utf8) else {
                _ = attempts.next()
                throw NSError(domain: "LegacyRuntimeValidation", code: 1)
            }
            _ = attempts.next()
            return String(decoding: data, as: UTF8.self)
        }

        #expect(value == "good")
        #expect(attempts.current == 2)
        // The repair must list the model and transfer its artifact. Transport
        // retries are permitted by both stages, so they are not part of this
        // legacy-cache repair contract.
        #expect(tracker.requestCount >= 2)
        #expect(plan.isComplete())
    }

    @Test("cancelled legacy validation preserves the offline cache")
    func cancelledLegacyValidationPreservesCache() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlan(
            modelID: "legacy-validation-cancel",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]]
        )
        try FileManager.default.createDirectory(at: plan.cacheDirectory, withIntermediateDirectories: true)
        let modelURL = plan.cacheDirectory.appendingPathComponent("model.bin")
        try Data("legacy".utf8).write(to: modelURL)

        await #expect(throws: CancellationError.self) {
            try await ManagedASRModelDownloader.loadValidated(plan) { _ in
                throw CancellationError()
            }
        }

        #expect(FileManager.default.fileExists(atPath: modelURL.path))
        #expect(plan.requiresRuntimeValidation())
    }

    @Test("managed ASR deletion cancels manifest discovery and blocks replacement work")
    func managedASRDeletionOwnsManifestDiscovery() async throws {
        let tracker = DownloadTestTracker()
        let page = try JSONSerialization.data(withJSONObject: [[
            "type": "file",
            "path": "model.bin",
            "size": 1,
            "oid": String(repeating: "x", count: 64 * 1024),
        ]])
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: page,
                chunkSize: 128,
                delay: 0.002,
                tracker: tracker
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlan(
            modelID: "managed-resolve-cancel",
            repository: "acme/asr",
            cacheDirectory: root.appendingPathComponent("model", isDirectory: true),
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])],
            requiredArtifactAlternatives: [["model.bin"]]
        )
        let resolver = HuggingFaceModelManifestResolver(configuration: makeSessionConfiguration())
        let coordinator = makeCoordinator()
        let task = Task {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                coordinator: coordinator
            )
        }
        #expect(tracker.waitUntilRequestStarts())

        let deletionToken = await ManagedASRModelDownloader.beginDeletion(
            modelID: plan.modelID,
            coordinator: coordinator
        )
        do {
            _ = try await task.value
            Issue.record("Manifest discovery unexpectedly completed after deletion began")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        await #expect(throws: CancellationError.self) {
            try await ManagedASRModelDownloader.downloadIfNeeded(
                plan,
                resolver: resolver,
                coordinator: coordinator
            )
        }
        await ManagedASRModelDownloader.endDeletion(deletionToken)
        #expect(!FileManager.default.fileExists(atPath: plan.cacheDirectory.path))
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

    @Test("same model IDs isolate different manifests and destinations")
    func sameModelIDDoesNotCrossInstallDestinations() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x42, count: 512 * 1024),
                chunkSize: 4 * 1024,
                delay: 0.002,
                tracker: tracker
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let remoteURL = try #require(URL(string: "https://example.com/model"))
        let firstManifest = ModelDownloadManifest(
            id: "same-model-id",
            version: "1",
            files: [ModelDownloadFile(relativePath: "first.bin", remoteURL: remoteURL, expectedByteCount: 512 * 1024)],
            maximumConcurrency: 1
        )
        let secondManifest = ModelDownloadManifest(
            id: "same-model-id",
            version: "1",
            files: [ModelDownloadFile(relativePath: "second.bin", remoteURL: remoteURL, expectedByteCount: 512 * 1024)],
            maximumConcurrency: 1
        )

        let first = Task { try await coordinator.download(firstManifest, to: firstDirectory) }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await coordinator.download(secondManifest, to: secondDirectory) }

        try await first.value
        try await second.value

        #expect(tracker.requestCount == 2)
        #expect(FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent("first.bin").path))
        #expect(FileManager.default.fileExists(atPath: secondDirectory.appendingPathComponent("second.bin").path))
    }

    @Test("conflicting same-model manifests do not write one destination concurrently")
    func conflictingSameDestinationIsRejected() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x42, count: 512 * 1024),
                chunkSize: 4 * 1024,
                delay: 0.002,
                tracker: tracker
            )
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remoteURL = try #require(URL(string: "https://example.com/model"))
        let firstManifest = ModelDownloadManifest(
            id: "same-destination-model",
            version: "1",
            files: [ModelDownloadFile(relativePath: "first.bin", remoteURL: remoteURL, expectedByteCount: 512 * 1024)],
            maximumConcurrency: 1
        )
        let secondManifest = ModelDownloadManifest(
            id: "same-destination-model",
            version: "1",
            files: [ModelDownloadFile(relativePath: "second.bin", remoteURL: remoteURL, expectedByteCount: 512 * 1024)],
            maximumConcurrency: 1
        )

        let first = Task { try await coordinator.download(firstManifest, to: directory) }
        try await Task.sleep(for: .milliseconds(20))
        do {
            try await coordinator.download(secondManifest, to: directory)
            Issue.record("Conflicting same-destination download unexpectedly started")
        } catch is ModelDownloadError {
            // Expected: only one manifest may write a model destination at a time.
        }
        try await first.value
        #expect(tracker.requestCount == 1)
    }

    @Test("removal fails while a download owns the destination")
    func removalFailsWhileDownloadIsActive() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x42, count: 512 * 1024),
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
            id: "active-removal",
            version: "1",
            files: [ModelDownloadFile(
                relativePath: "model.bin",
                remoteURL: try #require(URL(string: "https://example.com/model")),
                expectedByteCount: 512 * 1024
            )],
            maximumConcurrency: 1
        )
        let task = Task { try await coordinator.download(manifest, to: directory) }
        #expect(tracker.waitUntilRequestStarts())

        await #expect(throws: ModelDownloadError.self) {
            try await coordinator.removeDownload(manifest, at: directory)
        }
        await coordinator.cancelAndWait(modelID: manifest.id)
        do {
            try await task.value
            Issue.record("Cancellation unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("cancelling one duplicate caller does not cancel the shared transfer")
    func cancellingOneDuplicateCallerPreservesSharedTransfer() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x42, count: 2 * 1024 * 1024),
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
            id: "duplicate-cancellation",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")), expectedByteCount: 2 * 1024 * 1024)],
            maximumConcurrency: 1
        )

        let firstReturned = DownloadCompletionFlag()
        let first = Task {
            do {
                try await coordinator.download(manifest, to: directory)
            } catch {
                firstReturned.markCompleted()
                throw error
            }
            firstReturned.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await coordinator.download(manifest, to: directory) }
        first.cancel()

        try await Task.sleep(for: .milliseconds(20))
        #expect(firstReturned.isCompleted)
        try await second.value
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        #expect(tracker.requestCount == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.bin").path))
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

    @Test("recovers from HTTP 416 on the final retry")
    func finalAttempt416ResetsAndRetriesFromZero() async throws {
        let tracker = DownloadTestTracker()
        let sequence = DownloadResponseSequence()
        ModelDownloadTestURLProtocol.install { request in
            switch sequence.next() {
            case 1, 2:
                return ModelDownloadTestURLProtocol.Response(statusCode: 503, tracker: tracker)
            case 3:
                #expect(request.value(forHTTPHeaderField: "Range") != nil)
                return ModelDownloadTestURLProtocol.Response(statusCode: 416, tracker: tracker)
            default:
                #expect(request.value(forHTTPHeaderField: "Range") == nil)
                return ModelDownloadTestURLProtocol.Response(data: Data("hello".utf8), tracker: tracker)
            }
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("stale".utf8).write(to: directory.appendingPathComponent("model.bin.part"))
        let manifest = ModelDownloadManifest(
            id: "final-attempt-416",
            version: "1",
            files: [ModelDownloadFile(
                relativePath: "model.bin",
                remoteURL: try #require(URL(string: "https://example.com/model")),
                expectedByteCount: 5
            )],
            maximumConcurrency: 1
        )

        try await coordinator.download(manifest, to: directory)

        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == Data("hello".utf8))
        #expect(tracker.requestCount == 4)
    }

    @Test("repeated HTTP 416 responses respect the retry limit")
    func repeated416sExhaustRetries() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return ModelDownloadTestURLProtocol.Response(statusCode: 416, tracker: tracker)
        }
        defer { ModelDownloadTestURLProtocol.uninstall() }

        let coordinator = makeCoordinator()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = ModelDownloadManifest(
            id: "repeated-416",
            version: "1",
            files: [ModelDownloadFile(relativePath: "model.bin", remoteURL: try #require(URL(string: "https://example.com/model")))],
            maximumConcurrency: 1
        )

        await #expect(throws: ModelDownloadError.self) {
            try await coordinator.download(manifest, to: directory)
        }
        #expect(tracker.requestCount == 6)
    }

    @Test("cancel and wait preserves the partial file and finishes before deletion")
    func cancellationPreservesPartialFile() async throws {
        let tracker = DownloadTestTracker()
        ModelDownloadTestURLProtocol.install { _ in
            ModelDownloadTestURLProtocol.Response(
                data: Data(repeating: 0x43, count: 512 * 1024),
                chunkSize: 4 * 1024,
                delay: 0.01,
                tracker: tracker
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
        #expect(tracker.waitUntilRequestStarts())
        let partURL = directory.appendingPathComponent("model.bin.part")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: partURL.path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: partURL.path))
        await coordinator.cancelAndWait(modelID: manifest.id)
        do {
            try await task.value
            Issue.record("Cancellation unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }

        #expect(FileManager.default.fileExists(atPath: partURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.bin").path))
        try FileManager.default.removeItem(at: partURL)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    private func makeCoordinator() -> ModelDownloadCoordinator {
        ModelDownloadCoordinator(configuration: makeSessionConfiguration())
    }

    private func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadTestURLProtocol.self]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-download-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

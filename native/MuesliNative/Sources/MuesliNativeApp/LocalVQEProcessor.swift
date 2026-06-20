import CryptoKit
import Foundation
import LocalVQEBridge

enum LocalVQEError: Error, LocalizedError {
    case modelMissing(URL)
    case libraryMissing([URL])
    case loadFailed(String)
    case invalidRuntime(sampleRate: Int, hopLength: Int)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            return "LocalVQE model not found at \(url.path)"
        case .libraryMissing(let candidates):
            return "LocalVQE library not found in: \(candidates.map(\.path).joined(separator: ", "))"
        case .loadFailed(let message):
            return "LocalVQE failed to load: \(message)"
        case .invalidRuntime(let sampleRate, let hopLength):
            return "LocalVQE runtime reported unsupported sampleRate=\(sampleRate), hopLength=\(hopLength)"
        case .processFailed(let message):
            return "LocalVQE frame processing failed: \(message)"
        }
    }
}

enum LocalVQEModelStore {
    static let fileName = "localvqe-v1.2-1.3M-f32.gguf"
    static let sha256 = "4856ecf5f522b23fb2bc5caeac81f323c0ef1c4c156a9c7d40a6adbe092ba9ce"
    private static let downloadURL = URL(string: "https://huggingface.co/LocalAI-io/LocalVQE/resolve/main/localvqe-v1.2-1.3M-f32.gguf")!

    static var defaultModelURL: URL {
        AppIdentity.supportDirectoryURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("localvqe", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static var bundledModelURL: URL? {
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("localvqe", isDirectory: true)
                .appendingPathComponent(fileName),
            Bundle.main.url(forResource: "localvqe-v1.2-1.3M-f32", withExtension: "gguf"),
        ].compactMap { $0 }

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func resolveModelURL(downloadIfMissing: Bool = true) async throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MUESLI_LOCALVQE_MODEL_PATH"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LocalVQEError.modelMissing(url) }
            return url
        }

        let url = defaultModelURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try validateModel(at: url)
                return url
            } catch {
                fputs("[localvqe] ignoring invalid cached model at \(url.path): \(error)\n", stderr)
            }
        }

        if let bundledURL = bundledModelURL {
            try validateModel(at: bundledURL)
            return bundledURL
        }
        guard downloadIfMissing else { throw LocalVQEError.modelMissing(url) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(fileName).\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        fputs("[localvqe] downloading model to \(url.path)\n", stderr)
        let (downloadedURL, _) = try await URLSession.shared.download(from: downloadURL)
        try FileManager.default.moveItem(at: downloadedURL, to: temporaryURL)
        try validateModel(at: temporaryURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try validateModel(at: url)
            return url
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
        return url
    }

    private static func validateModel(at url: URL) throws {
        let actualHash = try sha256Hex(for: url)
        guard actualHash == sha256 else {
            throw LocalVQEError.loadFailed("model checksum mismatch at \(url.path): expected \(sha256), got \(actualHash)")
        }
    }

    private static func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LocalVQELibraryLocator {
    static func resolve(explicitPath: String? = ProcessInfo.processInfo.environment["MUESLI_LOCALVQE_LIBRARY_PATH"]) throws -> URL {
        if let explicitPath, !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LocalVQEError.libraryMissing([url]) }
            return url
        }

        let candidates = candidateURLs()
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw LocalVQEError.libraryMissing(candidates)
        }
        return found
    }

    static func candidateURLs(mainBundle: Bundle = .main) -> [URL] {
        let names = ["liblocalvqe.dylib", "liblocalvqe.0.1.0.dylib", "liblocalvqe_shared.dylib"]
        let roots = [
            mainBundle.executableURL?.deletingLastPathComponent(),
            mainBundle.privateFrameworksURL,
            mainBundle.resourceURL,
        ].compactMap { $0 }
        #if DEBUG
        let debugRoots = [
            URL(fileURLWithPath: "/usr/local/lib", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/lib", isDirectory: true),
        ]
        #else
        let debugRoots: [URL] = []
        #endif

        var seen = Set<String>()
        return (roots + debugRoots).flatMap { root in
            names.map { root.appendingPathComponent($0) }
        }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

final class LocalVQEAudioProcessor: MeetingAecProcessor {
    let name = "localvqe"
    let modelPath: String
    let libraryPath: String

    private var context: OpaquePointer?
    private(set) var frameSize = 256
    private(set) var sampleRate = 16_000

    static func load(downloadModelIfMissing: Bool = true, threads: Int = 2) async throws -> LocalVQEAudioProcessor {
        let modelURL = try await LocalVQEModelStore.resolveModelURL(downloadIfMissing: downloadModelIfMissing)
        let libraryURL = try LocalVQELibraryLocator.resolve()
        return try LocalVQEAudioProcessor(modelURL: modelURL, libraryURL: libraryURL, threads: threads)
    }

    init(modelURL: URL, libraryURL: URL, threads: Int) throws {
        modelPath = modelURL.path
        libraryPath = libraryURL.path
        var error = [CChar](repeating: 0, count: 2048)
        context = modelPath.withCString { modelCString in
            libraryPath.withCString { libraryCString in
                muesli_localvqe_create(
                    modelCString,
                    libraryCString,
                    Int32(threads),
                    &error,
                    Int32(error.count)
                )
            }
        }

        guard let context else {
            throw LocalVQEError.loadFailed(String(cString: error))
        }

        sampleRate = Int(muesli_localvqe_sample_rate(context))
        frameSize = Int(muesli_localvqe_hop_length(context))
        guard sampleRate == 16_000, frameSize == 256 else {
            throw LocalVQEError.invalidRuntime(sampleRate: sampleRate, hopLength: frameSize)
        }
    }

    deinit {
        if let context {
            muesli_localvqe_destroy(context)
        }
    }

    func reset() {
        guard let context else { return }
        muesli_localvqe_reset(context)
    }

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        guard let context else { throw LocalVQEError.loadFailed("runtime is not loaded") }
        guard mic.count == frameSize, reference.count == frameSize else {
            throw LocalVQEError.processFailed("expected \(frameSize) samples, got mic=\(mic.count), reference=\(reference.count)")
        }

        var output = [Float](repeating: 0, count: frameSize)
        let status = mic.withUnsafeBufferPointer { micBuffer in
            reference.withUnsafeBufferPointer { referenceBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    muesli_localvqe_process_frame_f32(
                        context,
                        micBuffer.baseAddress,
                        referenceBuffer.baseAddress,
                        Int32(frameSize),
                        outputBuffer.baseAddress
                    )
                }
            }
        }

        guard status == 0 else {
            throw LocalVQEError.processFailed(String(cString: muesli_localvqe_last_error(context)))
        }
        return output
    }
}

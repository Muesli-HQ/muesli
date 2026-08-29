import Foundation

/// A pinned, public Muesli model manifest hosted at the trusted asset origin.
///
/// The manifest is immutable for a released app build. It supplies the exact
/// files, sizes, and checksums used by the existing resumable downloader.
public struct MuesliModelMirror: Hashable, Sendable {
    public let manifestURL: URL

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }
}

/// Errors raised while validating a Muesli-hosted model manifest.
public enum MuesliModelMirrorManifestError: Error, LocalizedError, Sendable {
    case untrustedManifestURL(URL)
    case invalidHTTPStatus(Int, URL)
    case invalidManifest(URL)
    case unexpectedFormat(String)
    case unexpectedModelID(expected: String, actual: String)
    case invalidVersion
    case invalidFile(String)
    case duplicatePath(String)

    public var errorDescription: String? {
        switch self {
        case .untrustedManifestURL(let url):
            return "The model mirror manifest is not hosted at the trusted asset origin: \(url.host ?? url.absoluteString)"
        case .invalidHTTPStatus(let status, _):
            return "The model mirror returned HTTP \(status)"
        case .invalidManifest:
            return "The model mirror returned an invalid manifest"
        case .unexpectedFormat(let format):
            return "The model mirror manifest has an unsupported format: \(format)"
        case .unexpectedModelID(let expected, let actual):
            return "The model mirror manifest is for \(actual), not \(expected)"
        case .invalidVersion:
            return "The model mirror manifest has no immutable version"
        case .invalidFile(let path):
            return "The model mirror has an invalid file entry: \(path)"
        case .duplicatePath(let path):
            return "The model mirror lists \(path) more than once"
        }
    }
}

/// Resolves Muesli's immutable R2-backed model manifests into downloader manifests.
///
/// This deliberately accepts only the production asset origin and objects below
/// the manifest's own `files/` directory. A malformed remote manifest therefore
/// cannot redirect a client to an arbitrary host or another model release.
public final class MuesliModelMirrorManifestResolver: @unchecked Sendable {
    public static let shared = MuesliModelMirrorManifestResolver()

    private static let assetHost = "assets.muesli.works"
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .default) {
        let configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    public func resolve(
        modelID: String,
        mirror: MuesliModelMirror,
        maximumConcurrency: Int = 2
    ) async throws -> ModelDownloadManifest {
        guard Self.isTrustedAssetURL(mirror.manifestURL) else {
            throw MuesliModelMirrorManifestError.untrustedManifestURL(mirror.manifestURL)
        }

        let (data, response) = try await session.data(from: mirror.manifestURL)
        // See the Hugging Face resolver: a completed URLSession request does
        // not by itself mean the enclosing model operation is still wanted.
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MuesliModelMirrorManifestError.invalidManifest(mirror.manifestURL)
        }
        guard http.url == mirror.manifestURL else {
            throw MuesliModelMirrorManifestError.invalidManifest(mirror.manifestURL)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MuesliModelMirrorManifestError.invalidHTTPStatus(http.statusCode, mirror.manifestURL)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw MuesliModelMirrorManifestError.invalidManifest(mirror.manifestURL)
        }
        guard payload.format == "muesli-r2-model-manifest-v1" else {
            throw MuesliModelMirrorManifestError.unexpectedFormat(payload.format)
        }
        guard payload.modelID == modelID else {
            throw MuesliModelMirrorManifestError.unexpectedModelID(
                expected: modelID,
                actual: payload.modelID
            )
        }
        let version = payload.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { throw MuesliModelMirrorManifestError.invalidVersion }

        let objectKeyPrefix = Self.objectKeyPrefix(for: mirror.manifestURL)
        var seenPaths = Set<String>()
        let files = try payload.files.map { entry -> ModelDownloadFile in
            guard Self.isSafeRelativePath(entry.relativePath),
                  entry.bytes > 0,
                  Self.isSHA256(entry.sha256),
                  entry.objectKey.hasPrefix(objectKeyPrefix),
                  Self.isSafeObjectKey(entry.objectKey),
                  !entry.objectKey.contains("?") && !entry.objectKey.contains("#")
            else {
                throw MuesliModelMirrorManifestError.invalidFile(entry.relativePath)
            }
            guard seenPaths.insert(entry.relativePath).inserted else {
                throw MuesliModelMirrorManifestError.duplicatePath(entry.relativePath)
            }
            guard let remoteURL = Self.objectURL(for: entry.objectKey, relativeTo: mirror.manifestURL) else {
                throw MuesliModelMirrorManifestError.invalidFile(entry.relativePath)
            }
            return ModelDownloadFile(
                relativePath: entry.relativePath,
                remoteURL: remoteURL,
                expectedByteCount: entry.bytes,
                sha256: entry.sha256
            )
        }
        guard !files.isEmpty else { throw MuesliModelMirrorManifestError.invalidManifest(mirror.manifestURL) }

        return ModelDownloadManifest(
            id: modelID,
            version: version,
            files: files.sorted { $0.relativePath < $1.relativePath },
            maximumConcurrency: maximumConcurrency
        )
    }

    private struct Payload: Decodable {
        let format: String
        let modelID: String
        let version: String?
        let files: [File]

        struct File: Decodable {
            let relativePath: String
            let objectKey: String
            let bytes: Int64
            let sha256: String
        }
    }

    private static func isTrustedAssetURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.caseInsensitiveCompare(assetHost) == .orderedSame
            && url.query == nil
            && url.fragment == nil
            && url.lastPathComponent == "manifest.json"
    }

    private static func objectKeyPrefix(for manifestURL: URL) -> String {
        let directory = manifestURL.deletingLastPathComponent().path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return directory + "/files/"
    }

    private static func objectURL(for key: String, relativeTo manifestURL: URL) -> URL? {
        guard var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/" + key
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("\\")
            && components.allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func isSafeObjectKey(_ key: String) -> Bool {
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        return !key.isEmpty
            && !key.hasPrefix("/")
            && !key.contains("\\")
            && components.allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...70).contains(scalar.value)
                || (97...102).contains(scalar.value)
        }
    }
}

import CryptoKit
import Foundation

/// Selects a complete Hugging Face directory or a subset of its top-level artifacts.
public struct HuggingFaceModelSelection: Hashable, Sendable {
    /// Directory inside the repository. `nil` selects the repository root.
    public let remoteDirectory: String?
    /// Files or directories relative to `remoteDirectory`. An empty set selects everything.
    public let includedPaths: Set<String>
    /// Optional directory prepended to the local manifest paths.
    public let destinationDirectory: String?
    /// Whether the Hugging Face tree API should return descendants.
    public let recursive: Bool

    public init(
        remoteDirectory: String? = nil,
        includedPaths: Set<String> = [],
        destinationDirectory: String? = nil,
        recursive: Bool = true
    ) {
        self.remoteDirectory = Self.normalized(remoteDirectory)
        self.includedPaths = Set(includedPaths.compactMap(Self.normalized))
        self.destinationDirectory = Self.normalized(destinationDirectory)
        self.recursive = recursive
    }

    private static func normalized(_ path: String?) -> String? {
        guard let path else { return nil }
        let value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.isEmpty ? nil : value
    }
}

/// Errors reported while converting Hugging Face repository metadata into a manifest.
public enum HuggingFaceModelManifestError: Error, LocalizedError, Sendable {
    case invalidRepository(String)
    case invalidResponse(String)
    case invalidHTTPStatus(Int, String)
    case emptySelection(String)
    case conflictingDestination(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let repository):
            return "Invalid Hugging Face repository: \(repository)"
        case .invalidResponse(let path):
            return "Hugging Face returned invalid model metadata for \(path)"
        case .invalidHTTPStatus(let status, let path):
            return "Hugging Face returned HTTP \(status) while listing \(path)"
        case .emptySelection(let path):
            return "No downloadable files were found for \(path)"
        case .conflictingDestination(let path):
            return "More than one Hugging Face file maps to \(path)"
        }
    }
}

/// Resolves repository trees into manifests consumed by `ModelDownloadCoordinator`.
public final class HuggingFaceModelManifestResolver: @unchecked Sendable {
    public static let shared = HuggingFaceModelManifestResolver()

    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .default) {
        let configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
        configuration.timeoutIntervalForRequest = max(configuration.timeoutIntervalForRequest, 60)
        configuration.timeoutIntervalForResource = max(configuration.timeoutIntervalForResource, 180)
        session = URLSession(configuration: configuration)
    }

    public func resolve(
        modelID: String,
        repository: String,
        revision: String = "main",
        selections: [HuggingFaceModelSelection],
        maximumConcurrency: Int = 2
    ) async throws -> ModelDownloadManifest {
        guard repository.split(separator: "/").count == 2 else {
            throw HuggingFaceModelManifestError.invalidRepository(repository)
        }

        var filesByDestination: [String: (file: ModelDownloadFile, fingerprint: String)] = [:]
        for selection in selections {
            let entries = try await listFiles(
                repository: repository,
                revision: revision,
                selection: selection
            )
            var matchedCount = 0
            for entry in entries where selection.includes(entry.path) {
                guard let relativeRemotePath = selection.relativePath(for: entry.path) else { continue }
                let relativePath = [selection.destinationDirectory, relativeRemotePath]
                    .compactMap { $0 }
                    .joined(separator: "/")
                guard !relativePath.isEmpty else { continue }
                guard let remoteURL = Self.resolveURL(
                    repository: repository,
                    revision: revision,
                    path: entry.path
                ) else {
                    throw HuggingFaceModelManifestError.invalidResponse(entry.path)
                }
                let file = ModelDownloadFile(
                    relativePath: relativePath,
                    remoteURL: remoteURL,
                    expectedByteCount: entry.size,
                    sha256: nil
                )
                let fingerprint = "\(entry.path):\(entry.oid ?? ""): \(entry.size ?? -1)"
                if let existing = filesByDestination[relativePath], existing.file.remoteURL != remoteURL {
                    throw HuggingFaceModelManifestError.conflictingDestination(relativePath)
                }
                filesByDestination[relativePath] = (file, fingerprint)
                matchedCount += 1
            }
            guard matchedCount > 0 else {
                throw HuggingFaceModelManifestError.emptySelection(
                    [repository, selection.remoteDirectory].compactMap { $0 }.joined(separator: "/")
                )
            }
        }

        let sorted = filesByDestination.sorted { $0.key < $1.key }
        let revisionMaterial = sorted.map { $0.value.fingerprint }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(revisionMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return ModelDownloadManifest(
            id: modelID,
            version: "\(revision)-\(digest)",
            files: sorted.map { $0.value.file },
            maximumConcurrency: maximumConcurrency
        )
    }

    private func listFiles(
        repository: String,
        revision: String,
        selection: HuggingFaceModelSelection
    ) async throws -> [TreeEntry] {
        guard var nextURL = Self.treeURL(
            repository: repository,
            revision: revision,
            directory: selection.remoteDirectory,
            recursive: selection.recursive
        ) else {
            throw HuggingFaceModelManifestError.invalidRepository(repository)
        }

        var entries: [TreeEntry] = []
        var visited = Set<URL>()
        while visited.insert(nextURL).inserted {
            let (data, response) = try await fetch(nextURL)
            guard let http = response as? HTTPURLResponse else {
                throw HuggingFaceModelManifestError.invalidResponse(nextURL.absoluteString)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HuggingFaceModelManifestError.invalidHTTPStatus(http.statusCode, nextURL.absoluteString)
            }
            let page = try JSONDecoder().decode([TreeEntry].self, from: data)
            entries.append(contentsOf: page.filter { $0.type == "file" })
            guard let link = http.value(forHTTPHeaderField: "Link") else { break }
            guard link.contains("rel=\"next\"") else { break }
            guard let pageURL = Self.nextLink(in: link, relativeTo: nextURL),
                  Self.isTrustedPaginationURL(pageURL, relativeTo: nextURL)
            else {
                throw HuggingFaceModelManifestError.invalidResponse(nextURL.absoluteString)
            }
            nextURL = pageURL
        }
        return entries
    }

    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                if let token = Self.huggingFaceToken,
                   Self.isTrustedHuggingFaceURL(url) {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let result = try await session.data(for: request)
                // URLSession can complete successfully in the narrow window
                // after its parent task is cancelled. Do not turn that late
                // discovery response into a new file transfer.
                try Task.checkCancellation()
                if let http = result.1 as? HTTPURLResponse,
                   (http.statusCode == 429 || (500..<600).contains(http.statusCode)),
                   attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
                    continue
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < 2 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? HuggingFaceModelManifestError.invalidResponse(url.absoluteString)
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let oid: String?
    }

    private static var huggingFaceToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }

    private static func treeURL(
        repository: String,
        revision: String,
        directory: String?,
        recursive: Bool
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(repository)/tree/\(revision)"
        if let directory { components.path += "/\(directory)" }
        components.queryItems = [
            URLQueryItem(name: "recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        return components.url
    }

    private static func resolveURL(repository: String, revision: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(path)"
        return components.url
    }

    private static func nextLink(in header: String, relativeTo baseURL: URL) -> URL? {
        for component in header.split(separator: ",") where component.contains("rel=\"next\"") {
            guard let opening = component.firstIndex(of: "<"),
                  let closing = component[component.index(after: opening)...].firstIndex(of: ">")
            else { continue }
            return URL(
                string: String(component[component.index(after: opening)..<closing]),
                relativeTo: baseURL
            )?.absoluteURL
        }
        return nil
    }

    private static func isTrustedPaginationURL(_ candidate: URL, relativeTo current: URL) -> Bool {
        candidate.scheme?.lowercased() == "https"
            && candidate.host?.caseInsensitiveCompare(current.host ?? "") == .orderedSame
    }

    private static func isTrustedHuggingFaceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.caseInsensitiveCompare("huggingface.co") == .orderedSame
    }
}

private extension HuggingFaceModelSelection {
    func includes(_ repositoryPath: String) -> Bool {
        guard let relative = relativePath(for: repositoryPath) else { return false }
        guard !includedPaths.isEmpty else { return true }
        return includedPaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }

    func relativePath(for repositoryPath: String) -> String? {
        guard let remoteDirectory else { return repositoryPath }
        let prefix = remoteDirectory + "/"
        guard repositoryPath.hasPrefix(prefix) else { return nil }
        return String(repositoryPath.dropFirst(prefix.count))
    }
}

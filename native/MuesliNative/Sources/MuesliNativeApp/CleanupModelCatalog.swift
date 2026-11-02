import CryptoKit
import Foundation

/// Signed list of the newest cleanup model releases, published next to the
/// Sparkle appcast so a model can be updated without shipping a new app.
///
/// `cleanup-models.json` is accepted only with a detached Ed25519 signature
/// (`cleanup-models.json.sig`, base64) made by the same key as app updates
/// (`sign_update`). Each entry is then checked against the slot it targets;
/// anything unsigned, malformed or incompatible leaves the bundled releases in force.
enum CleanupModelCatalog {
    static let defaultURL = URL(string: "https://muesli-hq.github.io/muesli/models/cleanup-models.json")!
    static let catalogURLEnvVar = "MUESLI_CLEANUP_MODEL_CATALOG_URL"
    /// Development only: accept an unsigned catalog in non-production builds.
    static let allowUnsignedEnvVar = "MUESLI_CLEANUP_MODEL_CATALOG_ALLOW_UNSIGNED"
    /// The production Sparkle key, used when the bundle carries none (tests, CLI).
    static let productionPublicKey = "ok9CQBJ3f0MJ2GXuGBubc6VyeWyb5exmqP2b9DceqH4="

    struct Document: Codable {
        let schema: Int
        let releases: [CleanupModelRelease]
    }

    enum CatalogError: LocalizedError {
        case badSignature
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .badSignature: "Cleanup model catalog signature is invalid"
            case .unsupportedSchema(let schema): "Unsupported cleanup model catalog schema \(schema)"
            }
        }
    }

    /// Newest release per slot this build can run, from the bundled set alone.
    static var bundledLatest: [String: CleanupModelRelease] {
        Dictionary(uniqueKeysWithValues: CleanupModelSlot.all.map { ($0.id, $0.bundled) })
    }

    /// Verifies and filters a downloaded catalog, merged over the bundled releases.
    static func latestReleases(catalog data: Data, signature: Data?, publicKey: String,
                               appVersion: String, allowUnsigned: Bool = false) throws -> [String: CleanupModelRelease] {
        if let signature {
            guard let keyData = Data(base64Encoded: publicKey),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  let signatureData = Data(base64Encoded: String(decoding: signature, as: UTF8.self)
                      .trimmingCharacters(in: .whitespacesAndNewlines)),
                  key.isValidSignature(signatureData, for: data) else { throw CatalogError.badSignature }
        } else if !allowUnsigned {
            throw CatalogError.badSignature
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schema == 1 else { throw CatalogError.unsupportedSchema(document.schema) }

        var latest = bundledLatest
        for release in document.releases {
            guard let slot = CleanupModelSlot.slot(id: release.slot) else { continue }
            if let failure = release.validationFailure(for: slot, appVersion: appVersion) {
                Qwen3PostProcessorLogging.logVerbose("cleanup catalog skipped \(release.slot) \(release.version): \(failure)")
                continue
            }
            if release.sequence > latest[slot.id]?.sequence ?? 0 { latest[slot.id] = release }
        }
        return latest
    }

    /// Fetches the catalog. Returns nil if the network or signature fails, so the
    /// caller keeps what it last verified.
    static func fetchLatest(session: URLSession = .shared,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            bundle: Bundle = .main) async -> [String: CleanupModelRelease]? {
        let url = environment[catalogURLEnvVar].flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? defaultURL
        let isProduction = bundle.bundleIdentifier == "com.muesli.app"
        let allowUnsigned = !isProduction && environment[allowUnsignedEnvVar] == "1"
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? productionPublicKey
        do {
            let data = try await fetch(url, session: session)
            let signature = try? await fetch(url.appendingPathExtension("sig"), session: session)
            return try latestReleases(catalog: data, signature: signature, publicKey: publicKey,
                appVersion: AppIdentity.marketingVersion, allowUnsigned: allowUnsigned)
        } catch {
            fputs("[muesli-native] cleanup model catalog unavailable: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

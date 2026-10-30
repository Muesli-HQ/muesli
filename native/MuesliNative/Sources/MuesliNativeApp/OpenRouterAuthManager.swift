import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum OpenRouterAuthError: Error, LocalizedError, Equatable {
    case notAuthenticated
    case callbackServerFailed
    case callbackTimeout
    case callbackRejected(String)
    case callbackMissingCode
    case invalidCallback
    case couldNotOpenBrowser
    case keyExchangeFailed(statusCode: Int?)
    case invalidKeyExchangeResponse
    case credentialStorageFailed
    case credentialDeletionFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not connected to OpenRouter"
        case .callbackServerFailed:
            return "Could not start the OpenRouter sign-in callback server"
        case .callbackTimeout:
            return "OpenRouter sign-in timed out — please try again"
        case .callbackRejected(let reason):
            return "OpenRouter sign-in was not completed: \(reason)"
        case .callbackMissingCode:
            return "OpenRouter callback did not include an authorization code"
        case .invalidCallback:
            return "Received an invalid OpenRouter sign-in callback"
        case .couldNotOpenBrowser:
            return "Could not open OpenRouter sign-in in the browser"
        case .keyExchangeFailed(let statusCode):
            if let statusCode {
                return "OpenRouter key exchange failed (HTTP \(statusCode))"
            }
            return "OpenRouter key exchange failed"
        case .invalidKeyExchangeResponse:
            return "OpenRouter key exchange returned an invalid response"
        case .credentialStorageFailed:
            return "Could not store the OpenRouter credential"
        case .credentialDeletionFailed:
            return "Could not remove the local OpenRouter credential"
        }
    }
}

/// An OpenRouter OAuth exchange creates a normal, user-controlled API key.
/// It does not create refreshable OAuth access and refresh tokens.
struct OpenRouterCredential: Codable, Equatable, Sendable {
    let apiKey: String
    let userID: String?

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case userID = "user_id"
    }
}

struct OpenRouterCredentialStore {
    let fileURL: URL

    init(supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        fileURL = supportDirectory.appendingPathComponent("openrouter-auth.json")
    }

    func load() throws -> OpenRouterCredential? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(OpenRouterCredential.self, from: data)
    }

    func save(_ credential: OpenRouterCredential) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder().encode(credential)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var credentialURL = fileURL
        try credentialURL.setResourceValues(resourceValues)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

enum OpenRouterCredentialResolver {
    /// Environment variables intentionally win for automation and local
    /// development. The config value is a read-only compatibility fallback
    /// until ConfigStore migrates it to the dedicated credential file.
    static func resolvedAPIKey(
        legacyAPIKey: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialStore: OpenRouterCredentialStore = OpenRouterCredentialStore()
    ) -> String {
        let environmentKey = environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environmentKey.isEmpty { return environmentKey }

        if let credential = try? credentialStore.load(),
           !credential.apiKey.isEmpty {
            return credential.apiKey
        }

        return legacyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class OpenRouterAuthManager {
    static let shared = OpenRouterAuthManager()

    static let callbackTimeoutSeconds: TimeInterval = 600

    nonisolated private static let authorizationEndpoint = URL(string: "https://openrouter.ai/auth")!
    nonisolated private static let keyExchangeEndpoint = URL(
        string: "https://openrouter.ai/api/v1/auth/keys"
    )!

    private let credentialStore: OpenRouterCredentialStore
    private let loadData: (URLRequest) async throws -> (Data, URLResponse)
    private let openURL: (URL) -> Bool
    private let environment: () -> [String: String]
    private let deleteCredential: () throws -> Void

    init(
        credentialStore: OpenRouterCredentialStore = OpenRouterCredentialStore(),
        loadData: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        deleteCredential: (() throws -> Void)? = nil
    ) {
        self.credentialStore = credentialStore
        self.loadData = loadData
        self.openURL = openURL
        self.environment = environment
        self.deleteCredential = deleteCredential ?? { try credentialStore.delete() }
    }

    var hasEnvironmentCredential: Bool {
        let key = environment()["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    var hasStoredCredential: Bool {
        guard let credential = try? credentialStore.load() else { return false }
        return !credential.apiKey.isEmpty
    }

    var isAuthenticated: Bool {
        hasEnvironmentCredential || hasStoredCredential
    }

    func credential() throws -> OpenRouterCredential {
        guard let credential = try credentialStore.load(), !credential.apiKey.isEmpty else {
            throw OpenRouterAuthError.notAuthenticated
        }
        return credential
    }

    func apiKey() throws -> String {
        try credential().apiKey
    }

    func signIn() async throws {
        let (verifier, challenge) = generatePKCE()
        let authorizationCode = try await waitForAuthorizationCode(codeChallenge: challenge)
        let credential = try await exchangeAuthorizationCode(
            authorizationCode,
            codeVerifier: verifier
        )

        do {
            try credentialStore.save(credential)
        } catch {
            throw OpenRouterAuthError.credentialStorageFailed
        }
    }

    /// Removes only Muesli's local credential. The user-controlled key remains
    /// active at OpenRouter until the user deletes it from OpenRouter's key page.
    func signOut() throws {
        do {
            try deleteCredential()
        } catch {
            throw OpenRouterAuthError.credentialDeletionFailed
        }
    }

    func storeManualAPIKey(_ apiKey: String) throws {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw OpenRouterAuthError.notAuthenticated }
        do {
            try credentialStore.save(OpenRouterCredential(apiKey: normalizedKey, userID: nil))
        } catch {
            throw OpenRouterAuthError.credentialStorageFailed
        }
    }

    func resolvedAPIKey(
        legacyAPIKey: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        OpenRouterCredentialResolver.resolvedAPIKey(
            legacyAPIKey: legacyAPIKey,
            environment: environment,
            credentialStore: credentialStore
        )
    }

    var manageKeyURL: URL? {
        let apiKey = OpenRouterCredentialResolver.resolvedAPIKey(
            environment: environment(),
            credentialStore: credentialStore
        )
        guard !apiKey.isEmpty else { return nil }
        return Self.manageKeyURL(for: apiKey)
    }

    nonisolated static func manageKeyURL(for apiKey: String) -> URL {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(string: "https://openrouter.ai/keys/\(digest)")!
    }

    // MARK: - PKCE and authorization URL

    func generatePKCE() -> (verifier: String, challenge: String) {
        let verifier = randomBase64URL(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        return (verifier, challenge)
    }

    func generateCallbackPath() -> String {
        "/muesli/openrouter/oauth/\(randomBase64URL(byteCount: 32))"
    }

    nonisolated func buildAuthorizationURL(callbackURL: URL, codeChallenge: String) -> URL? {
        var components = URLComponents(
            url: Self.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    private func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            preconditionFailure("Secure random number generation failed")
        }
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - Loopback callback

    enum CallbackRequest: Equatable {
        case authorizationCode(String)
        case providerError(String)
        case missingCode
        case invalid
        case unrelated
    }

    nonisolated func parseCallbackRequest(
        _ httpRequest: String,
        expectedPath: String
    ) -> CallbackRequest {
        guard let requestLine = httpRequest.split(whereSeparator: { $0.isNewline }).first else {
            return .invalid
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return .invalid }
        guard let components = URLComponents(string: String(requestParts[1])) else { return .invalid }
        guard components.path == expectedPath else { return .unrelated }
        guard requestParts[0] == "GET" else { return .invalid }

        let queryItems = components.queryItems ?? []
        if let code = queryItems.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return .authorizationCode(code)
        }
        if let error = queryItems.first(where: { $0.name == "error" })?.value,
           !error.isEmpty {
            return .providerError(error)
        }
        return .missingCode
    }

    private func waitForAuthorizationCode(codeChallenge: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                continuation.resume(throwing: OpenRouterAuthError.callbackServerFailed)
                return
            }

            let callbackPath = generateCallbackPath()
            var completed = false
            var browserOpened = false

            func finish(_ result: Result<String, Error>) {
                guard !completed else { return }
                completed = true
                listener.cancel()
                switch result {
                case .success(let code): continuation.resume(returning: code)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            let timeout = DispatchWorkItem {
                Task { @MainActor in
                    finish(.failure(OpenRouterAuthError.callbackTimeout))
                }
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.callbackTimeoutSeconds,
                execute: timeout
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        guard !browserOpened, let self, let port = listener.port else { return }
                        browserOpened = true
                        guard let callbackURL = URL(
                            string: "http://localhost:\(port.rawValue)\(callbackPath)"
                        ),
                        let authorizationURL = self.buildAuthorizationURL(
                            callbackURL: callbackURL,
                            codeChallenge: codeChallenge
                        ) else {
                            timeout.cancel()
                            finish(.failure(OpenRouterAuthError.callbackServerFailed))
                            return
                        }
                        guard self.openURL(authorizationURL) else {
                            timeout.cancel()
                            finish(.failure(OpenRouterAuthError.couldNotOpenBrowser))
                            return
                        }
                    case .failed:
                        timeout.cancel()
                        finish(.failure(OpenRouterAuthError.callbackServerFailed))
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, !completed else {
                        connection.cancel()
                        return
                    }
                    connection.start(queue: .main)
                    Self.receiveHTTPRequest(on: connection) { request in
                        Task { @MainActor in
                            guard !completed else {
                                connection.cancel()
                                return
                            }
                            guard let request else {
                                Self.sendHTTPResponse(
                                    status: 400,
                                    title: "Sign-in failed",
                                    on: connection
                                )
                                return
                            }

                            switch self.parseCallbackRequest(request, expectedPath: callbackPath) {
                            case .authorizationCode(let code):
                                Self.sendHTTPResponse(
                                    status: 200,
                                    title: "OpenRouter connected to Muesli",
                                    on: connection
                                )
                                timeout.cancel()
                                finish(.success(code))
                            case .providerError(let reason):
                                Self.sendHTTPResponse(
                                    status: 400,
                                    title: "Sign-in cancelled",
                                    on: connection
                                )
                                timeout.cancel()
                                finish(.failure(OpenRouterAuthError.callbackRejected(reason)))
                            case .missingCode:
                                Self.sendHTTPResponse(
                                    status: 400,
                                    title: "Sign-in failed",
                                    on: connection
                                )
                                timeout.cancel()
                                finish(.failure(OpenRouterAuthError.callbackMissingCode))
                            case .invalid:
                                Self.sendHTTPResponse(
                                    status: 400,
                                    title: "Sign-in failed",
                                    on: connection
                                )
                                timeout.cancel()
                                finish(.failure(OpenRouterAuthError.invalidCallback))
                            case .unrelated:
                                // Port scanners and unrelated local requests do not consume the callback.
                                Self.sendHTTPResponse(status: 404, title: "Not found", on: connection)
                            }
                        }
                    }
                }
            }

            listener.start(queue: .main)
        }
    }

    nonisolated private static func receiveHTTPRequest(
        on connection: NWConnection,
        completion: @escaping (String?) -> Void
    ) {
        var received = Data()

        func receiveNextChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                data, _, isComplete, error in
                if let data { received.append(data) }

                if received.count > 16_384 {
                    completion(nil)
                    return
                }
                if received.range(of: Data("\r\n\r\n".utf8)) != nil ||
                    received.range(of: Data("\n\n".utf8)) != nil ||
                    isComplete {
                    completion(String(data: received, encoding: .utf8))
                    return
                }
                if error != nil {
                    completion(nil)
                    return
                }
                receiveNextChunk()
            }
        }

        receiveNextChunk()
    }

    nonisolated private static func sendHTTPResponse(
        status: Int,
        title: String,
        on connection: NWConnection
    ) {
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,system-ui;text-align:center;padding:5rem">
        <h2>\(title)</h2><p>You can close this window.</p></body></html>
        """
        let response = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Key exchange

    private struct KeyExchangeRequest: Encodable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod = "S256"

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case codeChallengeMethod = "code_challenge_method"
        }
    }

    private struct KeyExchangeResponse: Decodable {
        let key: String
        let userID: String?

        enum CodingKeys: String, CodingKey {
            case key
            case userID = "user_id"
        }
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> OpenRouterCredential {
        var request = URLRequest(url: Self.keyExchangeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            KeyExchangeRequest(code: code, codeVerifier: codeVerifier)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loadData(request)
        } catch {
            throw OpenRouterAuthError.keyExchangeFailed(statusCode: nil)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw OpenRouterAuthError.keyExchangeFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode
            )
        }
        guard let exchange = try? JSONDecoder().decode(KeyExchangeResponse.self, from: data),
              !exchange.key.isEmpty else {
            throw OpenRouterAuthError.invalidKeyExchangeResponse
        }
        return OpenRouterCredential(apiKey: exchange.key, userID: exchange.userID)
    }
}

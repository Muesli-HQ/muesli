import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum ChatGPTAuthError: Error, LocalizedError {
    case notAuthenticated
    case callbackTimeout
    case callbackMissingCode
    case callbackStateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case portInUse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to ChatGPT"
        case .callbackTimeout: return "Sign-in timed out — no response from browser"
        case .callbackMissingCode: return "OAuth callback missing authorization code"
        case .callbackStateMismatch: return "OAuth state mismatch — possible CSRF attack"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .refreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .portInUse: return "Callback port 1455 is already in use"
        }
    }
}

@MainActor
final class ChatGPTAuthManager {
    static let shared = ChatGPTAuthManager()

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authURL = "https://auth.openai.com/oauth/authorize"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scopes = "openid profile email offline_access"
    private static let callbackTimeoutSeconds: TimeInterval = 300 // 5 minutes

    private var tokenFileURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("chatgpt-auth.json")
    }

    private init() {
        // Migrate from legacy keychain storage to file
        migrateFromKeychain()
    }

    // MARK: - Public API

    var isAuthenticated: Bool {
        tokenRead(key: "access_token") != nil
    }

    func signIn() async throws {
        let (verifier, challenge) = generatePKCE()
        let code = try await startCallbackServerAndOpenBrowser(codeChallenge: challenge)
        let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: verifier)
        saveTokens(tokens)
        fputs("[chatgpt-auth] signed in successfully\n", stderr)
    }

    func signOut() {
        deleteTokens()
        // Also clean up legacy keychain entries
        for account in ["access_token", "refresh_token", "expires_at", "account_id"] {
            keychainDeleteLegacy(account: account)
        }
        fputs("[chatgpt-auth] signed out\n", stderr)
    }

    func validAccessToken() async throws -> (token: String, accountId: String) {
        guard let accessToken = tokenRead(key: "access_token") else {
            throw ChatGPTAuthError.notAuthenticated
        }
        let accountId = tokenRead(key: "account_id") ?? ""

        // Check expiry with 30-second margin
        if let expiresStr = tokenRead(key: "expires_at"),
           let expiresMs = Double(expiresStr) {
            let expiresAt = Date(timeIntervalSince1970: expiresMs / 1000.0)
            if expiresAt > Date().addingTimeInterval(30) {
                return (accessToken, accountId)
            }
            // Token expired or about to expire — refresh
            fputs("[chatgpt-auth] token expired, refreshing...\n", stderr)
            guard let refreshToken = tokenRead(key: "refresh_token") else {
                throw ChatGPTAuthError.notAuthenticated
            }
            let tokens = try await refreshAccessToken(refreshToken: refreshToken)
            saveTokens(tokens)
            return (tokens.accessToken, tokens.accountId)
        }

        // No expiry info — use token as-is
        return (accessToken, accountId)
    }

    // MARK: - PKCE

    func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64URLEncoded()
        return (verifier, challenge)
    }

    // MARK: - OAuth Flow

    func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    func buildAuthorizationURL(codeChallenge: String, state: String) -> URL? {
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "muesli"),
        ]
        return components.url
    }

    private func startCallbackServerAndOpenBrowser(codeChallenge: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let port: NWEndpoint.Port = 1455
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

            guard let listener = try? NWListener(using: params) else {
                continuation.resume(throwing: ChatGPTAuthError.portInUse)
                return
            }
            var resumed = false

            let timeoutWork = DispatchWorkItem { [weak listener] in
                guard !resumed else { return }
                resumed = true
                listener?.cancel()
                continuation.resume(throwing: ChatGPTAuthError.callbackTimeout)
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.callbackTimeoutSeconds,
                execute: timeoutWork
            )

            listener.stateUpdateHandler = { state in
                if case .failed = state {
                    guard !resumed else { return }
                    resumed = true
                    timeoutWork.cancel()
                    continuation.resume(throwing: ChatGPTAuthError.portInUse)
                }
            }

            // Generate state before setting up handler so closure can capture it
            let expectedState = self.generateState()

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    defer {
                        listener.cancel()
                        timeoutWork.cancel()
                    }
                    guard !resumed else { return }
                    resumed = true

                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: ChatGPTAuthError.callbackMissingCode)
                        return
                    }

                    // Parse code + state from: GET /callback?code=XXX&state=YYY HTTP/1.1
                    let code = self.extractCode(from: request)
                    let callbackState = self.extractParam(named: "state", from: request)

                    // Validate state before sending success page to prevent CSRF
                    guard callbackState == expectedState else {
                        fputs("[chatgpt-auth] OAuth state mismatch — possible CSRF\n", stderr)
                        let errorHtml = """
                        HTTP/1.1 400 Bad Request\r
                        Content-Type: text/html\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff"><div style="text-align:center"><h2>Sign-in failed</h2><p>Security validation failed. Please try again.</p></div></body></html>
                        """
                        connection.send(
                            content: errorHtml.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        continuation.resume(throwing: ChatGPTAuthError.callbackStateMismatch)
                        return
                    }

                    // Send success response HTML
                    let html = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/html\r
                    Connection: close\r
                    \r
                    <!DOCTYPE html><html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff"><div style="text-align:center"><h2>Signed in to Muesli</h2><p>You can close this window.</p></div></body></html>
                    """
                    connection.send(
                        content: html.data(using: .utf8),
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        }
                    )

                    if let code {
                        continuation.resume(returning: code)
                    } else {
                        continuation.resume(throwing: ChatGPTAuthError.callbackMissingCode)
                    }
                }
            }

            listener.start(queue: .main)

            // Open browser
            if let url = self.buildAuthorizationURL(codeChallenge: codeChallenge, state: expectedState) {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    func extractCode(from httpRequest: String) -> String? {
        // Parse "GET /callback?code=XXX&... HTTP/1.1"
        guard let pathLine = httpRequest.split(separator: "\r\n").first ?? httpRequest.split(separator: "\n").first,
              let pathPart = pathLine.split(separator: " ").dropFirst().first else {
            return nil
        }
        let pathString = String(pathPart)
        guard let components = URLComponents(string: pathString) else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    func extractParam(named name: String, from httpRequest: String) -> String? {
        guard let pathLine = httpRequest.split(separator: "\r\n").first ?? httpRequest.split(separator: "\n").first,
              let pathPart = pathLine.split(separator: " ").dropFirst().first else {
            return nil
        }
        guard let components = URLComponents(string: String(pathPart)) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - Token Exchange

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let expiresAtMs: Double
        let accountId: String
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": codeVerifier,
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ChatGPTAuthError.tokenExchangeFailed(errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw ChatGPTAuthError.tokenExchangeFailed("missing access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000.0
        let accountId = extractAccountId(from: accessToken)

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: expiresAtMs,
            accountId: accountId
        )
    }

    private func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ChatGPTAuthError.refreshFailed(errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw ChatGPTAuthError.refreshFailed("missing access_token in refresh response")
        }

        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000.0
        let accountId = extractAccountId(from: accessToken)

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAtMs: expiresAtMs,
            accountId: accountId
        )
    }

    // MARK: - JWT Parsing

    func extractAccountId(from jwt: String) -> String {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return "" }

        var payload = String(segments[1])
        // Pad base64
        while payload.count % 4 != 0 { payload += "=" }
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        // Try multiple claim paths (Codex uses these fallbacks)
        if let accountId = json["chatgpt_account_id"] as? String {
            return accountId
        }
        if let authClaims = json["https://api.openai.com/auth"] as? [String: Any],
           let accountId = authClaims["chatgpt_account_id"] as? String {
            return accountId
        }
        if let orgs = json["organizations"] as? [[String: Any]],
           let orgId = orgs.first?["id"] as? String {
            return orgId
        }
        return ""
    }

    // MARK: - File-based Token Storage

    private func saveTokens(_ tokens: TokenResponse) {
        let dict: [String: String] = [
            "access_token": tokens.accessToken,
            "refresh_token": tokens.refreshToken,
            "expires_at": String(format: "%.0f", tokens.expiresAtMs),
            "account_id": tokens.accountId,
        ]
        do {
            let dir = tokenFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
            try data.write(to: tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var fileURL = tokenFileURL
            try fileURL.setResourceValues(resourceValues)
        } catch {
            fputs("[chatgpt-auth] failed to save tokens: \(error)\n", stderr)
        }
    }

    private func tokenRead(key: String) -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict[key]
    }

    private func deleteTokens() {
        try? FileManager.default.removeItem(at: tokenFileURL)
    }

    // MARK: - Keychain Migration

    private static let keychainService = "com.muesli.app.chatgpt-auth"

    private func migrateFromKeychain() {
        // If file already exists, no migration needed
        guard !FileManager.default.fileExists(atPath: tokenFileURL.path) else { return }

        // Try reading from legacy keychain
        guard let accessToken = keychainReadLegacy(account: "access_token") else { return }
        let refreshToken = keychainReadLegacy(account: "refresh_token") ?? ""
        let expiresAt = keychainReadLegacy(account: "expires_at") ?? "0"
        let accountId = keychainReadLegacy(account: "account_id") ?? ""

        let tokens = TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: Double(expiresAt) ?? 0,
            accountId: accountId
        )
        saveTokens(tokens)

        // Clean up keychain entries
        for account in ["access_token", "refresh_token", "expires_at", "account_id"] {
            keychainDeleteLegacy(account: account)
        }
        fputs("[chatgpt-auth] migrated tokens from keychain to file\n", stderr)
    }

    private func keychainReadLegacy(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDeleteLegacy(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import AppKit
import CryptoKit
import Foundation
import Network

enum GoogleCalendarAuthError: Error, LocalizedError {
    case notAuthenticated
    case notAvailable
    case callbackTimeout
    case callbackMissingCode
    case callbackStateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case portInUse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in to Google Calendar"
        case .notAvailable: return "Google Calendar credentials not configured"
        case .callbackTimeout: return "Sign-in timed out — no response from browser"
        case .callbackMissingCode: return "OAuth callback missing authorization code"
        case .callbackStateMismatch: return "OAuth state mismatch — possible CSRF attack"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .refreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .portInUse: return "Callback port 1456 is already in use"
        }
    }
}

enum GoogleIntegrationScope: String, CaseIterable, Equatable {
    case calendarEventsReadonly = "https://www.googleapis.com/auth/calendar.events.readonly"
    case calendarReadonly = "https://www.googleapis.com/auth/calendar.readonly"
    case driveFile = "https://www.googleapis.com/auth/drive.file"
    case documents = "https://www.googleapis.com/auth/documents"

    static let calendar: Set<GoogleIntegrationScope> = [
        .calendarEventsReadonly,
        .calendarReadonly,
    ]

    static let driveDocs: Set<GoogleIntegrationScope> = [
        .driveFile,
        .documents,
    ]

    var label: String {
        switch self {
        case .calendarEventsReadonly: return "Calendar events"
        case .calendarReadonly: return "Calendar list"
        case .driveFile: return "Drive files opened or created by Sales Caddie"
        case .documents: return "Google Docs create/edit"
        }
    }

    static func scopeString(_ scopes: Set<GoogleIntegrationScope>) -> String {
        scopes
            .map(\.rawValue)
            .sorted()
            .joined(separator: " ")
    }
}

@MainActor
final class GoogleCalendarAuthManager {
    static let shared = GoogleCalendarAuthManager()

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let redirectURI = "http://localhost:1456/auth/callback"
    private static let callbackTimeoutSeconds: TimeInterval = 300

    private let credentials: GoogleCalendarCredentials?

    private var tokenFileURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("google-calendar-auth.json")
    }

    private init() {
        credentials = GoogleCalendarCredentials.load()
    }

    // MARK: - Public API

    /// Whether Google Calendar credentials are configured (feature available)
    var isAvailable: Bool { credentials != nil }

    /// Whether the Google OAuth app has passed verification review
    var isVerified: Bool { credentials?.verified ?? false }

    /// Whether the user has completed OAuth and has tokens
    var isAuthenticated: Bool {
        tokenRead(key: "access_token") != nil
    }

    func hasGrantedScopes(_ scopes: Set<GoogleIntegrationScope>) -> Bool {
        let granted = Set(tokenReadList(key: "granted_scopes"))
        return scopes.allSatisfy { granted.contains($0.rawValue) }
    }

    func signIn(scopes requestedScopes: Set<GoogleIntegrationScope> = GoogleIntegrationScope.calendar) async throws {
        guard let credentials else { throw GoogleCalendarAuthError.notAvailable }
        let (verifier, challenge) = generatePKCE()
        let code = try await startCallbackServerAndOpenBrowser(
            codeChallenge: challenge,
            clientId: credentials.clientId,
            scopes: requestedScopes
        )
        do {
            let tokens = try await exchangeCodeForTokens(
                code: code,
                codeVerifier: verifier,
                credentials: credentials
            )
            saveTokens(tokens)
            fputs("[google-cal] signed in successfully\n", stderr)
            appendDiagnostic("signed_in token_file=\(tokenFileURL.path)")
        } catch {
            appendDiagnostic("sign_in_failed_after_callback error=\(error.localizedDescription)")
            throw error
        }
    }

    func signOut() {
        appendDiagnostic("signed_out token_file=\(tokenFileURL.path)")
        deleteTokens()
        fputs("[google-cal] signed out\n", stderr)
    }

    func validAccessToken() async throws -> String {
        guard let credentials else { throw GoogleCalendarAuthError.notAvailable }
        guard let accessToken = tokenRead(key: "access_token") else {
            throw GoogleCalendarAuthError.notAuthenticated
        }

        // Check expiry with 30-second margin
        if let expiresStr = tokenRead(key: "expires_at"),
           let expiresMs = Double(expiresStr) {
            let expiresAt = Date(timeIntervalSince1970: expiresMs / 1000.0)
            if expiresAt > Date().addingTimeInterval(30) {
                return accessToken
            }
            fputs("[google-cal] token expired, refreshing...\n", stderr)
            guard let refreshToken = tokenRead(key: "refresh_token") else {
                throw GoogleCalendarAuthError.notAuthenticated
            }
            let tokens = try await refreshAccessToken(
                refreshToken: refreshToken,
                credentials: credentials
            )
            saveTokens(tokens)
            return tokens.accessToken
        }

        return accessToken
    }

    // MARK: - PKCE (reuses Data.base64URLEncoded() from ChatGPTAuthManager)

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64URLEncoded()
        return (verifier, challenge)
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - OAuth Flow

    private func buildAuthorizationURL(
        codeChallenge: String,
        state: String,
        clientId: String,
        scopes: Set<GoogleIntegrationScope>
    ) -> URL? {
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleIntegrationScope.scopeString(scopes)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url
    }

    private func startCallbackServerAndOpenBrowser(
        codeChallenge: String,
        clientId: String,
        scopes: Set<GoogleIntegrationScope>
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let port: NWEndpoint.Port = 1456
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

            guard let listener = try? NWListener(using: params) else {
                continuation.resume(throwing: GoogleCalendarAuthError.portInUse)
                return
            }
            var resumed = false

            let timeoutWork = DispatchWorkItem { [weak listener] in
                guard !resumed else { return }
                resumed = true
                listener?.cancel()
                continuation.resume(throwing: GoogleCalendarAuthError.callbackTimeout)
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.callbackTimeoutSeconds,
                execute: timeoutWork
            )

            let expectedState = self.generateState()

            // Pre-build the auth URL on the main actor before entering the closure
            let authURL = self.buildAuthorizationURL(
                codeChallenge: codeChallenge,
                state: expectedState,
                clientId: clientId,
                scopes: scopes
            )

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Listener is accepting connections — now safe to open browser
                    if let authURL {
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(authURL)
                        }
                    }
                case .failed:
                    guard !resumed else { return }
                    resumed = true
                    timeoutWork.cancel()
                    continuation.resume(throwing: GoogleCalendarAuthError.portInUse)
                default:
                    break
                }
            }

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
                        continuation.resume(throwing: GoogleCalendarAuthError.callbackMissingCode)
                        return
                    }

                    let code = self.extractParam(named: "code", from: request)
                    let callbackState = self.extractParam(named: "state", from: request)

                    guard callbackState == expectedState else {
                        fputs("[google-cal] OAuth state mismatch — possible CSRF\n", stderr)
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
                        continuation.resume(throwing: GoogleCalendarAuthError.callbackStateMismatch)
                        return
                    }

                    if let code {
                        let successHtml = """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/html\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff"><div style="text-align:center"><h2>Google Calendar connected</h2><p>You can close this window and return to Muesli.</p></div></body></html>
                        """
                        connection.send(
                            content: successHtml.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        continuation.resume(returning: code)
                    } else {
                        let deniedHtml = """
                        HTTP/1.1 400 Bad Request\r
                        Content-Type: text/html\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff"><div style="text-align:center"><h2>Sign-in failed</h2><p>Access was denied or no authorization code received.</p></div></body></html>
                        """
                        connection.send(
                            content: deniedHtml.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        continuation.resume(throwing: GoogleCalendarAuthError.callbackMissingCode)
                    }
                }
            }

            listener.start(queue: .main)
        }
    }

    private func extractParam(named name: String, from httpRequest: String) -> String? {
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
        let refreshToken: String?
        let expiresAtMs: Double
        let grantedScopes: [String]
    }

    private func exchangeCodeForTokens(
        code: String,
        codeVerifier: String,
        credentials: GoogleCalendarCredentials
    ) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
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
            throw GoogleCalendarAuthError.tokenExchangeFailed(errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw GoogleCalendarAuthError.tokenExchangeFailed("missing access_token in response")
        }

        let refreshToken = nonEmptyString(json["refresh_token"] as? String)
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000.0
        let grantedScopes = scopeList(json["scope"] as? String)

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: expiresAtMs,
            grantedScopes: grantedScopes
        )
    }

    private func refreshAccessToken(
        refreshToken: String,
        credentials: GoogleCalendarCredentials
    ) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
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
            if let httpResponse = response as? HTTPURLResponse,
               (httpResponse.statusCode == 400 || httpResponse.statusCode == 401),
               errorBody.contains("invalid_grant") {
                throw GoogleCalendarAuthError.notAuthenticated
            }
            throw GoogleCalendarAuthError.refreshFailed(errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw GoogleCalendarAuthError.refreshFailed("missing access_token in refresh response")
        }

        // Google may or may not return a new refresh token
        let newRefreshToken = nonEmptyString(json["refresh_token"] as? String) ?? refreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiresAtMs = (Date().timeIntervalSince1970 + expiresIn) * 1000.0
        let grantedScopes = tokenReadList(key: "granted_scopes")

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAtMs: expiresAtMs,
            grantedScopes: grantedScopes
        )
    }

    // MARK: - File-based Token Storage

    private func saveTokens(_ tokens: TokenResponse) {
        var dict: [String: String] = [
            "access_token": tokens.accessToken,
            "expires_at": String(format: "%.0f", tokens.expiresAtMs),
        ]
        if let refreshToken = tokens.refreshToken ?? tokenRead(key: "refresh_token") {
            dict["refresh_token"] = refreshToken
        }
        let grantedScopes = Set(tokenReadList(key: "granted_scopes")).union(tokens.grantedScopes)
        if !grantedScopes.isEmpty {
            dict["granted_scopes"] = grantedScopes.sorted().joined(separator: " ")
        }
        do {
            let dir = tokenFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
            try data.write(to: tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
            var fileURL = tokenFileURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try fileURL.setResourceValues(resourceValues)
        } catch {
            fputs("[google-cal] failed to save tokens: \(error)\n", stderr)
            appendDiagnostic("failed_to_save_tokens path=\(tokenFileURL.path) error=\(error.localizedDescription)")
        }
    }

    private func tokenRead(key: String) -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict[key]
    }

    private func tokenReadList(key: String) -> [String] {
        scopeList(tokenRead(key: key))
    }

    private func deleteTokens() {
        try? FileManager.default.removeItem(at: tokenFileURL)
    }

    private func nonEmptyString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scopeList(_ value: String?) -> [String] {
        (value ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func appendDiagnostic(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = AppIdentity.supportDirectoryURL.appendingPathComponent("google-calendar-auth.log")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            fputs("[google-cal] failed to write auth diagnostic: \(error)\n", stderr)
        }
    }
}

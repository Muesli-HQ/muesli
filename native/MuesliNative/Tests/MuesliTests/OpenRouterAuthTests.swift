import CryptoKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("OpenRouter OAuth")
struct OpenRouterAuthTests {
    @Test("PKCE uses a unique, unpadded base64url verifier and S256 challenge")
    @MainActor
    func pkce() {
        let auth = makeAuth()
        let first = auth.generatePKCE()
        let second = auth.generatePKCE()

        #expect(first.verifier.count >= 43)
        #expect(!first.verifier.contains("+"))
        #expect(!first.verifier.contains("/"))
        #expect(!first.verifier.contains("="))
        #expect(first.verifier != second.verifier)
        #expect(
            first.challenge == Data(SHA256.hash(data: Data(first.verifier.utf8))).base64URLEncoded()
        )
    }

    @Test("callback paths are high entropy and unique")
    @MainActor
    func callbackPath() {
        let auth = makeAuth()
        let first = auth.generateCallbackPath()
        let second = auth.generateCallbackPath()

        #expect(first.hasPrefix("/muesli/openrouter/oauth/"))
        #expect(first.count >= 68)
        #expect(first != second)
    }

    @Test("authorization URL uses OpenRouter callback and PKCE S256 parameters")
    @MainActor
    func authorizationURL() throws {
        let auth = makeAuth()
        let callbackURL = URL(string: "http://localhost:54321/muesli/openrouter/oauth/secret")!
        let url = try #require(
            auth.buildAuthorizationURL(callbackURL: callbackURL, codeChallenge: "challenge")
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        #expect(components.scheme == "https")
        #expect(components.host == "openrouter.ai")
        #expect(components.path == "/auth")
        #expect(parameters["callback_url"] == callbackURL.absoluteString)
        #expect(parameters["code_challenge"] == "challenge")
        #expect(parameters["code_challenge_method"] == "S256")
        #expect(OpenRouterAuthManager.callbackTimeoutSeconds == 600)
    }

    @Test("callback parser accepts only the exact one-shot callback path")
    @MainActor
    func callbackValidation() {
        let auth = makeAuth()
        let path = "/muesli/openrouter/oauth/secret"

        #expect(
            auth.parseCallbackRequest(
                "GET \(path)?code=abc%3D123 HTTP/1.1\r\nHost: localhost\r\n\r\n",
                expectedPath: path
            ) == .authorizationCode("abc=123")
        )
        #expect(
            auth.parseCallbackRequest(
                "GET /muesli/openrouter/oauth/wrong?code=stolen HTTP/1.1\r\n\r\n",
                expectedPath: path
            ) == .unrelated
        )
        #expect(
            auth.parseCallbackRequest(
                "POST \(path)?code=abc HTTP/1.1\r\n\r\n",
                expectedPath: path
            ) == .invalid
        )
        #expect(
            auth.parseCallbackRequest(
                "GET \(path)?error=access_denied HTTP/1.1\r\n\r\n",
                expectedPath: path
            ) == .providerError("access_denied")
        )
        #expect(
            auth.parseCallbackRequest(
                "GET \(path) HTTP/1.1\r\n\r\n",
                expectedPath: path
            ) == .missingCode
        )
    }

    @Test("key exchange sends the documented JSON and returns key plus user id")
    @MainActor
    func keyExchange() async throws {
        let recorder = RequestRecorder()
        let responseData = Data(#"{"key":"sk-or-v1-secret","user_id":"user_123"}"#.utf8)
        let auth = makeAuth { request in
            await recorder.record(request)
            return (
                responseData,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let credential = try await auth.exchangeAuthorizationCode("one-shot-code", codeVerifier: "verifier")
        #expect(credential == OpenRouterCredential(apiKey: "sk-or-v1-secret", userID: "user_123"))

        let recordedRequest = await recorder.request
        let request = try #require(recordedRequest)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["code"] == "one-shot-code")
        #expect(json["code_verifier"] == "verifier")
        #expect(json["code_challenge_method"] == "S256")
    }

    @Test("key exchange reports status without reflecting response secrets")
    @MainActor
    func keyExchangeErrorIsSanitized() async {
        let auth = makeAuth { request in
            (
                Data(#"{"error":"do not echo this secret"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: OpenRouterAuthError.keyExchangeFailed(statusCode: 403)) {
            try await auth.exchangeAuthorizationCode("code", codeVerifier: "verifier")
        }
    }

    @Test("credential store uses owner-only permissions and sign-out is local")
    @MainActor
    func credentialStorageAndLocalSignOut() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-openrouter-auth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenRouterCredentialStore(supportDirectory: root)
        let credential = OpenRouterCredential(apiKey: "sk-or-v1-local", userID: "user_local")
        try store.save(credential)

        #expect(try store.load() == credential)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)

        let auth = OpenRouterAuthManager(
            credentialStore: store,
            loadData: openRouterUnusedLoader,
            openURL: { _ in false },
            environment: { [:] }
        )
        let manageURL = auth.manageKeyURL
        try auth.signOut()

        #expect(manageURL == OpenRouterAuthManager.manageKeyURL(for: credential.apiKey))
        #expect(!auth.isAuthenticated)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("sign-out reports deletion failure and preserves authentication")
    @MainActor
    func signOutDeletionFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-openrouter-delete-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenRouterCredentialStore(supportDirectory: root)
        try store.save(OpenRouterCredential(apiKey: "sk-or-v1-retained", userID: nil))
        let auth = OpenRouterAuthManager(
            credentialStore: store,
            loadData: openRouterUnusedLoader,
            openURL: { _ in false },
            environment: { [:] },
            deleteCredential: { throw OpenRouterDeletionTestError.expected }
        )

        #expect(throws: OpenRouterAuthError.credentialDeletionFailed) {
            try auth.signOut()
        }
        #expect(auth.isAuthenticated)
        #expect(try store.load()?.apiKey == "sk-or-v1-retained")
    }

    @Test("environment credentials are authenticated and managed explicitly")
    @MainActor
    func environmentCredentialState() {
        let auth = makeAuth(environment: { ["OPENROUTER_API_KEY": "  sk-or-v1-environment  "] })

        #expect(auth.hasEnvironmentCredential)
        #expect(!auth.hasStoredCredential)
        #expect(auth.isAuthenticated)
        #expect(
            auth.manageKeyURL == OpenRouterAuthManager.manageKeyURL(for: "sk-or-v1-environment")
        )
    }

    @Test("manage-key URL is the lowercase SHA256 key hash")
    func manageKeyURL() {
        #expect(
            OpenRouterAuthManager.manageKeyURL(for: "abc").absoluteString ==
                "https://openrouter.ai/keys/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("manual keys are normalized and stored, with environment fallback")
    @MainActor
    func manualKeyAndEnvironmentFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-openrouter-manual-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = OpenRouterAuthManager(
            credentialStore: OpenRouterCredentialStore(supportDirectory: root),
            loadData: openRouterUnusedLoader,
            openURL: { _ in false },
            environment: { [:] }
        )

        #expect(auth.resolvedAPIKey(environment: ["OPENROUTER_API_KEY": " env-key "]) == "env-key")
        #expect(auth.resolvedAPIKey(legacyAPIKey: " legacy-key ", environment: [:]) == "legacy-key")
        try auth.storeManualAPIKey("  manual-key\n")
        #expect(auth.resolvedAPIKey(environment: ["OPENROUTER_API_KEY": "env-key"]) == "env-key")
        #expect(auth.resolvedAPIKey(environment: [:]) == "manual-key")
        #expect(auth.resolvedAPIKey(legacyAPIKey: "legacy-key", environment: [:]) == "manual-key")
        #expect(auth.isAuthenticated)
    }

    @MainActor
    private func makeAuth(
        loadData: @escaping (URLRequest) async throws -> (Data, URLResponse) = openRouterUnusedLoader,
        environment: @escaping () -> [String: String] = { [:] }
    ) -> OpenRouterAuthManager {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-openrouter-auth-\(UUID().uuidString)", isDirectory: true)
        return OpenRouterAuthManager(
            credentialStore: OpenRouterCredentialStore(supportDirectory: supportDirectory),
            loadData: loadData,
            openURL: { _ in false },
            environment: environment
        )
    }

}

private enum OpenRouterDeletionTestError: Error {
    case expected
}

private func openRouterUnusedLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    throw URLError(.unsupportedURL)
}

private actor RequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

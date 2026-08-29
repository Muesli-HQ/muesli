import CryptoKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("ChatGPT OAuth")
struct ChatGPTAuthTests {

    // MARK: - PKCE

    @Test("PKCE verifier is base64url with no padding")
    @MainActor
    func pkceVerifierFormat() {
        let auth = ChatGPTAuthManager.shared
        let (verifier, _) = auth.generatePKCE()
        #expect(!verifier.isEmpty)
        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
        #expect(!verifier.contains("="))
    }

    @Test("PKCE challenge is SHA256 of verifier")
    @MainActor
    func pkceChallengeIsCorrect() {
        let auth = ChatGPTAuthManager.shared
        let (verifier, challenge) = auth.generatePKCE()

        // Manually compute expected challenge
        let expectedData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let expected = expectedData.base64URLEncoded()
        #expect(challenge == expected)
    }

    @Test("PKCE generates unique values each time")
    @MainActor
    func pkceUniqueness() {
        let auth = ChatGPTAuthManager.shared
        let (v1, _) = auth.generatePKCE()
        let (v2, _) = auth.generatePKCE()
        #expect(v1 != v2)
    }

    // MARK: - State

    @Test("state is at least 8 characters (OpenAI minimum)")
    @MainActor
    func stateMinLength() {
        let auth = ChatGPTAuthManager.shared
        let state = auth.generateState()
        #expect(state.count >= 8)
    }

    // MARK: - Authorization URL

    @Test("authorization URL contains all required OAuth parameters")
    @MainActor
    func authURLContainsRequiredParams() {
        let auth = ChatGPTAuthManager.shared
        let url = auth.buildAuthorizationURL(codeChallenge: "test_challenge", state: "test_state")
        #expect(url != nil)

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let params = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })

        #expect(params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(params["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(params["response_type"] == "code")
        #expect(params["scope"] == "openid profile email offline_access")
        #expect(params["state"] == "test_state")
        #expect(params["code_challenge"] == "test_challenge")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["id_token_add_organizations"] == "true")
        #expect(params["codex_cli_simplified_flow"] == "true")
        #expect(params["originator"] == "muesli")
    }

    @Test("authorization URL points to auth.openai.com")
    @MainActor
    func authURLHost() {
        let auth = ChatGPTAuthManager.shared
        let url = auth.buildAuthorizationURL(codeChallenge: "c", state: "s")!
        #expect(url.host == "auth.openai.com")
        #expect(url.path == "/oauth/authorize")
        #expect(url.scheme == "https")
    }

    // MARK: - Callback Code Extraction

    @Test("extracts code from standard OAuth callback")
    @MainActor
    func extractCodeStandard() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"
        #expect(auth.extractCode(from: request) == "abc123")
    }

    @Test("extracts code with URL-encoded characters")
    @MainActor
    func extractCodeEncoded() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?code=abc%3D123&state=s HTTP/1.1\r\n\r\n"
        #expect(auth.extractCode(from: request) == "abc=123")
    }

    @Test("returns nil when code param is missing")
    @MainActor
    func extractCodeMissing() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?error=access_denied&state=s HTTP/1.1\r\n\r\n"
        #expect(auth.extractCode(from: request) == nil)
    }

    @Test("returns nil for empty request")
    @MainActor
    func extractCodeEmpty() {
        let auth = ChatGPTAuthManager.shared
        #expect(auth.extractCode(from: "") == nil)
    }

    @Test("returns nil for malformed request")
    @MainActor
    func extractCodeMalformed() {
        let auth = ChatGPTAuthManager.shared
        #expect(auth.extractCode(from: "garbage data") == nil)
    }

    @Test("handles LF-only line endings")
    @MainActor
    func extractCodeLFOnly() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?code=mycode&state=s HTTP/1.1\nHost: localhost\n\n"
        #expect(auth.extractCode(from: request) == "mycode")
    }

    // MARK: - JWT Account ID Extraction

    @Test("extracts chatgpt_account_id from top-level claim")
    @MainActor
    func jwtTopLevelClaim() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"chatgpt_account_id": "acct_123", "sub": "user"}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "acct_123")
    }

    @Test("extracts chatgpt_account_id from nested auth claim")
    @MainActor
    func jwtNestedClaim() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"https://api.openai.com/auth": {"chatgpt_account_id": "acct_456"}, "sub": "user"}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "acct_456")
    }

    @Test("falls back to organizations[0].id")
    @MainActor
    func jwtOrgFallback() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"organizations": [{"id": "org_789"}], "sub": "user"}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "org_789")
    }

    @Test("returns empty string for JWT without account claims")
    @MainActor
    func jwtNoClaims() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"sub": "user", "iat": 1234567890}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "")
    }

    @Test("returns empty string for invalid JWT")
    @MainActor
    func jwtInvalid() {
        let auth = ChatGPTAuthManager.shared
        #expect(auth.extractAccountId(from: "not.a.jwt") == "")
        #expect(auth.extractAccountId(from: "") == "")
        #expect(auth.extractAccountId(from: "single_segment") == "")
    }

    @Test("top-level chatgpt_account_id takes priority over nested")
    @MainActor
    func jwtClaimPriority() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"chatgpt_account_id": "top", "https://api.openai.com/auth": {"chatgpt_account_id": "nested"}, "organizations": [{"id": "org"}]}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "top")
    }

    // MARK: - Base64URL

    @Test("base64URL encoding removes padding and substitutes characters")
    func base64URLEncoding() {
        // Bytes that produce + and / in standard base64
        let data = Data([0xFB, 0xFF, 0xFE])
        let encoded = data.base64URLEncoded()
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test("base64URL encoding of empty data is empty string")
    func base64URLEmpty() {
        #expect(Data().base64URLEncoded() == "")
    }

    // MARK: - Helpers

    /// Build a fake JWT with the given JSON payload (header and signature are dummy values).
    private func makeJWT(payload: String) -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8).base64URLEncoded()
        let body = Data(payload.utf8).base64URLEncoded()
        let signature = "fake_signature"
        return "\(header).\(body).\(signature)"
    }
}

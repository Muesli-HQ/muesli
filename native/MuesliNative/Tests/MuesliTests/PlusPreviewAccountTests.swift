import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Muesli Plus account session")
@MainActor
struct PlusPreviewAccountTests {
    @Test func signedOutRefreshDoesNotContactTheService() async {
        let fixture = AccountFixture()
        let account = fixture.account()
        await account.refresh()?.value
        #expect(fixture.requests.isEmpty)
        #expect(account.email == nil)
    }

    @Test func restoresSavedAccountWithoutPairingOrUploading() async {
        let fixture = AccountFixture()
        fixture.saved = "saved-token"
        let account = fixture.account()
        await account.refresh()?.value
        #expect(account.email == "owner@example.com")
        #expect(account.token == "saved-token")
        #expect(account.termsVersion == "test-terms")
        #expect(fixture.requests == ["account"])
        #expect(fixture.opened.isEmpty)
    }

    @Test func signInValidatesAndPersistsAccountWithoutNoteData() async {
        let fixture = AccountFixture()
        let account = fixture.account()
        await account.signIn()?.value
        #expect(account.email == "owner@example.com")
        #expect(fixture.saved == "issued-token")
        #expect(fixture.requests == ["auth/exchange", "account"])
        #expect(fixture.opened.count == 1)
        #expect(!account.busy)
    }

    @Test func expiredConnectionReturnsToSignInWithoutOpeningBrowser() async {
        let fixture = AccountFixture()
        fixture.saved = "expired-token"
        fixture.handler = { path in
            throw PlusPreviewClient.Failure(status: 401, message: "Expired")
        }
        let account = fixture.account()
        await account.refresh()?.value
        #expect(fixture.saved == nil)
        #expect(!account.hasStoredSession)
        #expect(account.email == nil)
        #expect(fixture.opened.isEmpty)
    }

    @Test func signOutRevokesBeforeRemovingCredentials() async {
        let fixture = AccountFixture()
        fixture.saved = "saved-token"
        let account = fixture.account()
        await account.refresh()?.value
        fixture.handler = { path in
            #expect(path == "disconnect")
            #expect(fixture.saved == "saved-token")
            return [:]
        }
        await account.signOut()?.value
        #expect(fixture.saved == nil)
        #expect(account.email == nil)
        #expect(account.token == nil)
        #expect(account.termsVersion == nil)
    }

    @Test func failedSignOutDoesNotPretendToRevokeTheSession() async {
        let fixture = AccountFixture()
        fixture.saved = "saved-token"
        let account = fixture.account()
        await account.refresh()?.value
        fixture.handler = { _ in throw PlusPreviewClient.Failure(status: 503, message: "Offline") }
        await account.signOut()?.value
        #expect(fixture.saved == "saved-token")
        #expect(account.email == "owner@example.com")
        #expect(account.message.contains("Could not sign out"))
    }

    @Test func cancelledPairingCannotSaveALateToken() async {
        let fixture = AccountFixture()
        let account = fixture.account()
        fixture.handler = { path in
            if path == "auth/exchange" { account.cancelSignIn(); return ["token": "late-token"] }
            return AccountFixture.response(path)
        }
        await account.signIn()?.value
        #expect(fixture.saved == nil)
        #expect(account.email == nil)
        #expect(!fixture.requests.contains("account"))
        #expect(!account.busy)
    }

    @Test func keychainFailureDoesNotPublishASignedInAccount() async {
        let fixture = AccountFixture()
        fixture.failSave = true
        let account = fixture.account()
        await account.signIn()?.value
        #expect(account.email == nil)
        #expect(account.token == nil)
        #expect(!account.message.isEmpty)
    }

    @Test func rejectsWrongCallbackStateBeforeTokenExchange() async {
        let fixture = AccountFixture()
        fixture.callbackState = String(repeating: "0", count: 64)
        let account = fixture.account()
        await account.signIn()?.value
        #expect(fixture.requests.isEmpty)
        #expect(fixture.saved == nil)
    }

    @Test func callbackRejectsWrongDestinationAndDuplicateParameters() throws {
        let pkce = try PlusPreviewPKCE()
        let code = String(repeating: "a", count: 64)
        for text in ["https://auth/callback?code=\(code)&state=\(pkce.state)",
                     "com.muesli.plus://other/callback?code=\(code)&state=\(pkce.state)",
                     "com.muesli.plus://auth/callback?code=\(code)&state=\(pkce.state)&state=\(pkce.state)"] {
            #expect(throws: (any Error).self) { try pkce.authorizationCode(from: URL(string: text)!) }
        }
    }

    @Test func cancelledBrowserCannotPersistCredentials() async {
        let fixture = AccountFixture()
        fixture.cancelBrowser = true
        let account = fixture.account()
        await account.signIn()?.value
        #expect(fixture.requests.isEmpty)
        #expect(fixture.saved == nil)
        #expect(account.message.isEmpty)
        #expect(!account.busy)
    }

    @Test func nonPreviewBuildCannotStartAccountOperations() async {
        let fixture = AccountFixture()
        fixture.enabled = false
        fixture.saved = "saved-token"
        let account = fixture.account()
        await account.refresh()?.value
        await account.signIn()?.value
        await account.signOut()?.value
        #expect(fixture.requests.isEmpty)
        #expect(fixture.saved == "saved-token")
    }
}

@MainActor
private final class AccountFixture {
    var saved: String?
    var enabled = true
    var failSave = false
    var cancelBrowser = false
    var callbackState: String?
    var requests: [String] = []
    var opened: [URL] = []
    var handler: ((String) async throws -> [String: Any])?

    static func response(_ path: String) -> [String: Any] {
        switch path {
        case "auth/exchange": return ["token": "issued-token"]
        case "account": return ["email": "owner@example.com", "termsVersion": "test-terms"]
        default: return [:]
        }
    }

    func account() -> PlusPreviewAccount {
        var dependencies = PlusPreviewAccount.Dependencies()
        dependencies.enabled = { self.enabled }
        dependencies.readToken = { self.saved }
        dependencies.saveToken = {
            if self.failSave { throw PlusPreviewClient.Failure(status: 0, message: "Keychain unavailable") }
            self.saved = $0
        }
        dependencies.clearToken = { self.saved = nil }
        dependencies.call = { path, _, body in
            #expect(body?["summary"] == nil)
            #expect(body?["transcript"] == nil)
            self.requests.append(path)
            if let handler = self.handler { return try await handler(path) }
            return Self.response(path)
        }
        dependencies.authenticate = { url in
            self.opened.append(url)
            if self.cancelBrowser { throw CancellationError() }
            #expect(url.host == "notes.muesli.works")
            #expect(url.path == "/auth/native")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
            #expect(query.first(where: { $0.name == "code_challenge" })?.value?.count == 43)
            #expect(!url.absoluteString.contains("verifier"))
            let state = self.callbackState ?? query.first(where: { $0.name == "state" })!.value!
            return URL(string: "com.muesli.plus://auth/callback?code=" + String(repeating: "a", count: 64) + "&state=" + state)!
        }
        return PlusPreviewAccount(dependencies: dependencies)
    }
}

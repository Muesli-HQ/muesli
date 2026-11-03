import AppKit
import Combine
import Foundation
import SwiftUI

/// One account session for About and sharing. Credentials stay in the app's Keychain.
@MainActor
final class PlusPreviewAccount: ObservableObject {
    static let shared = PlusPreviewAccount()

    struct Dependencies {
        var enabled: @MainActor () -> Bool = { PlusPreviewShareView.enabled }
        var readToken: @MainActor () -> String? = { PlusPreviewClient.readToken() }
        var saveToken: @MainActor (String) throws -> Void = { try PlusPreviewClient.saveToken($0) }
        var clearToken: @MainActor () throws -> Void = { try PlusPreviewClient.clearToken() }
        var call: @MainActor (String, String?, [String: Any]?) async throws -> [String: Any] = {
            try await PlusPreviewClient.call($0, token: $1, body: $2)
        }
        var authenticate: @MainActor (URL) async throws -> URL = { try await PlusPreviewWebSignIn.shared.authenticate($0) }
    }

    @Published private(set) var email: String?
    @Published private(set) var token: String?
    @Published private(set) var termsVersion: String?
    @Published private(set) var canShare = false
    @Published private(set) var subscriptionTesting = false
    @Published private(set) var subscriptionBacked = false
    @Published private(set) var busy = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var hasStoredSession = false
    @Published private(set) var message = ""
    private let dependencies: Dependencies
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? { connect(interactive: false) }

    @discardableResult
    func signIn() -> Task<Void, Never>? { connect(interactive: true) }

    func cancelSignIn() {
        guard isSigningIn else { return }
        generation = UUID()
        operation?.cancel()
        operation = nil
        busy = false
        isSigningIn = false
        message = ""
    }

    private func resetAccount() {
        email = nil
        token = nil
        termsVersion = nil
        canShare = false
        subscriptionTesting = false
        subscriptionBacked = false
    }

    private func accept(_ info: [String: Any], token: String) throws {
        guard let email = info["email"] as? String, !email.isEmpty,
              let terms = info["termsVersion"] as? String, !terms.isEmpty else {
            throw PlusPreviewClient.Failure(status: 0, message: "Could not verify your account. Try again.")
        }
        self.email = email
        self.token = token
        termsVersion = terms
        canShare = info["eligible"] as? Bool ?? true // Compatibility with the existing test backend.
        subscriptionTesting = info["subscriptionTesting"] as? Bool ?? false
        subscriptionBacked = (info["subscription"] as? [String: Any])?["retentionPolicy"] as? String == "subscription"
    }

    /// Checkout carries identity and PKCE only. The sharing draft remains in its view.
    @discardableResult
    func subscribe() -> Task<Void, Never>? {
        guard dependencies.enabled(), subscriptionTesting, let currentToken = token, !busy else { return nil }
        busy = true
        isSigningIn = true
        message = ""
        let current = UUID()
        generation = current
        operation = Task { @MainActor in
            defer { if generation == current { busy = false; isSigningIn = false } }
            do {
                let pkce = try PlusPreviewPKCE()
                let start = try await dependencies.call("billing/start", currentToken, ["challenge": pkce.challenge, "state": pkce.state])
                try Task.checkCancellation()
                guard generation == current else { return }
                guard let link = start["url"] as? String, let url = URL(string: link),
                      url.scheme == "https", url.host == "notes.muesli.works", url.path == "/subscribe",
                      url.user == nil, url.password == nil, url.port == nil else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Could not start checkout safely.")
                }
                let callback = try await dependencies.authenticate(url)
                try Task.checkCancellation()
                guard generation == current else { return }
                let code = try pkce.authorizationCode(from: callback)
                let result = try await dependencies.call("auth/exchange", nil, ["code": code, "verifier": pkce.verifier])
                guard let issued = result["token"] as? String else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Could not verify checkout return.")
                }
                let info = try await dependencies.call("account", issued, nil)
                try Task.checkCancellation()
                guard generation == current else { return }
                guard info["eligible"] as? Bool == true,
                      let email = info["email"] as? String, email == self.email,
                      let terms = info["termsVersion"] as? String, !terms.isEmpty else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Payment is not verified for this account yet. Check your subscription.")
                }
                try dependencies.saveToken(issued)
                try accept(info, token: issued)
                hasStoredSession = true
                message = "Your subscription is ready. Review your note, then choose Upload and invite."
            } catch is CancellationError {
            } catch {
                if generation == current { message = error.localizedDescription }
            }
        }
        return operation
    }

    private func connect(interactive: Bool) -> Task<Void, Never>? {
        guard dependencies.enabled(), !busy else { return nil }
        var saved = dependencies.readToken()
        hasStoredSession = saved != nil
        if saved == nil {
            resetAccount()
            if !interactive { return nil }
        }
        busy = true
        isSigningIn = interactive
        message = ""
        let current = UUID()
        generation = current
        operation = Task { @MainActor in
            defer {
                if generation == current {
                    busy = false
                    isSigningIn = false
                }
            }
            do {
                if let savedToken = saved {
                    do {
                        let info = try await dependencies.call("account", savedToken, nil)
                        try Task.checkCancellation()
                        guard generation == current else { return }
                        try accept(info, token: savedToken)
                        return
                    } catch let error as PlusPreviewClient.Failure where error.status == 401 {
                        try Task.checkCancellation()
                        guard generation == current else { return }
                        try dependencies.clearToken()
                        resetAccount()
                        hasStoredSession = false
                        saved = nil
                        if !interactive { message = "Sign in again to use sharing." }
                    }
                }
                guard saved == nil, interactive else { return }
                let pkce = try PlusPreviewPKCE()
                let callback = try await dependencies.authenticate(pkce.authorizationURL)
                try Task.checkCancellation()
                guard generation == current else { return }
                let authCode = try pkce.authorizationCode(from: callback)
                let result = try await dependencies.call("auth/exchange", nil, ["code": authCode, "verifier": pkce.verifier])
                try Task.checkCancellation()
                guard generation == current else { return }
                guard let issued = result["token"] as? String else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Could not sign in. Try again.")
                }
                let info = try await dependencies.call("account", issued, nil)
                try Task.checkCancellation()
                guard generation == current else { return }
                // Validate before saving, and publish only after Keychain succeeds.
                guard let email = info["email"] as? String, !email.isEmpty,
                      let terms = info["termsVersion"] as? String, !terms.isEmpty else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Could not verify your account. Try again.")
                }
                try dependencies.saveToken(issued)
                try accept(info, token: issued)
                hasStoredSession = true
            } catch is CancellationError {
                // A dismissed sign-in must never save a late response.
            } catch {
                guard generation == current else { return }
                if let failure = error as? PlusPreviewClient.Failure, failure.status == 403 {
                    resetAccount()
                }
                message = error.localizedDescription
            }
        }
        return operation
    }

    @discardableResult
    func signOut() -> Task<Void, Never>? {
        guard dependencies.enabled(), !busy else { return nil }
        busy = true
        message = ""
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                if let saved = dependencies.readToken() {
                    do { _ = try await dependencies.call("disconnect", saved, [:]) }
                    catch let failure as PlusPreviewClient.Failure where failure.status == 401 {
                        // The server has already invalidated this session.
                    }
                }
                try dependencies.clearToken()
                resetAccount()
                hasStoredSession = false
            } catch {
                message = "Could not sign out. " + error.localizedDescription
            }
        }
        return operation
    }
}

struct PlusPreviewAccountView: View {
    @ObservedObject private var account = PlusPreviewAccount.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 28)).foregroundStyle(MuesliTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.email ?? "Muesli Plus")
                        .font(MuesliTheme.body()).textSelection(.enabled)
                    Text(account.email == nil ? "Sign in to share meeting notes." : "Signed in on this Mac")
                        .font(MuesliTheme.callout()).foregroundStyle(.secondary)
                }
                Spacer()
                if account.busy { ProgressView().controlSize(.small) }
                if account.isSigningIn {
                    Button("Cancel", systemImage: "xmark") { account.cancelSignIn() }
                        .buttonStyle(SharingSecondaryButtonStyle())
                } else if account.hasStoredSession {
                    if account.email == nil {
                        Button("Retry", systemImage: "arrow.clockwise") { account.refresh() }
                            .buttonStyle(SharingPrimaryButtonStyle()).disabled(account.busy)
                    }
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { account.signOut() }
                        .buttonStyle(SharingPrimaryButtonStyle()).disabled(account.busy)
                } else {
                    Button("Sign in", systemImage: "person.crop.circle") { account.signIn() }
                        .buttonStyle(SharingPrimaryButtonStyle()).disabled(account.busy)
                }
            }
            if !account.message.isEmpty {
                Text(account.message).font(.callout).foregroundStyle(.secondary)
            }
            if account.email != nil && account.subscriptionTesting {
                Link("Manage subscription", destination: URL(string: "https://notes.muesli.works/subscribe")!)
                    .font(.callout)
            }
        }
        .task { account.refresh() }
    }
}

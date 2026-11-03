import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// A system browser session routes the callback only to the initiating app session.
/// The verifier remains in memory on this Mac and never appears in a browser URL.
struct PlusPreviewPKCE {
    let verifier: String
    let state: String

    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw PlusPreviewClient.Failure(status: 0, message: "Could not start secure sign-in. Try again.")
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        verifier = try random()
        state = try random()
    }

    var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var authorizationURL: URL {
        var url = URLComponents(string: "https://notes.muesli.works/auth/native")!
        url.queryItems = [URLQueryItem(name: "code_challenge", value: challenge),
                          URLQueryItem(name: "code_challenge_method", value: "S256"),
                          URLQueryItem(name: "state", value: state)]
        return url.url!
    }

    func authorizationCode(from url: URL) throws -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = parts?.queryItems ?? []
        let codes = items.filter { $0.name == "code" }
        let states = items.filter { $0.name == "state" }
        guard url.scheme == "com.muesli.plus", url.host == "auth", url.path == "/callback",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              codes.count == 1, states.count == 1, states.first?.value == state,
              let code = codes.first?.value, code.count == 64,
              code.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw PlusPreviewClient.Failure(status: 0, message: "Sign-in could not be verified. Try again.")
        }
        return code
    }
}

@MainActor
final class PlusPreviewWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PlusPreviewWebSignIn()
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var attempt: UUID?
    private var anchor: NSWindow?

    func authenticate(_ url: URL) async throws -> URL {
        let id = UUID()
        guard session == nil else { throw CancellationError() }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.attempt = id
                self.continuation = continuation
                self.anchor = NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "com.muesli.plus") { [weak self] url, error in
                    Task { @MainActor in
                        guard let self, self.attempt == id else { return }
                        if let url { self.finish(.success(url)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self.finish(.failure(CancellationError()))
                        } else {
                            self.finish(.failure(PlusPreviewClient.Failure(status: 0, message: "Could not complete browser sign-in. Try again.")))
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    finish(.failure(PlusPreviewClient.Failure(status: 0, message: "Could not open browser sign-in. Try again.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.attempt == id else { return }
                self.session?.cancel()
                self.finish(.failure(CancellationError()))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? NSWindow()
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        attempt = nil
        anchor = nil
        pending?.resume(with: result)
        NSApp.activate(ignoringOtherApps: true)
    }
}

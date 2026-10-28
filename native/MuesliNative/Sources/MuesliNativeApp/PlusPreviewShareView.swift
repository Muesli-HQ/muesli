import AppKit
import Security
import SwiftUI

/// Available in the preview bundle or an explicitly opted-in DevC build. Account checks send no meeting content.
struct PlusPreviewShareView: View {
    static var enabled: Bool {
        let identifier = Bundle.main.bundleIdentifier
        return identifier == "com.muesli.plus.preview"
            || (identifier == "com.muesli.dev.c"
                && Bundle.main.object(forInfoDictionaryKey: "MuesliPlusPreviewEnabled") as? Bool == true)
    }
    var onShared: (URL, [String], Date) -> Void
    @Environment(\.dismiss) private var dismiss
    private struct NoteSnapshot {
        let title: String
        let summary: String
        let transcript: String
    }
    // Capture the saved note once when the sheet opens. The preview never edits or reserializes it.
    @State private var note: NoteSnapshot
    private var title: String { note.title }
    private var summary: String { note.summary }
    private var transcript: String { note.transcript }
    @State private var previewTranscript = false
    @State private var recipients = SharingRecipientInput()
    @State private var includeTranscript = false
    @State private var accepted = false
    @State private var uploading = false
    @ObservedObject private var session = PlusPreviewAccount.shared
    private var busy: Bool { uploading || session.busy }
    @State private var attempted = false
    private var account: String? { session.email }
    private var token: String? { session.token }
    private var termsVersion: String? { session.termsVersion }
    @State private var message = ""
    @State private var sharedURL: URL?
    @State private var requestID = UUID().uuidString

    init(title: String, summary: String, transcript: String, onShared: @escaping (URL, [String], Date) -> Void = { _, _, _ in }) {
        self.onShared = onShared
        _note = State(initialValue: NoteSnapshot(title: title, summary: summary, transcript: transcript))
    }
    private var emails: [String] { recipients.emails }
    private var validRecipients: Bool { recipients.isReady }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Share meeting").font(.title2.bold())
                Spacer()
                Text("Plus Preview").foregroundStyle(.secondary)
                Button("Close") {
                    session.cancelSignIn()
                    dismiss()
                }.disabled(busy && !session.isSigningIn)
            }
            if let sharedURL {
                SharingSuccessView(url: sharedURL, recipients: emails)
            } else {
                Text(
                    "A copy will leave this Mac. Only invited people who sign in can read it. Your local meeting stays unchanged."
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 8) {
                    if includeTranscript {
                        Picker("Preview", selection: $previewTranscript) {
                            Text("Notes").tag(false)
                            Text("Transcript").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Group {
                        if includeTranscript && previewTranscript {
                            ScrollView {
                                Text(transcript)
                                    .font(MuesliTheme.reading())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                        } else {
                            MeetingNotesView(markdown: summary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MuesliTheme.backgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Include transcript", isOn: $includeTranscript)
                    Text("Invite people").font(.callout.bold())
                    SharingRecipientField(input: $recipients)
                    Text("Audio and attachments are never included.").font(.caption).foregroundStyle(.secondary)
                    Toggle(
                        "I accept the sharing test terms and confirm this is fictional, non-confidential test content.",
                        isOn: $accepted
                    )
                    .font(.caption)
                    Link("Sharing test terms", destination: URL(string: "https://notes.muesli.works/sharing-terms")!)
                        .font(.caption)
                    Text(
                        "Test copies expire after seven days. Revoking access cannot erase copies a recipient already saved."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(busy || attempted)
                if let account {
                    Text("Sharing from: \(account)").font(.caption)
                }
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
                if !session.message.isEmpty { Text(session.message).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    if account == nil {
                        Button("Sign in with your account", systemImage: "person.crop.circle") { session.signIn() }
                            .buttonStyle(SharingPrimaryButtonStyle())
                            .help("Sign in to Muesli Plus to check sharing access. Nothing is uploaded yet.")
                            .disabled(busy)
                    } else {
                        Button("Sign out", systemImage: "person.crop.circle.badge.xmark") { session.signOut() }.disabled(busy)
                        Spacer()
                        Button("Upload and invite", systemImage: "square.and.arrow.up") { upload() }
                            .buttonStyle(SharingPrimaryButtonStyle())
                            .disabled(
                                busy || attempted || !accepted || !validRecipients
                                    || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || (summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        && (!includeTranscript
                                            || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            )
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
            }
        }.padding(24).frame(width: 620, height: sharedURL == nil ? 680 : 260)
            .task { session.refresh() }
            .onDisappear { session.cancelSignIn() }
    }
    private func upload() {
        guard Self.enabled, !busy, !attempted, accepted, validRecipients, let token, let termsVersion, account != nil else { return }
        // This is the sole content-bearing network call, reachable only from the explicit button.
        uploading = true
        attempted = true
        message = ""
        Task { @MainActor in
            defer { uploading = false }
            do {
                let snapshot: [String: Any] = ["title": title, "summary": summary,
                    "transcript": includeTranscript ? transcript : "", "recipients": emails,
                    "confirmed": true, "accepted": true, "termsVersion": termsVersion, "requestId": requestID]
                let result = try await PlusPreviewClient.call("upload", token: token, body: snapshot)
                guard let link = result["url"] as? String, let url = URL(string: link), url.scheme == "https",
                    url.host == "notes.muesli.works"
                else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Check Shared notes to confirm the result.")
                }
                guard let expiresAt = result["expiresAt"] as? Double else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Check Shared notes to confirm the result.")
                }
                onShared(url, emails, Date(timeIntervalSince1970: expiresAt))
                sharedURL = url
                NSWorkspace.shared.open(url)
            } catch {
                message =
                    error.localizedDescription
                    + " Check Shared notes before retrying; an interrupted request may have completed."
            }
        }
    }
}

private struct SharingSuccessView: View {
    let url: URL
    let recipients: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color(hex: 0x15803D), in: Circle())
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)
                    .accessibilityHidden(true)
                Text("Shared").font(.title.bold())
            }
            Text("Shared with " + recipients.joined(separator: ", ")).font(.callout).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Open note", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    .buttonStyle(SharingPrimaryButtonStyle())
                Button(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .buttonStyle(SharingSecondaryButtonStyle())
                Button("Manage access", systemImage: "person.2") {
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.fragment = "permissions"
                    if let destination = components?.url { NSWorkspace.shared.open(destination) }
                }
                .buttonStyle(SharingSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.65)) {
                appeared = true
            }
        }
    }
}

struct SharingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(hex: configuration.isPressed ? 0x4B5563 : 0x374151),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.3)))
    }
}

struct SharingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Color(hex: 0x2563EB).opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                in: RoundedRectangle(cornerRadius: 6))
    }
}

enum PlusPreviewClient {
    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }
    // Ephemeral transport deliberately avoids the browser's cookies and a disk response cache.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }
    static func call(_ path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://notes.muesli.works/api/preview/" + path)!)
        request.timeoutInterval = 30
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(status: 0, message: "Could not reach Muesli sharing.")
        }
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(
                status: http.statusCode, message: result["error"] as? String ?? "Could not reach Muesli sharing.")
        }
        return result
    }
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.muesli.plus.preview") + ".sharing",
            kSecAttrAccount as String: "device",
        ]
    }
    static func readToken() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    static func clearToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: 0, message: "Could not remove the connection from Keychain.")
        }
    }
    static func saveToken(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw Failure(status: 0, message: "Could not save the connection in Keychain.")
        }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
            throw Failure(status: 0, message: "Could not save the connection in Keychain.")
        }
    }
}

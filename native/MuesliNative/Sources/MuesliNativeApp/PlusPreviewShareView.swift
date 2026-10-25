import AppKit
import Security
import SwiftUI

/// Available in the preview bundle or an explicitly opted-in DevC build. Opening performs no network work.
struct PlusPreviewShareView: View {
    static var enabled: Bool {
        let identifier = Bundle.main.bundleIdentifier
        return identifier == "com.muesli.plus.preview"
            || (identifier == "com.muesli.dev.c"
                && Bundle.main.object(forInfoDictionaryKey: "MuesliPlusPreviewEnabled") as? Bool == true)
    }
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
    @State private var busy = false
    @State private var attempted = false
    @State private var account: String?
    @State private var token: String?
    @State private var termsVersion: String?
    @State private var code: String?
    @State private var message = ""
    @State private var sharedURL: URL?
    @State private var connectionTask: Task<Void, Never>?
    @State private var requestID = UUID().uuidString

    init(title: String, summary: String, transcript: String) {
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
                    connectionTask?.cancel()
                    dismiss()
                }.disabled(busy && code == nil)
            }
            if let sharedURL {
                Label("Shared copy created", systemImage: "checkmark.circle")
                Text("Invitation delivery is tracked in Manage access.").foregroundStyle(.secondary)
                Link("Manage access", destination: sharedURL)
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sharedURL.absoluteString, forType: .string)
                }
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
                    Text("Connected as \(account)").font(.caption)
                }
                if let code { Text("Connection code: \(code)").font(.headline.monospaced()) }
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    if account == nil {
                        Button("Sign in to share") { connect() }
                            .buttonStyle(SharingPrimaryButtonStyle())
                            .help("Sign in to Muesli Plus to check sharing access. Nothing is uploaded yet.")
                            .disabled(busy)
                    } else {
                        Button("Disconnect") { disconnect() }.disabled(busy)
                        Spacer()
                        Button("Upload and invite") { upload() }
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
        }.padding(24).frame(width: 620, height: 680)
            .onDisappear { connectionTask?.cancel() }
    }
    private func connect() {
        guard Self.enabled else { return }
        busy = true
        message = ""
        code = nil
        connectionTask = Task { @MainActor in
            defer {
                busy = false
                code = nil
            }
            do {
                var saved = PlusPreviewClient.readToken()
                if let current = saved {
                    do {
                        let info = try await PlusPreviewClient.call("account", token: current)
                        account = info["email"] as? String
                        termsVersion = info["termsVersion"] as? String
                        token = current
                        return
                    } catch let error as PlusPreviewClient.Failure where error.status == 401 {
                        PlusPreviewClient.clearToken()
                        saved = nil
                    }
                }
                if saved == nil {
                    let pair = try await PlusPreviewClient.call("pair/start", body: [:])
                    guard let id = pair["id"] as? String, let pollToken = pair["pollToken"] as? String,
                        let displayCode = pair["code"] as? String, let link = pair["url"] as? String,
                        let url = URL(string: link), url.scheme == "https", url.host == "notes.muesli.works",
                        url.path == "/preview/connect"
                    else { throw PlusPreviewClient.Failure(status: 0, message: "Could not connect. Try again.") }
                    code = displayCode
                    NSWorkspace.shared.open(url)
                    for _ in 0..<120 {
                        try await Task.sleep(for: .seconds(5))
                        let result = try await PlusPreviewClient.call(
                            "pair/poll", body: ["id": id, "pollToken": pollToken])
                        if let issued = result["token"] as? String {
                            try Task.checkCancellation()
                            let info = try await PlusPreviewClient.call("account", token: issued)
                            try Task.checkCancellation()
                            try PlusPreviewClient.saveToken(issued)
                            token = issued
                            account = info["email"] as? String
                            termsVersion = info["termsVersion"] as? String
                            return
                        }
                    }
                    message = "Connection expired. Try again."
                }
            } catch is CancellationError {} catch { message = error.localizedDescription }
        }
    }
    private func disconnect() {
        guard let token, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await PlusPreviewClient.call("disconnect", token: token, body: [:])
                PlusPreviewClient.clearToken()
                self.token = nil
                account = nil
                termsVersion = nil
                message = ""
            } catch { message = "Could not disconnect yet. " + error.localizedDescription }
        }
    }
    private func upload() {
        guard Self.enabled, !busy, !attempted, accepted, validRecipients, let token, let termsVersion else { return }
        // This is the sole content-bearing network call, reachable only from the explicit button.
        let snapshot: [String: Any] = [
            "title": title, "summary": summary, "transcript": includeTranscript ? transcript : "", "recipients": emails,
            "confirmed": true, "accepted": true, "termsVersion": termsVersion, "requestId": requestID,
        ]
        busy = true
        attempted = true
        message = ""
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await PlusPreviewClient.call("upload", token: token, body: snapshot)
                guard let link = result["url"] as? String, let url = URL(string: link), url.scheme == "https",
                    url.host == "notes.muesli.works"
                else {
                    throw PlusPreviewClient.Failure(status: 0, message: "Check Shared notes to confirm the result.")
                }
                sharedURL = url
            } catch {
                message =
                    error.localizedDescription
                    + " Check Shared notes before retrying; an interrupted request may have completed."
            }
        }
    }
}

private struct SharingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Color(hex: 0x2563EB).opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum PlusPreviewClient {
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
    static func clearToken() { SecItemDelete(query as CFDictionary) }
    static func saveToken(_ token: String) throws {
        clearToken()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
            throw Failure(status: 0, message: "Could not save the connection in Keychain.")
        }
    }
}

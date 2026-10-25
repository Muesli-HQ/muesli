import AppKit
import SwiftUI

/// Only remembers links explicitly created from this local meeting. No title-based matching.
struct MeetingSharingReceipt: Codable {
    let url: URL
    var recipients: [String]
    var expiresAt: Date
}

struct MeetingSharingControl: View {
    let meetingKey: String
    let title: String
    let summary: String
    let transcript: String
    let disabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var receipt: MeetingSharingReceipt?
    @State private var showUpload = false
    @State private var showAccess = false
    @State private var refreshing = false
    @State private var status = ""
    @State private var copied = false

    private var storageKey: String { "plus-preview.share." + meetingKey }

    var body: some View {
        Button {
            if receipt == nil { showUpload = true } else { showAccess = true }
        } label: {
            Label(receipt == nil ? "Share" : "Shared",
                  systemImage: receipt == nil ? "person.crop.circle.badge.plus" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(hex: receipt == nil ? 0x2563EB : 0x15803D),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
        .help(receipt.map { "Shared with " + $0.recipients.joined(separator: ", ") } ?? "Share this meeting")
        .sheet(isPresented: $showUpload) {
            PlusPreviewShareView(title: title, summary: summary, transcript: transcript) { url, emails, expiry in
                receipt = MeetingSharingReceipt(url: url, recipients: emails, expiresAt: expiry)
                status = ""
                persist()
            }
        }
        .popover(isPresented: $showAccess) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shared with").font(.headline)
                if let receipt {
                    if receipt.recipients.isEmpty {
                        Text("Only you have access.").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(receipt.recipients, id: \.self) { email in
                                    Label(email, systemImage: "person.crop.circle")
                                        .textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 160)
                    }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        Button("Manage access") {
                            var url = URLComponents(url: receipt.url, resolvingAgainstBaseURL: false)
                            url?.fragment = "permissions"
                            if let destination = url?.url { NSWorkspace.shared.open(destination) }
                        }.buttonStyle(SharingPrimaryButtonStyle())
                        Button(copied ? "Copied" : "Copy link") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(receipt.url.absoluteString, forType: .string)
                        }.buttonStyle(SharingSecondaryButtonStyle())
                    }
                    Button("Refresh access") { Task { await refresh() } }
                        .buttonStyle(SharingSecondaryButtonStyle()).disabled(refreshing)
                } else {
                    Text("This shared link is no longer available.")
                }
            }
            .padding(20).frame(width: 380)
            .task { await refresh() }
        }
        .task(id: meetingKey) {
            receipt = UserDefaults.standard.data(forKey: storageKey)
                .flatMap { try? JSONDecoder().decode(MeetingSharingReceipt.self, from: $0) }
            status = ""
            await refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func persist() {
        if let receipt, let data = try? JSONEncoder().encode(receipt) {
            UserDefaults.standard.set(data, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    private func refresh() async {
        guard !refreshing, let current = receipt else { return }
        if current.expiresAt <= Date() {
            receipt = nil
            persist()
            return
        }
        guard let token = PlusPreviewClient.readToken() else {
            status = "Last known access. Open Manage access to check your account."
            return
        }
        refreshing = true
        defer { refreshing = false }
        let key = meetingKey
        do {
            let result = try await PlusPreviewClient.call("notes/" + current.url.lastPathComponent, token: token)
            guard !Task.isCancelled, key == meetingKey,
                  let emails = result["recipients"] as? [String],
                  let expiry = result["expiresAt"] as? Double else { return }
            receipt = MeetingSharingReceipt(url: current.url, recipients: emails, expiresAt: Date(timeIntervalSince1970: expiry))
            status = ""
            persist()
        } catch let error as PlusPreviewClient.Failure where error.status == 404 {
            guard !Task.isCancelled, key == meetingKey else { return }
            receipt = nil
            persist()
        } catch {
            guard !Task.isCancelled, key == meetingKey else { return }
            status = "Last known access. Could not refresh; check Manage access."
        }
    }
}

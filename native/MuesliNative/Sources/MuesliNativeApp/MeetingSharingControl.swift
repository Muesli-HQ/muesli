import AppKit
import SwiftUI

/// Only remembers links explicitly created from this local meeting. No title-based matching.
struct MeetingSharingReceipt: Codable {
    let url: URL
    var recipients: [String]
    var expiresAt: Date
    var ownerEmail: String? = nil
}

struct MeetingSharingControl: View {
    let meetingKey: String
    let title: String
    let summary: String
    let transcript: String
    let disabled: Bool
    let reconcile: () async throws -> Void
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var account = PlusPreviewAccount.shared
    @State private var receipt: MeetingSharingReceipt?
    @State private var showUpload = false
    @State private var showAccess = false
    @State private var refreshing = false
    @State private var status = ""
    @State private var copied = false
    @State private var reconciling = true

    private var storageKey: String { "plus-preview.share." + meetingKey }

    var body: some View {
        Button {
            if receipt == nil { showUpload = true } else { showAccess = true }
        } label: {
            Label(receipt == nil ? "Share" : "Shared",
                  systemImage: receipt == nil ? "person.crop.circle.badge.plus" : "person.2.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(hex: receipt == nil ? 0x2563EB : 0x15803D),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled || reconciling)
        .help(receipt.map { "Shared with " + $0.recipients.joined(separator: ", ") } ?? "Share this meeting")
        .sheet(isPresented: $showUpload) {
            PlusPreviewShareView(title: title, summary: summary, transcript: transcript) { url, emails, expiry in
                receipt = MeetingSharingReceipt(url: url, recipients: emails, expiresAt: expiry)
                status = ""
                persist()
            }
        }
        .popover(isPresented: $showAccess) {
            SharingCardScaleLayout(scale: 0.75) {
                VStack(alignment: .leading, spacing: 0) {
                    if let receipt {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("People with access").font(.headline)
                                Spacer()
                                Menu {
                                    Button("Refresh access", systemImage: "arrow.clockwise") {
                                        Task { await refresh() }
                                    }
                                    .disabled(refreshing)
                                    Divider()
                                    Button("Share another copy", systemImage: "square.and.arrow.up") {
                                        showAccess = false
                                        showUpload = true
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .accessibilityLabel("Sharing options")
                            }
                            Button("Invite or manage people", systemImage: "person.badge.plus") {
                                openPermissions(receipt.url)
                            }
                            .buttonStyle(SharingPrimaryButtonStyle())

                            let readers = receipt.recipients.filter {
                                $0.caseInsensitiveCompare(receipt.ownerEmail ?? "") != .orderedSame
                            }
                            ScrollView {
                                VStack(spacing: 14) {
                                    personRow(receipt.ownerEmail ?? "You", role: "Owner", isOwner: true)
                                    ForEach(readers, id: \.self) { email in
                                        personRow(email, role: "Viewer", isOwner: false)
                                    }
                                }
                            }
                            .frame(height: min(CGFloat(readers.count + 1) * 48 - 14, 226))
                            if !status.isEmpty {
                                Label(status, systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(18)
                        Divider()
                        HStack(spacing: 12) {
                            Label("Invited people only", systemImage: "lock")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link") {
                                NSPasteboard.general.clearContents()
                                copied = NSPasteboard.general.setString(receipt.url.absoluteString, forType: .string)
                            }.buttonStyle(SharingPrimaryButtonStyle())
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                    } else {
                        Text("This shared link is no longer available.").padding(18)
                    }
                }
                .frame(width: 380)
                .fixedSize(horizontal: false, vertical: true)
                .scaleEffect(0.75)
            }
            .task { copied = false; await refresh() }
        }
        .task(id: meetingKey) {
            reconciling = true
            defer { reconciling = false }
            do { try await reconcile() } catch {
                status = "Could not check earlier shares. Try again when connected."
            }
            guard !Task.isCancelled else { return }
            receipt = UserDefaults.standard.data(forKey: storageKey)
                .flatMap { try? JSONDecoder().decode(MeetingSharingReceipt.self, from: $0) }
            status = ""
            await refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onChange(of: account.token) { _, _ in
            Task { await refresh() }
        }
    }

    private func personRow(_ email: String, role: String, isOwner: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isOwner ? "person.fill" : "person")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOwner ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background(isOwner ? Color(hex: 0x2563EB) : Color.primary.opacity(0.08), in: Circle())
            Text(email)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(email)
            Spacer(minLength: 6)
            Text(role).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func openPermissions(_ link: URL) {
        var url = URLComponents(url: link, resolvingAgainstBaseURL: false)
        url?.fragment = "permissions"
        if let destination = url?.url { NSWorkspace.shared.open(destination) }
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
            status = "App not signed in. Showing saved access."
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
            receipt = MeetingSharingReceipt(url: current.url, recipients: emails,
                                            expiresAt: Date(timeIntervalSince1970: expiry),
                                            ownerEmail: result["ownerEmail"] as? String ?? current.ownerEmail)
            status = ""
            persist()
        } catch let error as PlusPreviewClient.Failure where error.status == 404 {
            guard !Task.isCancelled, key == meetingKey else { return }
            receipt = nil
            persist()
        } catch let error as PlusPreviewClient.Failure where error.status == 401 || error.status == 403 {
            guard !Task.isCancelled, key == meetingKey else { return }
            status = error.status == 401
                ? "App sign-in expired. Showing saved access."
                : "Account access needs attention. Showing saved access."
        } catch {
            guard !Task.isCancelled, key == meetingKey else { return }
            status = "Couldn’t refresh. Showing saved access."
        }
    }
}

/// Shrinks the popover's layout bounds along with its contents, rather than
/// leaving the original empty space around a visually scaled card.
private struct SharingCardScaleLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(.unspecified)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY),
                             anchor: .center, proposal: .unspecified)
    }
}

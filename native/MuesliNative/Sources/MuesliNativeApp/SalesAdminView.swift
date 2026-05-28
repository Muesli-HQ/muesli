import AppKit
import SwiftUI

struct SalesAdminView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var identity: SalesCaddieIdentityResponse?
    @State private var members: [SalesCaddieWorkspaceMember] = []
    @State private var selectedMemberID: String?
    @State private var draft = MemberDraft()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isInviting = false
    @State private var latestInvite: SalesCaddieInviteResponse?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var selectedMember: SalesCaddieWorkspaceMember? {
        members.first { $0.id == selectedMemberID }
    }

    private var canManageMembers: Bool {
        identity?.permissions.canManageMembers == true
    }

    private var canManageLibrary: Bool {
        identity?.permissions.canManageLibrary == true || canManageMembers
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                header
                statusStrip
                adminOverviewSection
                librarySection
                membersSection
                editorSection
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
        .task {
            await load()
        }
        .onChange(of: selectedMemberID) { _, _ in
            loadSelectedMemberIntoDraft()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing16) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Workspace")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Team members, invites, permissions, and shared Sales Assist library setup.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Label(isLoading ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    .font(MuesliTheme.body())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shared Library")
                        .font(MuesliTheme.title2())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Central source for approved knowledge base notes, objections, battlecards, discovery prompts, and live cues.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.salesAssistAdminManagedLibraryEnabled },
                    set: { value in controller.updateConfig { $0.salesAssistAdminManagedLibraryEnabled = value } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
                .disabled(!canManageLibrary)
            }

            HStack(spacing: MuesliTheme.spacing8) {
                Text("Source")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 64, alignment: .leading)
                PastableTextField(
                    text: appState.config.salesAssistAdminLibraryURL,
                    placeholder: "Supabase table, signed URL, or admin API endpoint"
                ) { value in
                    controller.updateConfig { $0.salesAssistAdminLibraryURL = value }
                }
                .frame(height: 28)
                .disabled(!canManageLibrary)
            }

            HStack(spacing: MuesliTheme.spacing8) {
                pill("\(appState.config.salesAssistObjections.count) objections")
                pill("\(appState.config.salesAssistLiveCues.count) live cues")
                pill(appState.config.salesAssistAdminManagedLibraryEnabled ? "Shared source on" : "Local library")
                Spacer()
                Button {
                    appState.preferredSettingsPane = "sales"
                    appState.selectedTab = .settings
                } label: {
                    Label("Connection settings", systemImage: "slider.horizontal.3")
                        .font(MuesliTheme.caption())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MuesliTheme.spacing20)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .opacity(canManageLibrary ? 1 : 0.6)
    }

    private var adminOverviewSection: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: MuesliTheme.spacing12) {
            adminCapabilityCard(
                title: "Members",
                value: members.isEmpty ? "Not loaded" : "\(members.count) users",
                detail: canManageMembers ? "Invite, map, and permission reps." : "Your role cannot edit members.",
                systemImage: "person.2",
                good: canManageMembers
            )
            adminCapabilityCard(
                title: "Shared Library",
                value: appState.config.salesAssistAdminManagedLibraryEnabled ? "Managed" : "Local",
                detail: "Controls KB, objections, battlecards, and live cue cards.",
                systemImage: "rectangle.stack",
                good: canManageLibrary
            )
            adminCapabilityCard(
                title: "Cloud",
                value: appState.config.salesCaddieCloudSyncEnabled ? "Hosted API" : "Not connected",
                detail: identity?.workspace.slug ?? "Connect in Settings > Sales.",
                systemImage: "cloud",
                good: appState.config.salesCaddieCloudSyncEnabled && identity != nil
            )
        }
    }

    private func adminCapabilityCard(title: String, value: String, detail: String, systemImage: String, good: Bool) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(good ? MuesliTheme.accent : MuesliTheme.textTertiary)
                Spacer()
                Circle()
                    .fill(good ? MuesliTheme.success : MuesliTheme.transcribing)
                    .frame(width: 8, height: 8)
            }
            Text(title)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            Text(value)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
            Text(detail)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MuesliTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let identity {
            HStack(spacing: MuesliTheme.spacing12) {
                pill(identity.workspace.slug)
                pill(identity.member.email)
                pill(identity.member.role.capitalized)
                pill(canManageMembers ? "Can manage members" : "Read only")
                Spacer()
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        } else if isLoading {
            Text("Loading admin workspace...")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }

        if let statusMessage {
            Text(statusMessage)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.accent)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(MuesliTheme.body())
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack {
                Text("Team")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("\(members.count)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.horizontal, MuesliTheme.spacing8)
                    .padding(.vertical, 3)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(Capsule())
                Spacer()
                Button {
                    selectedMemberID = nil
                    draft = MemberDraft()
                } label: {
                    Label("New member", systemImage: "plus")
                        .font(MuesliTheme.body())
                }
                .buttonStyle(.plain)
                .disabled(!canManageMembers)
            }

            LazyVStack(spacing: 0) {
                if members.isEmpty {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text("No workspace members loaded")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(appState.config.salesCaddieCloudSyncEnabled ? "Refresh the workspace or create the first invite." : "Enable Sales Caddie Cloud in Settings > Sales before managing members.")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .padding(MuesliTheme.spacing20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    memberHeader
                    ForEach(members) { member in
                        memberRow(member)
                    }
                }
            }
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    private var memberHeader: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Role")
                .frame(width: 90, alignment: .leading)
            Text("Join")
                .frame(width: 92, alignment: .leading)
            Text("GHL")
                .frame(width: 120, alignment: .leading)
        }
        .font(MuesliTheme.caption())
        .foregroundStyle(MuesliTheme.textTertiary)
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.surfacePrimary)
    }

    private func memberRow(_ member: SalesCaddieWorkspaceMember) -> some View {
        VStack(spacing: 0) {
            Button {
                selectedMemberID = member.id
            } label: {
                HStack(spacing: MuesliTheme.spacing12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName?.isEmpty == false ? member.displayName! : member.email)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(member.email)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(member.role.capitalized)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: 90, alignment: .leading)

                    Text(joinStatus(for: member))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(joinStatusColor(for: member))
                        .frame(width: 92, alignment: .leading)

                    Text(member.ghlUserID?.isEmpty == false ? member.ghlUserID! : "Not set")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(1)
                        .frame(width: 120, alignment: .leading)
                }
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing12)
                .background(selectedMemberID == member.id ? MuesliTheme.surfaceSelected : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().background(MuesliTheme.surfaceBorder)
        }
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Text(selectedMember == nil ? "Add Member" : "Edit Member")
                .font(MuesliTheme.title2())
                .foregroundStyle(MuesliTheme.textPrimary)

            VStack(spacing: MuesliTheme.spacing12) {
                HStack(spacing: MuesliTheme.spacing12) {
                    field("Name", text: $draft.displayName)
                    field("Email", text: $draft.email)
                    Picker("Role", selection: $draft.role) {
                        ForEach(MemberDraft.roles, id: \.self) { role in
                            Text(role.capitalized).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                HStack(spacing: MuesliTheme.spacing12) {
                    field("Calendar email", text: $draft.calendarEmail)
                    field("CRM user ID", text: $draft.crmUserID)
                    field("GHL user ID", text: $draft.ghlUserID)
                }

                Toggle("Active", isOn: $draft.isActive)
                    .toggleStyle(.switch)

                permissionTemplateRow
                permissionGrid

                HStack {
                    Spacer()
                    Button {
                        Task { await createInvite() }
                    } label: {
                        Label(isInviting ? "Creating invite" : "Send setup invite", systemImage: "envelope")
                            .font(MuesliTheme.body())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canManageMembers || isInviting || draft.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await saveMember() }
                    } label: {
                        Label(isSaving ? "Saving" : "Save member", systemImage: "checkmark")
                            .font(MuesliTheme.body())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canManageMembers || isSaving || draft.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                invitePreview
            }
        }
        .padding(MuesliTheme.spacing20)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .opacity(canManageMembers ? 1 : 0.55)
    }

    @ViewBuilder
    private var invitePreview: some View {
        if let latestInvite {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack {
                    Text(inviteDeliveryTitle(latestInvite))
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Spacer()
                    Button {
                        copyInviteLink(latestInvite)
                    } label: {
                        Label("Copy setup link", systemImage: "link")
                            .font(MuesliTheme.caption())
                    }
                    .buttonStyle(.plain)
                    Button {
                        copyInviteEmail(latestInvite)
                    } label: {
                        Label("Copy email", systemImage: "doc.on.doc")
                            .font(MuesliTheme.caption())
                    }
                    .buttonStyle(.plain)
                    Button {
                        openInviteEmail(latestInvite)
                    } label: {
                        Label("Open email", systemImage: "envelope.open")
                            .font(MuesliTheme.caption())
                    }
                    .buttonStyle(.plain)
                }
                Text(inviteDeliveryMessage(latestInvite))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(latestInvite.email.body)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(MuesliTheme.spacing12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .padding(.top, MuesliTheme.spacing8)
        }
    }

    private var permissionTemplateRow: some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing8) {
            Text("Permission template")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            Spacer()
            ForEach(MemberPermissionTemplate.allCases) { template in
                Button {
                    draft.applyTemplate(template)
                } label: {
                    Text(template.title)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.horizontal, MuesliTheme.spacing8)
                        .padding(.vertical, 5)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(template.help)
            }
        }
    }

    private var permissionGrid: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Permissions")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: MuesliTheme.spacing12)], alignment: .leading, spacing: MuesliTheme.spacing8) {
                Toggle("Record meetings", isOn: $draft.canRecordMeetings)
                Toggle("Sync transcripts", isOn: $draft.canSyncMeetings)
                Toggle("AI assist", isOn: $draft.canUseAIAssist)
                Toggle("Jessica commands", isOn: $draft.canUseSalesAgent)
                Toggle("Computer control", isOn: $draft.canUseComputerControl)
                Toggle("Private notes", isOn: $draft.canManagePrivateNotes)
            }
            .toggleStyle(.checkbox)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(MuesliTheme.body())
                .padding(.horizontal, MuesliTheme.spacing8)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 4)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(Capsule())
    }

    private func joinStatus(for member: SalesCaddieWorkspaceMember) -> String {
        if member.isActive && member.metadata?.invite?.status == "accepted" {
            return "Joined"
        }
        if member.metadata?.invite?.status == "pending" {
            if let expiresAt = member.metadata?.invite?.expiresAt,
               let expires = ISO8601DateFormatter().date(from: expiresAt),
               expires < Date() {
                return "Expired"
            }
            return "Invited"
        }
        return member.isActive ? "Active" : "Off"
    }

    private func joinStatusColor(for member: SalesCaddieWorkspaceMember) -> Color {
        switch joinStatus(for: member) {
        case "Joined", "Active":
            return MuesliTheme.accent
        case "Invited":
            return MuesliTheme.textSecondary
        case "Expired":
            return MuesliTheme.recording
        default:
            return MuesliTheme.textTertiary
        }
    }

    @MainActor
    private func load() async {
        guard appState.config.salesCaddieCloudSyncEnabled else {
            errorMessage = "Sales Caddie Cloud is not enabled in Settings -> Sales."
            return
        }
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        do {
            async let identityResponse = SalesCaddieCloudAPIClient.fetchIdentity(config: appState.config)
            let identity = try await identityResponse
            self.identity = identity
            controller.applySalesCaddieIdentity(identity)
            if identity.permissions.canManageMembers == true {
                let memberResponse = try await SalesCaddieCloudAPIClient.fetchWorkspaceMembers(config: appState.config)
                members = memberResponse.members
                if selectedMemberID == nil {
                    selectedMemberID = members.first?.id
                }
                loadSelectedMemberIntoDraft()
            } else {
                members = [identity.member]
                selectedMemberID = identity.member.id
                loadSelectedMemberIntoDraft()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func saveMember() async {
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        latestInvite = nil
        do {
            try await SalesCaddieCloudAPIClient.upsertWorkspaceMember(draft.upsertPayload(), config: appState.config)
            statusMessage = "Member saved."
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    @MainActor
    private func createInvite() async {
        isInviting = true
        errorMessage = nil
        statusMessage = nil
        latestInvite = nil
        do {
            let invite = try await SalesCaddieCloudAPIClient.createWorkspaceInvite(draft.upsertPayload(), config: appState.config)
            latestInvite = invite
            statusMessage = "Invite created for \(invite.email.to)."
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        isInviting = false
    }

    private func loadSelectedMemberIntoDraft() {
        if let selectedMember {
            draft = MemberDraft(member: selectedMember)
        }
    }

    private func copyInviteEmail(_ invite: SalesCaddieInviteResponse) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Subject: \(invite.email.subject)\n\n\(invite.email.body)", forType: .string)
        statusMessage = "Invite email copied."
    }

    private func copyInviteLink(_ invite: SalesCaddieInviteResponse) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(invite.inviteURL, forType: .string)
        statusMessage = "Setup link copied."
    }

    private func openInviteEmail(_ invite: SalesCaddieInviteResponse) {
        guard let url = URL(string: invite.email.mailtoURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func inviteDeliveryTitle(_ invite: SalesCaddieInviteResponse) -> String {
        invite.emailDelivery?.sent == true ? "Invite sent" : "Invite ready"
    }

    private func inviteDeliveryMessage(_ invite: SalesCaddieInviteResponse) -> String {
        if invite.emailDelivery?.sent == true {
            return "Sales Caddie sent the invite email to \(invite.email.to)."
        }
        if let reason = invite.emailDelivery?.reason, !reason.isEmpty {
            return "\(reason) Copy the setup link or open the email draft."
        }
        return "Copy the setup link or open the email draft."
    }
}

private enum MemberPermissionTemplate: String, CaseIterable, Identifiable {
    case rep
    case manager
    case admin
    case lockedDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rep: return "Rep"
        case .manager: return "Manager"
        case .admin: return "Admin"
        case .lockedDown: return "Limited"
        }
    }

    var help: String {
        switch self {
        case .rep: return "Normal seller permissions."
        case .manager: return "Seller permissions plus meeting recording."
        case .admin: return "Workspace admin role with full sales permissions."
        case .lockedDown: return "Minimal access for testing or restricted users."
        }
    }
}

private struct MemberDraft {
    static let roles = ["owner", "admin", "manager", "rep", "viewer"]

    var email = ""
    var displayName = ""
    var role = "rep"
    var isActive = true
    var crmUserID = ""
    var ghlUserID = ""
    var calendarEmail = ""
    var canRecordMeetings = false
    var canSyncMeetings = true
    var canUseAIAssist = true
    var canUseSalesAgent = true
    var canUseComputerControl = false
    var canManagePrivateNotes = true

    init() {}

    init(member: SalesCaddieWorkspaceMember) {
        email = member.email
        displayName = member.displayName ?? ""
        role = Self.roles.contains(member.role) ? member.role : "rep"
        isActive = member.isActive
        crmUserID = member.crmUserID ?? ""
        ghlUserID = member.ghlUserID ?? ""
        calendarEmail = member.calendarEmail ?? member.email
        canRecordMeetings = member.permissions?.canRecordMeetings ?? false
        canSyncMeetings = member.permissions?.canSyncMeetings ?? true
        canUseAIAssist = member.permissions?.canUseAIAssist ?? true
        canUseSalesAgent = member.permissions?.canUseSalesAgent ?? true
        canUseComputerControl = member.permissions?.canUseComputerControl ?? false
        canManagePrivateNotes = member.permissions?.canManagePrivateNotes ?? true
    }

    mutating func applyTemplate(_ template: MemberPermissionTemplate) {
        switch template {
        case .rep:
            role = "rep"
            canRecordMeetings = false
            canSyncMeetings = true
            canUseAIAssist = true
            canUseSalesAgent = true
            canUseComputerControl = false
            canManagePrivateNotes = true
        case .manager:
            role = "manager"
            canRecordMeetings = true
            canSyncMeetings = true
            canUseAIAssist = true
            canUseSalesAgent = true
            canUseComputerControl = false
            canManagePrivateNotes = true
        case .admin:
            role = "admin"
            canRecordMeetings = true
            canSyncMeetings = true
            canUseAIAssist = true
            canUseSalesAgent = true
            canUseComputerControl = true
            canManagePrivateNotes = true
        case .lockedDown:
            role = "viewer"
            canRecordMeetings = false
            canSyncMeetings = false
            canUseAIAssist = false
            canUseSalesAgent = false
            canUseComputerControl = false
            canManagePrivateNotes = false
        }
    }

    func upsertPayload() -> SalesCaddieMemberUpsert {
        SalesCaddieMemberUpsert(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role,
            isActive: isActive,
            crmUserID: crmUserID.trimmingCharacters(in: .whitespacesAndNewlines),
            ghlUserID: ghlUserID.trimmingCharacters(in: .whitespacesAndNewlines),
            calendarEmail: calendarEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            permissions: SalesCaddiePermissions(
                canAdminWorkspace: nil,
                canManageMembers: nil,
                canManageLibrary: nil,
                canViewTeamCalls: nil,
                canUseSalesAgent: canUseSalesAgent,
                canSyncMeetings: canSyncMeetings,
                canRecordMeetings: canRecordMeetings,
                canUseAIAssist: canUseAIAssist,
                canUseComputerControl: canUseComputerControl,
                canManagePrivateNotes: canManagePrivateNotes
            )
        )
    }
}

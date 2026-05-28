import AVFoundation
import SwiftUI
import MuesliCore
import UniformTypeIdentifiers

private struct MeetingDetectionAppOption: Identifiable {
    let bundleID: String
    let name: String
    let icon: String

    var id: String { bundleID }
}

struct SettingsView: View {
    private enum PendingDataDestruction {
        case dictations
        case meetings

        var title: String {
            switch self {
            case .dictations:
                return "Clear dictation history?"
            case .meetings:
                return "Clear meeting history?"
            }
        }

        var message: String {
            switch self {
            case .dictations:
                return "This will permanently remove all saved dictations. This cannot be undone."
            case .meetings:
                return "This will permanently remove all saved meetings, notes, transcripts, and retained audio recordings. This cannot be undone."
            }
        }

        var confirmLabel: String {
            switch self {
            case .dictations:
                return "Clear Dictations"
            case .meetings:
                return "Clear Meetings"
            }
        }
    }

    enum SettingsPane: String, CaseIterable, Identifiable {
        case general
        case dictation
        case computerUse
        case meetings
        case sales
        case tools
        case appearance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .dictation: return "Dictation"
            case .computerUse: return "Computer Use"
            case .meetings: return "Meetings"
            case .sales: return "Sales"
            case .tools: return "Tools"
            case .appearance: return "Appearance"
            }
        }
    }

    let appState: AppState
    let controller: MuesliController

    @State private var chatGPTSignInError: String?
    @State private var isSigningInChatGPT = false
    @State private var googleCalSignInError: String?
    @State private var isSigningInGoogleCal = false
    @State private var googleDriveDocsAuthError: String?
    @State private var isAuthorizingGoogleDriveDocs = false
    @State private var pendingDataDestruction: PendingDataDestruction?
    @State private var isPreviewingClip = false
    @State private var selectedPane: SettingsPane = .general
    @State private var downloadedBackendOptions: [BackendOption] = []
    @State private var downloadedPostProcOptions: [PostProcessorOption] = []
    @State private var permissionPollTimer: Timer?
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var screenRecordingGranted = false
    @AppStorage("settings.pendingScreenContextEnable") private var pendingScreenContextEnable = false
    @AppStorage("settings.pendingScreenContextRequestedAt") private var pendingScreenContextRequestedAt = 0.0
    @State private var systemAudioGranted = false
    @State private var isCheckingSystemAudioPermission = false
    @State private var openRouterFreeModels: [SummaryModelPreset] = []
    @State private var isLoadingOpenRouterFreeModels = false
    @State private var openRouterFreeModelsError: String?
    @State private var salesImportMessage: String?
    @State private var salesImportError: String?
    @State private var isExtractingSalesObjections = false
    @State private var showSalesObjectionExtractionSheet = false
    @State private var salesObjectionExtractionText = ""
    @State private var selectedSalesObjectionID: String?
    @State private var salesObjectionSearchQuery = ""
    @State private var selectedSalesLiveCueID: String?
    @State private var salesLiveCueSearchQuery = ""
    @State private var isAnalyzingSalesCall = false
    @State private var inviteSetupCode = ""
    @State private var inviteAPIURL = ""
    @State private var isRedeemingInvite = false
    @State private var inviteRedeemMessage: String?
    @State private var inviteRedeemError: String?

    // Uniform width for all right-side controls
    private let controlWidth: CGFloat = 220
    private let meetingControlWidth: CGFloat = 275
    private let screenContextGrantIntentTimeout: TimeInterval = 15 * 60
    private var effectiveInviteAPIURL: String {
        let typed = inviteAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let configured = appState.config.salesCaddieCloudAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        return "https://sales-caddie-api-production.up.railway.app"
    }
    private let meetingDetectionAppOptions: [MeetingDetectionAppOption] = [
        MeetingDetectionAppOption(bundleID: "com.google.Chrome", name: "Chrome", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "company.thebrowser.Browser", name: "Arc", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.apple.Safari", name: "Safari", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.microsoft.edgemac", name: "Edge", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.brave.Browser", name: "Brave", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", icon: "message.fill"),
        MeetingDetectionAppOption(bundleID: "us.zoom.xos", name: "Zoom", icon: "video.fill"),
        MeetingDetectionAppOption(bundleID: "com.microsoft.teams2", name: "Teams", icon: "person.2.fill"),
        MeetingDetectionAppOption(bundleID: "com.apple.FaceTime", name: "FaceTime", icon: "video.fill"),
        MeetingDetectionAppOption(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", icon: "phone.fill"),
    ]

    init(appState: AppState, controller: MuesliController, initialPane: SettingsPane = .general) {
        self.appState = appState
        self.controller = controller
        _selectedPane = State(initialValue: initialPane)
    }

    private var dictationBackendOptions: [BackendOption] {
        backendOptions(including: appState.selectedBackend)
    }

    private var meetingBackendOptions: [BackendOption] {
        downloadedBackendOptions
    }

    private var selectedMeetingBackendLabel: String {
        if meetingBackendOptions.contains(appState.selectedMeetingTranscriptionBackend) {
            return appState.selectedMeetingTranscriptionBackend.label
        }
        return meetingBackendOptions.first?.label ?? "No downloaded models"
    }

    private var selectedSalesAgentBackend: SalesAgentBackendOption {
        SalesAgentBackendOption.resolved(appState.config.salesAgentBackend)
    }

    private var selectedSalesAgentUser: SalesAgentUserOption? {
        SalesAgentUserOption.resolved(
            userID: appState.config.salesAgentUserID,
            repKey: appState.config.salesAgentRepKey
        )
    }

    private var selectedCohereLanguage: CohereTranscribeLanguage {
        appState.config.resolvedCohereLanguage
    }

    private var filteredSalesObjections: [SalesAssistObjection] {
        let query = salesObjectionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return appState.config.salesAssistObjections }
        return appState.config.salesAssistObjections.filter { objection in
            objection.name.lowercased().contains(query)
                || objection.priority.lowercased().contains(query)
                || objection.triggerPhrases.lowercased().contains(query)
                || objection.guidance.lowercased().contains(query)
        }
    }

    private var selectedSalesObjection: SalesAssistObjection? {
        if let selectedSalesObjectionID,
           let objection = appState.config.salesAssistObjections.first(where: { $0.id == selectedSalesObjectionID }) {
            return objection
        }
        return filteredSalesObjections.first ?? appState.config.salesAssistObjections.first
    }

    private var filteredSalesLiveCues: [SalesAssistLiveCue] {
        let query = salesLiveCueSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return appState.config.salesAssistLiveCues }
        return appState.config.salesAssistLiveCues.filter { cue in
            cue.name.lowercased().contains(query)
                || cue.kind.lowercased().contains(query)
                || cue.priority.lowercased().contains(query)
                || cue.triggerPhrases.lowercased().contains(query)
                || cue.guidance.lowercased().contains(query)
        }
    }

    private var selectedSalesLiveCue: SalesAssistLiveCue? {
        if let selectedSalesLiveCueID,
           let cue = appState.config.salesAssistLiveCues.first(where: { $0.id == selectedSalesLiveCueID }) {
            return cue
        }
        return filteredSalesLiveCues.first ?? appState.config.salesAssistLiveCues.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Settings")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                settingsPanePicker
                paneContent
            }
            .padding(MuesliTheme.spacing32)
        }
        .background(MuesliTheme.backgroundBase)
        .onAppear {
            applyPreferredSettingsPane()
            refreshDownloadedModelOptions()
            startPermissionPolling()
            if appState.selectedMeetingSummaryBackend == .openRouter {
                loadOpenRouterFreeModelsIfNeeded()
            }
        }
        .onDisappear {
            SoundController.stopMaraudersMapClip()
            isPreviewingClip = false
            stopPermissionPolling()
        }
        .onChange(of: appState.selectedTab) { _, tab in
            if tab == .settings {
                applyPreferredSettingsPane()
                refreshDownloadedModelOptions()
                refreshPermissionStatuses()
            }
        }
        .onChange(of: appState.selectedBackend) { _, _ in
            refreshDownloadedModelOptions()
        }
        .onChange(of: appState.selectedMeetingTranscriptionBackend) { _, _ in
            refreshDownloadedModelOptions()
        }
        .onChange(of: appState.selectedMeetingSummaryBackend) { _, backend in
            if backend == .openRouter {
                loadOpenRouterFreeModelsIfNeeded()
            }
        }
        .alert(
            pendingDataDestruction?.title ?? "Confirm Destructive Action",
            isPresented: Binding(
                get: { pendingDataDestruction != nil },
                set: { if !$0 { pendingDataDestruction = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingDataDestruction = nil
            }
            Button(pendingDataDestruction?.confirmLabel ?? "Delete", role: .destructive) {
                switch pendingDataDestruction {
                case .dictations:
                    controller.clearDictationHistory()
                case .meetings:
                    controller.clearMeetingHistory()
                case nil:
                    break
                }
                pendingDataDestruction = nil
            }
        } message: {
            Text(pendingDataDestruction?.message ?? "")
        }
        .sheet(isPresented: $showSalesObjectionExtractionSheet) {
            salesObjectionExtractionSheet
        }
    }

    private func refreshDownloadedModelOptions() {
        controller.refreshMeetingTranscriptionSelectionForAvailability()
        downloadedBackendOptions = BackendOption.downloaded
        downloadedPostProcOptions = PostProcessorOption.downloaded
    }

    private func backendOptions(including selection: BackendOption) -> [BackendOption] {
        var options = downloadedBackendOptions
        if !options.contains(where: { $0 == selection }) {
            options.insert(selection, at: 0)
        }
        return options
    }

    private static let accentPresets: [(hex: String, name: String)] = [
        ("2563eb", "Blue"),
        ("ef4444", "Red"),
        ("f59e0b", "Amber"),
        ("10b981", "Green"),
        ("8b5cf6", "Purple"),
        ("ec4899", "Pink"),
        ("1e1e2e", "Dark"),
    ]

    private var screenContextDescription: String {
        if screenRecordingGranted {
            return "Adds nearby app text and meeting OCR context. Processed on-device."
        }
        return "Requires Screen Recording. Adds nearby app text and meeting OCR context."
    }

    @ViewBuilder
    private func screenContextRow(_ title: String, controlWidth rowControlWidth: CGFloat? = nil) -> some View {
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(screenContextDescription)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 20)

            ZStack(alignment: .trailing) {
                Color.clear.frame(width: width, height: 1)
                screenContextControl(width: width)
            }
        }
        .frame(minHeight: 52)
    }

    private let customIndicatorPositionLabel = "Custom (drag to reposition)"

    private var settingsPanePicker: some View {
        HStack {
            Spacer()
            Picker("", selection: $selectedPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 680)
            Spacer()
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalSettingsPane
        case .dictation:
            dictationSettingsPane
        case .computerUse:
            computerUseSettingsPane
        case .meetings:
            meetingsSettingsPane
        case .sales:
            salesSettingsPane
        case .tools:
            toolsSettingsPane
        case .appearance:
            appearanceSettingsPane
        }
    }

    private var toolsSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("App Tools") {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    settingsToolRow(
                        title: "Models",
                        subtitle: "Download and manage transcription models and post-processing models.",
                        icon: "square.and.arrow.down"
                    ) {
                        appState.selectedTab = .models
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsToolRow(
                        title: "Shortcuts",
                        subtitle: "Set hotkeys for dictation, Jessica, computer use, and meeting recording.",
                        icon: "keyboard"
                    ) {
                        appState.selectedTab = .shortcuts
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsToolRow(
                        title: "Dictionary",
                        subtitle: "Add custom words, names, brands, and domain terms for transcription cleanup.",
                        icon: "character.book.closed"
                    ) {
                        appState.selectedTab = .dictionary
                    }
                }
            }
        }
    }

    private var generalSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("General") {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    settingsRow("Launch at login") {
                        settingsSwitch(isOn: appState.config.launchAtLogin) { newValue in
                            controller.setLaunchAtLogin(newValue)
                        }
                    }
                    if appState.launchAtLoginRegistrationState == .requiresApproval {
                        launchAtLoginApprovalPrompt
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Open dashboard on launch") {
                    settingsSwitch(isOn: appState.config.openDashboardOnLaunch) { newValue in
                        controller.updateConfig { $0.openDashboardOnLaunch = newValue }
                    }
                }
            }

            permissionsSection

            settingsSection("Data") {
                HStack(spacing: MuesliTheme.spacing12) {
                    actionButton("Clear dictation history", role: .destructive) {
                        pendingDataDestruction = .dictations
                    }
                    actionButton("Clear meeting history", role: .destructive) {
                        pendingDataDestruction = .meetings
                    }
                    .disabled(controller.isMeetingRecording())
                    .help("Stop the current meeting recording before clearing meeting history.")
                }
            }
        }
    }

    private var salesSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Sales Caddie Cloud") {
                settingsRow(
                    "Use hosted API",
                    description: "Routes sync through the Sales Caddie Cloud API instead of writing directly to Supabase."
                ) {
                    settingsSwitch(isOn: appState.config.salesCaddieCloudSyncEnabled) { newValue in
                        controller.updateConfig { $0.salesCaddieCloudSyncEnabled = newValue }
                    }
                }

                if appState.config.salesCaddieCloudSyncEnabled {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("API URL", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.salesCaddieCloudAPIURL,
                            placeholder: "https://sales-caddie-api.example.com",
                            onChange: { value in controller.updateConfig { $0.salesCaddieCloudAPIURL = value } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("API token", controlWidth: meetingControlWidth) {
                        PastableSecureField(
                            text: appState.config.salesCaddieCloudAPIToken,
                            placeholder: "Sales Caddie Cloud token",
                            onChange: { value in controller.updateConfig { $0.salesCaddieCloudAPIToken = value } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Workspace slug", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.salesCaddieCloudWorkspaceSlug,
                            placeholder: "skriber-sales",
                            onChange: { value in controller.updateConfig { $0.salesCaddieCloudWorkspaceSlug = value } }
                        )
                        .frame(height: 22)
                    }
                    settingsDescription("Cloud sync uses the same Jessica history, transcript, and Sales library toggles below, but keeps Supabase credentials server-side.")
                }
            }

            HStack(spacing: MuesliTheme.spacing12) {
                actionButton("Sync all now") {
                    controller.syncAllCloudArtifactsNow()
                }
                .disabled(
                    !appState.config.salesCaddieCloudSyncEnabled
                        && !appState.config.supabaseSyncEnabled
                )
                Text("Pushes recent meetings, Jessica history, and Sales Assist library changes, then refreshes cloud identity when hosted API is enabled.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            settingsSection("Join Workspace") {
                settingsRow(
                    "Setup code",
                    description: "Paste the setup code from your Sales Caddie invite email."
                ) {
                    PastableTextField(
                        text: inviteSetupCode,
                        placeholder: "Invite setup code",
                        onChange: { value in inviteSetupCode = value }
                    )
                    .frame(height: 22)
                    .frame(width: meetingControlWidth)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Cloud API URL", controlWidth: meetingControlWidth) {
                    PastableTextField(
                        text: effectiveInviteAPIURL,
                        placeholder: "https://sales-caddie-api-production.up.railway.app",
                        onChange: { value in inviteAPIURL = value }
                    )
                    .frame(height: 22)
                }
                HStack(spacing: MuesliTheme.spacing12) {
                    actionButton(isRedeemingInvite ? "Joining..." : "Join workspace") {
                        redeemInviteCode()
                    }
                    .disabled(isRedeemingInvite || inviteSetupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let inviteRedeemMessage {
                        Text(inviteRedeemMessage)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.accent)
                    }
                    if let inviteRedeemError {
                        Text(inviteRedeemError)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.recording)
                    }
                }
                settingsDescription("Joining stores the workspace, user email, and cloud connection settings on this Mac.")
            }

            settingsSection("Supabase Sync") {
                settingsRow(
                    "Enable sync",
                    description: "Keeps Sales Caddie local-first, then syncs selected final artifacts online."
                ) {
                    settingsSwitch(isOn: appState.config.supabaseSyncEnabled) { newValue in
                        controller.updateConfig { $0.supabaseSyncEnabled = newValue }
                    }
                }

                if appState.config.supabaseSyncEnabled {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Supabase URL", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.supabaseURL,
                            placeholder: "https://project.supabase.co",
                            onChange: { val in controller.updateConfig { $0.supabaseURL = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Anon key", controlWidth: meetingControlWidth) {
                        PastableSecureField(
                            text: appState.config.supabaseAnonKey,
                            placeholder: "Supabase anon key",
                            onChange: { val in controller.updateConfig { $0.supabaseAnonKey = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Workspace", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.supabaseWorkspaceID,
                            placeholder: "skriber-sales",
                            onChange: { val in controller.updateConfig { $0.supabaseWorkspaceID = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("User", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.supabaseUserID,
                            placeholder: "Optional user or rep ID",
                            onChange: { val in controller.updateConfig { $0.supabaseUserID = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Jessica history", controlWidth: meetingControlWidth) {
                        settingsSwitch(isOn: appState.config.supabaseSyncJessicaHistory) { newValue in
                            controller.updateConfig { $0.supabaseSyncJessicaHistory = newValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Transcripts", controlWidth: meetingControlWidth) {
                        HStack(spacing: MuesliTheme.spacing8) {
                            settingsSwitch(isOn: appState.config.supabaseSyncTranscripts) { newValue in
                                controller.updateConfig { $0.supabaseSyncTranscripts = newValue }
                            }
                            actionButton("Sync now") {
                                controller.syncMeetingsNow()
                            }
                            .disabled(!appState.config.supabaseSyncTranscripts)
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Sales library", controlWidth: meetingControlWidth) {
                        HStack(spacing: MuesliTheme.spacing8) {
                            settingsSwitch(isOn: appState.config.supabaseSyncSalesLibrary) { newValue in
                                controller.updateConfig { $0.supabaseSyncSalesLibrary = newValue }
                            }
                            actionButton("Sync now") {
                                controller.syncSalesLibraryNow()
                            }
                            .disabled(!appState.config.supabaseSyncSalesLibrary)
                        }
                    }
                    settingsDescription("Jessica history syncs as events are created. Transcripts sync completed meeting records and summaries. Sales library sync pulls the shared KB, objections, and live cue cards from Supabase, and seeds Supabase from this app if the shared library is empty.")
                }
            }

            settingsSection("Sales Assist") {
                settingsRow(
                    "Enable overlay",
                    description: "Shows selected live coaching prompts during meeting recordings."
                ) {
                    settingsSwitch(isOn: appState.config.salesAssistEnabled) { newValue in
                        controller.updateConfig { $0.salesAssistEnabled = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "AI classifier",
                    description: "Uses the sales knowledge base and live cue library for fuzzy moment detection."
                ) {
                    settingsSwitch(isOn: appState.config.salesAssistAIEnabled) { newValue in
                        controller.updateConfig { $0.salesAssistAIEnabled = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                salesOverlayControls
            }
        }
    }

    private var launchAtLoginApprovalPrompt: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.recording)
            Text("Requires approval in System Settings")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            Spacer(minLength: MuesliTheme.spacing12)
            Button {
                controller.openLaunchAtLoginSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .help("Open Login Items in System Settings")
        }
        .padding(.leading, MuesliTheme.spacing16)
        .padding(.trailing, MuesliTheme.spacing16)
        .padding(.bottom, MuesliTheme.spacing8)
    }

    private var dictationSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Transcription") {
                settingsRow("Dictation model") {
                    settingsMenu(
                        selection: appState.selectedBackend.label,
                        options: dictationBackendOptions.map(\.label)
                    ) { label in
                        if let option = dictationBackendOptions.first(where: { $0.label == label }) {
                            controller.selectBackend(option)
                        }
                    }
                }
                if appState.selectedBackend.backend == BackendOption.cohereTranscribe.backend {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Cohere language") {
                        settingsMenu(
                            selection: selectedCohereLanguage.label,
                            options: CohereTranscribeLanguage.allCases.map(\.label)
                        ) { label in
                            guard let language = CohereTranscribeLanguage.allCases.first(where: { $0.label == label }) else { return }
                            controller.selectCohereLanguage(language)
                        }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("AI transcript cleanup") {
                    settingsSwitch(isOn: appState.config.enablePostProcessor) { newValue in
                        controller.setPostProcessorEnabled(newValue)
                    }
                }
                if appState.config.enablePostProcessor && !downloadedPostProcOptions.isEmpty {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Cleanup model") {
                        let selection = downloadedPostProcOptions.contains(where: { $0.id == appState.activePostProcessor.id })
                            ? appState.activePostProcessor.label
                            : (downloadedPostProcOptions.first?.label ?? "")
                        settingsMenu(
                            selection: selection,
                            options: downloadedPostProcOptions.map(\.label)
                        ) { label in
                            if let option = downloadedPostProcOptions.first(where: { $0.label == label }) {
                                controller.selectPostProcessor(option)
                            }
                        }
                    }
                } else if appState.config.enablePostProcessor {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Cleanup model") {
                        Text("Download a cleanup model in Models")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .multilineTextAlignment(.trailing)
                            .frame(width: controlWidth, alignment: .trailing)
                    }
                }
            }

            settingsSection("Advanced") {
                settingsRow("Pause media during dictation") {
                    settingsSwitch(isOn: appState.config.pauseMediaDuringDictation) { newValue in
                        controller.updateConfig { $0.pauseMediaDuringDictation = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Mute system audio during dictation") {
                    settingsSwitch(isOn: appState.config.muteSystemAudioDuringDictation) { newValue in
                        controller.updateConfig { $0.muteSystemAudioDuringDictation = newValue }
                    }
                }
                screenContextRow("App context")
            }
        }
    }

    private var computerUseSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Sales Agent") {
                settingsRow("Provider", controlWidth: meetingControlWidth) {
                    settingsMenu(
                        selection: selectedSalesAgentBackend.label,
                        options: SalesAgentBackendOption.all.map(\.label)
                    ) { label in
                        if let option = SalesAgentBackendOption.all.first(where: { $0.label == label }) {
                            controller.updateConfig { $0.salesAgentBackend = option.backend }
                        }
                    }
                }

                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Speaker", controlWidth: meetingControlWidth) {
                    settingsMenu(
                        selection: selectedSalesAgentUser?.label ?? "Not set",
                        options: ["Not set"] + SalesAgentUserOption.all.map(\.label)
                    ) { label in
                        if label == "Not set" {
                            controller.updateConfig {
                                $0.salesAgentUserID = ""
                                $0.salesAgentUserName = ""
                                $0.salesAgentUserRole = ""
                                $0.salesAgentRepKey = ""
                            }
                        } else if let option = SalesAgentUserOption.all.first(where: { $0.label == label }) {
                            controller.updateConfig {
                                $0.salesAgentUserID = option.id
                                $0.salesAgentUserName = option.name
                                $0.salesAgentUserRole = option.role
                                $0.salesAgentRepKey = option.repKey
                            }
                        }
                    }
                }

                if selectedSalesAgentBackend.backend == SalesAgentBackendOption.hostedJessica.backend
                    || selectedSalesAgentBackend.backend == SalesAgentBackendOption.customWebhook.backend {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Agent URL", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.salesAgentEndpointURL,
                            placeholder: selectedSalesAgentBackend.backend == SalesAgentBackendOption.hostedJessica.backend
                                ? "Railway Jessica URL optional"
                                : "https://your-agent.example.com/command",
                            onChange: { val in controller.updateConfig { $0.salesAgentEndpointURL = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Token", controlWidth: meetingControlWidth) {
                        PastableSecureField(
                            text: appState.config.salesAgentAuthToken,
                            placeholder: "Bearer token",
                            onChange: { val in controller.updateConfig { $0.salesAgentAuthToken = val } }
                        )
                        .frame(height: 22)
                    }
                } else if selectedSalesAgentBackend.backend == SalesAgentBackendOption.openAI.backend
                    || selectedSalesAgentBackend.backend == SalesAgentBackendOption.openRouter.backend
                    || selectedSalesAgentBackend.backend == SalesAgentBackendOption.ollama.backend {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Model", controlWidth: meetingControlWidth) {
                        settingsModelTextField(
                            currentModel: appState.config.salesAgentModel,
                            placeholder: selectedSalesAgentBackend.backend == SalesAgentBackendOption.ollama.backend
                                ? appState.config.ollamaModel
                                : "Default"
                        ) { val in controller.updateConfig { $0.salesAgentModel = val } }
                    }
                    if selectedSalesAgentBackend.backend == SalesAgentBackendOption.openAI.backend {
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("OpenAI key", controlWidth: meetingControlWidth) {
                            PastableSecureField(
                                text: appState.config.openAIAPIKey,
                                placeholder: "sk-...",
                                onChange: { val in controller.updateConfig { $0.openAIAPIKey = val } }
                            )
                            .frame(height: 22)
                        }
                    } else if selectedSalesAgentBackend.backend == SalesAgentBackendOption.openRouter.backend {
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("OpenRouter key", controlWidth: meetingControlWidth) {
                            PastableSecureField(
                                text: appState.config.openRouterAPIKey,
                                placeholder: "sk-or-...",
                                onChange: { val in controller.updateConfig { $0.openRouterAPIKey = val } }
                            )
                            .frame(height: 22)
                        }
                    } else {
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Ollama URL", controlWidth: meetingControlWidth) {
                            PastableTextField(
                                text: appState.config.ollamaURL,
                                placeholder: "http://localhost:11434",
                                onChange: { val in controller.updateConfig { $0.ollamaURL = val } }
                            )
                            .frame(height: 22)
                        }
                    }
                }

                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Send sales KB", controlWidth: meetingControlWidth) {
                    settingsSwitch(isOn: appState.config.salesAgentSendKnowledgeBase) { newValue in
                        controller.updateConfig { $0.salesAgentSendKnowledgeBase = newValue }
                    }
                }
            }

            settingsSection("Computer Use") {
                settingsRow("Enable planner", controlWidth: meetingControlWidth) {
                    settingsSwitch(isOn: appState.config.enableComputerUsePlanner) { newValue in
                        controller.updateConfig { $0.enableComputerUsePlanner = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Account", controlWidth: meetingControlWidth) {
                    chatGPTAccountControl
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Planner model", controlWidth: meetingControlWidth) {
                    settingsModelMenu(
                        currentModel: appState.config.computerUsePlannerModel,
                        presets: SummaryModelPreset.computerUsePlannerModels
                    ) { val in controller.updateConfig { $0.computerUsePlannerModel = val } }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Timeout", controlWidth: meetingControlWidth) {
                    Stepper(
                        value: Binding(
                            get: { max(appState.config.computerUseTimeoutSeconds, 1) },
                            set: { newValue in
                                controller.updateConfig { $0.computerUseTimeoutSeconds = max(newValue, 1) }
                            }
                        ),
                        in: 1...600,
                        step: 15
                    ) {
                        Text("\(max(appState.config.computerUseTimeoutSeconds, 1)) seconds")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }
                }
            }
        }
    }

    private var meetingsSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Meeting Transcription") {
                settingsRow("Meeting model") {
                    if meetingBackendOptions.isEmpty {
                        Text("No downloaded models")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(width: meetingControlWidth, alignment: .leading)
                    } else {
                        settingsMenu(
                            selection: selectedMeetingBackendLabel,
                            options: meetingBackendOptions.map(\.label)
                        ) { label in
                            if let option = meetingBackendOptions.first(where: { $0.label == label }) {
                                controller.selectMeetingTranscriptionBackend(option)
                            }
                        }
                        .frame(width: meetingControlWidth)
                    }
                }
                if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.cohereTranscribe.backend {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Cohere language") {
                        settingsMenu(
                            selection: selectedCohereLanguage.label,
                            options: CohereTranscribeLanguage.allCases.map(\.label)
                        ) { label in
                            guard let language = CohereTranscribeLanguage.allCases.first(where: { $0.label == label }) else { return }
                            controller.selectCohereLanguage(language)
                        }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                screenContextRow("Meeting context")
            }

            settingsSection("Meeting Summaries") {
                settingsRow("Summary backend", controlWidth: meetingControlWidth) {
                    settingsMenu(
                        selection: appState.selectedMeetingSummaryBackend.label,
                        options: MeetingSummaryBackendOption.all.map(\.label)
                    ) { label in
                        if let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) {
                            controller.selectMeetingSummaryBackend(option)
                        }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)

                if appState.selectedMeetingSummaryBackend == .chatGPT {
                    settingsRow("Account", controlWidth: meetingControlWidth) {
                        chatGPTAccountControl
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Model", controlWidth: meetingControlWidth) {
                        settingsModelMenu(
                            currentModel: appState.config.chatGPTModel,
                            presets: SummaryModelPreset.chatGPTModels
                        ) { val in controller.updateConfig { $0.chatGPTModel = val } }
                    }
                } else if appState.selectedMeetingSummaryBackend == .openAI {
                    settingsRow("API Key", controlWidth: meetingControlWidth) {
                        PastableSecureField(
                            text: appState.config.openAIAPIKey,
                            placeholder: "sk-...",
                            onChange: { val in controller.updateConfig { $0.openAIAPIKey = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Model", controlWidth: meetingControlWidth) {
                        settingsModelMenu(
                            currentModel: appState.config.openAIModel,
                            presets: SummaryModelPreset.openAIModels
                        ) { val in controller.updateConfig { $0.openAIModel = val } }
                    }
                    keyStatusRow(key: appState.config.openAIAPIKey)
                } else if appState.selectedMeetingSummaryBackend == .ollama {
                    settingsRow("Ollama URL", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.ollamaURL,
                            placeholder: "http://localhost:11434",
                            onChange: { val in controller.updateConfig { $0.ollamaURL = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Model", controlWidth: meetingControlWidth) {
                        settingsModelTextField(
                            currentModel: appState.config.ollamaModel,
                            placeholder: "qwen3.5"
                        ) { val in controller.updateConfig { $0.ollamaModel = val } }
                    }
                } else {
                    settingsRow("API Key", controlWidth: meetingControlWidth) {
                        PastableSecureField(
                            text: appState.config.openRouterAPIKey,
                            placeholder: "sk-or-...",
                            onChange: { val in controller.updateConfig { $0.openRouterAPIKey = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Free model", controlWidth: meetingControlWidth) {
                        openRouterFreeModelMenu
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Custom model ID", controlWidth: meetingControlWidth) {
                        settingsModelTextField(
                            currentModel: appState.config.openRouterModel,
                            placeholder: "provider/model or openrouter/free"
                        ) { val in controller.updateConfig { $0.openRouterModel = val } }
                    }
                    keyStatusRow(key: appState.config.openRouterAPIKey)
                }

                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Default template", controlWidth: meetingControlWidth) {
                    meetingTemplateMenu(selectionID: appState.config.defaultMeetingTemplateID) { id in
                        controller.updateDefaultMeetingTemplate(id: id)
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Templates", controlWidth: meetingControlWidth) {
                    actionButton("Manage Templates…") {
                        controller.showMeetingTemplatesManager()
                    }
                }
            }

            settingsSection("Recording") {
                settingsRow("Auto-record calendar meetings") {
                    settingsSwitch(isOn: appState.config.autoRecordMeetings) { newValue in
                        controller.updateConfig { $0.autoRecordMeetings = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Save meeting recording") {
                    settingsMenu(
                        selection: recordingSaveLabel(for: appState.config.meetingRecordingSavePolicy),
                        options: MeetingRecordingSavePolicy.allCases.map(recordingSaveLabel(for:))
                    ) { label in
                        guard let policy = recordingSavePolicy(for: label) else { return }
                        controller.updateConfig { $0.meetingRecordingSavePolicy = policy }
                    }
                }
            }

            settingsSection("Meeting Notifications") {
                settingsRow("Scheduled meetings") {
                    settingsSwitch(isOn: appState.config.showScheduledMeetingNotifications) { newValue in
                        controller.updateConfig { $0.showScheduledMeetingNotifications = newValue }
                    }
                }
                settingsDescription("Show notifications before meetings start based on your calendar.")

                Divider().background(MuesliTheme.surfaceBorder)

                settingsRow("Auto-detected meetings") {
                    settingsSwitch(isOn: appState.config.showMeetingDetectionNotification) { newValue in
                        controller.updateConfig { $0.showMeetingDetectionNotification = newValue }
                    }
                }
                settingsDescription("Show notifications when a call is detected from browser, camera, microphone, or app audio activity.")

                if appState.config.showMeetingDetectionNotification {
                    Divider().background(MuesliTheme.surfaceBorder)
                    mutedMeetingDetectionAppsControl
                }
            }

            settingsSection("Calendars") {
                calendarSourcesControl
            }

            if appState.isGoogleCalendarAvailable {
                settingsSection("Google Workspace") {
                    settingsRow("Google Calendar") {
                        googleCalendarControl
                    }
                    if appState.isGoogleCalendarAuthenticated {
                        Divider().background(MuesliTheme.surfaceBorder)
                        settingsRow("Drive & Docs") {
                            googleDriveDocsControl
                        }
                        settingsDescription("Optional. Request only when Sales Caddie needs to create Google Docs notes or access Drive files you choose.")
                    }
                }
            }

            settingsSection("Advanced") {
                settingsRow("Enable post-meeting hook") {
                    settingsSwitch(isOn: appState.config.meetingHookEnabled) { newValue in
                        controller.updateConfig { $0.meetingHookEnabled = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Hook script") {
                    meetingHookPathPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Timeout") {
                    Stepper(
                        value: Binding(
                            get: { max(appState.config.meetingHookTimeoutSeconds, 1) },
                            set: { newValue in
                                controller.updateConfig { $0.meetingHookTimeoutSeconds = max(newValue, 1) }
                            }
                        ),
                        in: 1...600
                    ) {
                        Text("\(max(appState.config.meetingHookTimeoutSeconds, 1)) seconds")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }
                }
                Text("Advanced: runs a user-supplied executable after each completed meeting. The executable receives JSON on stdin and must already be runnable on its own.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.horizontal, MuesliTheme.spacing16)
            }
        }
        .onAppear {
            controller.refreshAvailableEventKitCalendars()
            Task { await controller.refreshGoogleCalendarList() }
        }
    }

    private var appearanceSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Floating Indicator") {
                settingsRow("Show floating indicator") {
                    settingsSwitch(isOn: appState.config.showFloatingIndicator) { newValue in
                        controller.updateConfig { $0.showFloatingIndicator = newValue }
                        controller.refreshIndicatorVisibility()
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Indicator position") {
                    let isCustom = appState.config.indicatorAnchor == .custom
                    let selection = isCustom ? customIndicatorPositionLabel : appState.config.indicatorAnchor.label
                    let options = (isCustom ? [customIndicatorPositionLabel] : [])
                        + IndicatorAnchor.allCases.filter { $0 != .custom }.map(\.label)
                    settingsMenu(
                        selection: selection,
                        options: options
                    ) { label in
                        if label == customIndicatorPositionLabel { return }
                        guard let anchor = IndicatorAnchor.allCases.first(where: { $0.label == label }) else { return }
                        controller.updateConfig { $0.indicatorAnchor = anchor }
                        controller.refreshIndicatorVisibility()
                    }
                }
            }

            settingsSection("Appearance") {
                settingsRow("Dark mode") {
                    settingsSwitch(isOn: appState.config.darkMode) { newValue in
                        controller.updateConfig { $0.darkMode = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Menu bar icon") {
                    menuBarIconPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Accent color") {
                    glassTintPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Play sound effects") {
                    settingsSwitch(isOn: appState.config.soundEnabled) { newValue in
                        controller.updateConfig { $0.soundEnabled = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Show next meeting in menu bar") {
                    settingsSwitch(isOn: appState.config.showNextMeetingInMenuBar) { newValue in
                        controller.updateConfig { $0.showNextMeetingInMenuBar = newValue }
                    }
                }
            }

            if appState.config.maraudersMapUnlocked {
                settingsSection("Marauder\u{2019}s Map") {
                    settingsRow("Meeting countdown audio") {
                        maraudersMapControl
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("") {
                        Button {
                            SoundController.stopMaraudersMapClip()
                            isPreviewingClip = false
                            controller.resetMaraudersMap()
                        } label: {
                            Text("Mischief Managed")
                                .font(.system(size: 11))
                                .foregroundColor(MuesliTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var glassTintPicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.accentPresets, id: \.hex) { preset in
                let isSelected = appState.config.recordingColorHex.lowercased() == preset.hex
                Button {
                    controller.updateConfig { $0.recordingColorHex = preset.hex }
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                        )
                        .overlay(
                            Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    private var menuBarIconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(MenuBarIconRenderer.options, id: \.id) { option in
                    let isSelected = appState.config.menuBarIcon == option.id
                    Button {
                        controller.updateConfig { $0.menuBarIcon = option.id }
                    } label: {
                        Group {
                            if option.id == "sales-caddie",
                               let img = MenuBarIconRenderer.make(choice: "sales-caddie") {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: option.id)
                                    .font(.system(size: 12))
                            }
                        }
                        .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? MuesliTheme.surfaceSelected : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.white.opacity(isSelected ? 0.3 : 0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                }
            }
        }
    }

    @ViewBuilder
    private var chatGPTAccountControl: some View {
        if appState.isChatGPTAuthenticated {
            Button {
                controller.signOutChatGPT()
            } label: {
                HStack(spacing: 5) {
                    OpenAILogoShape()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                    Text("Signed in · Sign Out")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(MuesliTheme.success)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        } else if isSigningInChatGPT {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing in...")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isSigningInChatGPT = true
                    chatGPTSignInError = nil
                    Task {
                        let error = await controller.signInWithChatGPT()
                        isSigningInChatGPT = false
                        chatGPTSignInError = error
                    }
                } label: {
                    HStack(spacing: 5) {
                        OpenAILogoShape()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                        Text("Sign in with ChatGPT")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                if let chatGPTSignInError {
                    Text(chatGPTSignInError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var googleCalendarControl: some View {
        if appState.isGoogleCalendarAuthenticated {
            Button {
                controller.signOutGoogleCalendar()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                    Text("Connected · Disconnect")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(MuesliTheme.success)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        } else if isSigningInGoogleCal {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting...")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else if !appState.isGoogleCalendarVerified {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Connect Google Calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(MuesliTheme.textTertiary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                Text("Google OAuth verification pending")
                    .font(.system(size: 10))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isSigningInGoogleCal = true
                    googleCalSignInError = nil
                    Task {
                        let error = await controller.signInWithGoogleCalendar()
                        isSigningInGoogleCal = false
                        googleCalSignInError = error
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                        Text("Connect Google Calendar")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                if let googleCalSignInError {
                    Text(googleCalSignInError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var googleDriveDocsControl: some View {
        if appState.isGoogleDriveDocsAuthorized {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(MuesliTheme.success)
                Text("Authorized")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isAuthorizingGoogleDriveDocs {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Authorizing...")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isAuthorizingGoogleDriveDocs = true
                    googleDriveDocsAuthError = nil
                    Task {
                        let error = await controller.authorizeGoogleDriveDocs()
                        isAuthorizingGoogleDriveDocs = false
                        googleDriveDocsAuthError = error
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                        Text("Authorize when needed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                if let googleDriveDocsAuthError {
                    Text(googleDriveDocsAuthError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private var maraudersMapControl: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            settingsMenu(
                selection: SoundController.labelForClip(
                    id: appState.config.maraudersMapAudioClip,
                    customPath: appState.config.maraudersMapCustomAudioPath
                ),
                options: SoundController.maraudersMapClipLabels
            ) { label in
                if label == "Custom\u{2026}" {
                    pickCustomAudioFile()
                } else if let preset = SoundController.maraudersMapPresets
                    .first(where: { $0.label == label }) {
                    SoundController.stopMaraudersMapClip()
                    isPreviewingClip = false
                    controller.updateConfig {
                        $0.maraudersMapAudioClip = preset.id
                        $0.maraudersMapCustomAudioPath = nil
                    }
                    controller.updateMaraudersMapAudioClip()
                }
            }
            Button {
                if isPreviewingClip {
                    SoundController.stopMaraudersMapClip()
                    isPreviewingClip = false
                } else {
                    SoundController.playMaraudersMapClip(
                        id: appState.config.maraudersMapAudioClip,
                        customPath: appState.config.maraudersMapCustomAudioPath
                    ) {
                        isPreviewingClip = false
                    }
                    isPreviewingClip = true
                }
            } label: {
                Image(systemName: isPreviewingClip ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundColor(MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Marauder's Map

    private func pickCustomAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an audio clip"
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fputs("[muesli-native] Could not resolve Application Support directory\n", stderr)
            return
        }

        do {
            let supportDir = appSupportBase
                .appendingPathComponent(Bundle.main.infoDictionary?["MuesliSupportDirectoryName"] as? String ?? "Muesli")
            let destPath = try SoundController.importCustomClip(from: url, supportDir: supportDir)
            controller.updateConfig {
                $0.maraudersMapAudioClip = SoundController.customClipID
                $0.maraudersMapCustomAudioPath = destPath
            }
            controller.updateMaraudersMapAudioClip()
        } catch {
            fputs("[muesli-native] Failed to import custom audio: \(error)\n", stderr)
        }
    }

    private func pickMeetingHookFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a hook script"
        panel.prompt = "Choose Script"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = preferredMeetingHookDirectoryURL()

        presentOpenPanel(panel) { url in
            controller.updateConfig { $0.meetingHookPath = url.standardizedFileURL.path }
        }
    }

    private func preferredMeetingHookDirectoryURL() -> URL {
        let configuredPath = appState.config.meetingHookPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPath).standardizedFileURL
            let parentDirectory = configuredURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parentDirectory.path) {
                return parentDirectory
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, onPick: @escaping (URL) -> Void) {
        NSApp.activate()
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                onPick(url)
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                onPick(url)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        settingsSection("Permissions") {
            permissionStatusRow(
                "Microphone",
                granted: micGranted,
                action: { AVCaptureDevice.requestAccess(for: .audio) { _ in } },
                pane: "Privacy_Microphone"
            )
            Divider().background(MuesliTheme.surfaceBorder)
            permissionStatusRow(
                "Accessibility",
                granted: accessibilityGranted,
                action: {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                    AXIsProcessTrustedWithOptions(opts)
                    openPrivacyPane("Privacy_Accessibility")
                },
                pane: "Privacy_Accessibility"
            )
            Divider().background(MuesliTheme.surfaceBorder)
            permissionStatusRow(
                "Input Monitoring",
                granted: inputMonitoringGranted,
                action: {
                    if !CGRequestListenEventAccess() {
                        openPrivacyPane("Privacy_ListenEvent")
                    }
                },
                pane: "Privacy_ListenEvent"
            )
            Divider().background(MuesliTheme.surfaceBorder)
            permissionStatusRow(
                "Screen Recording",
                granted: screenRecordingGranted,
                action: {
                    if !CGRequestScreenCaptureAccess() {
                        openPrivacyPane("Privacy_ScreenCapture")
                    }
                },
                pane: "Privacy_ScreenCapture"
            )
            if appState.config.useCoreAudioTap {
                Divider().background(MuesliTheme.surfaceBorder)
                permissionStatusRow(
                    "System Audio",
                    granted: systemAudioGranted,
                    action: {
                        Task { await CoreAudioSystemRecorder.requestSystemAudioAccess() }
                        openPrivacyPane("Privacy_ScreenCapture")
                    },
                    pane: "Privacy_ScreenCapture"
                )
            }
        }
    }

    @ViewBuilder
    private func permissionStatusRow(_ name: String, granted: Bool, action: @escaping () -> Void, pane: String) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(granted ? MuesliTheme.success : MuesliTheme.recording)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(granted ? "Connected" : "Needed for \(permissionReason(name))")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .layoutPriority(1)

            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.success)
            } else {
                Button("Fix") {
                    action()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            Button("Recheck") {
                refreshPermissionStatuses()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            Button {
                openPrivacyPane(pane)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Open in System Settings")
        }
        .frame(minHeight: 44)
    }

    private func permissionReason(_ name: String) -> String {
        switch name {
        case "Microphone": return "recording and transcription"
        case "Accessibility": return "agent actions and UI automation"
        case "Input Monitoring": return "global shortcuts"
        case "Screen Recording": return "meeting context"
        case "System Audio": return "meeting audio capture"
        default: return "Sales Caddie"
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func screenContextControl(width: CGFloat? = nil) -> some View {
        if screenRecordingGranted {
            settingsSwitch(isOn: appState.config.enableScreenContext) { newValue in
                handleScreenContextToggle(newValue)
            }
            .frame(width: width, alignment: .trailing)
        } else {
            Button {
                handleScreenContextToggle(true)
            } label: {
                Text("Grant")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: width)
                    .frame(minHeight: 32)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
        }
    }

    private func handleScreenContextToggle(_ enabled: Bool) {
        guard enabled else {
            clearPendingScreenContextEnable()
            controller.updateConfig { $0.enableScreenContext = false }
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            controller.updateConfig { $0.enableScreenContext = false }
            pendingScreenContextEnable = true
            pendingScreenContextRequestedAt = Date().timeIntervalSince1970
            let granted = CGRequestScreenCaptureAccess()
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
            if granted || screenRecordingGranted {
                clearPendingScreenContextEnable()
                controller.updateConfig { $0.enableScreenContext = true }
            }
            return
        }

        screenRecordingGranted = true
        clearPendingScreenContextEnable()
        controller.updateConfig { $0.enableScreenContext = true }
    }

    private func startPermissionPolling() {
        refreshPermissionStatuses()
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshPermissionStatuses()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func refreshPermissionStatuses() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        controller.refreshLaunchAtLoginState()
        if screenRecordingGranted && pendingScreenContextEnable {
            clearPendingScreenContextEnable()
            controller.updateConfig { $0.enableScreenContext = true }
        }
        if !screenRecordingGranted && isPendingScreenContextGrantExpired {
            clearPendingScreenContextEnable()
        }
        if !screenRecordingGranted && appState.config.enableScreenContext {
            clearPendingScreenContextEnable()
            controller.updateConfig { $0.enableScreenContext = false }
        }
        controller.reclassifyVoiceNotesAsDictationIfReady(
            microphoneGranted: micGranted,
            accessibilityGranted: accessibilityGranted,
            inputMonitoringGranted: inputMonitoringGranted
        )
        refreshSystemAudioPermissionIfNeeded()
    }

    private var isPendingScreenContextGrantExpired: Bool {
        guard pendingScreenContextEnable else { return false }
        guard pendingScreenContextRequestedAt > 0 else { return true }
        return Date().timeIntervalSince1970 - pendingScreenContextRequestedAt > screenContextGrantIntentTimeout
    }

    private func clearPendingScreenContextEnable() {
        pendingScreenContextEnable = false
        pendingScreenContextRequestedAt = 0
    }

    private func refreshSystemAudioPermissionIfNeeded() {
        guard appState.config.useCoreAudioTap, !isCheckingSystemAudioPermission else { return }
        isCheckingSystemAudioPermission = true

        Task {
            let granted = await Task.detached(priority: .utility) {
                CoreAudioSystemRecorder.checkSystemAudioPermission()
            }.value
            await MainActor.run {
                self.systemAudioGranted = granted
                self.isCheckingSystemAudioPermission = false
            }
        }
    }

    // MARK: - Layout Primitives

    @ViewBuilder
    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .textCase(.uppercase)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    /// Standardized row: label on left, control on right.
    /// Controls share a fixed-width column so they all right-align consistently.
    @ViewBuilder
    private func settingsRow(_ label: String, controlWidth rowControlWidth: CGFloat? = nil, @ViewBuilder control: () -> some View) -> some View {
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .center) {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: 20)
            ZStack(alignment: .trailing) {
                // Invisible spacer forces the ZStack to exactly controlWidth
                Color.clear.frame(width: width, height: 1)
                control()
                    .frame(maxWidth: width)
            }
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private func settingsRow(
        _ label: String,
        description: String,
        controlWidth rowControlWidth: CGFloat? = nil,
        @ViewBuilder control: () -> some View
    ) -> some View {
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(description)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            control()
                .frame(width: width, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }

    private func settingsToolRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(subtitle)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(.vertical, MuesliTheme.spacing8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsDescription(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.top, -4)
            .padding(.bottom, MuesliTheme.spacing8)
    }

    // MARK: - Controls

    @ViewBuilder
    private func settingsSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func settingsMenu(selection: String, options: [String], onChange: @escaping (String) -> Void) -> some View {
        FixedWidthPopUp(selection: selection, options: options, onChange: onChange)
            .frame(height: 24)
    }

    private var mutedMeetingDetectionAppsControl: some View {
        let muted = Set(appState.config.mutedMeetingDetectionAppBundleIDs)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Don't notify me when a call is detected in these apps:")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], alignment: .leading, spacing: 8) {
                ForEach(meetingDetectionAppOptions) { app in
                    mutedDetectionAppButton(app, isMuted: muted.contains(app.bundleID))
                }
            }
        }
        .padding(.leading, MuesliTheme.spacing16)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(width: 2)
        }
    }

    private func mutedDetectionAppButton(_ app: MeetingDetectionAppOption, isMuted: Bool) -> some View {
        Button {
            updateMutedMeetingDetectionApp(app.bundleID, isMuted: !isMuted)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMuted ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 16)
                Image(systemName: app.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 14)
                Text(app.name)
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isMuted ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isMuted ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func updateMutedMeetingDetectionApp(_ bundleID: String, isMuted: Bool) {
        controller.updateConfig { config in
            var muted = Set(config.mutedMeetingDetectionAppBundleIDs)
            if isMuted {
                muted.insert(bundleID)
            } else {
                muted.remove(bundleID)
            }
            config.mutedMeetingDetectionAppBundleIDs = muted.sorted()
        }
    }

    private var salesOverlayControls: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing16) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Text("Popup types")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Enabled types can all run during the same call.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer(minLength: MuesliTheme.spacing12)
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: MuesliTheme.spacing8),
                        GridItem(.flexible(), spacing: MuesliTheme.spacing8),
                    ],
                    alignment: .leading,
                    spacing: MuesliTheme.spacing8
                ) {
                    ForEach(SalesAssistLiveCue.supportedKinds, id: \.self) { kind in
                        salesOverlayKindToggle(kind)
                    }
                }
                .frame(width: 420)
            }

            Divider().background(MuesliTheme.surfaceBorder)

            HStack(alignment: .top, spacing: MuesliTheme.spacing16) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Text("Preview")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Fire a sample card without starting a meeting.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer(minLength: MuesliTheme.spacing12)
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(126), spacing: MuesliTheme.spacing8),
                        GridItem(.fixed(126), spacing: MuesliTheme.spacing8),
                        GridItem(.fixed(126), spacing: MuesliTheme.spacing8),
                    ],
                    alignment: .trailing,
                    spacing: MuesliTheme.spacing8
                ) {
                    salesTestButton("Buying", kind: "buying_signal")
                    salesTestButton("Objection", kind: "objection")
                    salesTestButton("Battlecard", kind: "competitor")
                    salesTestButton("Discovery", kind: "discovery")
                    salesTestButton("Talk time", kind: "talk_ratio")
                }
                .frame(width: 420, alignment: .trailing)
            }
        }
    }

    private func salesOverlayKindToggle(_ kind: String) -> some View {
        let isEnabled = appState.config.salesAssistEnabledKinds.contains(kind)
        return Button {
            controller.updateConfig { config in
                var enabled = Set(config.salesAssistEnabledKinds)
                if isEnabled {
                    enabled.remove(kind)
                } else {
                    enabled.insert(kind)
                }
                config.salesAssistEnabledKinds = SalesAssistLiveCue.supportedKinds.filter { enabled.contains($0) }
            }
        } label: {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isEnabled ? MuesliTheme.accent : MuesliTheme.textTertiary)
                Text(SalesAssistLiveCue.kindLabels[kind] ?? kind)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isEnabled ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isEnabled ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func salesTestButton(_ label: String, kind: String) -> some View {
        Button {
            controller.testSalesAssistOverlay(kind: kind)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func salesLearningSuggestionRow(_ suggestion: SalesAssistLearningSuggestion) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                Text(suggestion.kind == .objection ? "Objection" : "KB")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(suggestion.kind == .objection ? MuesliTheme.accent : MuesliTheme.success)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((suggestion.kind == .objection ? MuesliTheme.accent : MuesliTheme.success).opacity(0.12))
                    .clipShape(Capsule())
                Text(suggestion.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
                Text(suggestion.sourceTitle)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(1)
            }

            Text(suggestion.content)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(suggestion.reason)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: MuesliTheme.spacing8) {
                Spacer()
                if suggestion.kind == .knowledgeBase {
                    actionButton("Add to KB") {
                        acceptSalesLearningSuggestion(suggestion)
                    }
                    .frame(width: 120)
                } else {
                    actionButton("Add objection") {
                        acceptSalesLearningSuggestion(suggestion)
                    }
                    .frame(width: 130)
                }
                actionButton("Dismiss") {
                    dismissSalesLearningSuggestion(suggestion.id)
                }
                .frame(width: 100)
            }
        }
        .padding(.vertical, MuesliTheme.spacing8)
    }

    private func analyzeLatestSalesCall() {
        clearSalesImportStatus()
        guard let meeting = appState.meetingRows.first(where: {
            $0.status == .completed && !$0.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            salesImportError = "No completed meeting transcript found."
            return
        }

        isAnalyzingSalesCall = true
        let config = appState.config
        Task {
            do {
                let suggestions = try await SalesAssistCallLearningAnalyzer().analyze(meeting: meeting, config: config)
                await MainActor.run {
                    controller.updateConfig { config in
                        config.salesAssistLearningSuggestions.insert(contentsOf: suggestions, at: 0)
                    }
                    salesImportMessage = "Found \(suggestions.count) learning suggestion\(suggestions.count == 1 ? "" : "s")."
                    isAnalyzingSalesCall = false
                }
            } catch {
                await MainActor.run {
                    salesImportError = error.localizedDescription
                    isAnalyzingSalesCall = false
                }
            }
        }
    }

    private func acceptSalesLearningSuggestion(_ suggestion: SalesAssistLearningSuggestion) {
        controller.updateConfig { config in
            switch suggestion.kind {
            case .knowledgeBase:
                let note = """

                ## \(suggestion.title)
                \(suggestion.content)
                Source: \(suggestion.sourceTitle)
                """
                config.salesAssistKnowledgeBase += note
            case .objection:
                if let objection = suggestion.objection {
                    config.salesAssistObjections.append(objection)
                    selectedSalesObjectionID = objection.id
                }
            }
            config.salesAssistLearningSuggestions.removeAll { $0.id == suggestion.id }
        }
    }

    private func dismissSalesLearningSuggestion(_ id: String) {
        controller.updateConfig { config in
            config.salesAssistLearningSuggestions.removeAll { $0.id == id }
        }
    }

    private var salesObjectionLibraryBrowser: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing16) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack {
                    Text("\(filteredSalesObjections.count) of \(appState.config.salesAssistObjections.count)")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Spacer()
                }

                PastableTextField(
                    text: salesObjectionSearchQuery,
                    placeholder: "Search objections"
                ) { value in
                    salesObjectionSearchQuery = value
                    if let first = filteredSalesObjections.first {
                        selectedSalesObjectionID = first.id
                    }
                }
                .frame(height: 28)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredSalesObjections) { objection in
                            salesObjectionListRow(
                                objection,
                                isSelected: selectedSalesObjection?.id == objection.id
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 250, height: 430)
                .background(MuesliTheme.surfacePrimary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }
            .frame(width: 250)

            Divider().background(MuesliTheme.surfaceBorder)

            if let objection = selectedSalesObjection {
                salesObjectionEditor(objection)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                Text("Select an objection.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 430, alignment: .center)
            }
        }
        .onAppear {
            ensureSelectedSalesObjection()
        }
        .onChange(of: appState.config.salesAssistObjections.map(\.id)) { _, _ in
            ensureSelectedSalesObjection()
        }
    }

    private func salesObjectionListRow(_ objection: SalesAssistObjection, isSelected: Bool) -> some View {
        Button {
            selectedSalesObjectionID = objection.id
        } label: {
            HStack(alignment: .top, spacing: MuesliTheme.spacing8) {
                Circle()
                    .fill(priorityColor(for: objection.priority))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(objection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled objection" : objection.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    Text(objection.triggerPhrases
                        .components(separatedBy: CharacterSet(charactersIn: "\n,;"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .prefix(2)
                        .joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(isSelected ? MuesliTheme.accentSubtle : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isSelected ? MuesliTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func salesObjectionEditor(_ objection: SalesAssistObjection) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                PastableTextField(
                    text: objection.name,
                    placeholder: "Objection name"
                ) { value in
                    updateSalesObjection(objection.id) { $0.name = value }
                }
                .frame(height: 28)

                settingsMenu(
                    selection: objection.priority.capitalized,
                    options: ["High", "Medium", "Low"]
                ) { label in
                    updateSalesObjection(objection.id) { $0.priority = label.lowercased() }
                }
                .frame(width: 120)

                Button {
                    controller.updateConfig { config in
                        config.salesAssistObjections.removeAll { $0.id == objection.id }
                        selectedSalesObjectionID = config.salesAssistObjections.first?.id
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.recording)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Remove objection")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Trigger phrases")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                MultilineTextEditor(
                    text: objection.triggerPhrases,
                    placeholder: "One per line, or comma separated. Example: need to ask my office manager, concerned about HIPAA, send me info",
                    minHeight: 64
                ) { value in
                    updateSalesObjection(objection.id) { $0.triggerPhrases = value }
                }
                .frame(minHeight: 64)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Handling guidance")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                MultilineTextEditor(
                    text: objection.guidance,
                    placeholder: "What should the rep say or ask next?",
                    minHeight: 72
                ) { value in
                    updateSalesObjection(objection.id) { $0.guidance = value }
                }
                .frame(minHeight: 72)
            }
        }
        .padding(.vertical, 4)
    }

    private func ensureSelectedSalesObjection() {
        if let selectedSalesObjectionID,
           appState.config.salesAssistObjections.contains(where: { $0.id == selectedSalesObjectionID }) {
            return
        }
        selectedSalesObjectionID = filteredSalesObjections.first?.id ?? appState.config.salesAssistObjections.first?.id
    }

    private func priorityColor(for priority: String) -> Color {
        switch priority.lowercased() {
        case "high":
            return MuesliTheme.recording
        case "low":
            return MuesliTheme.textTertiary
        default:
            return MuesliTheme.accent
        }
    }

    private func updateSalesObjection(_ id: String, mutate: @escaping (inout SalesAssistObjection) -> Void) {
        controller.updateConfig { config in
            guard let index = config.salesAssistObjections.firstIndex(where: { $0.id == id }) else { return }
            mutate(&config.salesAssistObjections[index])
        }
    }

    private var salesLiveCueLibraryBrowser: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing16) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack {
                    Text("\(filteredSalesLiveCues.count) of \(appState.config.salesAssistLiveCues.count)")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Spacer()
                }

                PastableTextField(
                    text: salesLiveCueSearchQuery,
                    placeholder: "Search live cues"
                ) { value in
                    salesLiveCueSearchQuery = value
                    if let first = filteredSalesLiveCues.first {
                        selectedSalesLiveCueID = first.id
                    }
                }
                .frame(height: 28)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredSalesLiveCues) { cue in
                            salesLiveCueListRow(
                                cue,
                                isSelected: selectedSalesLiveCue?.id == cue.id
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 250, height: 360)
                .background(MuesliTheme.surfacePrimary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }
            .frame(width: 250)

            Divider().background(MuesliTheme.surfaceBorder)

            if let cue = selectedSalesLiveCue {
                salesLiveCueEditor(cue)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                Text("Select a live cue.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
            }
        }
        .onAppear {
            ensureSelectedSalesLiveCue()
        }
        .onChange(of: appState.config.salesAssistLiveCues.map(\.id)) { _, _ in
            ensureSelectedSalesLiveCue()
        }
    }

    private func salesLiveCueListRow(_ cue: SalesAssistLiveCue, isSelected: Bool) -> some View {
        Button {
            selectedSalesLiveCueID = cue.id
        } label: {
            HStack(alignment: .top, spacing: MuesliTheme.spacing8) {
                Circle()
                    .fill(priorityColor(for: cue.priority))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(cue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled cue" : cue.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    Text(SalesAssistLiveCue.kindLabels[cue.kind] ?? cue.kind)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.accent)
                        .lineLimit(1)
                    Text(cue.triggerPhrases
                        .components(separatedBy: CharacterSet(charactersIn: "\n,;"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .prefix(2)
                        .joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(isSelected ? MuesliTheme.accentSubtle : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isSelected ? MuesliTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func salesLiveCueEditor(_ cue: SalesAssistLiveCue) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                PastableTextField(
                    text: cue.name,
                    placeholder: "Cue name"
                ) { value in
                    updateSalesLiveCue(cue.id) { $0.name = value }
                }
                .frame(height: 28)

                settingsMenu(
                    selection: SalesAssistLiveCue.kindLabels[cue.kind] ?? cue.kind,
                    options: SalesAssistLiveCue.supportedKinds
                        .filter { $0 != "objection" }
                        .map { SalesAssistLiveCue.kindLabels[$0] ?? $0 }
                ) { label in
                    let nextKind = SalesAssistLiveCue.supportedKinds.first {
                        (SalesAssistLiveCue.kindLabels[$0] ?? $0) == label
                    } ?? "buying_signal"
                    updateSalesLiveCue(cue.id) { $0.kind = nextKind }
                }
                .frame(width: 180)

                settingsMenu(
                    selection: cue.priority.capitalized,
                    options: ["High", "Medium", "Low"]
                ) { label in
                    updateSalesLiveCue(cue.id) { $0.priority = label.lowercased() }
                }
                .frame(width: 120)

                Button {
                    controller.updateConfig { config in
                        config.salesAssistLiveCues.removeAll { $0.id == cue.id }
                        selectedSalesLiveCueID = config.salesAssistLiveCues.first?.id
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.recording)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Remove live cue")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Trigger phrases")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                MultilineTextEditor(
                    text: cue.triggerPhrases,
                    placeholder: "One per line. Example: how do we get started, using Freed, notes take forever",
                    minHeight: 64
                ) { value in
                    updateSalesLiveCue(cue.id) { $0.triggerPhrases = value }
                }
                .frame(minHeight: 64)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Overlay guidance")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                MultilineTextEditor(
                    text: cue.guidance,
                    placeholder: "What should the rep say, ask, or do when this pops up?",
                    minHeight: 72
                ) { value in
                    updateSalesLiveCue(cue.id) { $0.guidance = value }
                }
                .frame(minHeight: 72)
            }
        }
        .padding(.vertical, 4)
    }

    private func ensureSelectedSalesLiveCue() {
        if let selectedSalesLiveCueID,
           appState.config.salesAssistLiveCues.contains(where: { $0.id == selectedSalesLiveCueID }) {
            return
        }
        selectedSalesLiveCueID = filteredSalesLiveCues.first?.id ?? appState.config.salesAssistLiveCues.first?.id
    }

    private func updateSalesLiveCue(_ id: String, mutate: @escaping (inout SalesAssistLiveCue) -> Void) {
        controller.updateConfig { config in
            guard let index = config.salesAssistLiveCues.firstIndex(where: { $0.id == id }) else { return }
            mutate(&config.salesAssistLiveCues[index])
        }
    }

    private var salesObjectionExtractionSheet: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Text("Extract Objections")
                .font(MuesliTheme.title2())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Paste messy notes, call snippets, markdown, or training material. The AI will create editable objection cards.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)

            MultilineTextEditor(
                text: salesObjectionExtractionText,
                placeholder: "Paste notes here...",
                minHeight: 260
            ) { value in
                salesObjectionExtractionText = value
            }
            .frame(minHeight: 260)

            HStack(spacing: MuesliTheme.spacing8) {
                Spacer()
                actionButton("Cancel") {
                    showSalesObjectionExtractionSheet = false
                }
                .frame(width: 120)
                actionButton(isExtractingSalesObjections ? "Extracting..." : "Extract") {
                    extractSalesObjectionsFromText()
                }
                .frame(width: 140)
                .disabled(isExtractingSalesObjections)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(width: 680)
        .frame(minHeight: 430)
        .background(MuesliTheme.backgroundBase)
    }

    private func importSalesKnowledgeBaseFile(append: Bool) {
        clearSalesImportStatus()
        guard let url = selectFile(
            title: append ? "Append Knowledge Base File" : "Replace Knowledge Base From File",
            allowedContentTypes: salesTextImportTypes
        ) else { return }
        do {
            let imported = try SalesAssistLibraryImport.text(from: url)
            guard !imported.isEmpty else { throw SalesAssistImportError.unreadableFile }
            controller.updateConfig { config in
                if append, !config.salesAssistKnowledgeBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    config.salesAssistKnowledgeBase += "\n\n" + imported
                } else {
                    config.salesAssistKnowledgeBase = imported
                }
            }
            salesImportMessage = append ? "Knowledge base appended." : "Knowledge base replaced."
        } catch {
            salesImportError = error.localizedDescription
        }
    }

    private func importSalesObjectionsFile() {
        clearSalesImportStatus()
        guard let url = selectFile(
            title: "Import Objections",
            allowedContentTypes: salesObjectionImportTypes
        ) else { return }
        do {
            let objections = try SalesAssistLibraryImport.objections(from: url)
            appendSalesObjections(objections)
            salesImportMessage = "Imported \(objections.count) objection\(objections.count == 1 ? "" : "s")."
        } catch {
            salesImportError = error.localizedDescription
        }
    }

    private func extractSalesObjectionsFromText() {
        clearSalesImportStatus()
        let notes = salesObjectionExtractionText
        isExtractingSalesObjections = true
        Task {
            do {
                let objections = try await SalesAssistObjectionExtractor().extract(from: notes)
                await MainActor.run {
                    appendSalesObjections(objections)
                    salesImportMessage = "Extracted \(objections.count) objection\(objections.count == 1 ? "" : "s")."
                    isExtractingSalesObjections = false
                    showSalesObjectionExtractionSheet = false
                }
            } catch {
                await MainActor.run {
                    salesImportError = error.localizedDescription
                    isExtractingSalesObjections = false
                }
            }
        }
    }

    private func appendSalesObjections(_ objections: [SalesAssistObjection]) {
        controller.updateConfig { config in
            config.salesAssistObjections.append(contentsOf: objections)
        }
        if let first = objections.first {
            selectedSalesObjectionID = first.id
        }
    }

    private func clearSalesImportStatus() {
        salesImportMessage = nil
        salesImportError = nil
    }

    private var salesTextImportTypes: [UTType] {
        [
            .plainText,
            .text,
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }
    }

    private var salesObjectionImportTypes: [UTType] {
        [
            .json,
            .commaSeparatedText,
            UTType(filenameExtension: "csv"),
        ].compactMap { $0 }
    }

    private func selectFile(title: String, allowedContentTypes: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedContentTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Calendars

    private struct CalendarToggleItem: Identifiable, Equatable {
        let id: String
        let title: String
        let colorHex: String?
        let isEnabled: Bool
    }

    private struct CalendarSourceGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let iconName: String
        let items: [CalendarToggleItem]
    }

    private var calendarSourceGroups: [CalendarSourceGroup] {
        let disabled = Set(appState.config.disabledCalendarIDs)
        var groups: [CalendarSourceGroup] = []

        let ekBySource = Dictionary(grouping: appState.availableEventKitCalendars) { $0.sourceTitle }
        for sourceTitle in ekBySource.keys.sorted() {
            let items = (ekBySource[sourceTitle] ?? [])
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { cal in
                    CalendarToggleItem(
                        id: cal.id,
                        title: cal.title,
                        colorHex: cal.colorHex,
                        isEnabled: !disabled.contains(cal.id)
                    )
                }
            groups.append(CalendarSourceGroup(
                id: "ek::\(sourceTitle)",
                title: sourceTitle,
                subtitle: calendarSourceSubtitle(for: sourceTitle),
                iconName: calendarSourceIconName(for: sourceTitle),
                items: items
            ))
        }

        if appState.isGoogleCalendarAuthenticated && !appState.availableGoogleCalendars.isEmpty {
            let items = appState.availableGoogleCalendars.map { cal in
                CalendarToggleItem(
                    id: cal.id,
                    title: cal.summary + (cal.isPrimary ? " (Primary)" : ""),
                    colorHex: cal.colorHex,
                    isEnabled: !disabled.contains(cal.id)
                )
            }
            groups.append(CalendarSourceGroup(
                id: "google_oauth",
                title: "Google Calendar",
                subtitle: "Connected directly to Muesli",
                iconName: "calendar.badge.plus",
                items: items
            ))
        }

        return groups
    }

    private var calendarSourcesControl: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text("Calendar sources are listed first, with their calendars underneath. Disabled calendars are hidden from Muesli — no notifications, no Coming Up, no meeting detection.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if calendarSourceGroups.isEmpty {
                Text("No calendars detected. Make sure Calendar permission is granted in System Settings > Privacy & Security > Calendars.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(calendarSourceGroups) { group in
                    calendarSourceGroupView(group)
                }
            }

            if appState.isGoogleCalendarAuthenticated && !appState.availableEventKitCalendars.isEmpty {
                Text("Google calendars may appear once from macOS Calendar and once from Muesli's Google connection. Turn off both copies to hide that calendar completely.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.isGoogleCalendarAuthenticated {
                googleCalendarListLoadStateView
            }
        }
    }

    @ViewBuilder
    private func calendarSourceGroupView(_ group: CalendarSourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: group.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)

                    Text("\(group.subtitle) • \(group.items.count) \(group.items.count == 1 ? "calendar" : "calendars")")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], alignment: .leading, spacing: 8) {
                ForEach(group.items) { item in
                    calendarToggleButton(item)
                }
            }
            .padding(.leading, 28)
        }
        .padding(.vertical, 2)
    }

    private func calendarSourceSubtitle(for sourceTitle: String) -> String {
        let normalized = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "icloud" {
            return "iCloud account in macOS Calendar"
        }
        if normalized == "subscribed calendars" {
            return "Subscribed in macOS Calendar"
        }
        if normalized == "other" {
            return "System calendars from macOS"
        }
        return "Calendar account in macOS"
    }

    private func calendarSourceIconName(for sourceTitle: String) -> String {
        let normalized = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "icloud" {
            return "icloud"
        }
        if normalized == "subscribed calendars" {
            return "calendar.badge.clock"
        }
        if normalized == "other" {
            return "person.crop.circle.badge.clock"
        }
        return "calendar"
    }

    private func calendarToggleButton(_ item: CalendarToggleItem) -> some View {
        Button {
            updateDisabledCalendar(item.id, isDisabled: item.isEnabled)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isEnabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.isEnabled ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 16)
                Circle()
                    .fill(item.colorHex.map { Color(hex: $0) } ?? MuesliTheme.textTertiary)
                    .frame(width: 8, height: 8)
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isEnabled ? MuesliTheme.textPrimary : MuesliTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var googleCalendarListLoadStateView: some View {
        switch appState.googleCalendarListLoadState {
        case .loading:
            Text("Loading Google calendars…")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        case .failed(let message):
            HStack(spacing: 8) {
                Text("Failed to load Google calendars: \(message)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Button("Retry") {
                    Task { await controller.refreshGoogleCalendarList() }
                }
                .buttonStyle(.link)
                .font(MuesliTheme.caption())
            }
        case .idle, .loaded:
            EmptyView()
        }
    }

    private func updateDisabledCalendar(_ calendarID: String, isDisabled: Bool) {
        controller.updateConfig { config in
            var disabled = Set(config.disabledCalendarIDs)
            if isDisabled {
                disabled.insert(calendarID)
            } else {
                disabled.remove(calendarID)
            }
            config.disabledCalendarIDs = disabled.sorted()
        }
        Task { await controller.refreshUpcomingCalendarEvents() }
    }

    @ViewBuilder
    private var meetingHookPathPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)

                if appState.config.meetingHookPath.isEmpty {
                    Text("Choose a script…")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.meetingHookPath)
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .help(appState.config.meetingHookPath.isEmpty ? "No hook script selected" : appState.config.meetingHookPath)

            if !appState.config.meetingHookPath.isEmpty {
                Button {
                    controller.updateConfig { $0.meetingHookPath = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Clear hook script")
            }

            Button {
                pickMeetingHookFile()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Choose hook script")
        }
    }

    @ViewBuilder
    private func meetingTemplateMenu(selectionID: String, onChange: @escaping (String) -> Void) -> some View {
        let allItems: [(id: String, label: String)] = {
            var items: [(String, String)] = [(MeetingTemplates.autoID, MeetingTemplates.auto.title)]
            items += controller.builtInMeetingTemplates().map { ($0.id, $0.title) }
            items += controller.customMeetingTemplates().map { ($0.id, $0.name) }
            return items
        }()
        let selectedLabel = allItems.first(where: { $0.id == selectionID })?.label ?? "Auto"
        FixedWidthPopUp(
            selection: selectedLabel,
            options: allItems.map(\.label),
            onSelectIndex: { index in
                guard index >= 0 && index < allItems.count else { return }
                onChange(allItems[index].id)
            }
        )
        .frame(height: 24)
    }

    @ViewBuilder
    private func settingsModelMenu(currentModel: String, presets: [SummaryModelPreset], onChange: @escaping (String) -> Void) -> some View {
        let menuPresets = SummaryModelPreset.menuPresets(presets, currentModel: currentModel)
        let effectiveModel = currentModel.isEmpty ? (presets.first?.id ?? "") : currentModel
        let selectedLabel = menuPresets.first(where: { $0.id == effectiveModel })?.label ?? menuPresets.first?.label ?? ""
        FixedWidthPopUp(
            selection: selectedLabel,
            options: menuPresets.map(\.label),
            onSelectIndex: { index in
                guard index >= 0 && index < menuPresets.count else { return }
                let selectedId = menuPresets[index].id
                onChange(selectedId == presets.first?.id ? "" : selectedId)
            }
        )
        .frame(height: 24)
    }

    @ViewBuilder
    private func settingsModelTextField(currentModel: String, placeholder: String, onChange: @escaping (String) -> Void) -> some View {
        PastableTextField(
            text: currentModel,
            placeholder: placeholder,
            onChange: { value in
                onChange(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
        .frame(height: 22)
    }

    @ViewBuilder
    private var openRouterFreeModelMenu: some View {
        if isLoadingOpenRouterFreeModels {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading models")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if !openRouterFreeModels.isEmpty {
            settingsModelMenu(
                currentModel: appState.config.openRouterModel,
                presets: openRouterFreeModels
            ) { val in controller.updateConfig { $0.openRouterModel = val } }
        } else {
            HStack(spacing: 8) {
                if let openRouterFreeModelsError {
                    Text(openRouterFreeModelsError)
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }
                Button("Load") {
                    loadOpenRouterFreeModels(force: true)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func loadOpenRouterFreeModelsIfNeeded() {
        guard openRouterFreeModels.isEmpty, !isLoadingOpenRouterFreeModels else { return }
        loadOpenRouterFreeModels(force: false)
    }

    private func loadOpenRouterFreeModels(force: Bool) {
        guard force || openRouterFreeModels.isEmpty else { return }
        isLoadingOpenRouterFreeModels = true
        openRouterFreeModelsError = nil

        Task {
            do {
                let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")!
                let (data, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let catalog = try JSONDecoder().decode(OpenRouterModelCatalog.self, from: data)
                let presets = OpenRouterModelCatalogFilter.freeTextSummaryPresets(from: catalog.data)

                await MainActor.run {
                    openRouterFreeModels = presets
                    openRouterFreeModelsError = presets.isEmpty ? "No free text models found" : nil
                    isLoadingOpenRouterFreeModels = false
                }
            } catch {
                await MainActor.run {
                    openRouterFreeModels = []
                    openRouterFreeModelsError = "Could not load"
                    isLoadingOpenRouterFreeModels = false
                }
            }
        }
    }

    private func applyPreferredSettingsPane() {
        guard let rawValue = appState.preferredSettingsPane,
              let pane = SettingsPane(rawValue: rawValue) else { return }
        selectedPane = pane
        appState.preferredSettingsPane = nil
    }

    private func redeemInviteCode() {
        let token = inviteSetupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        isRedeemingInvite = true
        inviteRedeemMessage = nil
        inviteRedeemError = nil
        let apiURL = effectiveInviteAPIURL

        Task {
            do {
                let response = try await SalesCaddieCloudAPIClient.redeemInvite(token: token, apiURL: apiURL)
                await MainActor.run {
                    controller.applySalesCaddieInviteConfig(response.config)
                    controller.applySalesCaddieIdentity(
                        SalesCaddieIdentityResponse(
                            ok: response.ok,
                            workspace: response.workspace,
                            member: response.member,
                            permissions: response.member.permissions ?? SalesCaddiePermissions()
                        )
                    )
                    inviteSetupCode = ""
                    inviteRedeemMessage = "Joined \(response.workspace.slug) as \(response.member.email)."
                    isRedeemingInvite = false
                }
            } catch {
                await MainActor.run {
                    inviteRedeemError = error.localizedDescription
                    isRedeemingInvite = false
                }
            }
        }
    }

    @ViewBuilder
    private func keyStatusRow(key: String) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Circle()
                .fill(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(key.isEmpty ? "No API key configured" : "Key configured")
                .font(.system(size: 11))
                .foregroundStyle(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private func actionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(
                            isDestructive ? MuesliTheme.recording.opacity(0.2) : MuesliTheme.surfaceBorder,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func recordingSaveLabel(for policy: MeetingRecordingSavePolicy) -> String {
        switch policy {
        case .never:
            return "Never"
        case .prompt:
            return "Ask every time"
        case .always:
            return "Always"
        }
    }

    private func recordingSavePolicy(for label: String) -> MeetingRecordingSavePolicy? {
        let policy = MeetingRecordingSavePolicy.allCases.first { recordingSaveLabel(for: $0) == label }
        if policy == nil {
            assertionFailure("Unexpected recording save label: \(label)")
        }
        return policy
    }
}

// MARK: - Pastable Secure Field (NSViewRepresentable)

/// NSSecureTextField subclass that handles Cmd+V/C/X/A without needing a standard Edit menu.
/// Required because the app runs as .accessory (no menu bar), so key equivalents
/// don't route to text fields by default.
class EditableNSSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// NSPopUpButton wrapper that respects width constraints (SwiftUI Picker with .menu style ignores them).
struct FixedWidthPopUp: NSViewRepresentable {
    let selection: String
    let options: [String]
    /// Reports the selected index, avoiding label collision issues.
    let onSelectionIndex: (Int) -> Void

    init(selection: String, options: [String], onChange: @escaping (String) -> Void) {
        self.selection = selection
        self.options = options
        self.onSelectionIndex = { index in
            guard index >= 0 && index < options.count else { return }
            onChange(options[index])
        }
    }

    init(selection: String, options: [String], onSelectIndex: @escaping (Int) -> Void) {
        self.selection = selection
        self.options = options
        self.onSelectionIndex = onSelectIndex
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.removeAllItems()
        button.addItems(withTitles: options)
        button.selectItem(withTitle: selection)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let currentTitles = button.itemTitles
        if currentTitles != options {
            button.removeAllItems()
            button.addItems(withTitles: options)
        }
        if button.titleOfSelectedItem != selection {
            button.selectItem(withTitle: selection)
        }
        context.coordinator.onSelectionIndex = onSelectionIndex
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectionIndex: onSelectionIndex) }

    class Coordinator: NSObject {
        var onSelectionIndex: (Int) -> Void
        init(onSelectionIndex: @escaping (Int) -> Void) { self.onSelectionIndex = onSelectionIndex }
        @objc func selectionChanged(_ sender: NSPopUpButton) {
            onSelectionIndex(sender.indexOfSelectedItem)
        }
    }
}

/// A text field that supports Cmd+V paste and masks the value when not focused.
struct PastableSecureField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> EditableNSSecureTextField {
        let field = EditableNSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: EditableNSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}

/// Plain text field with the same accessory-app edit shortcuts as secure fields.
struct PastableTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> EditableNSTextField {
        let field = EditableNSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: EditableNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }
}

struct MultilineTextEditor: NSViewRepresentable {
    let text: String
    let placeholder: String
    let minHeight: CGFloat
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.08)
        scrollView.borderType = .bezelBorder

        let textView = NSTextView()
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.backgroundColor = .clear
        textView.allowsUndo = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        context.coordinator.placeholder = placeholder
        context.coordinator.applyPlaceholderIfNeeded(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.placeholder = placeholder
        if !context.coordinator.isShowingPlaceholder, textView.string != text {
            textView.string = text
        }
        context.coordinator.applyPlaceholderIfNeeded(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (String) -> Void
        var placeholder = ""
        var isShowingPlaceholder = false

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, isShowingPlaceholder else { return }
            isShowingPlaceholder = false
            textView.string = ""
            textView.textColor = .labelColor
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            applyPlaceholderIfNeeded(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isShowingPlaceholder else { return }
            onChange(textView.string)
        }

        func applyPlaceholderIfNeeded(_ textView: NSTextView) {
            let isFirstResponder = textView.window?.firstResponder === textView
            guard textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isFirstResponder else { return }
            isShowingPlaceholder = true
            textView.string = placeholder
            textView.textColor = .placeholderTextColor
        }
    }
}

private extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            self = .black; return
        }
        self = Color(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8)  & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }
}

private extension NSColor {
    func toHexString() -> String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent   * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent  * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }
}

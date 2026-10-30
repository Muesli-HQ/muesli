import AppKit
import AVFoundation
import SwiftUI
import MuesliCore
import TelemetryDeck
import UniformTypeIdentifiers

private struct MicrophoneOption: Identifiable {
    let uid: String?
    let label: String

    var id: String { uid ?? "__automatic__" }
}

enum SettingsPermissionRefreshReason {
    case initialDisplay
    case permissionRequested
    case settingsSelected
    case appActivated

    var refreshesLaunchAtLogin: Bool {
        self == .appActivated
    }

    var refreshesSystemAudio: Bool {
        switch self {
        case .initialDisplay, .settingsSelected, .appActivated:
            true
        case .permissionRequested:
            false
        }
    }
}

struct ICloudLinkedDevicePresentation: Equatable {
    let name: String
    let platformLabel: String
    let systemImage: String

    init(name: String, platform: String?) {
        self.name = name
        switch platform?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ipados":
            platformLabel = "iPad"
            systemImage = "ipad"
        case "ios":
            platformLabel = "iPhone"
            systemImage = "iphone.gen3"
        default:
            platformLabel = "Device"
            systemImage = "iphone.gen3"
        }
    }
}

private struct ICloudLinkedDeviceRow: View {
    let device: ICloudLinkedDevicePresentation

    var body: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: device.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 30, height: 30)
                .background(MuesliTheme.accentSubtle)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                Text("\(device.platformLabel) · Linked")
                    .font(MuesliTheme.metadata())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MuesliTheme.success)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 6)
        .background(MuesliTheme.success.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.success.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.platformLabel) \(device.name), linked")
    }
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

    let appState: AppState
    let controller: MuesliController
    @ObservedObject private var cotypist = CotypistSetup.shared

    private enum OpenAIConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    @State private var chatGPTSignInError: String?
    @State private var isSigningInChatGPT = false
    @State private var openRouterSignInError: String?
    @State private var isSigningInOpenRouter = false
    @State private var claudeCodeAuthStatus: ClaudeCodeAuthenticationStatus?
    @State private var claudeCodeSignInError: String?
    @State private var isShowingInvalidClaudeCodeExecutableAlert = false
    @State private var isWaitingForClaudeCodeSignIn = false
    @State private var isShowingClaudeCodeAdvanced = false
    @State private var isShowingSummaryOutputAdvanced = false
    @State private var isEnteringOpenRouterAPIKey = false
    @State private var manualOpenRouterAPIKey = ""
    @State private var pendingDataDestruction: PendingDataDestruction?
    @State private var isShowingDictionaryAccessibilityPrompt = false
    @State private var isPreviewingClip = false
    @State private var selectedPane: SettingsPane
    @State private var downloadedBackendOptions: [BackendOption] = []
    @State private var downloadedPostProcOptions: [PostProcessorOption] = []
    @State private var downloadedMeetingLiveCaptionBackends: [MeetingLiveCaptionBackend] = []
    @State private var audioInputDevices: [AudioInputDeviceInfo] = []
    @State private var audioInputDeviceRefreshTask: Task<Void, Never>?
    @State private var permissionMonitoringClientID = UUID()
    @State private var isCleanupPromptManagerPresented = false
    @AppStorage("settings.pendingScreenContextEnable") private var pendingScreenContextEnable = false
    @AppStorage("settings.pendingScreenContextRequestedAt") private var pendingScreenContextRequestedAt = 0.0
    @State private var systemAudioGranted = false
    @State private var isCheckingSystemAudioPermission = false
    @State private var calendarPermission = CalendarPermissionState()
    @State private var calendarSourcesRefresh = CalendarSourceRefreshState()
    @State private var isShowingICloudSyncReconnectConfirmation = false
    @State private var isShowingICloudSyncResetConfirmation = false
    @State private var isShowingIPhoneBridgeQRCode = false
    @State private var openAIDictationAPIKey: String = ""
    @State private var openAITestState: OpenAIConnectionTestState = .idle
    @State private var stacksSettingsControls = false

    init(appState: AppState, controller: MuesliController) {
        self.appState = appState
        self.controller = controller
        _selectedPane = State(initialValue: appState.selectedSettingsPane)
    }

    private var micGranted: Bool {
        appState.interactionPermissionSnapshot?.microphone ?? false
    }

    private var accessibilityGranted: Bool {
        appState.interactionPermissionSnapshot?.accessibility ?? false
    }

    private var inputMonitoringGranted: Bool {
        appState.interactionPermissionSnapshot?.inputMonitoring ?? false
    }

    private var screenRecordingGranted: Bool {
        appState.interactionPermissionSnapshot?.screenRecording ?? false
    }

    // Uniform width for menus and fields; switches use `settingsCompactRow`.
    private let controlWidth = SettingsLayout.controlWidth
    // Model/provider rows use the same default as every other settings control.
    private var meetingControlWidth: CGFloat { controlWidth }

    private var dictationBackendOptions: [BackendOption] {
        guard appState.dictationProvider.isHosted else {
            return backendOptions(including: appState.selectedBackend)
        }
        return downloadedBackendOptions.filter(\.supportsHostedDictationFallback)
    }

    private var displayedDictationBackend: BackendOption? {
        guard appState.dictationProvider.isHosted else { return appState.selectedBackend }
        return BackendOption.resolveHostedDictationFallback(
            selected: appState.selectedBackend,
            available: dictationBackendOptions
        )
    }

    private var disabledDictationBackendLabels: Set<String> {
        guard !appState.selectedPostProcessorBackend.isCompatible(with: .gemma4E2BLiteRT),
              dictationBackendOptions.contains(where: { $0.backend == "gemma4-litert" }) else { return [] }
        return Set(dictationBackendOptions.filter { $0.backend == "gemma4-litert" }.map(\.label))
    }

    private var meetingBackendOptions: [BackendOption] {
        downloadedBackendOptions.filter(\.supportsMeetingTranscription)
    }

    private var selectedMeetingLiveCaptionLabel: String {
        let selected = appState.config.resolvedMeetingLiveCaptionBackend
        guard appState.config.enableLiveStreamingPartials,
              downloadedMeetingLiveCaptionBackends.contains(selected) else {
            return "Off"
        }
        return selected.settingsLabel
    }

    private var usesUnifiedMeetingTranscript: Bool {
        appState.config.enableLiveStreamingPartials
            && appState.config.resolvedMeetingLiveCaptionBackend.producesFinalTranscript
            && downloadedMeetingLiveCaptionBackends.contains(appState.config.resolvedMeetingLiveCaptionBackend)
    }

    private var meetingLiveTranscriptDescription: String {
        let selected = appState.config.resolvedMeetingLiveCaptionBackend
        guard appState.config.enableLiveStreamingPartials,
              downloadedMeetingLiveCaptionBackends.contains(selected) else {
            return "Shows completed transcript segments only."
        }
        if usesUnifiedMeetingTranscript {
            return "Creates the live and final transcript."
        }
        if selected == .selectedModelBuffered {
            guard appState.selectedMeetingTranscriptionBackend.supportsBufferedLiveTranscription else {
                return "Choose Parakeet or Whisper as the final model to enable this preview."
            }
            return "Previews the selected Parakeet or Whisper model while recording. Completed segments remain authoritative."
        }
        return "Adds a low-latency preview."
    }

    private var selectedMeetingBackendLabel: String {
        if meetingBackendOptions.contains(appState.selectedMeetingTranscriptionBackend) {
            return appState.selectedMeetingTranscriptionBackend.label
        }
        return meetingBackendOptions.first?.label ?? "No downloaded models"
    }

    private var cleanupPromptPresets: [TranscriptCleanupPromptPreset] {
        TranscriptCleanupPrompts.presets(custom: appState.config.customTranscriptCleanupPrompts)
    }

    private var cleanupBackendOptions: [TranscriptCleanupBackendOption] {
        TranscriptCleanupBackendOption.all.filter { !$0.isGemma4LiteRT }
    }

    private var selectedQuilBackend: TranscriptCleanupBackendOption {
        TranscriptCleanupBackendOption.resolved(appState.config.quilBackend)
    }

    private var selectedQuilModelSource: QuilModelSourceOption {
        QuilModelSourceOption.resolved(for: selectedQuilBackend)
    }

    private var quilLocalModels: [OnDeviceCleanupModel] {
        var models = downloadedPostProcOptions
            .filter(\.supportsQuil)
            .map(OnDeviceCleanupModel.gguf)
        for model in Gemma4LiteRTModel.generalPurpose where Gemma4LiteRTModelStore.isAvailableLocally(model: model) {
            models.append(.gemma4(model))
        }
        return models
    }

    private var selectedQuilLocalModelLabel: String {
        if selectedQuilBackend == .gemma4LiteRT {
            return Gemma4LiteRTModel.resolved(appState.config.quilModel).label
        }
        return quilLocalModels.first(where: { $0.id == appState.config.quilModel })?.quilLabel
            ?? quilLocalModels.first?.quilLabel
            ?? "No compatible model"
    }

    private var selectedCleanupBackendLabel: String {
        appState.selectedPostProcessorBackend.isOnDevice
            ? TranscriptCleanupBackendOption.local.label
            : appState.selectedPostProcessorBackend.label
    }

    private var onDeviceCleanupModels: [OnDeviceCleanupModel] {
        var models = downloadedPostProcOptions
            .filter { $0.isCompatible(with: appState.selectedBackend) }
            .map(OnDeviceCleanupModel.gguf)
        if TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: appState.selectedBackend) {
            for model in Gemma4LiteRTModel.allCases where Gemma4LiteRTModelStore.isAvailableLocally(model: model) {
                models.append(.gemma4(model))
            }
        }
        return models
    }

    private var selectedOnDeviceCleanupModelLabel: String {
        if appState.selectedPostProcessorBackend == .gemma4LiteRT {
            return Gemma4LiteRTModel.resolved(appState.config.postProcessorGemmaModel).label
        }
        let selectedID = appState.activePostProcessor.id
        return onDeviceCleanupModels.first(where: { $0.id == selectedID })?.label
            ?? onDeviceCleanupModels.first?.label
            ?? ""
    }

    private var selectedCleanupPromptName: String {
        cleanupPromptPresets.first { $0.id == appState.config.activeTranscriptCleanupPromptId }?.name
            ?? TranscriptCleanupPrompts.builtIns[0].name
    }

    private var cleanupModelUsesFixedPrompt: Bool {
        (appState.selectedPostProcessorBackend == .local
            && appState.activePostProcessor.inputFormat != .configurable)
            || (appState.selectedPostProcessorBackend == .gemma4LiteRT
                && Gemma4LiteRTModel.resolved(appState.config.postProcessorGemmaModel).isCleanupOnly)
    }

    private var gemmaCleanupIsUnavailable: Bool {
        Gemma4LiteRTModel.allCases.contains { Gemma4LiteRTModelStore.isAvailableLocally(model: $0) }
            && !TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: appState.selectedBackend)
    }

    private var cleanupBackendDescription: String {
        if appState.selectedPostProcessorBackend.isOnDevice {
            return onDeviceCleanupModels.isEmpty
                ? "Download a cleanup model from Models to refine dictations on this Mac."
                : "Refines dictated text on this Mac."
        }
        return "Sends dictated text to \(appState.selectedPostProcessorBackend.label) and may add latency."
    }

    private var selectedCohereLanguage: CohereTranscribeLanguage {
        appState.config.resolvedCohereLanguage
    }

    private var selectedUpcomingMeetingsWindow: UpcomingMeetingsWindow {
        appState.config.upcomingMeetingsWindow
    }

    private var selectedBodhanLanguage: BodhanLanguage {
        appState.config.resolvedBodhanLanguage
    }

    private var selectedNemotron35Language: Nemotron35Language {
        appState.config.resolvedNemotron35Language
    }
    private var selectedWhisperLanguage: WhisperKitLanguage {
        appState.config.resolvedWhisperLanguage
    }

    private var dictationMicrophoneOptions: [MicrophoneOption] {
        microphoneOptions(selectedUID: appState.config.dictationInputDeviceUID)
    }

    private var selectedDictationMicrophoneLabel: String {
        let selectedUID = appState.config.dictationInputDeviceUID
        return dictationMicrophoneOptions.first(where: { $0.uid == selectedUID })?.label ?? "Automatic"
    }

    private var meetingMicrophoneOptions: [MicrophoneOption] {
        microphoneOptions(selectedUID: appState.config.meetingInputDeviceUID)
    }

    private var selectedMeetingMicrophoneLabel: String {
        let selectedUID = appState.config.meetingInputDeviceUID
        return meetingMicrophoneOptions.first(where: { $0.uid == selectedUID })?.label ?? "Automatic"
    }

    private func microphoneOptions(selectedUID: String?) -> [MicrophoneOption] {
        var options = [MicrophoneOption(uid: nil, label: "Automatic")]
        options += audioInputDevices.map { MicrophoneOption(uid: $0.uid, label: $0.name) }
        if let selectedUID, !options.contains(where: { $0.uid == selectedUID }) {
            options.append(MicrophoneOption(uid: selectedUID, label: "Selected microphone unavailable"))
        }
        return options
    }

    private var activeFeatureTourTarget: FeatureTourTarget? {
        appState.activeFeatureTourTarget
    }

    var body: some View {
        // Build once for this surface; Observation refreshes dynamic choices.
        let _ = appState.config
        return settingsContent.environment(\.muesliSettingDefinitions, controller.settingsDefinitions())
    }

    private var settingsContent: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                    Text("Settings")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    settingsPanePicker
                    paneContent
                }
                .background {
                    // One page-level breakpoint; individual rows do not measure themselves.
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { updateSettingsControlStacking(contentWidth: proxy.size.width) }
                            .onChange(of: proxy.size.width) { _, width in
                                updateSettingsControlStacking(contentWidth: width)
                            }
                    }
                }
                .environment(\.settingsStacksControls, stacksSettingsControls)
                .padding(.horizontal, MuesliTheme.spacing32)
            .padding(.top, MuesliTheme.pageTop)
            .padding(.bottom, MuesliTheme.spacing32)
            }
            .background(MuesliTheme.backgroundBase)
            .onAppear {
                refreshDownloadedModelOptions()
                refreshAudioInputDevices()
                startPermissionMonitoring()
                if appState.selectedMeetingSummaryBackend == .openRouter {
                    loadOpenRouterFreeModelsIfNeeded()
                }
                if appState.dictationProvider == .openRouter,
                   controller.hostedDictationModelVisibility.shows(.openRouter) {
                    loadOpenRouterTranscriptionModelsIfNeeded()
                }
                scrollToFeatureTourTarget(activeFeatureTourTarget, using: scrollProxy)
            }
            .onDisappear {
                SoundController.stopMaraudersMapClip()
                isPreviewingClip = false
                audioInputDeviceRefreshTask?.cancel()
                audioInputDeviceRefreshTask = nil
                stopPermissionMonitoring()
            }
            .onChange(of: appState.selectedTab) { _, tab in
                if tab == .settings {
                    selectedPane = appState.selectedSettingsPane
                    refreshDownloadedModelOptions()
                    refreshAudioInputDevices()
                    refreshPermissionStatuses(for: .settingsSelected)
                }
            }
            .onChange(of: appState.selectedSettingsPane) { _, pane in
                selectedPane = pane
            }
            .onChange(of: selectedPane) { _, pane in
                appState.selectedSettingsPane = pane
                calendarPermission.refresh()
                if pane == .dictation || pane == .meetings {
                    loadCachedAudioInputDevices()
                }
                scrollToFeatureTourTarget(activeFeatureTourTarget, using: scrollProxy)
            }
            .onChange(of: activeFeatureTourTarget) { _, target in
                scrollToFeatureTourTarget(target, using: scrollProxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard appState.selectedTab == .settings else { return }
                refreshAudioInputDevices()
                refreshPermissionStatuses(for: .appActivated)
                if selectedPane == .meetings {
                    if appState.selectedMeetingSummaryBackend == .claudeCode {
                        Task { await refreshClaudeCodeAuthStatus() }
                    }
                }
                if selectedPane == .general || selectedPane == .meetings {
                    refreshCalendarSources(reconcileAccess: true)
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
                } else if backend == .claudeCode {
                    Task { await refreshClaudeCodeAuthStatus() }
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
            .alert(
                "Enable Accessibility?",
                isPresented: $isShowingDictionaryAccessibilityPrompt
            ) {
                Button("Cancel", role: .cancel) {
                    controller.cancelDictionaryCorrectionAccessibilityEnableRequest()
                }
                Button("Enable") {
                    controller.requestDictionaryCorrectionAccessibilityEnable()
                }
            } message: {
                Text("Dictionary suggestions briefly read focused app text via Accessibility after dictation. Grant access, then relaunch muesli to turn suggestions on.")
            }
            .alert("Reconnect iCloud sync?", isPresented: $isShowingICloudSyncReconnectConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reconnect") {
                    controller.reconnectICloudSyncToCurrentAccount()
                }
            } message: {
                Text("Reconnect with this iCloud account. Local history and audio stay on this Mac.")
            }
            .alert("Reset iCloud sync?", isPresented: $isShowingICloudSyncResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset sync", role: .destructive) {
                    controller.resetICloudSync()
                }
            } message: {
                Text("Clear this Mac's sync connection and set it up again. Local history, audio, and CloudKit data won't be deleted.")
            }
            .sheet(isPresented: $isShowingIPhoneBridgeQRCode, onDismiss: {
                controller.cancelIPhoneBridgeDeviceDiscovery()
            }) {
                IPhoneBridgeQRCodeSheet(
                    deepLinkURL: IPhoneBridgeLinks.iOSSyncDeepLinkURL,
                    installURL: IPhoneBridgeLinks.installURL,
                    isWaitingForDevice: appState.iCloudBridgeCompanionDiscoveryState == .waiting
                )
            }
            .onChange(of: syncQRCodePresentationPhase) { _, phase in
                guard phase == .dismiss else { return }
                isShowingIPhoneBridgeQRCode = false
                TelemetryDeck.signal("bridge_qr_auto_dismissed", parameters: ["platform": "macos_settings"])
            }
            .sheet(isPresented: $isCleanupPromptManagerPresented) {
                TranscriptCleanupPromptsManagerView(
                    appState: appState,
                    controller: controller,
                    onClose: { isCleanupPromptManagerPresented = false }
                )
            }
        }

    }

    private func scrollToFeatureTourTarget(_ target: FeatureTourTarget?, using proxy: ScrollViewProxy) {
        guard let target,
              target == .liveCaptionsSetting
                || target == .cloudCleanupSetting
                || target == .dictationProviderSetting
                || target == .recordingIndicatorStyle
                || target == .meetingSummaryProvider
                || target == .quillSettings else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target.rawValue, anchor: .center)
            }
        }
    }

    private func updateSettingsControlStacking(contentWidth: CGFloat) {
        let stacks = contentWidth < SettingsLayout.stackedContentWidth
        if stacksSettingsControls != stacks { stacksSettingsControls = stacks }
    }

    private func refreshDownloadedModelOptions() {
        controller.refreshMeetingTranscriptionSelectionForAvailability()
        // Only write changed values. Unconditional writes from onAppear re-render Settings
        // and can feed a SwiftUI update loop (#632).
        let backends = BackendOption.downloaded
        if downloadedBackendOptions != backends { downloadedBackendOptions = backends }
        let postProcessors = PostProcessorOption.downloaded
        if downloadedPostProcOptions != postProcessors { downloadedPostProcOptions = postProcessors }
        let liveCaptionBackends = MeetingLiveCaptionBackend.allCases.filter(\.isDownloaded)
        if downloadedMeetingLiveCaptionBackends != liveCaptionBackends {
            downloadedMeetingLiveCaptionBackends = liveCaptionBackends
        }
    }

    private func refreshAudioInputDevices() {
        loadCachedAudioInputDevices()
        audioInputDeviceRefreshTask?.cancel()
        audioInputDeviceRefreshTask = Task { @MainActor in
            let devices = await controller.refreshDictationInputDevices()
            guard !Task.isCancelled else { return }
            audioInputDevices = devices
        }
    }

    private func loadCachedAudioInputDevices() {
        audioInputDevices = controller.cachedDictationInputDevices()
    }

    private func backendOptions(including selection: BackendOption) -> [BackendOption] {
        var options = downloadedBackendOptions
        if !options.contains(where: { $0 == selection }) {
            options.insert(selection, at: 0)
        }
        return options
    }

    private func screenContextDescription(includesScreenOCR: Bool) -> String {
        if !accessibilityGranted {
            return "Grant Accessibility, then toggle again if needed."
        }
        if includesScreenOCR, !screenRecordingGranted {
            return "Adds nearby app text for post-processing. Screen Recording enables OCR context."
        }
        if includesScreenOCR {
            return "Adds nearby app text and OCR context."
        }
        return "Adds nearby app text for post-processing."
    }

    private var dictationOCRContextDescription: String {
        if !appState.config.enableScreenContext {
            return "Turn on App context first."
        }
        if !screenRecordingGranted {
            return "Grant Screen Recording to add frontmost-window OCR text."
        }
        return "Adds frontmost-window OCR text. Cloud cleanup may send this text to the selected provider."
    }

    private func screenContextRow(_ title: String, includesScreenOCR: Bool = false) -> some View {
        settingsCompactRow(title, description: screenContextDescription(includesScreenOCR: includesScreenOCR)) {
            screenContextControl()
        }
    }

    private var dictationOCRContextRow: some View {
        settingsCompactRow("Screen OCR context", description: dictationOCRContextDescription) {
            dictationOCRContextControl()
        }
    }

    private let customIndicatorPositionLabel = "Custom (drag to reposition)"

    private var settingsPanePicker: some View {
        HStack {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                Picker("Settings section", selection: $selectedPane) {
                    ForEach(SettingsPane.allCases) { pane in
                        Text(pane.title).tag(pane)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)

                Picker("Settings section", selection: $selectedPane) {
                    ForEach(SettingsPane.allCases) { pane in
                        Text(pane.title).tag(pane)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: SettingsLayout.controlWidth)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalSettingsPane
        case .dictation:
            dictationSettingsPane
        case .meetings:
            meetingsSettingsPane
        case .appearance:
            appearanceSettingsPane
        case .experimental:
            experimentalSettingsPane
        }
    }

    private var generalSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("General") {
                settingsCompactRow("Launch at login") {
                    settingsControl("launch_at_login")
                }
                if appState.launchAtLoginRegistrationState == .requiresApproval {
                    launchAtLoginApprovalPrompt
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Open dashboard on launch") {
                    settingsControl("open_dashboard")
                }
            }

            syncSettingsPane

            permissionsSection

            settingsSection("Local storage") {
                LocalStorageUsageView()
            }

            settingsSection("Data") {
                HStack(spacing: MuesliTheme.spacing12) {
                    compactActionButton("Clear dictation history", role: .destructive) {
                        pendingDataDestruction = .dictations
                    }
                    compactActionButton("Clear meeting history", role: .destructive) {
                        pendingDataDestruction = .meetings
                    }
                    .disabled(controller.isMeetingRecording())
                    .help("Stop the current meeting recording before clearing meeting history.")
                }
            }
        }
    }

    private var launchAtLoginApprovalPrompt: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.recording)
            SettingsNote("Requires approval in System Settings")
            Spacer(minLength: MuesliTheme.spacing12)
            accentActionButton("Open", systemImage: "arrow.up.forward.square") {
                controller.openLaunchAtLoginSettings()
            }
            .help("Open Login Items in System Settings")
        }
        .padding(.bottom, MuesliTheme.spacing8)
    }

    private var syncSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("iCloud Sync") {
                if stacksSettingsControls {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                        syncStatusDetails
                        syncFlowControls
                            .frame(maxWidth: controlWidth)
                    }
                } else {
                    HStack(alignment: .top, spacing: SettingsLayout.columnSpacing) {
                        syncStatusDetails
                            .frame(maxWidth: .infinity, alignment: .leading)
                        syncFlowControls
                            .frame(width: controlWidth)
                    }
                }
            }
        }
    }

    private var syncStatusDetails: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text("Sync with iPhone or iPad")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            SettingsNote(syncStatusText)
            if let lastSyncedText = syncLastSyncedText {
                SettingsNote("Last synced: \(lastSyncedText)")
            }
            if let linkedDevice = syncLinkedDevice {
                ICloudLinkedDeviceRow(device: linkedDevice)
                    .padding(.top, MuesliTheme.spacing4)
            } else if let unlinkedDeviceText = syncUnlinkedDeviceText {
                SettingsNote(unlinkedDeviceText)
            }
        }
    }

    @ViewBuilder
    private var syncFlowControls: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            switch syncFlowAction {
            case .setUp:
                actionButton("Set up sync", systemImage: "icloud") {
                    showSyncSetupQRCode(source: "macos_settings_setup")
                    controller.enableIPhoneBridgeSync()
                }
            case .continueSetup:
                actionButton("Continue setup", systemImage: "qrcode") {
                    showSyncSetupQRCode(source: "macos_settings_continue")
                    controller.enableIPhoneBridgeSync()
                }
            case .connectDevice:
                actionButton("Connect device", systemImage: "qrcode") {
                    showSyncSetupQRCode(source: "macos_settings")
                }
            case .waitingForDevice:
                actionButton("Checking…", systemImage: "arrow.triangle.2.circlepath") {}
                    .disabled(true)
            case .syncNow:
                actionButton("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                    controller.performICloudSync()
                }
            case .reconnect:
                actionButton("Reconnect", systemImage: "arrow.triangle.2.circlepath") {
                    isShowingICloudSyncReconnectConfirmation = true
                }
            case .reset:
                actionButton("Reset sync", systemImage: "arrow.counterclockwise.icloud") {
                    isShowingICloudSyncResetConfirmation = true
                }
            case .retry:
                actionButton("Try again", systemImage: "arrow.triangle.2.circlepath") {
                    controller.enableIPhoneBridgeSync()
                }
            case .working:
                actionButton("Working…", systemImage: "arrow.triangle.2.circlepath") {}
                    .disabled(true)
            }

            if shouldOfferICloudSyncReset {
                actionButton("Reset sync", systemImage: "arrow.counterclockwise.icloud") {
                    isShowingICloudSyncResetConfirmation = true
                }
            }
        }
    }

    private func showSyncSetupQRCode(source: String) {
        isShowingIPhoneBridgeQRCode = true
        controller.beginIPhoneBridgeDeviceDiscovery()
        TelemetryDeck.signal("bridge_qr_shown", parameters: ["platform": source])
    }

    private var syncFlowAction: ICloudSyncFlowAction {
        ICloudSyncFlowPolicy.action(
            for: displayedICloudBridgeState,
            isEnabled: appState.config.iCloudSyncEnabled,
            hasCompanionDevice: appState.iCloudBridgeCompanionDeviceName != nil,
            companionDiscoveryState: appState.iCloudBridgeCompanionDiscoveryState
        )
    }

    private var syncQRCodePresentationPhase: ICloudSyncQRCodePresentationPhase {
        ICloudSyncQRCodePresentationPolicy.phase(
            isPresented: isShowingIPhoneBridgeQRCode,
            hasCompanionDevice: appState.iCloudBridgeCompanionDeviceName != nil
        )
    }

    private var displayedICloudBridgeState: ICloudBridgeState {
        appState.iCloudBridgeState
    }

    private var syncStatusText: String {
        switch displayedICloudBridgeState {
        case .checkingICloud:
            return "Checking iCloud…"
        case .syncing:
            if appState.isICloudBridgeActivationPending {
                return appState.iCloudBridgeCompanionDeviceName == nil
                    ? "Setting up sync…"
                    : "Device linked. Finishing sync…"
            }
            return "Syncing…"
        case .needsICloud:
            return "Sign in to iCloud to sync."
        case .needsReconnection:
            if ICloudSyncRecoveryPolicy.action(for: appState.iCloudBridgeState) == .resetAccountLink {
                return "Reset sync to start again."
            }
            return "Reconnect to keep syncing."
        case .needsAccountReplacement:
            return "Reset sync to use this iCloud account."
        case .error:
            return appState.iCloudBridgeCompanionDeviceName == nil
                ? "Setup was interrupted. Continue to pair your device."
                : "Sync couldn't finish. Try again."
        case .active:
            guard appState.config.iCloudSyncEnabled else { return "Sync is off." }
            if appState.iCloudBridgeCompanionDeviceName != nil {
                return "Sync is on. Audio stays on this Mac."
            }
            switch appState.iCloudBridgeCompanionDiscoveryState {
            case .waiting:
                return "Finishing device setup…"
            case .timedOut:
                return "Couldn't find your device. Open muesli there, then try again."
            case .idle:
                return "Ready to connect. Audio stays on this Mac."
            }
        case .notConfigured:
            return "Set up private iCloud text sync."
        }
    }

    private var syncLastSyncedText: String? {
        guard let date = appState.iCloudLastSyncedAt else { return nil }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private var syncLinkedDevice: ICloudLinkedDevicePresentation? {
        guard let remoteDeviceName = appState.iCloudBridgeCompanionDeviceName else { return nil }
        return ICloudLinkedDevicePresentation(
            name: remoteDeviceName,
            platform: appState.iCloudBridgeRemoteDevicePlatform
        )
    }

    private var syncUnlinkedDeviceText: String? {
        // While active, `syncStatusText` already describes device discovery.
        guard appState.config.iCloudSyncEnabled, displayedICloudBridgeState != .active else { return nil }
        switch appState.iCloudBridgeCompanionDiscoveryState {
        case .waiting:
            return "Waiting for iPhone or iPad…"
        case .timedOut:
            return "No device found yet."
        case .idle:
            return "No linked device yet."
        }
    }

    private var shouldOfferICloudSyncReset: Bool {
        appState.config.iCloudSyncEnabled
            && displayedICloudBridgeState == .active
            && (syncFlowAction == .syncNow || syncFlowAction == .connectDevice)
    }

    private var dictationModelSettingsSection: some View {
        settingsSection("Speech Recognition") {
            settingsRow("Provider", controlWidth: meetingControlWidth) {
                settingsControl("dictation_provider")
            }
            .id(FeatureTourTarget.dictationProviderSetting.rawValue)
            .featureTourTarget(.dictationProviderSetting)
            Divider().background(MuesliTheme.surfaceBorder)
            if appState.dictationProvider == .openAI {
                openAIDictationSettingsRows
                Divider().background(MuesliTheme.surfaceBorder)
            } else if appState.dictationProvider == .openRouter {
                openRouterDictationSettingsRows
                Divider().background(MuesliTheme.surfaceBorder)
            }
            settingsRow(
                appState.dictationProvider.isHosted ? "Fallback model" : "Dictation model",
                description: dictationModelDescription,
                controlWidth: meetingControlWidth
            ) {
                if displayedDictationBackend != nil {
                    settingsControl(appState.dictationProvider.isHosted ? "dictation_fallback_model" : "dictation_model")
                } else {
                    Text("No compatible model installed")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }
            if appState.dictationProvider == .local,
               displayedDictationBackend?.supportsBufferedLiveTranscription == true {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow(
                    "Watch text appear during hands-free mode",
                    description: "Preview as you speak; apply enabled cleanup when you stop."
                ) {
                    settingsControl("buffered_live_dictation")
                }
            }
            if displayedDictationBackend?.backend == BackendOption.cohereTranscribe.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Cohere language", controlWidth: meetingControlWidth) {
                    cohereLanguageMenu
                }
            }
            if displayedDictationBackend?.backend == BackendOption.bodhanFlex.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Bodhan language", controlWidth: meetingControlWidth) {
                    indicLanguageMenu(model: displayedDictationBackend?.model ?? "")
                }
                bodhanOutputMenu(model: displayedDictationBackend?.model ?? "")
            }
            if displayedDictationBackend?.supportsWhisperLanguageSelection == true {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Whisper language", controlWidth: meetingControlWidth) {
                    whisperLanguageMenu(model: displayedDictationBackend?.model ?? appState.config.sttModel)
                }
            }
        }
    }

    private var dictationModelDescription: String? {
        var notes: [String] = []
        if appState.dictationProvider.isHosted {
            notes.append(displayedDictationBackend == nil
                ? "Download a non-streaming local model to enable automatic fallback."
                : "Used automatically if \(appState.dictationProvider.label) transcription fails.")
        }
        if !disabledDictationBackendLabels.isEmpty {
            notes.append("Gemma 4 dictation is unavailable while Gemma 4 is the cleanup backend.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    @ViewBuilder
    private var openAIDictationSettingsRows: some View {
        settingsRow("API Key", controlWidth: meetingControlWidth) {
            PastableSecureField(
                text: appState.config.openAIAPIKey,
                placeholder: "sk-...",
                onChange: { val in
                    openAITestState = .idle
                    controller.setOpenAIDictationAPIKey(val)
                }
            )
            .frame(height: 22)
        }
        if controller.hostedDictationModelVisibility.shows(.openAI) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Model", controlWidth: meetingControlWidth) {
                settingsControl("openai_dictation_model")
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Connection", controlWidth: meetingControlWidth) {
                openAITestControl
            }
            if case .failed(let message) = openAITestState {
                SettingsNote(message, tone: .error)
                    .padding(.bottom, MuesliTheme.spacing4)
            }
        }
    }

    private var openAIDictationModelPresets: [SummaryModelPreset] {
        OpenAITranscriptionClient.modelPresets.map { SummaryModelPreset(id: $0, label: $0) }
    }

    @ViewBuilder
    private var openRouterDictationSettingsRows: some View {
        settingsRow("Account", controlWidth: meetingControlWidth) {
            openRouterAccountControl(selectMeetingSummaryBackend: false)
        }
        if controller.hostedDictationModelVisibility.shows(.openRouter) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Model", controlWidth: meetingControlWidth) {
                openRouterTranscriptionModelMenu
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Custom model ID", controlWidth: meetingControlWidth) {
                settingsModelTextField(
                    currentModel: appState.config.openRouterDictationModel,
                    placeholder: "provider/model"
                ) { controller.selectOpenRouterDictationModel($0) }
            }
        }
    }

    @ViewBuilder
    private var openAITestControl: some View {
        switch openAITestState {
        case .idle:
            HStack {
                Spacer()
                compactActionButton("Test connection") {
                    testOpenAIConnection()
                }
            }
        case .testing:
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Testing…")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        case .success:
            HStack(spacing: 6) {
                Spacer()
                Circle()
                    .fill(MuesliTheme.success)
                    .frame(width: 6, height: 6)
                Text("Connected")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.success)
                compactActionButton("Test again") {
                    testOpenAIConnection()
                }
            }
        case .failed:
            // The failure message is shown in full beneath the row.
            HStack(spacing: 6) {
                Spacer()
                Text("Failed")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.recording)
                compactActionButton("Retry") {
                    testOpenAIConnection()
                }
            }
        }
    }

    private func testOpenAIConnection() {
        openAITestState = .testing
        Task {
            do {
                try await controller.testOpenAIConnection()
                await MainActor.run { openAITestState = .success }
            } catch {
                await MainActor.run { openAITestState = .failed(error.localizedDescription) }
            }
        }
    }

    private var meetingTranscriptionSettingsSection: some View {
        settingsSection("Transcription") {
            settingsRow(
                "Microphone",
                description: "Only affects muesli. Changes apply immediately.",
                controlWidth: meetingControlWidth
            ) {
                settingsControl("meeting_microphone")
                .frame(height: 24)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsCompactRow(
                "Show transcript on hover",
                description: "Over the recording pill or notch."
            ) {
                settingsControl("meeting_hover_transcript")
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow(
                "Live transcript model",
                description: meetingLiveTranscriptDescription,
                controlWidth: meetingControlWidth
            ) {
                if !downloadedMeetingLiveCaptionBackends.isEmpty {
                    settingsControl("live_transcript")
                } else {
                    Text("Download from Models")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }
            .id(FeatureTourTarget.liveCaptionsSetting.rawValue)
            .featureTourTarget(.liveCaptionsSetting)
            Divider().background(MuesliTheme.surfaceBorder)
            settingsCompactRow(
                "Identify in-room speakers",
                description: "Speaker playback may cause duplicate labels; headphones help."
            ) {
                settingsControl("diarize_microphone")
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Final transcript", controlWidth: meetingControlWidth) {
                if usesUnifiedMeetingTranscript {
                    Text("\(appState.config.resolvedMeetingLiveCaptionBackend.label) (same model)")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                } else if meetingBackendOptions.isEmpty {
                    Text("No downloaded models")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                } else {
                    settingsControl("meeting_model")
                }
            }
            if usesUnifiedMeetingTranscript {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Language", controlWidth: meetingControlWidth) {
                    if appState.config.resolvedMeetingLiveCaptionBackend == .nemotron35 {
                        nemotron35LanguageMenu
                    } else {
                        Text("Set in Models → Apple Speech")
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.cohereTranscribe.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Cohere language", controlWidth: meetingControlWidth) {
                    cohereLanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.bodhanFlex.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Bodhan language", controlWidth: meetingControlWidth) {
                    indicLanguageMenu(model: appState.selectedMeetingTranscriptionBackend.model)
                }
                bodhanOutputMenu(model: appState.selectedMeetingTranscriptionBackend.model)
            } else if appState.selectedMeetingTranscriptionBackend.supportsWhisperLanguageSelection {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Whisper language", controlWidth: meetingControlWidth) {
                    whisperLanguageMenu(model: appState.selectedMeetingTranscriptionBackend.model)
                }
            }
        }
    }

    private var dictationCleanupSettingsSection: some View {
        settingsSection("Dictation Cleanup") {
            settingsCompactRow("AI transcript cleanup") {
                settingsControl("transcript_cleanup")
            }
            if appState.config.enablePostProcessor {
                Divider().background(MuesliTheme.surfaceBorder)
                if cleanupModelUsesFixedPrompt {
                    fixedCleanupPromptNotice
                } else {
                    cleanupPromptSettings
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "Cleanup source",
                    description: cleanupBackendDescription,
                    controlWidth: meetingControlWidth
                ) {
                    settingsControl("cleanup_source")
                }
                .id(FeatureTourTarget.cloudCleanupSetting.rawValue)
                .featureTourTarget(.cloudCleanupSetting)
                if appState.selectedPostProcessorBackend.isOnDevice {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow(
                        "Cleanup model",
                        description: gemmaCleanupIsUnavailable
                            ? "Gemma 4 is unavailable for cleanup while a Gemma 4 model is selected for dictation."
                            : nil,
                        controlWidth: meetingControlWidth
                    ) {
                        if onDeviceCleanupModels.isEmpty {
                            compactActionButton("View cleanup models", systemImage: "arrow.right") {
                                controller.showModels(category: .postProcessing)
                            }
                        } else {
                            settingsControl("cleanup_on_device_model")
                            .frame(height: 24)
                        }
                    }
                } else {
                    hostedCleanupSettings(for: appState.selectedPostProcessorBackend)
                }
            }
        }
    }

    private var quilSettingsSection: some View {
        settingsSection("Quill", icon: QuillIcon.image()) {
            settingsCompactRow(
                "Rewrite selected text",
                description: "Highlight text to transform it. With no selection, Quill generates and pastes at the cursor."
            ) {
                settingsControl("quill")
            }
            if let quilPermissionMessage = controller.independentShortcutPermissionMessageIfNeeded(
                isEnabled: appState.config.enableQuilMode
            ) {
                SettingsNote(quilPermissionMessage, tone: .warning)
                    .padding(.bottom, MuesliTheme.spacing4)
            }
            Group {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Play Quill sounds") {
                    settingsControl("quill_sound")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Writing model source", description: "Shared by Quill and Computer Use writing tasks.", controlWidth: meetingControlWidth) {
                    settingsControl("quill_source")
                }
                if selectedQuilBackend.isOnDevice {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Writing model", controlWidth: meetingControlWidth) {
                        if quilLocalModels.isEmpty {
                            compactActionButton("View local models", systemImage: "arrow.right") {
                                controller.showModels(category: .quill)
                            }
                        } else {
                            settingsControl("quill_local_model")
                            .frame(height: 24)
                        }
                    }
                } else {
                    hostedQuilSettings(for: selectedQuilBackend)
                }
            }
        }
        .id(FeatureTourTarget.quillSettings.rawValue)
        .featureTourTarget(.quillSettings)
    }

    @ViewBuilder
    private func hostedQuilSettings(for backend: TranscriptCleanupBackendOption) -> some View {
        if backend == .hosted(.chatGPT) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Account", controlWidth: meetingControlWidth) {
                chatGPTAccountControl(selectMeetingSummaryBackend: false)
            }
        } else if backend == .hosted(.openAI) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("API Key", controlWidth: meetingControlWidth) {
                PastableSecureField(
                    text: appState.config.openAIAPIKey,
                    placeholder: "sk-...",
                    onChange: { value in controller.updateConfig { $0.openAIAPIKey = value } }
                ).frame(height: 22)
            }
        } else if backend == .hosted(.anthropic) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("API Key", controlWidth: meetingControlWidth) {
                PastableSecureField(
                    text: appState.config.anthropicAPIKey,
                    placeholder: "sk-ant-api...",
                    onChange: { value in controller.updateConfig { $0.anthropicAPIKey = value } }
                ).frame(height: 22)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Workspace ID", description: anthropicWorkspaceIDDescription, controlWidth: meetingControlWidth) {
                PastableTextField(
                    text: appState.config.anthropicWorkspaceID,
                    placeholder: "Optional workspace ID",
                    onChange: { value in controller.updateConfig { $0.anthropicWorkspaceID = value } }
                ).frame(height: 22)
            }
        } else if backend == .hosted(.openRouter) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Account", controlWidth: meetingControlWidth) {
                openRouterAccountControl(selectMeetingSummaryBackend: false)
            }
        } else if backend == .hosted(.ollama) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Ollama URL", controlWidth: meetingControlWidth) {
                PastableTextField(
                    text: appState.config.ollamaURL,
                    placeholder: "http://localhost:11434",
                    onChange: { value in controller.updateConfig { $0.ollamaURL = value } }
                ).frame(height: 22)
            }
        } else if backend == .hosted(.lmStudio) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("LM Studio URL", controlWidth: meetingControlWidth) {
                PastableTextField(
                    text: appState.config.lmStudioURL,
                    placeholder: "http://localhost:1234",
                    onChange: { value in controller.updateConfig { $0.lmStudioURL = value } }
                ).frame(height: 22)
            }
        } else if backend == .hosted(.customLLM) {
            customLLMSettingsRows(model: appState.config.quilModel) { value in
                controller.updateConfig { $0.quilModel = value }
            }
        }
        if backend != .hosted(.customLLM) {
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Writing model", controlWidth: meetingControlWidth) {
                settingsModelTextField(
                    currentModel: appState.config.quilModel,
                    placeholder: TranscriptCleanupClient.defaultModel(for: backend)
                ) { value in controller.updateConfig { $0.quilModel = value } }
            }
        }
    }

    private let anthropicWorkspaceIDDescription = "For keys not scoped to one workspace."

    private var cohereLanguageMenu: some View {
        settingsControl("cohere_language")
    }

    private var nemotron35LanguageMenu: some View {
        settingsControl("nemotron_language")
    }

    private func whisperLanguageMenu(model: String) -> some View {
        MuesliSettingControl(controller: controller, id: "whisper_language",
            allowedChoiceIDs: Set(WhisperKitLanguage.choices(for: model).map(\.rawValue)))
    }

    @ViewBuilder
    private func bodhanOutputMenu(model: String) -> some View {
        if BodhanModel(rawValue: model)?.isCore == false {
            settingsRow("Bodhan output", controlWidth: meetingControlWidth) {
                settingsControl("bodhan_output")
            }
        }
    }

    private func indicLanguageMenu(model: String) -> some View {
        return MuesliSettingControl(controller: controller, id: "bodhan_language",
            allowedChoiceIDs: Set(BodhanLanguage.choices(for: model).map(\.rawValue)))
        .frame(height: 24)
    }

    @ViewBuilder
    private func hostedCleanupSettings(for backend: TranscriptCleanupBackendOption) -> some View {
        switch backend.llmBackend {
        case .some(.chatGPT):
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Account", controlWidth: meetingControlWidth) {
                chatGPTAccountControl(selectMeetingSummaryBackend: false)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Cleanup model", controlWidth: meetingControlWidth) {
                settingsControl("cleanup_chatgpt_model")
            }
            let model = TranscriptCleanupClient.configuredModel(for: backend, config: appState.config)
            if !ReasoningEffortPolicy.selectableEfforts(for: model).isEmpty {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Thinking", controlWidth: meetingControlWidth) {
                    settingsControl("cleanup_thinking")
                }
            }
        case .some(.openAI):
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("API Key", controlWidth: meetingControlWidth) {
                PastableSecureField(
                    text: appState.config.openAIAPIKey,
                    placeholder: "sk-...",
                    onChange: { val in controller.updateConfig { $0.openAIAPIKey = val } }
                )
                .frame(height: 22)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Cleanup model", controlWidth: meetingControlWidth) {
                settingsControl("cleanup_openai_model")
            }
            let model = TranscriptCleanupClient.configuredModel(for: backend, config: appState.config)
            if !ReasoningEffortPolicy.selectableEfforts(for: model).isEmpty {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Thinking", controlWidth: meetingControlWidth) {
                    settingsControl("cleanup_thinking")
                }
            }
            keyStatusRow(key: appState.config.openAIAPIKey)
        case .some(.anthropic):
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("API Key", controlWidth: meetingControlWidth) {
                PastableSecureField(
                    text: appState.config.anthropicAPIKey,
                    placeholder: "sk-ant-api...",
                    onChange: { val in controller.updateConfig { $0.anthropicAPIKey = val } }
                )
                .frame(height: 22)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Cleanup model", controlWidth: meetingControlWidth) {
                settingsControl("cleanup_anthropic_model")
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Custom model ID", controlWidth: meetingControlWidth) {
                settingsModelTextField(
                    currentModel: appState.config.postProcessorAnthropicModel,
                    placeholder: "Optional model ID"
                ) { controller.updatePostProcessorModel($0, for: backend) }
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Workspace ID", description: anthropicWorkspaceIDDescription, controlWidth: meetingControlWidth) {
                PastableTextField(
                    text: appState.config.anthropicWorkspaceID,
                    placeholder: "Optional workspace ID",
                    onChange: { val in controller.updateConfig { $0.anthropicWorkspaceID = val } }
                )
                .frame(height: 22)
            }
            keyStatusRow(key: MeetingSummaryClient.resolvedAnthropicAPIKey(config: appState.config))
        case .some(.openRouter):
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Account", controlWidth: meetingControlWidth) {
                openRouterAccountControl(selectMeetingSummaryBackend: false)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Model preset", controlWidth: meetingControlWidth) {
                settingsControl("cleanup_openrouter_model")
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Custom model ID", controlWidth: meetingControlWidth) {
                settingsModelTextField(
                    currentModel: appState.config.postProcessorOpenRouterModel,
                    placeholder: "provider/model"
                ) { controller.updatePostProcessorModel($0, for: backend) }
            }
        case .some(.ollama):
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Ollama URL", controlWidth: meetingControlWidth) {
                PastableTextField(
                    text: appState.config.ollamaURL,
                    placeholder: "http://localhost:11434",
                    onChange: { val in controller.updateConfig { $0.ollamaURL = val } }
                )
                .frame(height: 22)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Cleanup model", controlWidth: meetingControlWidth) {
                settingsModelTextField(
                    currentModel: appState.config.postProcessorOllamaModel,
                    placeholder: TranscriptCleanupClient.defaultModel(for: backend)
                ) { controller.updatePostProcessorModel($0, for: backend) }
            }
        case .some(.lmStudio):
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("LM Studio URL", controlWidth: meetingControlWidth) {
                PastableTextField(
                    text: appState.config.lmStudioURL,
                    placeholder: "http://localhost:1234",
                    onChange: { val in controller.updateConfig { $0.lmStudioURL = val } }
                )
                .frame(height: 22)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Cleanup model", controlWidth: meetingControlWidth) {
                settingsModelTextField(
                    currentModel: appState.config.postProcessorLMStudioModel,
                    placeholder: "Loaded LM Studio model"
                ) { controller.updatePostProcessorModel($0, for: backend) }
            }
        case .some(.customLLM):
            customLLMSettingsRows(model: appState.config.postProcessorCustomLLMModel) {
                controller.updatePostProcessorModel($0, for: backend)
            }
        default:
            EmptyView()
        }
    }

    private var cleanupPromptSettings: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            settingsRow("Cleanup preset", controlWidth: meetingControlWidth) {
                settingsControl("cleanup_preset")
                .frame(height: 24)
            }

            Text(appState.config.postProcessorSystemPrompt)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(4)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MuesliTheme.surfacePrimary.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )

            HStack {
                Spacer()
                compactActionButton("Manage Presets…", systemImage: "slider.horizontal.3") {
                    isCleanupPromptManagerPresented = true
                }
            }
        }
    }

    private var fixedCleanupPromptNotice: some View {
        settingsRow(
            "Cleanup prompt",
            description: appState.selectedPostProcessorBackend == .gemma4LiteRT
                ? "muesli Pro Cleanup uses its trained cleanup instructions. Custom presets do not apply."
                : (appState.activePostProcessor.inputFormat.isTrainedV12 ? "This model uses its trained cleanup instructions. Custom presets do not apply." : "S1-mini uses Superwhisper’s built-in normalization instructions."),
            controlWidth: meetingControlWidth
        ) {
            Text("Built in")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var meetingSummarySettingsSection: some View {
        settingsSection("Meeting Summaries") {
            settingsRow(
                "Summary backend",
                // Ollama, LM Studio and custom endpoints can be on another machine; don't imply local.
                description: "Summaries may send transcripts, notes, screen context, and participant names to the selected backend.",
                controlWidth: meetingControlWidth
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    settingsControl("summary_source")
                        .id(FeatureTourTarget.meetingSummaryProvider.rawValue)
                        .featureTourTarget(.meetingSummaryProvider)
                    if ClaudeCodeSummarizer.executableURL(configuredPath: appState.config.claudeCodeExecutablePath) == nil,
                       appState.selectedMeetingSummaryBackend != .claudeCode {
                        Button("Locate existing Claude Code…") { pickExistingClaudeCodeExecutable() }
                            .font(MuesliTheme.caption())
                            .buttonStyle(.link)
                            .alert("Couldn't Use Claude Code", isPresented: $isShowingInvalidClaudeCodeExecutableAlert) {
                                Button("OK", role: .cancel) {}
                            } message: {
                                Text("The selected file isn't executable. Choose the installed Claude Code CLI.")
                            }
                    }
                }
            }
            Divider().background(MuesliTheme.surfaceBorder)

            if appState.selectedMeetingSummaryBackend == .chatGPT {
                settingsRow("Account", controlWidth: meetingControlWidth) {
                    chatGPTAccountControl()
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    settingsControl("summary_chatgpt_model")
                }
                let model = appState.config.chatGPTModel.isEmpty
                    ? (SummaryModelPreset.chatGPTModels.first?.id ?? "")
                    : appState.config.chatGPTModel
                if !ReasoningEffortPolicy.selectableEfforts(for: model).isEmpty {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Thinking", controlWidth: meetingControlWidth) {
                        settingsControl("summary_thinking")
                    }
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
                    settingsControl("summary_openai_model")
                }
                let model = appState.config.openAIModel.isEmpty
                    ? (SummaryModelPreset.openAIModels.first?.id ?? "")
                    : appState.config.openAIModel
                if !ReasoningEffortPolicy.selectableEfforts(for: model).isEmpty {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Thinking", controlWidth: meetingControlWidth) {
                        settingsControl("summary_thinking")
                    }
                }
                keyStatusRow(key: appState.config.openAIAPIKey)
            } else if appState.selectedMeetingSummaryBackend == .anthropic {
                settingsRow("API Key", description: "Use an Anthropic API key from the Claude Console.", controlWidth: meetingControlWidth) {
                    PastableSecureField(
                        text: appState.config.anthropicAPIKey,
                        placeholder: "sk-ant-api...",
                        onChange: { val in controller.updateConfig { $0.anthropicAPIKey = val } }
                    )
                    .frame(height: 22)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    settingsControl("summary_anthropic_model")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Custom model ID", description: "For Claude API models not in the list.", controlWidth: meetingControlWidth) {
                    settingsModelTextField(
                        currentModel: appState.config.anthropicModel,
                        placeholder: "Optional model ID"
                    ) { val in controller.updateConfig { $0.anthropicModel = val } }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Workspace ID", description: anthropicWorkspaceIDDescription, controlWidth: meetingControlWidth) {
                    PastableTextField(
                        text: appState.config.anthropicWorkspaceID,
                        placeholder: "Optional workspace ID",
                        onChange: { val in controller.updateConfig { $0.anthropicWorkspaceID = val } }
                    )
                    .frame(height: 22)
                }
                keyStatusRow(key: MeetingSummaryClient.resolvedAnthropicAPIKey(config: appState.config))
            } else if appState.selectedMeetingSummaryBackend == .claudeCode {
                settingsRow("Account", description: "Uses the Claude Code sign-in on this Mac.", controlWidth: meetingControlWidth) {
                    claudeCodeAccountControl()
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", description: "Uses your Claude Code model preference, or your account's default.", controlWidth: meetingControlWidth) {
                    claudeCodeModelControl()
                }
                Divider().background(MuesliTheme.surfaceBorder)
                DisclosureGroup(isExpanded: $isShowingClaudeCodeAdvanced) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                        settingsRow("Custom executable path", description: "Override the Claude Code CLI muesli detected.", controlWidth: meetingControlWidth) {
                            PastableTextField(
                                text: appState.config.claudeCodeExecutablePath,
                                placeholder: "Optional path",
                                onChange: { val in controller.updateConfig { $0.claudeCodeExecutablePath = val } }
                            )
                            .frame(height: 22)
                        }
                        settingsRow("Custom model ID", controlWidth: meetingControlWidth) {
                            settingsModelTextField(
                                currentModel: appState.config.claudeCodeModel,
                                placeholder: "Optional model ID"
                            ) { val in controller.updateConfig { $0.claudeCodeModel = val } }
                        }
                    }
                    .padding(.top, MuesliTheme.spacing12)
                } label: {
                    Text("Advanced")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
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
            } else if appState.selectedMeetingSummaryBackend == .lmStudio {
                settingsRow("LM Studio URL", controlWidth: meetingControlWidth) {
                    PastableTextField(
                        text: appState.config.lmStudioURL,
                        placeholder: "http://localhost:1234",
                        onChange: { val in controller.updateConfig { $0.lmStudioURL = val } }
                    )
                    .frame(height: 22)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    settingsModelTextField(
                        currentModel: appState.config.lmStudioModel,
                        placeholder: "Select a loaded LM Studio model"
                    ) { val in controller.updateConfig { $0.lmStudioModel = val } }
                }
            } else if appState.selectedMeetingSummaryBackend == .customLLM {
                customLLMSettingsRows(model: appState.config.customLLMModel) {
                    val in controller.updateConfig { $0.customLLMModel = val }
                }
            } else {
                settingsRow("Account", controlWidth: meetingControlWidth) {
                    openRouterAccountControl()
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model", controlWidth: meetingControlWidth) {
                    openRouterFreeModelMenu
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Custom model ID", controlWidth: meetingControlWidth) {
                    settingsModelTextField(
                        currentModel: appState.config.openRouterModel,
                        placeholder: "provider/model"
                    ) { val in controller.updateConfig { $0.openRouterModel = val } }
                }
            }
            if ![MeetingSummaryBackendOption.chatGPT, .claudeCode].contains(appState.selectedMeetingSummaryBackend) {
                Divider().background(MuesliTheme.surfaceBorder)
                DisclosureGroup(isExpanded: $isShowingSummaryOutputAdvanced) {
                    settingsRow(
                        "Output token limit",
                        description: "No added limit lets the model finish naturally. Provider and model limits still apply.",
                        controlWidth: meetingControlWidth
                    ) {
                        settingsControl("summary_output_limit")
                    }
                    .padding(.top, MuesliTheme.spacing8)
                } label: {
                    Text("Advanced")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func customLLMSettingsRows(model: String, onModelChange: @escaping (String) -> Void) -> some View {
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("API Format", controlWidth: meetingControlWidth) {
            settingsControl("custom_llm_format")
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Endpoint", description: CustomLLMConnectionGuidance.endpointHelp, controlWidth: meetingControlWidth) {
            PastableTextField(
                text: appState.config.customLLMURL,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "https://api.anthropic.com"
                    : "http://localhost:8080/v1",
                onChange: { val in controller.updateConfig { $0.customLLMURL = val } }
            )
            .frame(height: 22)
        }
        settingsDetails("HTTPS setup") {
            SettingsNote("Use HTTPS with a certificate trusted by your Mac. Enable TLS on the server or use a reverse proxy such as Caddy. Localhost means a server running on this Mac.")
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("API Key", controlWidth: meetingControlWidth) {
            PastableSecureField(
                text: appState.config.customLLMAPIKey,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "Required for Anthropic API"
                    : "Optional for local servers",
                onChange: { val in controller.updateConfig { $0.customLLMAPIKey = val } }
            )
            .frame(height: 22)
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow(
            "API Key Command",
            description: "Runs shell code with your permissions before each request. Failures use the saved API key.",
            controlWidth: meetingControlWidth
        ) {
            PastableTextField(
                text: appState.config.customLLMAPIKeyCommand,
                placeholder: "e.g. /opt/homebrew/bin/vault print token",
                commitsOnEndEditing: true,
                onChange: { val in controller.updateConfig { $0.customLLMAPIKeyCommand = val } }
            )
            .frame(height: 22)
        }
        settingsDetails("API key command setup") {
            SettingsNote("Use an absolute executable path. Commands run via /bin/sh; non-empty output replaces the saved API key.")
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow(
            "Headers",
            description: "Optional authentication or routing headers.",
            controlWidth: meetingControlWidth
        ) {
            VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                ForEach(appState.config.customLLMHeaders) { header in
                    HStack(spacing: 6) {
                        PastableTextField(
                            text: header.name,
                            placeholder: "Header name",
                            onChange: { updateCustomLLMHeader(id: header.id, name: $0) }
                        )
                        .frame(width: 116, height: 22)
                        PastableTextField(
                            text: header.value,
                            placeholder: "Value",
                            onChange: { updateCustomLLMHeader(id: header.id, value: $0) }
                        )
                        .frame(width: 116, height: 22)
                        Button {
                            removeCustomLLMHeader(id: header.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MuesliTheme.textSecondary)
                                .frame(width: 20, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Remove header")
                    }
                }
                compactActionButton("Add Header", systemImage: "plus") {
                    controller.updateConfig {
                        $0.customLLMHeaders.append(CustomLLMRequestHeader())
                    }
                }
                .help("Stored in the owner-only config file and never logged. muesli-managed HTTP headers cannot be overridden.")
                .disabled(appState.config.customLLMHeaders.count >= CustomLLMRequestHeaders.maximumCount)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.vertical, 2)
        }
        if let message = customLLMHeadersValidationMessage {
            SettingsNote(message, tone: .error)
                .padding(.bottom, MuesliTheme.spacing4)
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Model", controlWidth: meetingControlWidth) {
            settingsModelTextField(
                currentModel: model,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "claude-3-5-sonnet-20241022"
                    : "custom-model-id"
            ) { val in onModelChange(val) }
        }
    }

    private var customLLMHeadersValidationMessage: String? {
        do {
            _ = try CustomLLMRequestHeaders.validated(appState.config.customLLMHeaders)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func updateCustomLLMHeader(id: String, name: String? = nil, value: String? = nil) {
        controller.updateConfig { config in
            guard let index = config.customLLMHeaders.firstIndex(where: { $0.id == id }) else { return }
            if let name { config.customLLMHeaders[index].name = name }
            if let value { config.customLLMHeaders[index].value = value }
        }
    }

    private func removeCustomLLMHeader(id: String) {
        controller.updateConfig {
            $0.customLLMHeaders.removeAll { $0.id == id }
        }
    }

    private var dictationSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            dictationModelSettingsSection

            settingsSection("Transcription") {
                settingsRow(
                    "Microphone",
                    description: "Automatic uses system input, or Mac mic with AirPods."
                ) {
                    settingsControl("dictation_microphone")
                    .frame(height: 24)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow(
                    "Dictionary suggestions",
                    description: "Suggests words from your corrections. Briefly reads focused app text via Accessibility after dictation."
                ) {
                    settingsControl("dictionary_suggestions")
                }
            }

            dictationCleanupSettingsSection

            settingsSection("App Formatting") {
                DictationFormattingSettingsView(appState: appState, controller: controller)
            }

            settingsSection("Advanced") {
                settingsRow(
                    "Paste shortcut",
                    description: "Uses your keyboard layout. Re-record a custom shortcut after changing layouts.",
                    controlWidth: meetingControlWidth
                ) {
                    PasteShortcutControl(controller: controller, appState: appState)
                        .help("Custom applies to keyboard paste in Dictation, Quill, and Computer Use. Browser Paste commands and live streaming are unchanged. Re-record custom shortcuts after changing keyboard layouts.")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Pause media during dictation") {
                    settingsControl("pause_media")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Mute system audio during dictation") {
                    settingsControl("mute_audio")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                screenContextRow("App context")
                Divider().background(MuesliTheme.surfaceBorder)
                dictationOCRContextRow
            }
        }
    }

    /// Cotypist (experimental, dev builds): on means its input source is active. Turning it on
    /// selects it, or opens Keyboard settings with a guide until the user has added it.
    private var cotypistSettingsSection: some View {
        settingsSection("Cotypist") {
            settingsCompactRow("Typeahead suggestions", description: cotypistStatus) {
                settingsControl("cotypist_enabled")
            }
            if cotypist.state == .addingInputSource {
                compactActionButton("Show setup guide", systemImage: "keyboard") {
                    cotypist.showGuide()
                }
                .padding(.bottom, MuesliTheme.spacing12)
            }
            if cotypist.modelState != .ready {
                cotypistModelRow
                    .padding(.bottom, MuesliTheme.spacing12)
            }
            if cotypist.state == .on {
                cotypistKeyHints
                    .padding(.bottom, MuesliTheme.spacing12)
                cotypistOptions
            }
        }
    }

    /// Shown only while Cotypist is on: off, none of them do anything.
    @ViewBuilder
    private var cotypistOptions: some View {
        Divider().background(MuesliTheme.surfaceBorder)
        cotypistModelLine
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Suggestion length") {
            settingsControl("cotypist_length")
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("How often to suggest", description: "Fewer shows only suggestions the model is sure of.") {
            settingsControl("cotypist_frequency")
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsCompactRow("Finish half-typed words", description: appState.config.cotypistCompleteWords
            ? "Pause inside a word to see the rest of it."
            : "Off: suggestions appear only after a space or punctuation.") {
            settingsControl("cotypist_complete_words")
        }
        if appState.config.cotypistCompleteWords {
            cotypistSubRow("Pause before completing") {
                settingsControl("cotypist_word_pause")
            }
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsCompactRow("Use on-screen text", description: "Reads the window around the text field. Off while a meeting records.") {
            settingsControl("cotypist_screen_context")
        }
        Divider().background(MuesliTheme.surfaceBorder)
        cotypistQuietApps
            .padding(.top, MuesliTheme.spacing4)
    }

    private var cotypistStatus: String {
        switch cotypist.state {
        case .on:
            "Suggests the next words as you type, in any app."
        case .addingInputSource:
            cotypist.suggestsRelogin
                ? "\(CotypistSetup.displayName) isn't listed yet. Log out and back in, then turn this on again."
                : "Add \(CotypistSetup.displayName) in Keyboard settings. It turns on as soon as it's added."
        case .off:
            "Local typeahead in every app, running on this Mac."
        }
    }

    /// The selected typeahead model, until it's on this Mac: its size, download progress, or what
    /// went wrong. Models › Cotypist has the full choice.
    private var cotypistModelRow: some View {
        let model = appState.config.cotypistModel
        return HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "cpu")
                .font(.system(size: 14))
                .foregroundStyle(MuesliTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Typeahead model: \(model.label)")
                    .font(MuesliTheme.font(size: 13, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                switch cotypist.modelState {
                case .downloading(let fraction):
                    ProgressView(value: fraction).tint(MuesliTheme.accent)
                    SettingsNote("Downloading… \(Int(fraction * 100))% of \(model.sizeLabel)")
                case .failed(let message):
                    SettingsNote("Download failed: \(message)", tone: .error)
                case .unavailable:
                    SettingsNote("Coming soon. Choose another model in Models.")
                default:
                    SettingsNote("\(model.sizeLabel). Runs on this Mac; downloaded when you turn Cotypist on.")
                }
            }
            Spacer(minLength: 0)
            switch cotypist.modelState {
            case .missing, .failed:
                compactActionButton("Download", systemImage: "arrow.down.circle") { cotypist.downloadModelIfNeeded() }
            default:
                compactActionButton("Models", systemImage: "square.stack.3d.up") { controller.showModels(category: .cotypist) }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    /// The model in use, with a way to change it, once Cotypist is set up.
    private var cotypistModelLine: some View {
        settingsCompactRow("Model") {
            HStack(spacing: MuesliTheme.spacing8) {
                Text(appState.config.cotypistModel.label)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                compactActionButton("Change", systemImage: "square.stack.3d.up") { controller.showModels(category: .cotypist) }
            }
        }
    }

    /// The keys, shown once Cotypist is on.
    private var cotypistKeyHints: some View {
        HStack(spacing: MuesliTheme.spacing16) {
            cotypistKeyHint(["Tab"], "Accept")
            cotypistKeyHint(["⌥", "→"], "Accept one word")
            Text("Keep typing to ignore")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func cotypistKeyHint(_ keys: [String], _ action: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
                }
            }
            Text(action)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A setting that refines the row above it: indented, without its own divider.
    private func cotypistSubRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        settingsRow(label, control: control)
            .padding(.leading, MuesliTheme.spacing16)
            .padding(.bottom, MuesliTheme.spacing4)
    }

    // MARK: Cotypist quiet apps

    private var cotypistQuietApps: some View {
        let quiet = appState.config.cotypistDisabledApps
        let recommended = CotypistQuietApps.recommended(excluding: quiet)
        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            settingsCompactRow("Quiet in these apps", description: "Cotypist won't suggest anything in apps you add here.") {
                cotypistAddAppMenu(excluding: quiet)
            }
            if quiet.isEmpty {
                cotypistQuietAppsEmptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: MuesliTheme.spacing8)],
                          alignment: .leading, spacing: MuesliTheme.spacing8) {
                    ForEach(quiet, id: \.self) { bundleID in
                        cotypistQuietAppChip(bundleID)
                    }
                }
            }
            if !recommended.isEmpty {
                HStack(spacing: MuesliTheme.spacing8) {
                    Text("Suggested")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    ForEach(recommended, id: \.self) { bundleID in
                        cotypistRecommendedAppButton(bundleID)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.bottom, MuesliTheme.spacing4)
    }

    private var cotypistQuietAppsEmptyState: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(MuesliTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("On in every app")
                    .font(MuesliTheme.font(size: 13, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                SettingsNote("Add password managers, or apps with their own autocomplete like code editors.")
            }
            Spacer(minLength: 0)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func cotypistQuietAppChip(_ bundleID: String) -> some View {
        let name = CotypistQuietApps.name(of: bundleID)
        return HStack(spacing: MuesliTheme.spacing8) {
            cotypistAppIcon(bundleID, size: 20)
            Text(name)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                controller.setSettingFromUI(CotypistQuietApps.settingID(bundleID), value: "off")
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(MuesliTheme.surfaceBorder.opacity(0.6))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Turn Cotypist back on in \(name)")
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall).strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
    }

    private func cotypistRecommendedAppButton(_ bundleID: String) -> some View {
        let name = CotypistQuietApps.name(of: bundleID)
        return Button {
            controller.setSettingFromUI(CotypistQuietApps.settingID(bundleID), value: "on")
        } label: {
            HStack(spacing: 5) {
                cotypistAppIcon(bundleID, size: 14)
                Text(name).lineLimit(1)
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            }
            .font(MuesliTheme.font(size: 12, weight: .medium))
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Keep Cotypist quiet in \(name)")
    }

    /// Open apps first, then any app from the Applications folder.
    private func cotypistAddAppMenu(excluding quiet: [String]) -> some View {
        Menu {
            let running = CotypistQuietApps.running(excluding: quiet)
            if !running.isEmpty {
                Section("Open apps") {
                    ForEach(running, id: \.bundleID) { app in
                        Button {
                            controller.setSettingFromUI(CotypistQuietApps.settingID(app.bundleID), value: "on")
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                if let icon = CotypistQuietApps.menuIcon(of: app.bundleID) { Image(nsImage: icon) }
                            }
                        }
                    }
                }
            }
            Button("Choose from Applications…") { chooseCotypistQuietApp(excluding: quiet) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("Add app")
            }
            .font(MuesliTheme.font(size: 12, weight: .medium))
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall).strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func chooseCotypistQuietApp(excluding quiet: [String]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Cotypist won't suggest anything in the apps you choose."
        panel.begin { response in
            guard response == .OK else { return }
            let chosen = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !quiet.contains($0) }
            CotypistQuietApps.chosen.append(contentsOf: chosen)
            for bundleID in chosen { controller.setSettingFromUI(CotypistQuietApps.settingID(bundleID), value: "on") }
        }
    }

    @ViewBuilder
    private func cotypistAppIcon(_ bundleID: String, size: CGFloat) -> some View {
        if let icon = CotypistQuietApps.icon(of: bundleID) {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .resizable().scaledToFit().frame(width: size, height: size)
                .foregroundStyle(MuesliTheme.textTertiary)
        }
    }


    private var experimentalSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            computerUseSettingsPane
            quilSettingsSection
            if CotypistSetup.isAvailable {
                cotypistSettingsSection
            }
        }
    }

    private var computerUseSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Computer Use") {
                settingsCompactRow("Enable planner") {
                    settingsControl("cua_planner")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                let plannerModel = ComputerUsePlannerClient.plannerModel(for: appState.config)
                let isLocalPlanner = ComputerUseLocalPlanner.isLocal(plannerModel)
                settingsRow("Planner backend", controlWidth: meetingControlWidth) {
                    settingsControl("cua_backend")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                if !isLocalPlanner {
                    settingsRow("Account", controlWidth: meetingControlWidth) {
                        chatGPTAccountControl(selectMeetingSummaryBackend: false)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                }
                settingsRow(
                    "Planner model",
                    description: isLocalPlanner
                        ? "Planning runs on this Mac. No ChatGPT sign-in is needed."
                        : (ComputerUseLocalPlanner.models.contains(where: \.available)
                            ? nil
                            : "Download Gemma in Models to enable the On-device backend."),
                    controlWidth: meetingControlWidth
                ) {
                    MuesliSettingControl(controller: controller, id: "cua_model",
                        allowedChoiceIDs: isLocalPlanner
                            ? Set(ComputerUseLocalPlanner.models.filter(\.available).map(\.id))
                            : Set(SummaryModelPreset.computerUsePlannerModels.map(\.id)))
                }
                if !isLocalPlanner, !ReasoningEffortPolicy.selectableEfforts(for: plannerModel).isEmpty {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Thinking", controlWidth: meetingControlWidth) {
                        settingsControl("cua_thinking")
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "Execution timeout",
                    description: "Limits desktop observation and actions. Model thinking and time spent answering questions are excluded.",
                    controlWidth: meetingControlWidth
                ) {
                    integerInput(
                        label: "Computer use execution timeout",
                        value: Binding(
                            get: { max(appState.config.computerUseTimeoutSeconds, 1) },
                            set: { newValue in
                                controller.updateConfig { $0.computerUseTimeoutSeconds = max(newValue, 1) }
                            }
                        ),
                        range: 1...600,
                        step: 15,
                        unit: { $0 == 1 ? "second" : "seconds" }
                    )
                }
            }
        }
    }

    private var meetingsSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            meetingTranscriptionSettingsSection

            settingsSection("Meeting Context") {
                screenContextRow("Meeting context", includesScreenOCR: true)
            }

            meetingSummarySettingsSection

            settingsSection("Meeting Notes") {
                settingsRow("Default template", controlWidth: meetingControlWidth) {
                    settingsControl("meeting_template")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "Summary retries",
                    description: "Retries transient AI failures before saving failed notes.",
                    controlWidth: meetingControlWidth
                ) {
                    integerInput(
                        label: "Summary retries",
                        value: Binding(
                            get: {
                                MeetingSummaryRetryPolicy.clampedRetryCount(appState.config.meetingSummaryRetryCount)
                            },
                            set: { newValue in
                                controller.updateConfig {
                                    $0.meetingSummaryRetryCount = MeetingSummaryRetryPolicy.clampedRetryCount(newValue)
                                }
                            }
                        ),
                        range: 0...MeetingSummaryRetryPolicy.maximumRetryCount,
                        unit: { $0 == 1 ? "retry" : "retries" }
                    )
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Templates", controlWidth: meetingControlWidth) {
                    actionButton("Manage Templates…") {
                        controller.showMeetingTemplatesManager()
                    }
                }
            }

            settingsSection("Recording") {
                settingsCompactRow("Auto-record calendar meetings") {
                    settingsControl("auto_record_meetings")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Save meeting recording") {
                    settingsControl("recording_policy")
                }
                if appState.config.meetingRecordingSavePolicy != .never {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow(
                        "Recording format",
                        description: "M4A is recommended for smaller files. WAV is lossless and uses more storage."
                    ) {
                        settingsControl("recording_format")
                    }
                }
            }

            settingsSection("Auto Export") {
                settingsCompactRow("Auto-export meetings") {
                    settingsControl("auto_export_meetings")
                }
                if appState.config.autoExportMarkdownEnabled {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Destination folder") {
                        autoExportFolderPicker
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Content") {
                        settingsControl("export_content")
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("File format") {
                        settingsControl("export_format")
                    }
                }
            }

            settingsSection("Meeting Notifications") {
                settingsCompactRow("Scheduled meetings", description: "For calendar events with a join link.") {
                    settingsControl("meeting_reminders")
                }

                if appState.config.showScheduledMeetingNotifications {
                    Divider().background(MuesliTheme.surfaceBorder)

                    settingsRow("Reminder timing") {
                        settingsControl("meeting_reminder_time")
                    }
                }

                Divider().background(MuesliTheme.surfaceBorder)

                settingsRow("Default action", description: meetingJoinActionDescription) {
                    settingsControl("meeting_join_action")
                }

                Divider().background(MuesliTheme.surfaceBorder)

                settingsCompactRow(
                    "Auto-detected meetings",
                    description: "Detects calls from browser, camera, microphone, or app audio activity."
                ) {
                    settingsControl("meeting_detection")
                }

                if appState.config.showMeetingDetectionNotification {
                    Divider().background(MuesliTheme.surfaceBorder)
                    mutedMeetingDetectionAppsControl
                }
            }

            settingsSection("Calendars") {
                settingsCompactRow(
                    "Calendar access",
                    description: calendarPermission.granted
                        ? nil
                        : (calendarPermission.canRequest
                            ? "Show meetings from calendars on your Mac."
                            : "Allow full Calendar access in System Settings.")
                ) {
                    calendarPermissionControl
                }
                if let errorMessage = calendarPermission.errorMessage {
                    SettingsNote(errorMessage, tone: .error)
                        .padding(.bottom, MuesliTheme.spacing4)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "Upcoming meetings",
                    description: "How far ahead to show meetings and check reminders.",
                    controlWidth: meetingControlWidth
                ) {
                    settingsControl("upcoming_meetings")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Only show events with a meeting link") {
                    settingsControl("calendar_meeting_links_only")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                calendarSourcesControl
            }

            settingsSection("Advanced") {
                settingsCompactRow(
                    "Enable post-meeting hook",
                    description: "Runs your chosen executable with your user permissions after each completed meeting. It receives the meeting ID and completion time as JSON on stdin."
                ) {
                    settingsControl("meeting_hook")
                }
                settingsDetails("Hook details") {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        SettingsNote("muesli runs the file directly, not through a shell, so it must already be runnable on its own. Runs, failures and their stderr are logged to meeting-hook.log in muesli's support folder. The hook is stopped after the timeout.")
                        Text(verbatim: #"{"schemaVersion":1,"event":"meeting.completed","kind":"meeting","id":42,"completedAt":"2026-01-01T12:00:00Z"}"#)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Hook script", controlWidth: meetingControlWidth) {
                    meetingHookPathPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Timeout", controlWidth: meetingControlWidth) {
                    meetingHookTimeoutControl
                }
            }
            .padding(.top, MuesliTheme.spacing8)
        }
        .onAppear {
            refreshMeetingCalendarSourcesIfNeeded()
        }
    }

    private var meetingJoinActionDescription: String {
        appState.config.meetingJoinDefaultAction == .recordOnly
            ? "Used in notifications and Coming Up."
            : "Used in notifications and Coming Up. Joining in another browser? Choose Transcribe Only."
    }

    private var calendarPermissionControl: some View {
        permissionStatusControl(
            granted: calendarPermission.granted,
            actionTitle: calendarPermission.canRequest ? "Grant" : "Open Settings",
            isBusy: calendarPermission.requesting,
            action: requestCalendarPermission
        )
    }

    private var appearanceSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Recording indicator") {
                RecordingIndicatorStylePicker(selection: appState.config.recordingIndicatorStyle,
                    accent: Color(nsColor: RecordingIndicatorPalette.accent(hex: appState.config.recordingColorHex))) { style in
                    controller.setSettingFromUI("indicator_style", value: style.rawValue)
                }
                .id(FeatureTourTarget.recordingIndicatorStyle.rawValue)
                .padding(.bottom, MuesliTheme.spacing8)
                if appState.config.recordingIndicatorStyle == .notch {
                    SettingsNote("Shows during recording and processing. Click the logo or status to open muesli. On external displays, it appears at the top center.")
                } else {
                    settingsCompactRow(
                        "Keep visible when idle",
                        description: "When off, appears only during recording and processing."
                    ) {
                        settingsControl("show_floating_indicator")
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Position") {
                        settingsControl("indicator_position")
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsCompactRow("Show keyboard shortcut on hover") {
                        settingsControl("show_hotkey_hover")
                        .disabled(!appState.config.showFloatingIndicator)
                    }
                }
            }

            settingsSection("Appearance") {
                settingsRow("Theme") {
                    settingsControl("appearance")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Menu bar icon") {
                    menuBarIconPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Show hotkey in menu bar") {
                    settingsControl("show_hotkey_menu")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Accent color", description: appState.config.appearanceMode == .ultraDark ? "Used for toggles in Ultra Dark." : nil) {
                    glassTintPicker
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Play sound effects") {
                    settingsControl("sound")
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsCompactRow("Show next meeting in menu bar") {
                    settingsControl("show_next_meeting")
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
                                .font(MuesliTheme.caption())
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
            ForEach(MuesliSettings.accentPresets, id: \.hex) { preset in
                let isSelected = appState.config.recordingColorHex.lowercased() == preset.hex
                Button {
                    controller.setSettingFromUI("accent_color", value: preset.hex)
                } label: {
                    Circle()
                        .fill(preset.hex == "1e1e2e" ? MuesliTheme.defaultAccent : Color(hex: preset.hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                        )
                        .overlay(
                            Circle().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(preset.hex == "1e1e2e" ? "Default (adaptive blue)" : preset.name)
                .accessibilityLabel(preset.name)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }
        }
    }

    private var menuBarIconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(MenuBarIconRenderer.options, id: \.id) { option in
                    let isSelected = appState.config.menuBarIcon == option.id
                    Button {
                        controller.setSettingFromUI("menu_icon", value: option.id)
                    } label: {
                        Group {
                            if option.id == "muesli",
                               let img = MenuBarIconRenderer.make(choice: "muesli") {
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

    private func claudeCodeAccountControl() -> some View {
        VStack(alignment: .center, spacing: 5) {
            switch claudeCodeAuthStatus {
            case .signedIn:
                Label("Connected to Claude Code", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(MuesliTheme.success)
            case .unavailable:
                Label("Claude Code unavailable", systemImage: "exclamationmark.circle")
                    .foregroundStyle(MuesliTheme.textSecondary)
            case .signedOut, .unknown:
                if isWaitingForClaudeCodeSignIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finish sign-in in Terminal or your browser")
                    }
                    .foregroundStyle(MuesliTheme.textSecondary)
                } else {
                    ClaudeCodeSignInButton(compact: true) { beginClaudeCodeSignIn() }
                }
                Button("Check again") { Task { await refreshClaudeCodeAuthStatus() } }
                    .font(MuesliTheme.caption())
                    .buttonStyle(.plain)
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking Claude Code…")
                }
                .foregroundStyle(MuesliTheme.textSecondary)
            }
            if let claudeCodeSignInError {
                SettingsNote(claudeCodeSignInError, tone: .error)
            }
        }
        .font(MuesliTheme.caption())
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: appState.config.claudeCodeExecutablePath) {
            await refreshClaudeCodeAuthStatus()
        }
        .task(id: isWaitingForClaudeCodeSignIn) {
            guard isWaitingForClaudeCodeSignIn else { return }
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshClaudeCodeAuthStatus()
                if claudeCodeAuthStatus == .signedIn || claudeCodeAuthStatus == .unavailable {
                    isWaitingForClaudeCodeSignIn = false
                    return
                }
            }
            isWaitingForClaudeCodeSignIn = false
        }
    }

    private func claudeCodeModelControl() -> some View {
        settingsControl("summary_claude_code_model")
    }

    @MainActor
    private func refreshClaudeCodeAuthStatus() async {
        claudeCodeAuthStatus = await ClaudeCodeSummarizer.authenticationStatus(
            executablePath: appState.config.claudeCodeExecutablePath
        )
    }

    @MainActor
    private func beginClaudeCodeSignIn() {
        claudeCodeSignInError = nil
        do {
            try ClaudeCodeSignInLauncher.start(executablePath: appState.config.claudeCodeExecutablePath)
            isWaitingForClaudeCodeSignIn = true
        } catch {
            claudeCodeSignInError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func chatGPTAccountControl(selectMeetingSummaryBackend: Bool = true) -> some View {
        if appState.isChatGPTAuthenticated {
            HStack(spacing: 10) {
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.success)
                Spacer(minLength: 8)
                Button("Sign Out") { controller.signOutChatGPT() }
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .buttonStyle(.plain)
                    .help("Sign out of ChatGPT")
            }
            .frame(minHeight: 28)
        } else if isSigningInChatGPT {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing in...")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isSigningInChatGPT = true
                    chatGPTSignInError = nil
                    Task {
                        let error = await controller.signInWithChatGPT(selectMeetingSummaryBackend: selectMeetingSummaryBackend)
                        isSigningInChatGPT = false
                        chatGPTSignInError = error
                    }
                } label: {
                    HStack(spacing: 5) {
                        OpenAILogoShape()
                            .fill(MuesliTheme.onAccent)
                            .frame(width: 10, height: 10)
                        Text("Sign in with ChatGPT")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.onAccent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                if let chatGPTSignInError {
                    SettingsNote(chatGPTSignInError, tone: .error)
                }
            }
        }
    }

    @ViewBuilder
    private func openRouterAccountControl(
        selectMeetingSummaryBackend: Bool = true
    ) -> some View {
        if appState.isOpenRouterAuthenticated {
            // Same shape as the ChatGPT account control: status, then compact actions.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Label(
                        appState.isOpenRouterEnvironmentManaged ? "Environment key" : "Connected",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: MuesliTheme.spacing8)
                    Button("Manage key") { controller.manageOpenRouterKey() }
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Manage this key at OpenRouter")
                    if appState.hasStoredOpenRouterCredential {
                        Button(appState.isOpenRouterEnvironmentManaged ? "Forget local" : "Disconnect") {
                            openRouterSignInError = controller.signOutOpenRouter()
                        }
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Remove muesli's local copy of this OpenRouter key")
                    } else {
                        Text("Managed externally")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .fixedSize()
                    }
                }
                .frame(minHeight: 28)

                if let openRouterSignInError {
                    SettingsNote(openRouterSignInError, tone: .error)
                }
            }
        } else if isSigningInOpenRouter {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting...")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    isSigningInOpenRouter = true
                    openRouterSignInError = nil
                    Task {
                        let error = await controller.signInWithOpenRouter(
                            selectMeetingSummaryBackend: selectMeetingSummaryBackend
                        )
                        isSigningInOpenRouter = false
                        openRouterSignInError = error
                        if error == nil, appState.dictationProvider == .openRouter {
                            loadOpenRouterTranscriptionModelsIfNeeded()
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.onAccent)
                        Text("Connect OpenRouter")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.onAccent)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)

                Button(isEnteringOpenRouterAPIKey ? "Cancel manual key" : "Enter API key manually") {
                    isEnteringOpenRouterAPIKey.toggle()
                    manualOpenRouterAPIKey = ""
                    openRouterSignInError = nil
                }
                .buttonStyle(.link)
                .font(MuesliTheme.caption())

                if isEnteringOpenRouterAPIKey {
                    HStack(spacing: 6) {
                        PastableSecureField(
                            text: manualOpenRouterAPIKey,
                            placeholder: "sk-or-...",
                            onChange: { manualOpenRouterAPIKey = $0 }
                        )
                        .frame(height: 22)

                        Button("Save") {
                            openRouterSignInError = controller.storeManualOpenRouterAPIKey(
                                manualOpenRouterAPIKey,
                                selectMeetingSummaryBackend: selectMeetingSummaryBackend
                            )
                            if openRouterSignInError == nil {
                                manualOpenRouterAPIKey = ""
                                isEnteringOpenRouterAPIKey = false
                                if appState.dictationProvider == .openRouter {
                                    loadOpenRouterTranscriptionModelsIfNeeded()
                                }
                            }
                        }
                        .disabled(manualOpenRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let openRouterSignInError {
                    SettingsNote(openRouterSignInError, tone: .error)
                }
            }
        }
    }


    private var maraudersMapControl: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            settingsControl("marauders_audio")
            Button("Custom…") { pickCustomAudioFile() }
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

    private func pickExistingClaudeCodeExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose your existing Claude Code executable"
        panel.prompt = "Use Claude Code"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        presentOpenPanel(panel) { url in
            let path = url.standardizedFileURL.path
            guard ClaudeCodeSummarizer.executableURL(configuredPath: path) != nil else {
                isShowingInvalidClaudeCodeExecutableAlert = true
                return
            }
            controller.updateConfig {
                $0.claudeCodeExecutablePath = path
                $0.meetingSummaryBackend = MeetingSummaryBackendOption.claudeCode.backend
            }
        }
    }

    private func pickAutoExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for exported notes"
        panel.prompt = "Choose Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferredAutoExportDirectoryURL()

        presentOpenPanel(panel) { url in
            controller.updateConfig { $0.autoExportMarkdownFolderPath = url.standardizedFileURL.path }
        }
    }

    private func preferredAutoExportDirectoryURL() -> URL {
        let configuredPath = appState.config.autoExportMarkdownFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPath).standardizedFileURL
            if FileManager.default.fileExists(atPath: configuredURL.path) {
                return configuredURL
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
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
                action: { CGRequestScreenCaptureAccess() },
                pane: "Privacy_ScreenCapture"
            )
            if appState.config.useCoreAudioTap {
                Divider().background(MuesliTheme.surfaceBorder)
                permissionStatusRow(
                    "System Audio",
                    granted: systemAudioGranted,
                    action: {
                        guard !isCheckingSystemAudioPermission else { return }
                        isCheckingSystemAudioPermission = true
                        Task { @MainActor in
                            defer { isCheckingSystemAudioPermission = false }
                            systemAudioGranted = await CoreAudioSystemRecorder.requestSystemAudioAccess()
                        }
                    },
                    pane: "Privacy_ScreenCapture",
                    isBusy: isCheckingSystemAudioPermission
                )
            }
            Divider().background(MuesliTheme.surfaceBorder)
            permissionStatusRow(
                "Calendars",
                granted: calendarPermission.granted,
                action: requestCalendarPermission,
                pane: "Privacy_Calendars",
                isBusy: calendarPermission.requesting,
                actionTitle: calendarPermission.canRequest ? "Grant" : "Open Settings"
            )
            if let errorMessage = calendarPermission.errorMessage {
                SettingsNote(errorMessage, tone: .error)
                    .padding(.bottom, MuesliTheme.spacing4)
            }
        }
    }

    @ViewBuilder
    private func permissionStatusRow(
        _ name: String,
        granted: Bool,
        action: @escaping () -> Void,
        pane: String,
        isBusy: Bool = false,
        actionTitle: String = "Grant"
    ) -> some View {
        settingsCompactRow(name) {
            HStack(spacing: MuesliTheme.spacing8) {
                permissionStatusControl(granted: granted, actionTitle: actionTitle, isBusy: isBusy, action: action)
                Button {
                    openPrivacyPane(pane)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in System Settings")
                .accessibilityLabel("Open \(name) in System Settings")
            }
        }
    }

    /// Shared by Permissions and Calendars so the same permission reads the same way in both places.
    @ViewBuilder
    private func permissionStatusControl(
        granted: Bool,
        actionTitle: String,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.success)
        } else {
            accentActionButton(isBusy ? "Checking…" : actionTitle, action: action)
                .disabled(isBusy)
        }
    }

    private func accentActionButton(
        _ title: String,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestCalendarPermission() {
        calendarPermission.refresh()
        guard calendarPermission.canRequest else {
            CalendarIntegration.openPrivacy()
            return
        }
        Task { @MainActor in
            await calendarPermission.requestAccess()
            if calendarPermission.granted {
                refreshCalendarSources(reconcileAccess: true)
            }
        }
    }

    @ViewBuilder
    private func screenContextControl() -> some View {
        if accessibilityGranted {
            settingsControl("app_context")
        } else {
            accentActionButton("Grant") {
                handleScreenContextToggle(true)
            }
        }
    }

    @ViewBuilder
    private func dictationOCRContextControl() -> some View {
        if !appState.config.enableScreenContext {
            settingsControl("ocr_context")
                .disabled(true)
        } else if screenRecordingGranted {
            settingsControl("ocr_context")
        } else {
            accentActionButton("Grant") {
                _ = CGRequestScreenCaptureAccess()
                refreshPermissionStatuses(for: .permissionRequested)
            }
        }
    }

    @discardableResult
    private func handleScreenContextToggle(_ enabled: Bool) -> Bool {
        guard enabled else {
            clearPendingScreenContextEnable()
            controller.updateConfig {
                $0.enableScreenContext = false
                $0.enableDictationOCRContext = false
            }
            return false
        }

        guard accessibilityGranted else {
            pendingScreenContextEnable = true
            pendingScreenContextRequestedAt = Date().timeIntervalSince1970
            let granted = controller.requestScreenContextEnable()
            controller.refreshInteractionPermissionSnapshot()
            if granted {
                clearPendingScreenContextEnable()
            }
            return granted
        }

        clearPendingScreenContextEnable()
        return controller.requestScreenContextEnable()
    }

    private func startPermissionMonitoring() {
        controller.beginInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
        refreshPermissionStatuses(for: .initialDisplay)
    }

    private func stopPermissionMonitoring() {
        controller.endInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
    }

    private func refreshPermissionStatuses(for reason: SettingsPermissionRefreshReason) {
        calendarPermission.refresh()
        if reason.refreshesLaunchAtLogin {
            controller.refreshLaunchAtLoginState()
        }
        controller.refreshInteractionPermissionSnapshot()
        if reason.refreshesSystemAudio {
            refreshSystemAudioPermissionIfNeeded()
        }
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
    private func settingsSection(
        _ title: String,
        icon: NSImage? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            SettingsSectionHeading(title: title, icon: icon)

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

    /// Menus, fields and compound controls: a bounded trailing column that stacks in narrow windows.
    private func settingsRow(
        _ label: String,
        description: String? = nil,
        controlWidth rowControlWidth: CGFloat? = nil,
        @ViewBuilder control: () -> some View
    ) -> some View {
        SettingsRow(label: label, description: description, controlWidth: rowControlWidth ?? controlWidth, control: control)
    }

    /// Switches and small buttons: intrinsic width, so the label keeps the remaining space.
    private func settingsCompactRow(
        _ label: String,
        description: String? = nil,
        @ViewBuilder control: () -> some View
    ) -> some View {
        SettingsRow(label: label, description: description, controlWidth: nil, control: control)
    }

    /// Optional setup reference, kept out of the way but available without hovering.
    private func settingsDetails(_ title: String, @ViewBuilder content: @escaping () -> some View) -> some View {
        DisclosureGroup {
            content()
                .padding(.top, MuesliTheme.spacing4)
        } label: {
            Text(title)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(.bottom, MuesliTheme.spacing8)
    }

    // MARK: - Controls

    private func settingsControl(_ id: String) -> some View {
        MuesliSettingControl(controller: controller, id: id)
    }

    @ViewBuilder
    private func compactActionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(MuesliTheme.font(size: 12, weight: .medium))
            .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isDestructive ? Color.clear : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                ForEach(MuesliSettings.meetingDetectionAppOptions) { app in
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
                    .font(MuesliTheme.callout())
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
        controller.setSettingFromUI("mute_meeting_detection_" + bundleID, value: isMuted ? "on" : "off")
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
                items: items
            ))
        }

        return groups
    }

    private var calendarSourcesControl: some View {
        let sourceGroups = calendarSourceGroups
        return VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            if calendarPermission.granted {
                if sourceGroups.isEmpty {
                    SettingsNote(calendarSourcesRefresh.isLoading ? "Loading calendars…" : "No calendars on this Mac.")
                } else {
                    SettingsNote("Choose calendars to show meetings from.")
                    ForEach(sourceGroups) { group in
                        calendarSourceGroupView(group)
                    }
                }
            }
            HStack {
                Button("Manage accounts…", action: CalendarIntegration.openAccounts)
                    .buttonStyle(.link)
                    .help("Add or remove accounts in macOS Internet Accounts. Changes also affect other apps on this Mac.")
                Spacer()
                Button("Open Calendar…", action: CalendarIntegration.openCalendar)
                    .buttonStyle(.link)
                    .help("Manage local calendars and subscriptions in Apple Calendar.")
            }
        }
        .padding(.top, MuesliTheme.spacing8)
    }

    @ViewBuilder
    private func calendarSourceGroupView(_ group: CalendarSourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: CalendarIntegration.calendarIcon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(MuesliTheme.font(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)

                    Text("\(group.subtitle) • \(group.items.count) \(group.items.count == 1 ? "calendar" : "calendars")")
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(MuesliTheme.textSecondary)
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
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
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
                    .font(MuesliTheme.callout())
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
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isEnabled ? "Included" : "Hidden")
    }

    private func refreshMeetingCalendarSourcesIfNeeded() {
        guard calendarSourcesRefresh.needsInitialRefresh else { return }
        refreshCalendarSources()
    }

    private func refreshCalendarSources(reconcileAccess: Bool = false) {
        calendarSourcesRefresh.begin()
        Task { @MainActor in
            defer { calendarSourcesRefresh.finish(completed: !Task.isCancelled) }
            if reconcileAccess {
                await controller.calendarAccessDidChange()
            } else {
                await controller.refreshAvailableEventKitCalendars()
            }
        }
    }

    private func updateDisabledCalendar(_ calendarID: String, isDisabled: Bool) {
        controller.setSettingFromUI("calendar_" + calendarID, value: isDisabled ? "off" : "on")
    }

    @ViewBuilder
    private var autoExportFolderPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)

                if appState.config.autoExportMarkdownFolderPath.isEmpty {
                    Text("Choose a folder…")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.autoExportMarkdownFolderPath)
                        .font(MuesliTheme.callout())
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
            .help(appState.config.autoExportMarkdownFolderPath.isEmpty ? "No destination folder selected" : appState.config.autoExportMarkdownFolderPath)

            if !appState.config.autoExportMarkdownFolderPath.isEmpty {
                Button {
                    controller.updateConfig { $0.autoExportMarkdownFolderPath = "" }
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
                .accessibilityLabel("Clear destination folder")
                .help("Clear destination folder")
            }

            Button {
                pickAutoExportFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
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
            .accessibilityLabel("Choose destination folder")
            .help("Choose destination folder")
        }
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
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.meetingHookPath)
                        .font(MuesliTheme.callout())
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
            .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var meetingHookTimeoutControl: some View {
        integerInput(
            label: "Meeting hook timeout",
            value: Binding(
                get: { max(appState.config.meetingHookTimeoutSeconds, 1) },
                set: { newValue in
                    controller.updateConfig { $0.meetingHookTimeoutSeconds = max(newValue, 1) }
                }
            ),
            range: 1...600,
            unit: { $0 == 1 ? "second" : "seconds" }
        )
    }

    private func integerInput(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: @escaping (Int) -> String
    ) -> some View {
        let clampedValue = min(max(value.wrappedValue, range.lowerBound), range.upperBound)
        let clampedBinding = Binding(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )

        return HStack(spacing: MuesliTheme.spacing8) {
            TextField(label, value: clampedBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .accessibilityLabel(label)

            Text(unit(clampedValue))
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 58, alignment: .leading)

            Stepper(label, value: clampedBinding, in: range, step: step)
                .labelsHidden()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func settingsModelTextField(
        currentModel: String,
        placeholder: String,
        onBeginEditing: (() -> Void)? = nil,
        onChange: @escaping (String) -> Void
    ) -> some View {
        SettingsModelTextField(
            text: currentModel,
            placeholder: placeholder,
            onBeginEditing: onBeginEditing,
            onChange: onChange
        )
    }

    @ViewBuilder
    private var openRouterFreeModelMenu: some View {
        if appState.openRouterSummaryCatalogState == .loading,
           appState.openRouterSummaryModels.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading models")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if !appState.openRouterSummaryModels.isEmpty {
            HStack(spacing: 8) {
                settingsControl("summary_openrouter_model")
                .frame(height: 24)
                if case .failed = appState.openRouterSummaryCatalogState {
                    Button("Retry") {
                        controller.loadOpenRouterModels(.text, force: true)
                    }
                    .font(MuesliTheme.captionMedium())
                }
            }
        } else {
            HStack(spacing: 8) {
                if case .failed(let message) = appState.openRouterSummaryCatalogState {
                    Text(message)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.recording)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(appState.openRouterSummaryCatalogState == .idle ? "Load" : "Retry") {
                    controller.loadOpenRouterModels(.text, force: true)
                }
                .font(MuesliTheme.captionMedium())
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func loadOpenRouterFreeModelsIfNeeded() {
        controller.loadOpenRouterModels(.text)
    }

    @ViewBuilder
    private var openRouterTranscriptionModelMenu: some View {
        let presets = appState.openRouterTranscriptionModels
        HStack(spacing: 8) {
            if appState.openRouterTranscriptionCatalogState == .loading, presets.isEmpty {
                ProgressView().controlSize(.small)
            }
            settingsControl("openrouter_dictation_model")
            .frame(height: 24)

            if case .failed = appState.openRouterTranscriptionCatalogState {
                Button("Retry") {
                    controller.loadOpenRouterModels(.transcription, force: true)
                }
                .font(MuesliTheme.captionMedium())
            }
        }
    }

    private func loadOpenRouterTranscriptionModelsIfNeeded() {
        controller.loadOpenRouterModels(.transcription)
    }

    @ViewBuilder
    private func keyStatusRow(key: String) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Circle()
                .fill(key.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(key.isEmpty ? "No API key configured" : "Key configured")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(key.isEmpty ? MuesliTheme.textSecondary : MuesliTheme.success)
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: MuesliTheme.spacing8) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
            }
                .font(MuesliTheme.font(size: 13, weight: .medium))
                .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(isDestructive ? Color.clear : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(
                            MuesliTheme.surfaceBorder,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
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
    let disabledOptions: Set<String>
    /// Reports the selected index, avoiding label collision issues.
    let onSelectionIndex: (Int) -> Void

    init(
        selection: String,
        options: [String],
        disabledOptions: Set<String> = [],
        onChange: @escaping (String) -> Void
    ) {
        self.selection = selection
        self.options = options
        self.disabledOptions = disabledOptions
        self.onSelectionIndex = { index in
            guard index >= 0 && index < options.count else { return }
            guard !disabledOptions.contains(options[index]) else { return }
            onChange(options[index])
        }
    }

    init(
        selection: String,
        options: [String],
        disabledOptions: Set<String> = [],
        onSelectIndex: @escaping (Int) -> Void
    ) {
        self.selection = selection
        self.options = options
        self.disabledOptions = disabledOptions
        self.onSelectionIndex = { index in
            guard index >= 0 && index < options.count else { return }
            guard !disabledOptions.contains(options[index]) else { return }
            onSelectIndex(index)
        }
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.removeAllItems()
        button.addItems(withTitles: options)
        button.menu?.autoenablesItems = false
        button.isEnabled = context.environment.isEnabled
        updateEnabledItems(in: button)
        button.selectItem(withTitle: selection)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        let currentTitles = button.itemTitles
        if currentTitles != options {
            button.removeAllItems()
            button.addItems(withTitles: options)
        }
        updateEnabledItems(in: button)
        if button.titleOfSelectedItem != selection {
            button.selectItem(withTitle: selection)
        }
        context.coordinator.onSelectionIndex = onSelectionIndex
    }

    private func updateEnabledItems(in button: NSPopUpButton) {
        for item in button.itemArray {
            item.isEnabled = !disabledOptions.contains(item.title)
        }
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
        field.font = AppFonts.font(size: 13)
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

/// Model IDs stay local to the field editor until Return or focus loss.
struct SettingsModelTextField: View {
    let text: String
    let placeholder: String
    var onBeginEditing: (() -> Void)? = nil
    let onChange: (String) -> Void

    var body: some View {
        PastableTextField(
            text: text,
            placeholder: placeholder,
            onBeginEditing: onBeginEditing,
            commitsOnEndEditing: true,
            showsFullValueOnHover: true,
            onChange: { onChange($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
        .frame(minHeight: 26)
    }
}

/// Plain text field with the same accessory-app edit shortcuts as secure fields.
struct PastableTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onBeginEditing: (() -> Void)?
    let commitsOnEndEditing: Bool
    let showsFullValueOnHover: Bool
    let onChange: (String) -> Void

    init(
        text: String,
        placeholder: String,
        onBeginEditing: (() -> Void)? = nil,
        commitsOnEndEditing: Bool = false,
        showsFullValueOnHover: Bool = false,
        onChange: @escaping (String) -> Void
    ) {
        self.text = text
        self.placeholder = placeholder
        self.onBeginEditing = onBeginEditing
        self.commitsOnEndEditing = commitsOnEndEditing
        self.showsFullValueOnHover = showsFullValueOnHover
        self.onChange = onChange
    }

    func makeNSView(context: Context) -> EditableNSTextField {
        let field = EditableNSTextField()
        field.placeholderString = placeholder
        field.font = AppFonts.font(size: 13)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        if commitsOnEndEditing {
            field.cell?.usesSingleLineMode = true
            field.cell?.lineBreakMode = .byTruncatingMiddle
            if showsFullValueOnHover { field.toolTip = text.isEmpty ? nil : text }
        }
        return field
    }

    func updateNSView(_ nsView: EditableNSTextField, context: Context) {
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.onChange = onChange
        context.coordinator.synchronize(nsView, text: text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, commitsOnEndEditing: commitsOnEndEditing, showsFullValueOnHover: showsFullValueOnHover,
                    onBeginEditing: onBeginEditing, onChange: onChange)
    }

    static func dismantleNSView(_ nsView: EditableNSTextField, coordinator: Coordinator) {
        // AppKit does not guarantee an end-edit notification during removal.
        // Save outside SwiftUI's teardown transaction to avoid publishing into it.
        coordinator.finishEditing(nsView, deferCommit: true)
        nsView.delegate = nil
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var onBeginEditing: (() -> Void)?
        var onChange: (String) -> Void
        private let commitsOnEndEditing: Bool
        private let showsFullValueOnHover: Bool
        private var configuredText: String
        private var editingStartText: String?
        private var draftText: String?
        private var isEditing = false
        private weak var editingField: NSTextField?

        init(text: String, commitsOnEndEditing: Bool, showsFullValueOnHover: Bool,
             onBeginEditing: (() -> Void)?, onChange: @escaping (String) -> Void) {
            self.configuredText = text
            self.commitsOnEndEditing = commitsOnEndEditing
            self.showsFullValueOnHover = showsFullValueOnHover
            self.onBeginEditing = onBeginEditing
            self.onChange = onChange
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
            editingStartText = configuredText
            if let field = obj.object as? NSTextField {
                draftText = field.stringValue
                editingField = field
                if commitsOnEndEditing, let window = field.window {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(windowWillClose(_:)),
                        name: NSWindow.willCloseNotification, object: window
                    )
                }
            }
            onBeginEditing?()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if commitsOnEndEditing {
                draftText = field.stringValue
                if showsFullValueOnHover { field.toolTip = field.stringValue.isEmpty ? nil : field.stringValue }
                return
            }
            onChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            finishEditing(field)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            guard let field = editingField else { return }
            finishEditing(field)
        }

        func finishEditing(_ field: NSTextField, deferCommit: Bool = false) {
            guard isEditing else { return }
            isEditing = false
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            editingField = nil
            let value = draftText ?? field.stringValue
            let changed = value != editingStartText
            editingStartText = nil
            draftText = nil
            guard commitsOnEndEditing else { return }
            if changed {
                configuredText = value
                let commit = onChange
                if deferCommit {
                    DispatchQueue.main.async { commit(value) }
                } else {
                    commit(value)
                }
            } else {
                // An external update may have arrived during an unchanged edit.
                field.stringValue = configuredText
            }
            if showsFullValueOnHover { field.toolTip = field.stringValue.isEmpty ? nil : field.stringValue }
        }

        func synchronize(_ field: NSTextField, text: String) {
            configuredText = text
            // SwiftUI can refresh from unrelated state while the user types.
            // Replacing stringValue here resets the live field editor/caret.
            guard !isEditing, field.currentEditor() == nil else { return }
            if field.stringValue != text { field.stringValue = text }
            if showsFullValueOnHover { field.toolTip = text.isEmpty ? nil : text }
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

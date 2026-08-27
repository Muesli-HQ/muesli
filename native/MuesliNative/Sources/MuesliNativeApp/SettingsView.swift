import AppKit
import AVFoundation
import SwiftUI
import MuesliCore
import TelemetryDeck

private struct MeetingDetectionAppOption: Identifiable {
    let bundleID: String
    let name: String
    let icon: String

    var id: String { bundleID }
}

private struct MicrophoneOption: Identifiable {
    let uid: String?
    let label: String

    var id: String { uid ?? "__automatic__" }
}

enum SettingsPermissionRefreshReason {
    case initialDisplay
    case periodicPoll
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
        case .periodicPoll, .permissionRequested:
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
                    .font(.system(size: 11, weight: .regular))
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

private enum OnDeviceCleanupModel: Identifiable {
    case gguf(PostProcessorOption)
    case gemma4(Gemma4LiteRTModel)

    var id: String {
        switch self {
        case let .gguf(option): option.id
        case let .gemma4(model): model.repoID
        }
    }

    var label: String {
        switch self {
        case let .gguf(option): option.label
        case let .gemma4(model): model.label
        }
    }

    var quilLabel: String {
        switch self {
        case let .gguf(option): option.quilLabel
        case let .gemma4(model): model.label
        }
    }

    var quilBackend: TranscriptCleanupBackendOption {
        switch self {
        case .gguf: .local
        case .gemma4: .gemma4LiteRT
        }
    }

    var quilModelID: String {
        switch self {
        case let .gguf(option): option.id
        case let .gemma4(model): model.repoID
        }
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
    @State private var isEnteringOpenRouterAPIKey = false
    @State private var manualOpenRouterAPIKey = ""
    @State private var googleCalSignInError: String?
    @State private var isSigningInGoogleCal = false
    @State private var pendingDataDestruction: PendingDataDestruction?
    @State private var isShowingDictionaryAccessibilityPrompt = false
    @State private var isPreviewingClip = false
    @State private var selectedPane: SettingsPane
    @State private var downloadedBackendOptions: [BackendOption] = []
    @State private var downloadedPostProcOptions: [PostProcessorOption] = []
    @State private var downloadedMeetingLiveCaptionBackends: [MeetingLiveCaptionBackend] = []
    @State private var audioInputDevices: [AudioInputDeviceInfo] = []
    @State private var audioInputDeviceRefreshTask: Task<Void, Never>?
    @State private var permissionPollTimer: Timer?
    @State private var isCleanupPromptManagerPresented = false
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
    @State private var isUsingCustomOpenRouterModel = false
    @State private var hasRefreshedMeetingCalendarSources = false
    @State private var isShowingICloudSyncReconnectConfirmation = false
    @State private var isShowingICloudSyncResetConfirmation = false
    @State private var isShowingIPhoneBridgeQRCode = false
    @State private var openAIDictationAPIKey: String = ""
    @State private var openAITestState: OpenAIConnectionTestState = .idle

    init(appState: AppState, controller: MuesliController) {
        self.appState = appState
        self.controller = controller
        _selectedPane = State(initialValue: appState.selectedSettingsPane)
    }

    // Uniform width for standard right-side controls.
    private let controlWidth: CGFloat = 220
    // Wider controls keep model/provider selections visually consistent in Settings.
    private let meetingControlWidth: CGFloat = 275
    private let screenContextGrantIntentTimeout: TimeInterval = 15 * 60
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

    private var dictationBackendOptions: [BackendOption] {
        guard appState.dictationProvider == .openAI else {
            return backendOptions(including: appState.selectedBackend)
        }
        return downloadedBackendOptions.filter(\.supportsOpenAIFallback)
    }

    private var displayedDictationBackend: BackendOption? {
        guard appState.dictationProvider == .openAI else { return appState.selectedBackend }
        return BackendOption.resolveOpenAIFallback(
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
            && appState.config.resolvedMeetingLiveCaptionBackend == .nemotron35
            && downloadedMeetingLiveCaptionBackends.contains(.nemotron35)
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
        for model in Gemma4LiteRTModel.allCases where Gemma4LiteRTModelStore.isAvailableLocally(model: model) {
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
        appState.selectedPostProcessorBackend == .local
            && appState.activePostProcessor.inputFormat == .s1Mini
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
        UpcomingMeetingsWindow.resolve(dayCount: appState.config.upcomingMeetingsDayCount)
    }

    private var selectedIndicASRLanguage: IndicASRLanguage {
        appState.config.resolvedIndicASRLanguage
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
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                    Text("Settings")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    settingsPanePicker
                    paneContent
                }
                .padding(.horizontal, MuesliTheme.spacing32)
            .padding(.top, MuesliTheme.pageTop)
            .padding(.bottom, MuesliTheme.spacing32)
            }
            .background(MuesliTheme.backgroundBase)
            .onAppear {
                refreshDownloadedModelOptions()
                refreshAudioInputDevices()
                startPermissionPolling()
                if appState.selectedMeetingSummaryBackend == .openRouter {
                    loadOpenRouterFreeModelsIfNeeded()
                }
                scrollToFeatureTourTarget(activeFeatureTourTarget, using: scrollProxy)
            }
            .onDisappear {
                SoundController.stopMaraudersMapClip()
                isPreviewingClip = false
                audioInputDeviceRefreshTask?.cancel()
                audioInputDeviceRefreshTask = nil
                stopPermissionPolling()
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
                Text("Dictionary suggestions briefly read focused app text via Accessibility after dictation. Grant access, then relaunch Muesli to turn suggestions on.")
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
              target == .liveCaptionsSetting || target == .cloudCleanupSetting else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target.rawValue, anchor: .center)
            }
        }
    }

    private func refreshDownloadedModelOptions() {
        controller.refreshMeetingTranscriptionSelectionForAvailability()
        downloadedBackendOptions = BackendOption.downloaded
        downloadedPostProcOptions = PostProcessorOption.downloaded
        downloadedMeetingLiveCaptionBackends = MeetingLiveCaptionBackend.allCases.filter(\.isDownloaded)
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

    private static let accentPresets: [(hex: String, name: String)] = [
        ("2563eb", "Blue"),
        ("ef4444", "Red"),
        ("f59e0b", "Amber"),
        ("10b981", "Green"),
        ("8b5cf6", "Purple"),
        ("ec4899", "Pink"),
        ("1e1e2e", "Dark"),
    ]

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

    @ViewBuilder
    private func screenContextRow(
        _ title: String,
        includesScreenOCR: Bool = false,
        controlWidth rowControlWidth: CGFloat? = nil
    ) -> some View {
        let width = rowControlWidth ?? controlWidth
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(screenContextDescription(includesScreenOCR: includesScreenOCR))
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

    @ViewBuilder
    private var dictationOCRContextRow: some View {
        let width = controlWidth
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen OCR context")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(dictationOCRContextDescription)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 20)

            ZStack(alignment: .trailing) {
                Color.clear.frame(width: width, height: 1)
                dictationOCRContextControl(width: width)
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
            .frame(width: 760)
            Spacer()
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalSettingsPane
        case .sync:
            syncSettingsPane
        case .dictation:
            dictationSettingsPane
        case .computerUse:
            computerUseSettingsPane
        case .meetings:
            meetingsSettingsPane
        case .appearance:
            appearanceSettingsPane
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

    private var syncSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("iCloud Sync") {
                HStack(spacing: MuesliTheme.spacing12) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Sync with iPhone or iPad")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(syncStatusText)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let lastSyncedText = syncLastSyncedText {
                            Text("Last synced: \(lastSyncedText)")
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        if let linkedDevice = syncLinkedDevice {
                            ICloudLinkedDeviceRow(device: linkedDevice)
                                .padding(.top, MuesliTheme.spacing4)
                        } else if let unlinkedDeviceText = syncUnlinkedDeviceText {
                            Text(unlinkedDeviceText)
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: MuesliTheme.spacing16)
                    syncFlowControls
                        .frame(width: controlWidth)
                }

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
                return "Couldn't find your device. Open Muesli there, then try again."
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
        guard appState.config.iCloudSyncEnabled else { return nil }
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
                settingsMenu(
                    selection: appState.dictationProvider.label,
                    options: DictationProvider.allCases.map(\.label)
                ) { label in
                    if let provider = DictationProvider.allCases.first(where: { $0.label == label }) {
                        controller.selectDictationProvider(provider)
                    }
                }
            }
            Divider().background(MuesliTheme.surfaceBorder)
            if appState.dictationProvider == .openAI {
                openAIDictationSettingsRows
                Divider().background(MuesliTheme.surfaceBorder)
            }
            settingsRow(appState.dictationProvider == .openAI ? "Fallback model" : "Dictation model", controlWidth: meetingControlWidth) {
                if let displayedDictationBackend {
                    settingsMenu(
                        selection: displayedDictationBackend.label,
                        options: dictationBackendOptions.map(\.label),
                        disabledOptions: disabledDictationBackendLabels
                    ) { label in
                        if let option = dictationBackendOptions.first(where: { $0.label == label }) {
                            controller.selectBackend(option)
                        }
                    }
                } else {
                    Text("No compatible model installed")
                        .foregroundStyle(.secondary)
                }
            }
            if appState.dictationProvider == .openAI {
                settingsDescription(
                    displayedDictationBackend == nil
                        ? "Download a non-streaming local model to enable automatic fallback."
                        : "Used automatically if the Realtime connection fails."
                )
            }
            if !disabledDictationBackendLabels.isEmpty {
                settingsDescription("Gemma 4 dictation is unavailable while Gemma 4 is the cleanup backend.")
            }
            if displayedDictationBackend?.backend == BackendOption.cohereTranscribe.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Cohere language", controlWidth: meetingControlWidth) {
                    cohereLanguageMenu
                }
            }
            if displayedDictationBackend?.backend == BackendOption.indicASR.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Indic language", controlWidth: meetingControlWidth) {
                    indicLanguageMenu
                }
            }
            if displayedDictationBackend?.supportsWhisperLanguageSelection == true {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Whisper language", controlWidth: meetingControlWidth) {
                    whisperLanguageMenu
                }
            }
        }
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
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Model", controlWidth: meetingControlWidth) {
            settingsModelMenu(
                currentModel: appState.config.openaiDictationModel,
                presets: openAIDictationModelPresets
            ) { controller.selectOpenAIDictationModel($0) }
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Connection", controlWidth: meetingControlWidth) {
            openAITestControl
        }
    }

    private var openAIDictationModelPresets: [SummaryModelPreset] {
        OpenAITranscriptionClient.modelPresets.map { SummaryModelPreset(id: $0, label: $0) }
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        case .success:
            HStack(spacing: 6) {
                Spacer()
                Circle()
                    .fill(MuesliTheme.success)
                    .frame(width: 6, height: 6)
                Text("Connected")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.success)
                compactActionButton("Test again") {
                    testOpenAIConnection()
                }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Spacer()
                Text("Failed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.recording)
                    .help(message)
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
                description: "Only affects Muesli. Changes apply immediately.",
                controlWidth: meetingControlWidth
            ) {
                let options = meetingMicrophoneOptions
                FixedWidthPopUp(
                    selection: selectedMeetingMicrophoneLabel,
                    options: options.map(\.label),
                    onSelectIndex: { index in
                        guard options.indices.contains(index) else { return }
                        controller.selectMeetingInputDeviceUID(options[index].uid)
                        loadCachedAudioInputDevices()
                    }
                )
                .frame(height: 24)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow(
                "Show transcript on hover",
                description: "Show recent transcript beside the waveform.",
                controlWidth: meetingControlWidth
            ) {
                settingsSwitch(isOn: appState.config.showMeetingTranscriptOnIndicatorHover) { newValue in
                    controller.updateConfig { $0.showMeetingTranscriptOnIndicatorHover = newValue }
                }
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow(
                "Live preview model",
                description: meetingLiveTranscriptDescription,
                controlWidth: meetingControlWidth
            ) {
                if !downloadedMeetingLiveCaptionBackends.isEmpty {
                    settingsMenu(
                        selection: selectedMeetingLiveCaptionLabel,
                        options: downloadedMeetingLiveCaptionBackends.map(\.settingsLabel) + ["Off"]
                    ) { label in
                        guard label != "Off" else {
                            controller.updateConfig { $0.enableLiveStreamingPartials = false }
                            return
                        }
                        guard let backend = downloadedMeetingLiveCaptionBackends.first(where: { $0.settingsLabel == label }) else {
                            return
                        }
                        controller.updateConfig {
                            $0.meetingLiveCaptionBackend = backend.rawValue
                            $0.enableLiveStreamingPartials = true
                        }
                    }
                } else {
                    Text("Download from Models")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: meetingControlWidth, alignment: .trailing)
                }
            }
            .id(FeatureTourTarget.liveCaptionsSetting.rawValue)
            .featureTourTarget(.liveCaptionsSetting)
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Final transcript", controlWidth: meetingControlWidth) {
                if usesUnifiedMeetingTranscript {
                    Text("\(MeetingLiveCaptionBackend.nemotron35.label) (same model)")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: meetingControlWidth, alignment: .trailing)
                } else if meetingBackendOptions.isEmpty {
                    Text("No downloaded models")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    settingsMenu(
                        selection: selectedMeetingBackendLabel,
                        options: meetingBackendOptions.map(\.label)
                    ) { label in
                        if let option = meetingBackendOptions.first(where: { $0.label == label }) {
                            controller.selectMeetingTranscriptionBackend(option)
                        }
                    }
                }
            }
            if usesUnifiedMeetingTranscript {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Language", controlWidth: meetingControlWidth) {
                    nemotron35LanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.cohereTranscribe.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Cohere language", controlWidth: meetingControlWidth) {
                    cohereLanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.backend == BackendOption.indicASR.backend {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Indic language", controlWidth: meetingControlWidth) {
                    indicLanguageMenu
                }
            } else if appState.selectedMeetingTranscriptionBackend.supportsWhisperLanguageSelection {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Whisper language", controlWidth: meetingControlWidth) {
                    whisperLanguageMenu
                }
            }
        }
    }

    private var dictationCleanupSettingsSection: some View {
        settingsSection("Dictation Cleanup") {
            settingsRow("AI transcript cleanup") {
                settingsSwitch(isOn: appState.config.enablePostProcessor) { newValue in
                    controller.setPostProcessorEnabled(newValue)
                }
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
                    settingsMenu(
                        selection: selectedCleanupBackendLabel,
                        options: cleanupBackendOptions.map(\.label)
                    ) { label in
                        if let option = cleanupBackendOptions.first(where: { $0.label == label }) {
                            controller.selectPostProcessorBackend(option)
                        }
                    }
                }
                .id(FeatureTourTarget.cloudCleanupSetting.rawValue)
                .featureTourTarget(.cloudCleanupSetting)
                if appState.selectedPostProcessorBackend.isOnDevice {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Cleanup model", controlWidth: meetingControlWidth) {
                        if onDeviceCleanupModels.isEmpty {
                            compactActionButton("View cleanup models", systemImage: "arrow.right") {
                                controller.showModels(category: .postProcessing)
                            }
                            .frame(width: meetingControlWidth, alignment: .trailing)
                        } else {
                            FixedWidthPopUp(
                                selection: selectedOnDeviceCleanupModelLabel,
                                options: onDeviceCleanupModels.map(\.label),
                                onSelectIndex: { index in
                                    guard onDeviceCleanupModels.indices.contains(index) else { return }
                                    switch onDeviceCleanupModels[index] {
                                    case let .gguf(option):
                                        controller.selectPostProcessor(option)
                                    case let .gemma4(model):
                                        controller.selectGemma4PostProcessor(model)
                                    }
                                }
                            )
                            .frame(height: 24)
                        }
                    }
                    if gemmaCleanupIsUnavailable {
                        Text("Gemma 4 is unavailable for cleanup while a Gemma 4 model is selected for dictation.")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    hostedCleanupSettings(for: appState.selectedPostProcessorBackend)
                }
            }
        }
    }

    private var quilSettingsSection: some View {
        settingsSection("Quill", icon: QuillIcon.image()) {
            settingsRow(
                "Rewrite selected text",
                description: "Highlight text to transform it. With no selection, Quill generates and pastes at the cursor."
            ) {
                settingsSwitch(isOn: appState.config.enableQuilMode) { newValue in
                    _ = controller.updateQuilModeEnabled(newValue)
                }
            }
            if appState.config.enableQuilMode {
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "Play Quill sounds",
                    description: "Play the activation and release cues for Quill mode."
                ) {
                    settingsSwitch(isOn: appState.config.quilSoundEnabled) { newValue in
                        controller.updateConfig { $0.quilSoundEnabled = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Model source", controlWidth: meetingControlWidth) {
                    settingsMenu(
                        selection: selectedQuilModelSource.label,
                        options: QuilModelSourceOption.all.map(\.label)
                    ) { label in
                        guard let source = QuilModelSourceOption.all.first(where: { $0.label == label }) else {
                            return
                        }
                        if source == .localModels {
                            if !selectedQuilBackend.isOnDevice {
                                selectQuilLocalModel(quilLocalModels.first)
                            }
                        } else if let backend = source.hostedBackend {
                            controller.updateConfig {
                                $0.quilBackend = backend.backend
                                $0.quilModel = TranscriptCleanupClient.defaultModel(for: backend)
                            }
                        }
                    }
                }
                if selectedQuilBackend.isOnDevice {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Quill model", controlWidth: meetingControlWidth) {
                        if quilLocalModels.isEmpty {
                            compactActionButton("View local models", systemImage: "arrow.right") {
                                controller.showModels(category: .postProcessing)
                            }
                            .frame(width: meetingControlWidth, alignment: .trailing)
                        } else {
                            FixedWidthPopUp(
                                selection: selectedQuilLocalModelLabel,
                                options: quilLocalModels.map(\.quilLabel),
                                onSelectIndex: { index in
                                    guard quilLocalModels.indices.contains(index) else { return }
                                    selectQuilLocalModel(quilLocalModels[index])
                                }
                            )
                            .frame(height: 24)
                        }
                    }
                } else {
                    hostedQuilSettings(for: selectedQuilBackend)
                }
            }
        }
    }

    private func selectQuilLocalModel(_ model: OnDeviceCleanupModel?) {
        controller.updateConfig {
            let resolved = model ?? .gguf(PostProcessorOption.defaultQuilOption)
            $0.quilBackend = resolved.quilBackend.backend
            $0.quilModel = resolved.quilModelID
        }
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
            settingsRow("Quill model", controlWidth: meetingControlWidth) {
                settingsModelTextField(
                    currentModel: appState.config.quilModel,
                    placeholder: TranscriptCleanupClient.defaultModel(for: backend)
                ) { value in controller.updateConfig { $0.quilModel = value } }
            }
        }
    }

    private var cohereLanguageMenu: some View {
        settingsMenu(
            selection: selectedCohereLanguage.label,
            options: CohereTranscribeLanguage.allCases.map(\.label)
        ) { label in
            guard let language = CohereTranscribeLanguage.allCases.first(where: { $0.label == label }) else { return }
            controller.selectCohereLanguage(language)
        }
    }

    private var nemotron35LanguageMenu: some View {
        settingsMenu(
            selection: selectedNemotron35Language.label,
            options: Nemotron35Language.allCases.map(\.label)
        ) { label in
            guard let language = Nemotron35Language.allCases.first(where: { $0.label == label }) else { return }
            Task { await controller.setNemotron35Language(language) }
        }
    }

    private var whisperLanguageMenu: some View {
        settingsMenu(
            selection: selectedWhisperLanguage.label,
            options: WhisperKitLanguage.allCases.map(\.label)
        ) { label in
            guard let language = WhisperKitLanguage.allCases.first(where: { $0.label == label }) else { return }
            controller.selectWhisperLanguage(language)
        }
    }

    private var indicLanguageMenu: some View {
        FixedWidthPopUp(
            selection: selectedIndicASRLanguage.label,
            options: IndicASRLanguage.allCases.map(\.label),
            onSelectIndex: { index in
                guard index >= 0, index < IndicASRLanguage.allCases.count else { return }
                controller.selectIndicASRLanguage(IndicASRLanguage.allCases[index])
            }
        )
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
                settingsModelMenu(
                    currentModel: appState.config.postProcessorChatGPTModel,
                    presets: SummaryModelPreset.chatGPTTranscriptCleanupModels
                ) { controller.updatePostProcessorModel($0, for: backend) }
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
                settingsModelMenu(
                    currentModel: appState.config.postProcessorOpenAIModel,
                    presets: SummaryModelPreset.openAIModels
                ) { controller.updatePostProcessorModel($0, for: backend) }
            }
            keyStatusRow(key: appState.config.openAIAPIKey)
        case .some(.openRouter):
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Account", controlWidth: meetingControlWidth) {
                openRouterAccountControl(selectMeetingSummaryBackend: false)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Model preset", controlWidth: meetingControlWidth) {
                settingsModelMenu(
                    currentModel: appState.config.postProcessorOpenRouterModel,
                    presets: SummaryModelPreset.openRouterModels
                ) { controller.updatePostProcessorModel($0, for: backend) }
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
                FixedWidthPopUp(
                    selection: selectedCleanupPromptName,
                    options: cleanupPromptPresets.map(\.name),
                    onSelectIndex: { index in
                        guard index >= 0, index < cleanupPromptPresets.count else { return }
                        controller.selectTranscriptCleanupPrompt(id: cleanupPromptPresets[index].id)
                    }
                )
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
            description: "S1-mini uses Superwhisper’s built-in normalization instructions.",
            controlWidth: meetingControlWidth
        ) {
            Text("Built in")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: meetingControlWidth, alignment: .trailing)
        }
    }

    private var meetingSummarySettingsSection: some View {
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
                    chatGPTAccountControl()
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
                        placeholder: "provider/model",
                        onBeginEditing: { isUsingCustomOpenRouterModel = true }
                    ) { val in controller.updateConfig { $0.openRouterModel = val } }
                }
            }
        }
    }

    @ViewBuilder
    private func customLLMSettingsRows(model: String, onModelChange: @escaping (String) -> Void) -> some View {
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("API Format", controlWidth: meetingControlWidth) {
            settingsMenu(
                selection: CustomLLMFormat(rawValue: appState.config.customLLMFormat)?.label ?? CustomLLMFormat.openAI.label,
                options: CustomLLMFormat.allCases.map(\.label)
            ) { label in
                guard let format = CustomLLMFormat.allCases.first(where: { $0.label == label }) else { return }
                controller.updateConfig { $0.customLLMFormat = format.rawValue }
            }
        }
        Divider().background(MuesliTheme.surfaceBorder)
        settingsRow("Endpoint", controlWidth: meetingControlWidth) {
            PastableTextField(
                text: appState.config.customLLMURL,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "https://api.anthropic.com"
                    : "http://localhost:8080/v1",
                onChange: { val in controller.updateConfig { $0.customLLMURL = val } }
            )
            .frame(height: 22)
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
        settingsRow("Model", controlWidth: meetingControlWidth) {
            settingsModelTextField(
                currentModel: model,
                placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                    ? "claude-3-5-sonnet-20241022"
                    : "custom-model-id"
            ) { val in onModelChange(val) }
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
                    let options = dictationMicrophoneOptions
                    FixedWidthPopUp(
                        selection: selectedDictationMicrophoneLabel,
                        options: options.map(\.label),
                        onSelectIndex: { index in
                            guard index >= 0, index < options.count else { return }
                            controller.selectDictationInputDeviceUID(options[index].uid)
                            loadCachedAudioInputDevices()
                        }
                    )
                    .frame(height: 24)
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow(
                    "Dictionary suggestions",
                    description: "Suggest words after corrections by briefly reading focused app text via Accessibility."
                ) {
                    settingsSwitch(isOn: appState.config.enableDictionaryCorrectionPrompts) { newValue in
                        handleDictionaryCorrectionPromptsToggle(newValue)
                    }
                    .help("Briefly reads focused app text after dictation to detect corrections.")
                }
            }

            dictationCleanupSettingsSection

            quilSettingsSection

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
                Divider().background(MuesliTheme.surfaceBorder)
                screenContextRow("App context")
                Divider().background(MuesliTheme.surfaceBorder)
                dictationOCRContextRow
            }
        }
    }

    private var computerUseSettingsPane: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            settingsSection("Computer Use") {
                settingsRow("Enable planner", controlWidth: meetingControlWidth) {
                    settingsSwitch(isOn: appState.config.enableComputerUsePlanner) { newValue in
                        controller.updateConfig { $0.enableComputerUsePlanner = newValue }
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Account", controlWidth: meetingControlWidth) {
                    chatGPTAccountControl()
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
                    integerInput(
                        label: "Computer use timeout",
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
                    meetingTemplateMenu(selectionID: appState.config.defaultMeetingTemplateID) { id in
                        controller.updateDefaultMeetingTemplate(id: id)
                    }
                }
                Divider().background(MuesliTheme.surfaceBorder)
                settingsRow("Summary retries", controlWidth: meetingControlWidth) {
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
                settingsDescription("Retry transient AI summary failures before saving failed notes.")
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
                if appState.config.meetingRecordingSavePolicy != .never {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Recording format") {
                        settingsMenu(
                            selection: appState.config.resolvedMeetingRecordingFileFormat.displayName,
                            options: MeetingRecordingFileFormat.allCases.map(recordingFileFormatLabel(for:))
                        ) { label in
                            guard let format = recordingFileFormat(for: label) else { return }
                            controller.updateConfig { $0.meetingRecordingFileFormat = format.rawValue }
                        }
                    }
                    settingsDescription("M4A is recommended for smaller files. WAV is lossless and uses more storage.")
                }
            }

            settingsSection("Auto Export") {
                settingsRow("Auto-export meetings") {
                    settingsSwitch(isOn: appState.config.autoExportMarkdownEnabled) { newValue in
                        controller.updateConfig { $0.autoExportMarkdownEnabled = newValue }
                    }
                }
                if appState.config.autoExportMarkdownEnabled {
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Destination folder") {
                        autoExportFolderPicker
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Content") {
                        settingsMenu(
                            selection: appState.config.resolvedAutoExportMarkdownContent.displayName,
                            options: MeetingExportContent.allCases.map(\.displayName)
                        ) { label in
                            guard let index = MeetingExportContent.allCases.firstIndex(where: { $0.displayName == label }) else { return }
                            let content = MeetingExportContent.allCases[index]
                            controller.updateConfig { $0.autoExportMarkdownContent = content.rawValue }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("File format") {
                        settingsMenu(
                            selection: appState.config.resolvedAutoExportFileFormat.displayName,
                            options: MeetingAutoExportFileFormat.allCases.map(\.displayName)
                        ) { label in
                            guard let format = MeetingAutoExportFileFormat.allCases.first(where: { $0.displayName == label }) else { return }
                            controller.updateConfig { $0.autoExportFileFormat = format.rawValue }
                        }
                    }
                }
                Text("Automatically saves each completed meeting to the chosen folder in the selected format.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.horizontal, MuesliTheme.spacing16)
            }

            settingsSection("Meeting Notifications") {
                settingsRow("Scheduled meetings") {
                    settingsSwitch(isOn: appState.config.showScheduledMeetingNotifications) { newValue in
                        controller.updateConfig { $0.showScheduledMeetingNotifications = newValue }
                    }
                }
                settingsDescription("Show notifications for calendar meetings with a join link.")

                if appState.config.showScheduledMeetingNotifications {
                    Divider().background(MuesliTheme.surfaceBorder)

                    settingsRow("Reminder timing") {
                        settingsMenu(
                            selection: scheduledMeetingLeadTimeLabel(for: appState.config.scheduledMeetingNotificationLeadTime),
                            options: ScheduledMeetingNotificationLeadTime.allCases.map(scheduledMeetingLeadTimeLabel(for:))
                        ) { label in
                            guard let leadTime = scheduledMeetingLeadTime(for: label) else { return }
                            controller.updateConfig { $0.scheduledMeetingNotificationLeadTime = leadTime }
                        }
                    }
                    settingsDescription("At start time avoids early calendar-only prompts before you join.")
                }

                Divider().background(MuesliTheme.surfaceBorder)

                settingsRow("Default action") {
                    settingsMenu(
                        selection: appState.config.meetingJoinDefaultAction.buttonLabel,
                        options: MeetingJoinDefaultAction.allCases.map(\.buttonLabel)
                    ) { label in
                        guard let action = meetingJoinDefaultAction(for: label) else { return }
                        controller.updateConfig { $0.meetingJoinDefaultAction = action }
                    }
                }
                settingsDescription("Primary button for notifications and Coming Up. Pick “Transcribe Only” if you join in another browser.")

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
                settingsRow("Upcoming meetings", controlWidth: meetingControlWidth) {
                    settingsMenu(
                        selection: selectedUpcomingMeetingsWindow.label,
                        options: UpcomingMeetingsWindow.allCases.map(\.label)
                    ) { label in
                        guard let window = UpcomingMeetingsWindow.allCases.first(where: { $0.label == label }) else { return }
                        controller.updateUpcomingMeetingsWindow(dayCount: window.dayCount)
                    }
                }
                settingsDescription("Controls how many calendar days appear in Coming Up, the menu bar, and scheduled meeting checks.")
                Divider().background(MuesliTheme.surfaceBorder)
                calendarSourcesControl
                    .padding(.bottom, MuesliTheme.spacing8)
            }

            if appState.isGoogleCalendarAvailable {
                settingsSection("Calendar") {
                    settingsRow("Google Calendar") {
                        googleCalendarControl
                    }
                }
            }

            settingsSection("Advanced") {
                settingsRow("Enable post-meeting hook", controlWidth: meetingControlWidth) {
                    settingsSwitch(isOn: appState.config.meetingHookEnabled) { newValue in
                        controller.updateConfig { $0.meetingHookEnabled = newValue }
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
                settingsDescription("Runs a user-supplied executable after each completed meeting. The executable receives JSON on stdin and must already be runnable on its own.")
            }
            .padding(.top, MuesliTheme.spacing8)
        }
        .onAppear {
            refreshMeetingCalendarSourcesIfNeeded()
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
                settingsRow("Show hotkey on floating indicator") {
                    settingsSwitch(isOn: appState.config.showHotkeyOnFloatingIndicator) { newValue in
                        controller.updateConfig { $0.showHotkeyOnFloatingIndicator = newValue }
                    }
                    .disabled(!appState.config.showFloatingIndicator)
                }
                settingsRow("Hover style") {
                    settingsMenu(
                        selection: appState.config.indicatorHoverStyle.label,
                        options: IndicatorHoverStyle.allCases.map(\.label)
                    ) { label in
                        guard let style = IndicatorHoverStyle.allCases.first(where: { $0.label == label }) else { return }
                        controller.updateConfig { $0.indicatorHoverStyle = style }
                    }
                    .disabled(!appState.config.showFloatingIndicator)
                }
                settingsDescription("Classic grows the pill to show the hotkey. Shortcut pill keeps a thin grip and pops a separate label on hover.")
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
                settingsRow("Show hotkey in menu bar") {
                    settingsSwitch(isOn: appState.config.showHotkeyInMenuBar) { newValue in
                        controller.updateConfig { $0.showHotkeyInMenuBar = newValue }
                    }
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

    @ViewBuilder
    private func chatGPTAccountControl(selectMeetingSummaryBackend: Bool = true) -> some View {
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
                        let error = await controller.signInWithChatGPT(selectMeetingSummaryBackend: selectMeetingSummaryBackend)
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
    private func openRouterAccountControl(
        selectMeetingSummaryBackend: Bool = true
    ) -> some View {
        if appState.isOpenRouterAuthenticated {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.success)
                        Text(appState.isOpenRouterEnvironmentManaged ? "Environment key" : "Connected")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .background(MuesliTheme.surfaceBorder)
                        .padding(.vertical, 5)

                    Button {
                        controller.manageOpenRouterKey()
                    } label: {
                        Text("Manage key")
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help("Manage this key at OpenRouter")

                    Divider()
                        .background(MuesliTheme.surfaceBorder)
                        .padding(.vertical, 5)

                    if appState.hasStoredOpenRouterCredential {
                        Button {
                            openRouterSignInError = controller.signOutOpenRouter()
                            if openRouterSignInError == nil && !appState.isOpenRouterAuthenticated {
                                isUsingCustomOpenRouterModel = false
                            }
                        } label: {
                            Text(appState.isOpenRouterEnvironmentManaged ? "Forget local" : "Disconnect")
                                .font(.system(size: 10))
                                .foregroundStyle(MuesliTheme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .help("Remove Muesli's local copy of this OpenRouter key")
                    } else {
                        Text("Managed externally")
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .lineLimit(1)
                    }
                }
                .frame(height: 24)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )

                if let openRouterSignInError {
                    Text(openRouterSignInError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        } else if isSigningInOpenRouter {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting...")
                    .font(.system(size: 11))
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
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Connect OpenRouter")
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

                Button(isEnteringOpenRouterAPIKey ? "Cancel manual key" : "Enter API key manually") {
                    isEnteringOpenRouterAPIKey.toggle()
                    manualOpenRouterAPIKey = ""
                    openRouterSignInError = nil
                }
                .buttonStyle(.link)
                .font(.system(size: 10))

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
                            }
                        }
                        .disabled(manualOpenRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let openRouterSignInError {
                    Text(openRouterSignInError)
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
        }
    }

    @ViewBuilder
    private func permissionStatusRow(
        _ name: String,
        granted: Bool,
        action: @escaping () -> Void,
        pane: String,
        isBusy: Bool = false
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(granted ? MuesliTheme.success : MuesliTheme.recording)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.success)
            } else {
                Button(isBusy ? "Checking…" : "Grant") {
                    action()
                }
                .disabled(isBusy)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
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
        .frame(minHeight: 32)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func screenContextControl(width: CGFloat? = nil) -> some View {
        if accessibilityGranted {
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

    @ViewBuilder
    private func dictationOCRContextControl(width: CGFloat? = nil) -> some View {
        if !appState.config.enableScreenContext {
            settingsSwitch(isOn: false) { _ in }
                .frame(width: width, alignment: .trailing)
                .disabled(true)
        } else if screenRecordingGranted {
            settingsSwitch(isOn: appState.config.enableDictationOCRContext) { newValue in
                controller.updateConfig { $0.enableDictationOCRContext = newValue }
            }
            .frame(width: width, alignment: .trailing)
        } else {
            Button {
                _ = CGRequestScreenCaptureAccess()
                refreshPermissionStatuses(for: .permissionRequested)
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
            accessibilityGranted = AXIsProcessTrusted()
            if granted || accessibilityGranted {
                clearPendingScreenContextEnable()
            }
            return granted || accessibilityGranted
        }

        clearPendingScreenContextEnable()
        return controller.requestScreenContextEnable()
    }

    private func handleDictionaryCorrectionPromptsToggle(_ enabled: Bool) {
        if controller.setDictionaryCorrectionPromptsFromToggle(enabled) == .needsAccessibilityPermission {
            isShowingDictionaryAccessibilityPrompt = true
        }
    }

    private func startPermissionPolling() {
        // Keep the 1 Hz poll limited to cheap TCC snapshots. SMAppService can block
        // the main thread, while probing system audio creates a CoreAudio process
        // tap and can perturb the HAL. Refresh those only at lifecycle boundaries.
        refreshPermissionStatuses(for: .initialDisplay)
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshPermissionStatuses(for: .periodicPoll)
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func refreshPermissionStatuses(for reason: SettingsPermissionRefreshReason) {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        controller.reconcilePendingDictionaryCorrectionAccessibilityEnable()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        if reason.refreshesLaunchAtLogin {
            controller.refreshLaunchAtLoginState()
        }
        if accessibilityGranted && pendingScreenContextEnable {
            if controller.requestScreenContextEnable() {
                clearPendingScreenContextEnable()
            }
        }
        if !accessibilityGranted && isPendingScreenContextGrantExpired {
            clearPendingScreenContextEnable()
        }
        if !accessibilityGranted && appState.config.enableScreenContext {
            clearPendingScreenContextEnable()
            controller.updateConfig {
                $0.enableScreenContext = false
                $0.enableDictationOCRContext = false
            }
        }
        if (!appState.config.enableScreenContext || !screenRecordingGranted) && appState.config.enableDictationOCRContext {
            controller.updateConfig { $0.enableDictationOCRContext = false }
        }
        controller.reclassifyVoiceNotesAsDictationIfReady(
            microphoneGranted: micGranted,
            accessibilityGranted: accessibilityGranted,
            inputMonitoringGranted: inputMonitoringGranted
        )
        if reason.refreshesSystemAudio {
            refreshSystemAudioPermissionIfNeeded()
        }
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
    private func settingsSection(
        _ title: String,
        icon: NSImage? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: 5) {
                if let icon {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(MuesliTheme.textTertiary)
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
    private func settingsMenu(
        selection: String,
        options: [String],
        disabledOptions: Set<String> = [],
        onChange: @escaping (String) -> Void
    ) -> some View {
        FixedWidthPopUp(
            selection: selection,
            options: options,
            disabledOptions: disabledOptions,
            onChange: onChange
        )
            .frame(height: 24)
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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isDestructive ? MuesliTheme.recording.opacity(0.25) : MuesliTheme.surfaceBorder, lineWidth: 1)
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
        let sourceGroups = calendarSourceGroups
        return VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Text("Calendar sources are listed first, with their calendars underneath. Disabled calendars are hidden from Muesli — no notifications, no Coming Up, no meeting detection.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if sourceGroups.isEmpty {
                Text("No calendars detected. Make sure Calendar permission is granted in System Settings > Privacy & Security > Calendars.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sourceGroups) { group in
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

    private func refreshMeetingCalendarSourcesIfNeeded() {
        guard !hasRefreshedMeetingCalendarSources else { return }
        hasRefreshedMeetingCalendarSources = true
        Task {
            async let eventKitRefresh: Void = controller.refreshAvailableEventKitCalendars()
            async let googleRefresh: Void = controller.refreshGoogleCalendarList()
            _ = await (eventKitRefresh, googleRefresh)
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
    private var autoExportFolderPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)

                if appState.config.autoExportMarkdownFolderPath.isEmpty {
                    Text("Choose a folder…")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text(appState.config.autoExportMarkdownFolderPath)
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
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 58, alignment: .leading)

            Stepper(label, value: clampedBinding, in: range, step: step)
                .labelsHidden()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
    private func settingsModelTextField(
        currentModel: String,
        placeholder: String,
        onBeginEditing: (() -> Void)? = nil,
        onChange: @escaping (String) -> Void
    ) -> some View {
        PastableTextField(
            text: currentModel,
            placeholder: placeholder,
            onBeginEditing: onBeginEditing,
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
            let configuredModel = appState.config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuredPreset = openRouterFreeModels.first { $0.id == configuredModel }
            let showsCustomSelection = isUsingCustomOpenRouterModel
                || (!configuredModel.isEmpty && configuredPreset == nil)
            let customLabel = configuredModel.isEmpty
                ? "Custom model ID"
                : "Custom: \(configuredModel)"
            let menuPresets = showsCustomSelection
                ? openRouterFreeModels + [SummaryModelPreset(id: configuredModel, label: customLabel)]
                : openRouterFreeModels
            let selectedLabel = showsCustomSelection
                ? customLabel
                : (configuredPreset?.label ?? openRouterFreeModels[0].label)

            FixedWidthPopUp(
                selection: selectedLabel,
                options: menuPresets.map(\.label),
                onSelectIndex: { index in
                    guard index >= 0 && index < menuPresets.count else { return }
                    if showsCustomSelection && index == openRouterFreeModels.count {
                        isUsingCustomOpenRouterModel = true
                        return
                    }
                    isUsingCustomOpenRouterModel = false
                    let selectedID = openRouterFreeModels[index].id
                    controller.updateConfig {
                        $0.openRouterModel = OpenRouterModelSelection.persistedModelID(for: selectedID)
                    }
                }
            )
            .frame(height: 24)
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

    private func recordingFileFormatLabel(for format: MeetingRecordingFileFormat) -> String {
        format.displayName
    }

    private func recordingFileFormat(for label: String) -> MeetingRecordingFileFormat? {
        let format = MeetingRecordingFileFormat.allCases.first { recordingFileFormatLabel(for: $0) == label }
        if format == nil {
            assertionFailure("Unexpected recording file format label: \(label)")
        }
        return format
    }

    private func scheduledMeetingLeadTimeLabel(for leadTime: ScheduledMeetingNotificationLeadTime) -> String {
        switch leadTime {
        case .atStart:
            return "At start time"
        case .oneMinute:
            return "1 min before"
        case .threeMinutes:
            return "3 min before"
        case .fiveMinutes:
            return "5 min before"
        }
    }

    private func scheduledMeetingLeadTime(for label: String) -> ScheduledMeetingNotificationLeadTime? {
        let leadTime = ScheduledMeetingNotificationLeadTime.allCases.first {
            scheduledMeetingLeadTimeLabel(for: $0) == label
        }
        if leadTime == nil {
            assertionFailure("Unexpected scheduled meeting notification lead time label: \(label)")
        }
        return leadTime
    }

    private func meetingJoinDefaultAction(for label: String) -> MeetingJoinDefaultAction? {
        let action = MeetingJoinDefaultAction.allCases.first { $0.buttonLabel == label }
        if action == nil {
            assertionFailure("Unexpected meeting join default action label: \(label)")
        }
        return action
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
        updateEnabledItems(in: button)
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
    let onBeginEditing: (() -> Void)?
    let onChange: (String) -> Void

    init(
        text: String,
        placeholder: String,
        onBeginEditing: (() -> Void)? = nil,
        onChange: @escaping (String) -> Void
    ) {
        self.text = text
        self.placeholder = placeholder
        self.onBeginEditing = onBeginEditing
        self.onChange = onChange
    }

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
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBeginEditing: onBeginEditing, onChange: onChange)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var onBeginEditing: (() -> Void)?
        var onChange: (String) -> Void

        init(onBeginEditing: (() -> Void)?, onChange: @escaping (String) -> Void) {
            self.onBeginEditing = onBeginEditing
            self.onChange = onChange
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            onBeginEditing?()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onChange(field.stringValue)
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

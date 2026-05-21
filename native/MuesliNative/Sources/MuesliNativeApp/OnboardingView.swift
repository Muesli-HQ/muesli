import AVFoundation
import ApplicationServices
import SwiftUI
import MuesliCore

struct OnboardingView: View {
    let controller: MuesliController
    let appState: AppState

    @State private var currentStep: Int
    @State private var userName: String
    @State private var selectedUseCase: OnboardingUseCase
    @State private var selectedBackend: BackendOption
    @State private var selectedCohereLanguage: CohereTranscribeLanguage
    @State private var summaryBackend: MeetingSummaryBackendOption = .chatGPT
    @State private var apiKey = ""
    @State private var isSigningInChatGPT = false
    @State private var chatGPTSignInDone = false
    @State private var chatGPTSignInError: String?

    // Permission states — polled from OS every second
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var screenRecordingGranted = false
    @State private var systemAudioGranted = false
    @State private var permissionPollTimer: Timer?
    @State private var grantingPermissionName: String?
    @State private var nativePermissionPromptName: String?
    @State private var recentlyGrantedPermissionName: String?

    // Hotkey recorder
    @State private var selectedHotkey: HotkeyConfig
    @State private var isRecordingHotkey = false
    @State private var hotkeyEventMonitor: Any?

    // Model selection
    @State private var showMoreModels = false

    // Dictation test
    @State private var isDictationTesting = false
    @State private var dictationTestResult: String?
    @State private var dictationTestError: String?
    @State private var isModelStillDownloading = false
    @State private var modelReadyBackend: BackendOption?
    @State private var modelDownloadBackend: BackendOption?
    @State private var modelDownloadTask: Task<Void, Never>?
    @State private var modelDownloadProgress: Double?
    @State private var isModelPreparingAfterDownload = false
    @State private var modelDownloadStatus: String?
    @State private var modelDownloadError: String?
    @State private var modelReadyIndicatorBackend: BackendOption?
    @State private var modelReadyIndicatorTask: Task<Void, Never>?

    // Google Calendar
    @State private var isSigningInGoogleCal = false
    @State private var googleCalSignInDone = false
    @State private var googleCalSignInError: String?
    @State private var hasFinishedOnboarding = false

    static let permissionsStep = OnboardingFlow.Step.permissions.rawValue
    static let dictationTestStep = OnboardingFlow.Step.dictationTest.rawValue

    private var orderedSteps: [Int] {
        OnboardingFlow.orderedSteps(for: selectedUseCase)
    }

    private var currentStepIndex: Int {
        OnboardingFlow.stepIndex(currentStep, for: selectedUseCase)
    }

    private var totalSteps: Int {
        orderedSteps.count
    }

    private var onboardingAlternativeModels: [BackendOption] {
        var options = BackendOption.onboarding.filter { $0 != .parakeetMultilingual }
        if BackendOption.onboarding.contains(selectedBackend),
           selectedBackend != .parakeetMultilingual,
           !options.contains(selectedBackend) {
            options.insert(selectedBackend, at: 0)
        }
        return options
    }

    init(
        controller: MuesliController,
        appState: AppState,
        initialStep: Int = 0,
        initialUserName: String = "",
        initialBackend: BackendOption = .parakeetMultilingual,
        initialCohereLanguage: CohereTranscribeLanguage = CohereTranscribeLanguage.defaultLanguage,
        initialHotkey: HotkeyConfig = .default,
        initialSystemAudioRequested: Bool = false,
        initialUseCase: OnboardingUseCase = .dictation,
        initialSummaryBackend: MeetingSummaryBackendOption = .chatGPT,
        initialModelDownloadProgress: Double? = nil,
        initialModelDownloadStatus: String? = nil
    ) {
        self.controller = controller
        self.appState = appState
        // Pre-populate permission states so resumed onboarding reflects grants
        // that happened before the deliberate restart.
        let initialMicGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let initialAccessibilityGranted = AXIsProcessTrusted()
        let initialInputMonitoringGranted = CGPreflightListenEventAccess()
        let initialScreenRecordingGranted = CGPreflightScreenCaptureAccess()
        let initialSystemAudioGranted = initialSystemAudioRequested
        let initialPermissions = OnboardingPermissionSnapshot(
            microphone: initialMicGranted,
            accessibility: initialAccessibilityGranted,
            inputMonitoring: initialInputMonitoringGranted,
            systemAudio: initialSystemAudioGranted,
            screenRecording: initialScreenRecordingGranted
        )
        let permissionGatedInitialStep = OnboardingPermissionGate.resumeStep(
            requestedStep: initialStep,
            permissions: initialPermissions,
            useCase: initialUseCase,
            permissionsStep: Self.permissionsStep,
            dictationTestStep: Self.dictationTestStep
        )
        let effectiveInitialStep = OnboardingFlow.normalizedStep(permissionGatedInitialStep, for: initialUseCase)

        _currentStep = State(initialValue: effectiveInitialStep)
        _userName = State(initialValue: initialUserName)
        _selectedUseCase = State(initialValue: initialUseCase)
        let sanitizedInitialBackend = BackendOption.onboarding.contains(initialBackend) ? initialBackend : .parakeetMultilingual
        _selectedBackend = State(initialValue: sanitizedInitialBackend)
        _selectedCohereLanguage = State(initialValue: initialCohereLanguage)
        _selectedHotkey = State(initialValue: initialHotkey)
        _summaryBackend = State(initialValue: initialSummaryBackend)
        _modelDownloadProgress = State(initialValue: initialModelDownloadProgress)
        _modelDownloadStatus = State(initialValue: initialModelDownloadStatus)
        _micGranted = State(initialValue: initialMicGranted)
        _accessibilityGranted = State(initialValue: initialAccessibilityGranted)
        _inputMonitoringGranted = State(initialValue: initialInputMonitoringGranted)
        _screenRecordingGranted = State(initialValue: initialScreenRecordingGranted)
        _systemAudioGranted = State(initialValue: initialSystemAudioGranted)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: modelStep
                case 2: hotkeyStep
                case 3: permissionsStep
                case 4: dictationTestStep
                case 5: meetingSummaryStep
                case 6: googleCalendarStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().background(MuesliTheme.surfaceBorder)

            // Bottom bar
            HStack {
                HStack(spacing: 6) {
                    ForEach(Array(orderedSteps.enumerated()), id: \.offset) { _, step in
                        Circle()
                            .fill(step == currentStep ? MuesliTheme.accent : MuesliTheme.textTertiary)
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                HStack(spacing: MuesliTheme.spacing12) {
                    if canGoBack {
                        Button("Back") {
                            goToPreviousStep()
                        }
                        .buttonStyle(.plain)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .padding(.horizontal, MuesliTheme.spacing16)
                        .padding(.vertical, MuesliTheme.spacing8)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        )
                    }

                    primaryButton
                }
            }
            .padding(.horizontal, MuesliTheme.spacing32)
            .padding(.vertical, MuesliTheme.spacing16)
        }
        .background(MuesliTheme.backgroundBase)
        .preferredColorScheme(.dark)
        .onAppear {
            saveProgress(atStep: currentStep)
        }
        .onChange(of: currentStep) { _, step in
            saveProgress(atStep: step)
        }
        .onChange(of: userName) { _, _ in
            saveProgress(atStep: currentStep)
        }
        .onChange(of: selectedUseCase) { _, _ in
            if !orderedSteps.contains(currentStep) {
                currentStep = OnboardingFlow.normalizedStep(currentStep, for: selectedUseCase)
            }
            resetModelDownloadForBackendChange()
            saveProgress(atStep: currentStep)
        }
        .onChange(of: selectedBackend) { _, _ in
            resetModelDownloadForBackendChange()
            saveProgress(atStep: currentStep)
        }
        .onChange(of: selectedCohereLanguage) { _, _ in
            saveProgress(atStep: currentStep)
        }
        .onChange(of: modelReadyBackend) { _, _ in
            startDictationTestMonitorIfReady()
        }
        .onChange(of: isModelStillDownloading) { _, _ in
            startDictationTestMonitorIfReady()
        }
        .overlay(alignment: .topTrailing) {
            if shouldShowModelDownloadIndicator {
                modelDownloadIndicator
                    .padding(.top, MuesliTheme.spacing16)
                    .padding(.trailing, MuesliTheme.spacing16)
            }
        }
    }

    // MARK: - Primary Button

    @ViewBuilder
    private var primaryButton: some View {
        switch currentStep {
        case 0:
            onboardingButton("Continue", enabled: !userName.trimmingCharacters(in: .whitespaces).isEmpty) {
                goToNextStep()
            }
        case 1:
            onboardingButton(selectedBackend.isDownloaded ? "Continue" : "Download & Continue", enabled: true) {
                startDownload()
            }
        case 2:
            onboardingButton("Continue", enabled: true) {
                goToNextStep()
            }
        case 3:
            onboardingButton(currentStepIndex == orderedSteps.count - 1 ? "Finish" : "Continue", enabled: requiredPermissionsGranted) {
                if selectedUseCase.includesPushToTalk {
                    saveProgressAndRestart()
                } else if currentStepIndex == orderedSteps.count - 1 {
                    finishOnboarding(withKey: false)
                } else {
                    goToNextStep()
                }
            }
        case 4:
            if dictationTestResult != nil {
                onboardingButton(selectedUseCase.includesMeetings ? "Continue" : "Finish", enabled: true) {
                    if selectedUseCase.includesMeetings {
                        goToNextStep()
                    } else {
                        finishOnboarding(withKey: false)
                    }
                }
            } else {
                HStack(spacing: MuesliTheme.spacing12) {
                    skipButton {
                        if selectedUseCase.includesMeetings {
                            goToNextStep()
                        } else {
                            finishOnboarding(withKey: false)
                        }
                    }
                    onboardingButton(selectedUseCase.includesMeetings ? "Continue" : "Finish", enabled: false) {
                        if selectedUseCase.includesMeetings {
                            goToNextStep()
                        } else {
                            finishOnboarding(withKey: false)
                        }
                    }
                }
            }
        case 5:
            HStack(spacing: MuesliTheme.spacing12) {
                skipButton { goToNextStep() }
                onboardingButton("Continue", enabled: true) {
                    goToNextStep()
                }
            }
        case 6:
            HStack(spacing: MuesliTheme.spacing12) {
                skipButton { finishOnboarding(withKey: true) }
                onboardingButton("Finish", enabled: true) {
                    finishOnboarding(withKey: true)
                }
            }
        default:
            EmptyView()
        }
    }

    private func goToNextStep() {
        guard currentStepIndex < orderedSteps.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = orderedSteps[currentStepIndex + 1]
        }
    }

    private func goToPreviousStep() {
        guard currentStepIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = orderedSteps[currentStepIndex - 1]
        }
    }

    @ViewBuilder
    private func onboardingButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(enabled ? MuesliTheme.accent : MuesliTheme.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func skipButton(action: @escaping () -> Void) -> some View {
        Button("Skip", action: action)
            .buttonStyle(.plain)
            .font(MuesliTheme.body())
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }

    private var shouldShowModelDownloadIndicator: Bool {
        isModelStillDownloading || modelDownloadError != nil || isShowingModelReadyIndicator
    }

    private var isShowingModelReadyIndicator: Bool {
        modelReadyIndicatorBackend == selectedBackend && !isModelStillDownloading && modelDownloadError == nil
    }

    private var isSelectedModelReadyForDictationTest: Bool {
        modelReadyBackend == selectedBackend && !isModelStillDownloading && modelDownloadError == nil
    }

    private var canGoBack: Bool {
        OnboardingFlow.canGoBack(
            from: currentStep,
            useCase: selectedUseCase,
            dictationTestSucceeded: dictationTestResult != nil
        )
    }

    private var modelDownloadIndicator: some View {
        let progress = modelDownloadProgress.map { min(max($0, 0), 1) }
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(MuesliTheme.surfaceBorder)
                    .frame(width: 24, height: 24)

                if isModelPreparingAfterDownload {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                } else if let progress {
                    ModelDownloadProgressShape(progress: progress)
                        .fill(MuesliTheme.accent)
                        .frame(width: 24, height: 24)

                    Circle()
                        .stroke(MuesliTheme.accent.opacity(0.7), lineWidth: 1)
                        .frame(width: 24, height: 24)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(modelDownloadIndicatorTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(modelDownloadError == nil ? MuesliTheme.textSecondary : MuesliTheme.recording)
                    .lineLimit(1)
                Text(modelDownloadIndicatorDetail(progress: progress))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(MuesliTheme.backgroundRaised.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)
        .frame(width: 260, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.2), value: shouldShowModelDownloadIndicator)
    }

    private var modelDownloadIndicatorTitle: String {
        if modelDownloadError != nil {
            return "Download paused"
        }
        if isShowingModelReadyIndicator {
            return "\(selectedBackend.label) ready"
        }
        return "Preparing \(selectedBackend.label)"
    }

    private func modelDownloadIndicatorDetail(progress: Double?) -> String {
        if let modelDownloadError {
            return modelDownloadError
        }
        if isShowingModelReadyIndicator {
            return "Ready to test"
        }
        if let modelDownloadStatus {
            return modelDownloadStatus
        }
        if let progress {
            return "\(Int((progress * 100).rounded()))% complete"
        }
        return "Downloading..."
    }

    private var dictationTestSubtitle: AttributedString {
        let markdown: String
        if isSelectedModelReadyForDictationTest {
            markdown = selectedUseCase.includesVoiceNotes
                ? "Hold **\(selectedHotkey.label)** to record a voice note, then release.\nYour words should appear below."
                : "Hold **\(selectedHotkey.label)** and say something, then release.\nYour words should appear below."
        } else {
            markdown = dictationTestPreparationSubtitleMarkdown
        }
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown.replacingOccurrences(of: "**", with: ""))
    }

    private var dictationTestPreparationSubtitleMarkdown: String {
        let unlockCopy = selectedUseCase.includesVoiceNotes ? "Voice note test" : "Dictation"
        if isModelPreparingAfterDownload {
            return "Optimizing **\(selectedBackend.label)** for this Mac.\n\(unlockCopy) will unlock when it is ready."
        }
        return "Preparing **\(selectedBackend.label)** for your first test.\n\(unlockCopy) will unlock when the model is ready."
    }

    private var modelPreparationHints: [String] {
        if selectedBackend.backend == "whisper" {
            return [
                "Compiling CoreML files for the Neural Engine",
                "Preparing the first dictation test",
                "Future launches will skip most of this",
                "We'll bring Muesli forward when ready",
            ]
        }
        return [
            "Preparing the first dictation test",
            "Future launches will skip most of this",
            "We'll bring Muesli forward when ready",
        ]
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            Spacer()

            MWaveformIcon(barCount: 13, spacing: 3)
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 80, height: 48)

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Welcome to Muesli")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Local-first dictation and meeting transcription for macOS.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Your name")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)

                OnboardingTextField(text: $userName, placeholder: "Enter your name", onSubmit: {
                    if !userName.trimmingCharacters(in: .whitespaces).isEmpty {
                        goToNextStep()
                    }
                })
                    .frame(width: 280, height: 32)
            }

            VStack(spacing: MuesliTheme.spacing8) {
                Text("What will you use Muesli for?")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)

                LazyVGrid(
                    columns: [
                        GridItem(.fixed(132), spacing: MuesliTheme.spacing8),
                        GridItem(.fixed(132), spacing: MuesliTheme.spacing8),
                    ],
                    spacing: MuesliTheme.spacing8
                ) {
                    useCaseCard(
                        icon: "waveform",
                        title: "Voice Notes",
                        subtitle: "Record in Muesli",
                        selected: selectedUseCase == .voiceNotes
                    ) {
                        selectedUseCase = .voiceNotes
                    }

                    useCaseCard(
                        icon: "keyboard.fill",
                        title: "Dictation",
                        subtitle: "Paste into apps",
                        selected: selectedUseCase == .dictation
                    ) {
                        selectedUseCase = .dictation
                    }

                    useCaseCard(
                        icon: "person.2.fill",
                        title: "Meetings",
                        subtitle: "Notes and summaries",
                        selected: selectedUseCase == .meetings
                    ) {
                        selectedUseCase = .meetings
                    }

                    useCaseCard(
                        icon: "rectangle.3.group.fill",
                        title: "Everything",
                        subtitle: "Dictation + meetings",
                        selected: selectedUseCase == .dictationAndMeetings
                    ) {
                        selectedUseCase = .dictationAndMeetings
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func useCaseCard(
        icon: String,
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .white.opacity(0.72) : MuesliTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? .white : MuesliTheme.textSecondary)
            .frame(width: 132, height: 74)
            .background(selected ? MuesliTheme.accent : MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(selected ? MuesliTheme.accent : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Model Selection

    private var modelStep: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            VStack(spacing: MuesliTheme.spacing8) {
                Text("Choose your transcription model")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Start with a fast local model.\nLarger models are available after setup.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, MuesliTheme.spacing24)

            ScrollView {
                VStack(spacing: MuesliTheme.spacing8) {
                    modelCard(option: .parakeetMultilingual)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showMoreModels.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Other models")
                                .font(MuesliTheme.caption())
                            Image(systemName: showMoreModels ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, MuesliTheme.spacing4)

                    if showMoreModels {
                        ForEach(onboardingAlternativeModels, id: \.model) { option in
                            modelCard(option: option)
                        }

                        Text("More models are available after onboarding.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, MuesliTheme.spacing4)
                    }

                    if selectedBackend.backend == BackendOption.cohereTranscribe.backend {
                        cohereLanguageCard
                    }
                }
                .padding(.horizontal, MuesliTheme.spacing32)
            }

        }
        .frame(maxWidth: .infinity)
    }

    private var cohereLanguageCard: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Cohere language")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)

            Text("Cohere does not auto-detect language, so pick the language you want it to transcribe.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)

            FixedWidthPopUp(
                selection: selectedCohereLanguage.label,
                options: CohereTranscribeLanguage.allCases.map(\.label)
            ) { label in
                guard let language = CohereTranscribeLanguage.allCases.first(where: { $0.label == label }) else { return }
                selectedCohereLanguage = language
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .padding(.top, MuesliTheme.spacing8)
    }

    private func modelCard(option: BackendOption) -> some View {
        let isSelected = selectedBackend == option
        return Button {
            selectedBackend = option
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                Circle()
                    .fill(isSelected ? MuesliTheme.accent : Color.clear)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? MuesliTheme.accent : MuesliTheme.textTertiary, lineWidth: 1.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        if option.recommended {
                            Text("Recommended")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(isSelected ? MuesliTheme.accent : MuesliTheme.surfaceBorder, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: Permissions (sequential, one at a time)

    /// The ordered list of permissions to grant during onboarding.
    /// Keep this to the core dictation path so first-run setup gets to a
    /// successful transcription before meeting-specific permissions appear.
    private var permissionSteps: [(icon: String, name: String, description: String, granted: Bool, action: () -> Void)] {
        var steps: [(String, String, String, Bool, () -> Void)] = [
            ("mic.fill", "Microphone", "Record audio for voice notes, dictation, and meetings", micGranted, {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            })
        ]
        if selectedUseCase.includesPushToTalk {
            if selectedUseCase.includesDictation {
                steps += [
                    ("hand.raised.fill", "Accessibility", "Paste transcribed text into other apps", accessibilityGranted, requestAccessibilityPermission),
                ]
            }
            steps += [
            ("keyboard.fill", "Input Monitoring", "Detect hotkey for push-to-talk recording", inputMonitoringGranted, {
                if !CGRequestListenEventAccess() {
                    self.openSystemSettings("Privacy_ListenEvent")
                }
            }),
            ]
        }
        return steps
    }

    /// Index of the current permission being requested.
    private var currentPermissionIndex: Int {
        for (i, step) in permissionSteps.enumerated() {
            if !step.granted { return i }
        }
        return permissionSteps.count
    }

    private var permissionsStep: some View {
        let steps = permissionSteps
        let idx = currentPermissionIndex
        let total = steps.count
        let confirmationIndex = recentlyGrantedPermissionName.flatMap { grantedName in
            steps.firstIndex { $0.name == grantedName }
        }
        let displayIndex = confirmationIndex ?? idx

        return VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            if displayIndex < total {
                let step = steps[displayIndex]
                let isConfirmingGrant = recentlyGrantedPermissionName == step.name

                VStack(spacing: MuesliTheme.spacing8) {
                    Text("Permission \(displayIndex + 1) of \(total)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .textCase(.uppercase)

                    Text(step.name)
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    Text(step.description)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Image(systemName: step.icon)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(isConfirmingGrant ? MuesliTheme.success : MuesliTheme.accent)
                    .frame(height: 64)

                Button {
                    if grantingPermissionName == step.name && !isConfirmingGrant {
                        guard !isWaitingForNativePermissionPrompt(step.name) else { return }
                        openSystemSettingsForPermission(at: displayIndex)
                    } else {
                        grantingPermissionName = step.name
                        recentlyGrantedPermissionName = nil
                        saveProgress(atStep: currentStep)
                        step.action()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isConfirmingGrant {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Text(permissionButtonTitle(for: step.name, isConfirmingGrant: isConfirmingGrant))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.vertical, MuesliTheme.spacing12)
                    .background(isConfirmingGrant ? MuesliTheme.success : MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(isConfirmingGrant || isWaitingForNativePermissionPrompt(step.name))
                .animation(.easeInOut(duration: 0.2), value: isConfirmingGrant)

                // Progress dots
                HStack(spacing: 6) {
                    ForEach(0..<total, id: \.self) { i in
                        Circle()
                            .fill(progressDotColor(
                                index: i,
                                currentIndex: displayIndex,
                                isConfirmingGrant: isConfirmingGrant
                            ))
                            .frame(width: 8, height: 8)
                    }
                }

                if isWaitingForNativePermissionPrompt(step.name) {
                    Text("Respond to the macOS permission prompt")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                } else {
                    Button {
                        openSystemSettingsForPermission(at: displayIndex)
                    } label: {
                        Text("Not seeing a prompt? Open System Settings")
                            .font(.system(size: 11))
                            .foregroundStyle(MuesliTheme.accent)
                    }
                    .buttonStyle(.plain)
                }

                if step.name == "Input Monitoring", grantingPermissionName == step.name {
                    Button {
                        openApplicationsFolder()
                    } label: {
                        Text("Need to add Muesli manually? Open Applications")
                            .font(.system(size: 11))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                if selectedUseCase.canSwitchToVoiceNotesOnly && step.name == "Accessibility" {
                    Button {
                        switchToVoiceNotesOnly()
                    } label: {
                        VStack(spacing: 2) {
                            Text("Use Voice Notes instead")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Keeps the hotkey, skips paste permission")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            } else {
                // All granted
                VStack(spacing: MuesliTheme.spacing8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(MuesliTheme.success)

                    Text("All permissions granted")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
    }

    private func permissionButtonTitle(for permissionName: String, isConfirmingGrant: Bool) -> String {
        if isConfirmingGrant { return "Granted" }
        if isWaitingForNativePermissionPrompt(permissionName) { return "Waiting for macOS..." }
        if grantingPermissionName == permissionName { return "Open Settings" }
        return "Grant Permission"
    }

    private func isWaitingForNativePermissionPrompt(_ permissionName: String) -> Bool {
        nativePermissionPromptName == permissionName
    }

    private func requestAccessibilityPermission() {
        nativePermissionPromptName = "Accessibility"
        controller.prepareOnboardingForNativePermissionPrompt()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if nativePermissionPromptName == "Accessibility", !accessibilityGranted {
                nativePermissionPromptName = nil
            }
        }
    }

    private func switchToVoiceNotesOnly() {
        grantingPermissionName = nil
        nativePermissionPromptName = nil
        recentlyGrantedPermissionName = nil
        selectedUseCase = .voiceNotes
        currentStep = OnboardingFlow.normalizedStep(currentStep, for: .voiceNotes)
        saveProgress(atStep: currentStep)
    }

    private func systemSettingsPane(for permissionIndex: Int) -> String {
        let steps = permissionSteps
        guard permissionIndex < steps.count else { return "Privacy_Microphone" }
        switch steps[permissionIndex].name {
        case "Microphone": return "Privacy_Microphone"
        case "Accessibility": return "Privacy_Accessibility"
        case "Input Monitoring": return "Privacy_ListenEvent"
        default: return "Privacy_Microphone"
        }
    }

    private func progressDotColor(index: Int, currentIndex: Int, isConfirmingGrant: Bool) -> Color {
        if index < currentIndex || (isConfirmingGrant && index == currentIndex) {
            return MuesliTheme.success
        }
        if index == currentIndex {
            return MuesliTheme.accent
        }
        return MuesliTheme.surfaceBorder
    }

    private func permissionRow(icon: String, name: String, description: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(description)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(MuesliTheme.success)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 4)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing12)
        .animation(.easeInOut(duration: 0.25), value: granted)
    }

    private var requiredPermissionsGranted: Bool {
        OnboardingPermissionGate.hasRequiredPermissions(
            OnboardingPermissionSnapshot(
                microphone: micGranted,
                accessibility: accessibilityGranted,
                inputMonitoring: inputMonitoringGranted,
                systemAudio: systemAudioGranted,
                screenRecording: screenRecordingGranted
            ),
            for: selectedUseCase
        )
    }

    private func startPermissionPolling() {
        refreshPermissions()
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation { refreshPermissions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()

        if let grantingPermissionName, isPermissionGranted(named: grantingPermissionName) {
            notePermissionGranted(grantingPermissionName)
        }
    }

    private func isPermissionGranted(named permissionName: String) -> Bool {
        switch permissionName {
        case "Microphone":
            return micGranted
        case "Accessibility":
            return accessibilityGranted
        case "Input Monitoring":
            return inputMonitoringGranted
        default:
            return false
        }
    }

    @MainActor
    private func notePermissionGranted(_ permissionName: String) {
        guard recentlyGrantedPermissionName != permissionName else { return }
        grantingPermissionName = nil
        nativePermissionPromptName = nil
        recentlyGrantedPermissionName = permissionName
        saveProgress(atStep: currentStep)
        controller.bringOnboardingToFront()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            if recentlyGrantedPermissionName == permissionName {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recentlyGrantedPermissionName = nil
                }
            }
        }
    }

    private func saveProgress(atStep step: Int? = nil) {
        guard !hasFinishedOnboarding else { return }
        let progress = OnboardingProgress(
            currentStep: step ?? currentStep,
            userName: userName,
            selectedBackendKey: selectedBackend.backend,
            selectedModelKey: selectedBackend.model,
            selectedCohereLanguageCode: selectedCohereLanguage.rawValue,
            hotkeyKeyCode: selectedHotkey.keyCode,
            hotkeyLabel: selectedHotkey.label,
            systemAudioRequested: systemAudioGranted,
            onboardingUseCaseRawValue: selectedUseCase.rawValue,
            modelDownloadProgress: modelDownloadProgress,
            modelDownloadStatus: modelDownloadStatus
        )
        OnboardingProgress.save(progress)
    }

    private func saveProgressAndRestart() {
        saveProgress(atStep: Self.dictationTestStep)
        controller.relaunchApp()
    }

    private func openSystemSettingsForPermission(at permissionIndex: Int) {
        let steps = permissionSteps
        if permissionIndex < steps.count {
            grantingPermissionName = steps[permissionIndex].name
            nativePermissionPromptName = nil
            recentlyGrantedPermissionName = nil
            saveProgress(atStep: currentStep)
        }
        openSystemSettings(systemSettingsPane(for: permissionIndex))
    }

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            controller.yieldOnboardingFocusToSystemSettings()
            NSWorkspace.shared.open(url)
        }
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    // MARK: - Step 4: Hotkey Configuration

    private var hotkeyStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Dictation Shortcut")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Choose the key you'll hold to dictate. Press and hold the key to record, release to transcribe.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: MuesliTheme.spacing16) {
                // Current hotkey display
                Text(selectedHotkey.label)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing32)
                    .padding(.vertical, MuesliTheme.spacing16)
                    .background(MuesliTheme.backgroundRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )

                // Change button
                Button {
                    if isRecordingHotkey {
                        stopRecordingHotkey()
                    } else {
                        startRecordingHotkey()
                    }
                } label: {
                    Text(isRecordingHotkey ? "Press a modifier key..." : "Change Shortcut")
                        .font(MuesliTheme.body())
                        .foregroundStyle(isRecordingHotkey ? MuesliTheme.accent : MuesliTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(isRecordingHotkey ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(isRecordingHotkey ? MuesliTheme.accent.opacity(0.3) : MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }

            Text("Supported: Left Cmd, Right Cmd, Fn, Ctrl, Option, Shift")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onDisappear { stopRecordingHotkey() }
    }

    private func startRecordingHotkey() {
        isRecordingHotkey = true
        hotkeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let keyCode = event.keyCode
            if let label = HotkeyConfig.label(for: keyCode) {
                selectedHotkey = HotkeyConfig(keyCode: keyCode, label: label)
                stopRecordingHotkey()
            }
            return event
        }
    }

    private func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let monitor = hotkeyEventMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyEventMonitor = nil
        }
    }

    // MARK: - Step 5: Dictation Test

    private var dictationTestStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text(selectedUseCase.includesVoiceNotes ? "Test Voice Note" : "Test Dictation")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text(dictationTestSubtitle)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)

                if isSelectedModelReadyForDictationTest {
                    Text("Try saying: \"testing this one out\"")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(MuesliTheme.accent)
                        .padding(.top, 2)
                }
            }

            if !isSelectedModelReadyForDictationTest {
                VStack(spacing: MuesliTheme.spacing8) {
                    if isModelPreparingAfterDownload {
                        IndeterminatePreparationBar()
                            .frame(width: 260, height: 7)
                        Text(modelDownloadStatus ?? "Preparing \(selectedBackend.label)...")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MuesliTheme.textTertiary)
                        Text("This usually takes 20-60 seconds the first time.")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(MuesliTheme.textTertiary)
                        RotatingPreparationHint(messages: modelPreparationHints)
                            .padding(.top, 2)
                    } else if let modelDownloadProgress {
                        ProgressView(value: modelDownloadProgress, total: 1.0)
                            .frame(width: 260)
                        Text(modelDownloadStatus ?? "\(Int((modelDownloadProgress * 100).rounded()))% complete")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                        Text(modelDownloadStatus ?? "Preparing \(selectedBackend.label)...")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    Text("The dictation test is disabled until download and warmup complete.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .multilineTextAlignment(.center)

                    if let modelDownloadError {
                        Text(modelDownloadError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)

                        Button("Retry Download") {
                            self.modelDownloadError = nil
                            ensureModelDownloadStarted()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.accent)
                    }
                }
            } else {
                VStack(spacing: MuesliTheme.spacing16) {
                    Text(dictationTestResult ?? "Your transcription will appear here...")
                        .font(dictationTestResult != nil ? .system(size: 14, design: .monospaced) : .system(size: 13, design: .rounded))
                        .foregroundStyle(dictationTestResult != nil ? MuesliTheme.textPrimary : MuesliTheme.textTertiary)
                        .italic(dictationTestResult == nil)
                        .frame(maxWidth: 400, minHeight: 60, alignment: .topLeading)
                        .padding(MuesliTheme.spacing16)
                        .background(MuesliTheme.backgroundRaised)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                                .strokeBorder(dictationTestResult != nil ? MuesliTheme.success.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: 1)
                        )

                    if isDictationTesting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Listening... release \(selectedHotkey.label) when done")
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }
                    } else if dictationTestResult == nil {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                                .font(.system(size: 14))
                            Text("Hold \(selectedHotkey.label) to start")
                                .font(MuesliTheme.body())
                        }
                        .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    if let dictationTestError {
                        Text(dictationTestError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }

                    if dictationTestResult != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(MuesliTheme.success)
                            Text("Dictation is working!")
                                .font(MuesliTheme.body())
                                .foregroundStyle(MuesliTheme.success)
                        }
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            ensureModelDownloadStarted()
            controller.dictationTestBackend = selectedBackend
            controller.dictationTestCohereLanguage = selectedCohereLanguage
            controller.dictationTestRecordingStarted = {
                withAnimation { isDictationTesting = true }
                dictationTestError = nil
            }
            controller.dictationTestCallback = { text in
                if text.isEmpty {
                    dictationTestError = "No speech detected. Try again."
                } else {
                    withAnimation { dictationTestResult = text }
                    advanceAfterSuccessfulDictationTest(text: text)
                }
                isDictationTesting = false
            }
            controller.dictationTestFailureCallback = { message in
                dictationTestError = message
                isDictationTesting = false
            }
            startDictationTestMonitorIfReady()
        }
        .onDisappear {
            // Cancel any in-flight recording before clearing callbacks to prevent
            // the transcription Task from falling through to the production paste path
            controller.cancelTestDictation()
            controller.dictationTestCallback = nil
            controller.dictationTestFailureCallback = nil
            controller.dictationTestRecordingStarted = nil
            controller.dictationTestBackend = nil
            controller.dictationTestCohereLanguage = nil
            // Stop the test monitor while moving through onboarding, but leave the
            // production monitor running when finishing from the dictation test.
            if !hasFinishedOnboarding {
                controller.stopHotkeyMonitor()
            }
        }
    }

    // MARK: - Step 6: Meeting Summaries

    private var meetingSummaryStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Meeting Summaries")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Connect an LLM provider to get AI-powered meeting notes.\nYou can set this up later in Settings.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 0) {
                providerTab("ChatGPT", selected: summaryBackend == .chatGPT) {
                    summaryBackend = .chatGPT
                    apiKey = ""
                }
                providerTab("OpenAI", selected: summaryBackend == .openAI) {
                    summaryBackend = .openAI
                    apiKey = ""
                }
                providerTab("OpenRouter", selected: summaryBackend == .openRouter) {
                    summaryBackend = .openRouter
                    apiKey = ""
                }
                providerTab("Ollama", selected: summaryBackend == .ollama) {
                    summaryBackend = .ollama
                    apiKey = ""
                }
                providerTab("LM Studio", selected: summaryBackend == .lmStudio) {
                    summaryBackend = .lmStudio
                    apiKey = ""
                }
            }
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(width: 400)

            if summaryBackend == .chatGPT {
                Text("Use your ChatGPT Plus or Pro subscription.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)

                if appState.isChatGPTAuthenticated || chatGPTSignInDone {
                    HStack(spacing: 6) {
                        OpenAILogoShape()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                        Text("Signed in with ChatGPT")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(MuesliTheme.success)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                } else if isSigningInChatGPT {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Signing in...")
                            .font(.system(size: 12))
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                } else {
                    Button {
                        isSigningInChatGPT = true
                        chatGPTSignInError = nil
                        Task {
                            let error = await controller.signInWithChatGPT()
                            isSigningInChatGPT = false
                            chatGPTSignInDone = ChatGPTAuthManager.shared.isAuthenticated
                            chatGPTSignInError = error
                        }
                    } label: {
                        HStack(spacing: 6) {
                            OpenAILogoShape()
                                .fill(.white)
                                .frame(width: 14, height: 14)
                            Text("Sign in with ChatGPT")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(MuesliTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)

                    if let chatGPTSignInError {
                        Text(chatGPTSignInError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            } else if summaryBackend == .ollama {
                Text("Run AI models locally on your device with Ollama.\nNo API key needed — just install Ollama and pull a model.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Text("Ollama is served by default at http://localhost:11434")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(MuesliTheme.success)
                            .frame(width: 6, height: 6)
                        Text("No authentication required")
                            .font(.system(size: 11))
                            .foregroundStyle(MuesliTheme.success)
                    }
                }
            } else if summaryBackend == .lmStudio {
                Text("Run AI models locally with LM Studio.\nNo API key needed — just start the LM Studio server.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Text("LM Studio is served by default at http://localhost:1234")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(MuesliTheme.success)
                            .frame(width: 6, height: 6)
                        Text("No authentication required")
                            .font(.system(size: 11))
                            .foregroundStyle(MuesliTheme.success)
                    }

                    Text("Select a model in Settings after setup.")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.transcribing)
                        .padding(.top, 4)
                }
            } else {
                if summaryBackend == .openRouter {
                    Text("OpenRouter supports many model providers through one API key.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Text("API Key")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)

                    PastableSecureField(
                        text: apiKey,
                        placeholder: summaryBackend == .openAI ? "sk-..." : "sk-or-...",
                        onChange: { apiKey = $0 }
                    )
                    .frame(width: 320, height: 28)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(apiKey.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                            .frame(width: 6, height: 6)
                        Text(apiKey.isEmpty ? "No API key" : "Key entered")
                            .font(.system(size: 11))
                            .foregroundStyle(apiKey.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.success)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func providerTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                .frame(width: 80)
                .padding(.vertical, MuesliTheme.spacing8)
                .background(selected ? MuesliTheme.surfacePrimary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func startDownload() {
        ensureModelDownloadStarted()
        goToNextStep()
    }

    private func startDictationTestMonitorIfReady() {
        guard currentStep == Self.dictationTestStep else { return }
        guard isSelectedModelReadyForDictationTest else {
            if isDictationTesting {
                controller.cancelTestDictation()
                isDictationTesting = false
            }
            controller.stopHotkeyMonitor()
            return
        }

        dictationTestError = nil
        controller.dictationTestBackend = selectedBackend
        controller.dictationTestCohereLanguage = selectedCohereLanguage
        controller.startHotkeyMonitor(keyCode: selectedHotkey.keyCode)
    }

    private func advanceAfterSuccessfulDictationTest(text: String) {
        guard selectedUseCase.includesMeetings else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard currentStep == Self.dictationTestStep, dictationTestResult == text else { return }
            goToNextStep()
        }
    }

    private func ensureModelDownloadStarted() {
        if modelReadyBackend == selectedBackend {
            isModelStillDownloading = false
            modelDownloadProgress = 1.0
            isModelPreparingAfterDownload = false
            modelDownloadStatus = "\(selectedBackend.label) ready"
            modelDownloadError = nil
            publishModelPreparationStatus(
                title: "\(selectedBackend.label) ready",
                detail: "Ready for transcription",
                progress: 1.0,
                isPreparing: false,
                isComplete: true
            )
            return
        }

        if modelDownloadTask != nil {
            guard modelDownloadBackend != selectedBackend else {
                isModelStillDownloading = true
                return
            }
            modelDownloadTask?.cancel()
            modelDownloadTask = nil
            modelDownloadBackend = nil
        }

        let backend = selectedBackend
        let useCase = selectedUseCase
        let alreadyDownloaded = backend.isDownloaded
        modelDownloadBackend = backend
        isModelStillDownloading = true
        modelDownloadProgress = alreadyDownloaded ? nil : (modelDownloadProgress ?? 0.02)
        isModelPreparingAfterDownload = alreadyDownloaded
        modelDownloadStatus = alreadyDownloaded
            ? "Warming up \(backend.label)..."
            : (modelDownloadStatus ?? initialDownloadStatus(for: backend))
        modelDownloadError = nil
        publishModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: modelDownloadStatus,
            progress: modelDownloadProgress,
            isPreparing: isModelPreparingAfterDownload,
            isComplete: false
        )

        modelDownloadTask = Task {
            defer {
                Task { @MainActor in
                    if modelDownloadBackend == backend {
                        modelDownloadTask = nil
                        modelDownloadBackend = nil
                    }
                }
            }
            do {
                try await controller.downloadModelForOnboarding(backend, onboardingUseCase: useCase) { progress, status in
                    Task { @MainActor in
                        guard selectedBackend == backend else { return }
                        applyModelPreparationProgress(progress, status: status, backend: backend)
                    }
                }
                await MainActor.run {
                    guard selectedBackend == backend else { return }
                    modelReadyBackend = backend
                    modelDownloadProgress = 1.0
                    isModelPreparingAfterDownload = false
                    modelDownloadStatus = "\(backend.label) ready"
                    modelDownloadError = nil
                    withAnimation { isModelStillDownloading = false }
                    publishModelPreparationStatus(
                        title: "\(backend.label) ready",
                        detail: "Ready for transcription",
                        progress: 1.0,
                        isPreparing: false,
                        isComplete: true
                    )
                    showModelReadyIndicator(for: backend)
                    controller.notifyOnboardingModelReady()
                    saveProgress(atStep: currentStep)
                }
            } catch is CancellationError {
                // Backend changes cancel the old task; the new selection owns the download UI.
            } catch {
                await MainActor.run {
                    guard selectedBackend == backend else { return }
                    modelDownloadError = modelPreparationFailureMessage(for: backend)
                    modelDownloadStatus = backend.isDownloaded ? "Model setup paused" : "Download paused"
                    modelDownloadProgress = nil
                    isModelPreparingAfterDownload = false
                    isModelStillDownloading = false
                    publishModelPreparationStatus(
                        title: backend.isDownloaded ? "Model setup paused" : "Download paused",
                        detail: modelDownloadError,
                        progress: nil,
                        isPreparing: false,
                        isComplete: false
                    )
                }
                fputs("[muesli-native] onboarding model download failed: \(error)\n", stderr)
            }
        }
    }

    private func applyModelPreparationProgress(_ progress: Double, status: String?, backend: BackendOption) {
        let detail = status ?? "Preparing \(backend.label)..."
        let lowercasedDetail = detail.lowercased()
        let isPreparing = lowercasedDetail.contains("compiling")
            || lowercasedDetail.contains("warming")
            || lowercasedDetail.contains("readying")

        modelDownloadError = nil
        isModelStillDownloading = true

        if isPreparing {
            isModelPreparingAfterDownload = true
            modelDownloadStatus = "Optimizing \(backend.label) for this Mac..."
            publishModelPreparationStatus(
                title: "Preparing \(backend.label)",
                detail: modelDownloadStatus,
                progress: nil,
                isPreparing: true,
                isComplete: false
            )
            saveProgress(atStep: currentStep)
            return
        }

        isModelPreparingAfterDownload = false
        let clampedProgress = min(max(progress, 0), 1)
        let currentProgress = modelDownloadProgress ?? 0
        let isZeroReset = clampedProgress <= 0.001 && currentProgress > 0.03

        guard !isZeroReset else { return }
        modelDownloadProgress = max(currentProgress, max(clampedProgress, 0.02))
        modelDownloadStatus = detail
        publishModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: detail,
            progress: modelDownloadProgress,
            isPreparing: false,
            isComplete: false
        )
        saveProgress(atStep: currentStep)
    }

    private func resetModelDownloadForBackendChange() {
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelReadyIndicatorTask?.cancel()
        modelReadyIndicatorTask = nil
        modelReadyBackend = nil
        modelReadyIndicatorBackend = nil
        modelDownloadBackend = nil
        modelDownloadProgress = nil
        isModelPreparingAfterDownload = false
        modelDownloadStatus = nil
        modelDownloadError = nil
        isModelStillDownloading = false
    }

    private func initialDownloadStatus(for backend: BackendOption) -> String {
        let size = backend.sizeLabel
            .replacingOccurrences(of: "~", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !size.isEmpty {
            return "0 MB of \(size)"
        }
        return "Starting \(backend.label) download..."
    }

    private func modelPreparationFailureMessage(for backend: BackendOption) -> String {
        backend.isDownloaded
            ? "Model setup failed. Restart Muesli or retry from Models."
            : "Download failed. Check your connection and retry."
    }

    private func publishModelPreparationStatus(
        title: String,
        detail: String?,
        progress: Double?,
        isPreparing: Bool,
        isComplete: Bool
    ) {
        appState.modelPreparationTitle = title
        appState.modelPreparationDetail = detail
        appState.modelPreparationProgress = progress.map { min(max($0, 0), 1) }
        appState.isModelPreparingAfterDownload = isPreparing
        appState.modelPreparationIsComplete = isComplete
        if isComplete {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard appState.modelPreparationTitle == title,
                      appState.modelPreparationIsComplete else { return }
                appState.modelPreparationTitle = nil
                appState.modelPreparationDetail = nil
                appState.modelPreparationProgress = nil
                appState.isModelPreparingAfterDownload = false
                appState.modelPreparationIsComplete = false
            }
        } else if !isPreparing && progress == nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard appState.modelPreparationTitle == title,
                      appState.modelPreparationProgress == nil,
                      !appState.isModelPreparingAfterDownload,
                      !appState.modelPreparationIsComplete else { return }
                appState.modelPreparationTitle = nil
                appState.modelPreparationDetail = nil
            }
        }
    }

    private func showModelReadyIndicator(for backend: BackendOption) {
        modelReadyIndicatorTask?.cancel()
        modelReadyIndicatorBackend = backend
        modelReadyIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard modelReadyIndicatorBackend == backend else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                modelReadyIndicatorBackend = nil
            }
            modelReadyIndicatorTask = nil
        }
    }

    private var googleCalendarStep: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Spacer()

            VStack(spacing: MuesliTheme.spacing8) {
                Text("Google Calendar")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Connect Google Calendar to see upcoming meetings.\nYou can set this up later in Settings.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: MuesliTheme.spacing12) {
                if googleCalSignInDone {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MuesliTheme.success)
                        Text("Google Calendar connected")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }
                } else if isSigningInGoogleCal {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting...")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                } else if appState.isGoogleCalendarAvailable && !appState.isGoogleCalendarVerified {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 14))
                            Text("Connect Google Calendar")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, MuesliTheme.spacing16)
                        .padding(.vertical, MuesliTheme.spacing8)
                        .background(MuesliTheme.textTertiary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                        Text("Google OAuth verification pending")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                } else if appState.isGoogleCalendarAvailable {
                    Button {
                        isSigningInGoogleCal = true
                        googleCalSignInError = nil
                        Task {
                            let error = await controller.signInWithGoogleCalendar()
                            isSigningInGoogleCal = false
                            if let error {
                                googleCalSignInError = error
                            } else {
                                googleCalSignInDone = true
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 14))
                            Text("Connect Google Calendar")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, MuesliTheme.spacing16)
                        .padding(.vertical, MuesliTheme.spacing8)
                        .background(MuesliTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }
                    .buttonStyle(.plain)

                    if let googleCalSignInError {
                        Text(googleCalSignInError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text("Google Calendar credentials not configured.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, MuesliTheme.spacing32)
    }

    private func finishOnboarding(withKey: Bool) {
        hasFinishedOnboarding = true
        OnboardingProgress.clear()
        let shouldContinueModelPreparation = modelDownloadTask != nil && modelReadyBackend != selectedBackend
        if shouldContinueModelPreparation {
            modelDownloadTask?.cancel()
            modelDownloadTask = nil
            modelDownloadBackend = nil
            controller.continueModelPreparationAfterOnboarding(
                selectedBackend,
                onboardingUseCase: selectedUseCase,
                initialProgress: modelDownloadProgress,
                initialStatus: modelDownloadStatus,
                isPreparing: isModelPreparingAfterDownload
            )
        } else if isModelStillDownloading || modelReadyBackend == selectedBackend {
            publishModelPreparationStatus(
                title: modelReadyBackend == selectedBackend ? "\(selectedBackend.label) ready" : "Preparing \(selectedBackend.label)",
                detail: modelReadyBackend == selectedBackend ? "Ready for transcription" : modelDownloadStatus,
                progress: modelReadyBackend == selectedBackend ? 1.0 : modelDownloadProgress,
                isPreparing: isModelPreparingAfterDownload,
                isComplete: modelReadyBackend == selectedBackend
            )
        }
        controller.completeOnboarding(
            userName: userName.trimmingCharacters(in: .whitespaces),
            backend: selectedBackend,
            cohereLanguage: selectedCohereLanguage,
            hotkey: selectedHotkey,
            onboardingUseCase: selectedUseCase,
            summaryBackend: summaryBackend,
            apiKey: withKey ? apiKey : nil
        )
    }
}

private struct ModelDownloadProgressShape: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clampedProgress = min(max(progress, 0), 1)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()

        guard clampedProgress > 0 else { return path }
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + (360 * clampedProgress)),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct IndeterminatePreparationBar: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let segmentWidth = max(trackWidth * 0.32, 64)
            let travel = max(trackWidth - segmentWidth, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MuesliTheme.surfaceBorder)

                Capsule()
                    .fill(MuesliTheme.textSecondary.opacity(0.9))
                    .frame(width: segmentWidth)
                    .offset(x: isAnimating ? travel : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct RotatingPreparationHint: View {
    let messages: [String]
    @State private var index = 0
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(messages.isEmpty ? "" : messages[index % messages.count])
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(MuesliTheme.textTertiary)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .id(index)
            .transition(.opacity)
            .onReceive(timer) { _ in
                guard messages.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    index = (index + 1) % messages.count
                }
            }
            .onChange(of: messages) { _, _ in
                index = 0
            }
    }
}

// MARK: - Text Field

/// NSTextField subclass that handles Cmd+V/C/X/A without needing a standard Edit menu.
class EditableNSTextField: NSTextField {
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

struct OnboardingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> EditableNSTextField {
        let field = EditableNSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
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
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: (() -> Void)?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            _text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit?()
                return true
            }
            return false
        }
    }
}

// MARK: - OpenAI Logo

struct OpenAILogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        var p = Path()
        p.move(to: CGPoint(x: 22.2819 * sx, y: 9.8211 * sy))
        p.addCurve(to: CGPoint(x: 21.7662 * sx, y: 4.9103 * sy), control1: CGPoint(x: 22.8248 * sx, y: 8.1862 * sy), control2: CGPoint(x: 22.6369 * sx, y: 6.3967 * sy))
        p.addCurve(to: CGPoint(x: 15.2564 * sx, y: 2.0103 * sy), control1: CGPoint(x: 20.4571 * sx, y: 2.6316 * sy), control2: CGPoint(x: 17.8260 * sx, y: 1.4595 * sy))
        p.addCurve(to: CGPoint(x: 4.9807 * sx, y: 4.1818 * sy), control1: CGPoint(x: 12.1364 * sx, y: -1.4602 * sy), control2: CGPoint(x: 6.4298 * sx, y: -0.2543 * sy))
        p.addCurve(to: CGPoint(x: 0.9830 * sx, y: 7.0818 * sy), control1: CGPoint(x: 3.2928 * sx, y: 4.5279 * sy), control2: CGPoint(x: 1.8360 * sx, y: 5.5847 * sy))
        p.addCurve(to: CGPoint(x: 1.7257 * sx, y: 14.1784 * sy), control1: CGPoint(x: -0.3404 * sx, y: 9.3568 * sy), control2: CGPoint(x: -0.0401 * sx, y: 12.2267 * sy))
        p.addCurve(to: CGPoint(x: 2.2367 * sx, y: 19.0891 * sy), control1: CGPoint(x: 1.1808 * sx, y: 15.8125 * sy), control2: CGPoint(x: 1.3670 * sx, y: 17.6022 * sy))
        p.addCurve(to: CGPoint(x: 8.7513 * sx, y: 21.9892 * sy), control1: CGPoint(x: 3.5475 * sx, y: 21.3686 * sy), control2: CGPoint(x: 6.1803 * sx, y: 22.5406 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 24.0000 * sy), control1: CGPoint(x: 9.8948 * sx, y: 23.2770 * sy), control2: CGPoint(x: 11.5377 * sx, y: 24.0097 * sy))
        p.addCurve(to: CGPoint(x: 19.0317 * sx, y: 19.7942 * sy), control1: CGPoint(x: 15.8937 * sx, y: 24.0024 * sy), control2: CGPoint(x: 18.2271 * sx, y: 22.3021 * sy))
        p.addCurve(to: CGPoint(x: 23.0294 * sx, y: 16.8941 * sy), control1: CGPoint(x: 20.7194 * sx, y: 19.4475 * sy), control2: CGPoint(x: 22.1760 * sx, y: 18.3908 * sy))
        p.addCurve(to: CGPoint(x: 22.2819 * sx, y: 9.8212 * sy), control1: CGPoint(x: 24.3368 * sx, y: 14.6231 * sy), control2: CGPoint(x: 24.0351 * sx, y: 11.7688 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy))
        p.addCurve(to: CGPoint(x: 10.3835 * sx, y: 21.3884 * sy), control1: CGPoint(x: 12.2086 * sx, y: 22.4309 * sy), control2: CGPoint(x: 11.1903 * sx, y: 22.0624 * sy))
        p.addLine(to: CGPoint(x: 10.5254 * sx, y: 21.3080 * sy))
        p.addLine(to: CGPoint(x: 15.3037 * sx, y: 18.5498 * sy))
        p.addCurve(to: CGPoint(x: 15.6964 * sx, y: 17.8685 * sy), control1: CGPoint(x: 15.5456 * sx, y: 18.4079 * sy), control2: CGPoint(x: 15.6949 * sx, y: 18.1490 * sy))
        p.addLine(to: CGPoint(x: 15.6964 * sx, y: 11.1316 * sy))
        p.addLine(to: CGPoint(x: 17.7164 * sx, y: 12.3002 * sy))
        p.addCurve(to: CGPoint(x: 17.7544 * sx, y: 12.3522 * sy), control1: CGPoint(x: 17.7367 * sx, y: 12.3105 * sy), control2: CGPoint(x: 17.7508 * sx, y: 12.3298 * sy))
        p.addLine(to: CGPoint(x: 17.7544 * sx, y: 17.9348 * sy))
        p.addCurve(to: CGPoint(x: 13.2599 * sx, y: 22.4292 * sy), control1: CGPoint(x: 17.7491 * sx, y: 20.4148 * sy), control2: CGPoint(x: 15.7399 * sx, y: 22.4240 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy))
        p.addCurve(to: CGPoint(x: 3.0646 * sx, y: 15.2901 * sy), control1: CGPoint(x: 3.0720 * sx, y: 17.3934 * sy), control2: CGPoint(x: 2.8827 * sx, y: 16.3263 * sy))
        p.addLine(to: CGPoint(x: 3.2066 * sx, y: 15.3753 * sy))
        p.addLine(to: CGPoint(x: 7.9896 * sx, y: 18.1335 * sy))
        p.addCurve(to: CGPoint(x: 8.7702 * sx, y: 18.1335 * sy), control1: CGPoint(x: 8.2306 * sx, y: 18.2749 * sy), control2: CGPoint(x: 8.5292 * sx, y: 18.2749 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 14.7650 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 17.0974 * sy))
        p.addCurve(to: CGPoint(x: 14.5798 * sx, y: 17.1589 * sy), control1: CGPoint(x: 14.6119 * sx, y: 17.1219 * sy), control2: CGPoint(x: 14.5997 * sx, y: 17.1445 * sy))
        p.addLine(to: CGPoint(x: 9.7400 * sx, y: 19.9502 * sy))
        p.addCurve(to: CGPoint(x: 3.5992 * sx, y: 18.3038 * sy), control1: CGPoint(x: 7.5893 * sx, y: 21.1891 * sy), control2: CGPoint(x: 4.8416 * sx, y: 20.4525 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 2.3408 * sx, y: 7.8956 * sy))
        p.addCurve(to: CGPoint(x: 4.7063 * sx, y: 5.9228 * sy), control1: CGPoint(x: 2.8717 * sx, y: 6.9794 * sy), control2: CGPoint(x: 3.7096 * sx, y: 6.2805 * sy))
        p.addLine(to: CGPoint(x: 4.7063 * sx, y: 11.6000 * sy))
        p.addCurve(to: CGPoint(x: 5.0942 * sx, y: 12.2765 * sy), control1: CGPoint(x: 4.7026 * sx, y: 11.8793 * sy), control2: CGPoint(x: 4.8513 * sx, y: 12.1386 * sy))
        p.addLine(to: CGPoint(x: 10.9086 * sx, y: 15.6308 * sy))
        p.addLine(to: CGPoint(x: 8.8885 * sx, y: 16.7993 * sy))
        p.addCurve(to: CGPoint(x: 8.8175 * sx, y: 16.7993 * sy), control1: CGPoint(x: 8.8663 * sx, y: 16.8111 * sy), control2: CGPoint(x: 8.8397 * sx, y: 16.8111 * sy))
        p.addLine(to: CGPoint(x: 3.9872 * sx, y: 14.0128 * sy))
        p.addCurve(to: CGPoint(x: 2.3408 * sx, y: 7.8720 * sy), control1: CGPoint(x: 1.8408 * sx, y: 12.7686 * sy), control2: CGPoint(x: 1.1047 * sx, y: 10.0230 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 18.9371 * sx, y: 11.7514 * sy))
        p.addLine(to: CGPoint(x: 13.1038 * sx, y: 8.3640 * sy))
        p.addLine(to: CGPoint(x: 15.1192 * sx, y: 7.2000 * sy))
        p.addCurve(to: CGPoint(x: 15.1902 * sx, y: 7.2000 * sy), control1: CGPoint(x: 15.1414 * sx, y: 7.1882 * sy), control2: CGPoint(x: 15.1680 * sx, y: 7.1882 * sy))
        p.addLine(to: CGPoint(x: 20.0205 * sx, y: 9.9913 * sy))
        p.addCurve(to: CGPoint(x: 19.3440 * sx, y: 18.0955 * sy), control1: CGPoint(x: 23.3136 * sx, y: 11.8915 * sy), control2: CGPoint(x: 22.9065 * sx, y: 16.7676 * sy))
        p.addLine(to: CGPoint(x: 19.3440 * sx, y: 12.4183 * sy))
        p.addCurve(to: CGPoint(x: 18.9370 * sx, y: 11.7513 * sy), control1: CGPoint(x: 19.3355 * sx, y: 12.1397 * sy), control2: CGPoint(x: 19.1808 * sx, y: 11.8863 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 20.9478 * sx, y: 8.7283 * sy))
        p.addLine(to: CGPoint(x: 20.8058 * sx, y: 8.6431 * sy))
        p.addLine(to: CGPoint(x: 16.0323 * sx, y: 5.8613 * sy))
        p.addCurve(to: CGPoint(x: 15.2469 * sx, y: 5.8613 * sy), control1: CGPoint(x: 15.7898 * sx, y: 5.7190 * sy), control2: CGPoint(x: 15.4894 * sx, y: 5.7190 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 9.2297 * sy))
        p.addLine(to: CGPoint(x: 9.4090 * sx, y: 6.8974 * sy))
        p.addCurve(to: CGPoint(x: 9.4374 * sx, y: 6.8359 * sy), control1: CGPoint(x: 9.4065 * sx, y: 6.8732 * sy), control2: CGPoint(x: 9.4174 * sx, y: 6.8496 * sy))
        p.addLine(to: CGPoint(x: 14.2677 * sx, y: 4.0493 * sy))
        p.addCurve(to: CGPoint(x: 20.9479 * sx, y: 8.7093 * sy), control1: CGPoint(x: 17.5693 * sx, y: 2.1473 * sy), control2: CGPoint(x: 21.5928 * sx, y: 4.9539 * sy))
        p.closeSubpath()
        p.move(to: CGPoint(x: 8.3065 * sx, y: 12.8630 * sy))
        p.addLine(to: CGPoint(x: 6.2865 * sx, y: 11.6992 * sy))
        p.addCurve(to: CGPoint(x: 6.2485 * sx, y: 11.6425 * sy), control1: CGPoint(x: 6.2660 * sx, y: 11.6869 * sy), control2: CGPoint(x: 6.2521 * sx, y: 11.6661 * sy))
        p.addLine(to: CGPoint(x: 6.2485 * sx, y: 6.0742 * sy))
        p.addCurve(to: CGPoint(x: 13.6242 * sx, y: 2.6205 * sy), control1: CGPoint(x: 6.2535 * sx, y: 2.2647 * sy), control2: CGPoint(x: 10.6950 * sx, y: 0.1849 * sy))
        p.addLine(to: CGPoint(x: 13.4822 * sx, y: 2.7010 * sy))
        p.addLine(to: CGPoint(x: 8.7040 * sx, y: 5.4590 * sy))
        p.addCurve(to: CGPoint(x: 8.3113 * sx, y: 6.1403 * sy), control1: CGPoint(x: 8.4621 * sx, y: 5.6009 * sy), control2: CGPoint(x: 8.3128 * sx, y: 5.8598 * sy))
        p.closeSubpath()
        // Inner hexagon
        p.move(to: CGPoint(x: 9.4041 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 12.0061 * sx, y: 8.9978 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 10.4976 * sy))
        p.addLine(to: CGPoint(x: 14.6130 * sx, y: 13.4970 * sy))
        p.addLine(to: CGPoint(x: 12.0156 * sx, y: 14.9967 * sy))
        p.addLine(to: CGPoint(x: 9.4089 * sx, y: 13.4970 * sy))
        p.closeSubpath()
        return p
    }
}

import FluidAudio
import MuesliCore
import SwiftUI

struct ModelDownloadGenerationState: Equatable {
    private(set) var current: UUID?

    mutating func begin() -> UUID {
        let generation = UUID()
        current = generation
        return generation
    }

    func contains(_ generation: UUID) -> Bool {
        current == generation
    }

    @discardableResult
    mutating func clear(_ generation: UUID) -> Bool {
        guard current == generation else { return false }
        current = nil
        return true
    }
}

struct ModelsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var nemotron35UpdateAvailable = false
    @State private var downloadingModels: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadMessages: [String: String] = [:]
    @State private var downloadSnapshots: [String: ModelDownloadProgress] = [:]
    @State private var downloadGenerations: [String: UUID] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var modelToDelete: BackendOption?
    @State private var selectedParakeetModel: String
    @State private var selectedWhisperModel: String
    @State private var showExperimental: Bool
    @State private var appleSpeechLanguageOptions: [AppleSpeechLanguageOption] = [.system]
    @State private var isLiveCaptionModelDownloaded = false
    @State private var isDownloadingLiveCaptionModel = false
    @State private var isCancellingLiveCaptionModelDownload = false
    @State private var liveCaptionDownloadProgress = 0.0
    @State private var liveCaptionDownloadTask: Task<Void, Never>?
    @State private var liveCaptionDownloadGeneration = ModelDownloadGenerationState()
    @State private var showDeleteLiveCaptionModelConfirmation = false

    // Post-processor state
    @State private var downloadingPostProcModels: Set<String> = []
    @State private var downloadProgressPostProc: [String: Double] = [:]
    @State private var downloadedPostProcModels: Set<String> = []
    @State private var downloadTasksPostProc: [String: Task<Void, Never>] = [:]
    @State private var postProcModelToDelete: PostProcessorOption?

    init(appState: AppState, controller: MuesliController) {
        self.appState = appState
        self.controller = controller

        let active = appState.selectedBackend
        _selectedParakeetModel = State(initialValue: BackendOption.parakeetFamily.contains(active) ? active.model : BackendOption.parakeetUnified.model)
        _selectedWhisperModel = State(initialValue: BackendOption.whisperFamily.contains(active) ? active.model : BackendOption.whisperSmall.model)
        _showExperimental = State(initialValue: appState.activeFeatureTourTarget == .experimentalModels)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                    Text("Models")
                        .font(MuesliTheme.title1())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    Text("Choose the transcription and cleanup models that fit how you speak and work.")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)

                    Picker("Model category", selection: modelsCategorySelection) {
                        ForEach(ModelsCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    .id(FeatureTourTarget.modelLibrary.rawValue)
                    .featureTourTarget(.modelLibrary)

                    selectedCategoryContent
                }
                .padding(.horizontal, MuesliTheme.spacing32)
            .padding(.top, MuesliTheme.pageTop)
            .padding(.bottom, MuesliTheme.spacing32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                revealFeatureTourTargetIfNeeded(using: proxy)
            }
            .onChange(of: activeFeatureTourTarget) { _, target in
                guard target == .modelLibrary
                        || target == .appleSpeechCard
                        || target == .streamingModels
                        || target == .experimentalModels else { return }
                revealFeatureTourTargetIfNeeded(using: proxy)
            }
        }
        .background(MuesliTheme.backgroundBase)
        .onAppear {
            checkDownloadedModels()
            checkDownloadedPostProcModels()
            isLiveCaptionModelDownloaded = MeetingLiveCaptionModelStore.isDownloaded()
            syncSelectionsFromActiveBackend()
            checkNemotron35Update()
            loadAppleSpeechLanguageOptions()
        }
        .onChange(of: appState.selectedBackend.model) { _, _ in
            syncSelectionsFromActiveBackend()
        }
        .alert(
            "Delete \"\(modelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = modelToDelete else { return }
                deleteModel(option)
                modelToDelete = nil
            }
        } message: {
            Text("The downloaded model files will be removed from this Mac. You can download the model again later.")
        }
        .alert(
            "Delete \"\(postProcModelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { postProcModelToDelete != nil },
                set: { if !$0 { postProcModelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                postProcModelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = postProcModelToDelete else { return }
                deletePostProcModel(option)
                postProcModelToDelete = nil
            }
        } message: {
            Text(postProcessorDeleteMessage)
        }
        .alert(
            "Delete \"\(MeetingLiveCaptionModelStore.label)\"?",
            isPresented: $showDeleteLiveCaptionModelConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteLiveCaptionModel()
            }
        } message: {
            Text("Live meetings will fall back to standard chunk-by-chunk captions until this model is downloaded again.")
        }
    }

    private var modelsCategorySelection: Binding<ModelsCategory> {
        Binding(
            get: { appState.selectedModelsCategory },
            set: { appState.selectedModelsCategory = $0 }
        )
    }

    private var postProcessorDeleteMessage: String {
        guard let option = postProcModelToDelete, !option.isDownloadable else {
            return "The downloaded model files will be removed from this Mac. You can download the model again later."
        }
        return "The downloaded model files will be removed from this Mac. This legacy model is no longer available to download, so deleting it is permanent."
    }

    @ViewBuilder
    private var selectedCategoryContent: some View {
        switch appState.selectedModelsCategory {
        case .dictation:
            ForEach(BackendOption.systemManaged, id: \.model) { option in
                let featureTourTarget: FeatureTourTarget? = option.backend == BackendOption.appleSpeechAnalyzer.backend
                    ? .appleSpeechCard
                    : nil
                modelCard(
                    option: option,
                    logo: logoForBackend(option),
                    downloadedLabel: "Available"
                )
                .id(featureTourTarget?.rawValue ?? option.model)
                .featureTourTarget(featureTourTarget)
            }

            familyCard(
                title: "Parakeet Family",
                subtitle: "The most responsive choices for everyday dictation, with multilingual and English-only options.",
                defaultBadge: "Recommended: Unified",
                logo: "nvidia-logo",
                selection: $selectedParakeetModel,
                options: BackendOption.parakeetFamily
            )

            familyCard(
                title: "Whisper",
                subtitle: "Dependable alternatives when you prefer Whisper's transcription style or need broader multilingual coverage.",
                defaultBadge: "Default: Small",
                logo: "openai-logo",
                selection: $selectedWhisperModel,
                options: BackendOption.whisperFamily
            )

            modelCard(option: .cohereTranscribe, logo: "cohere-logo")
            experimentalSection
            comingSoonSection
        case .streaming:
            streamingSection
        case .postProcessing:
            postProcessorSection
        }
    }

    @ViewBuilder
    private var comingSoonSection: some View {
        if !BackendOption.comingSoon.isEmpty {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("COMING SOON")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)
                    .padding(.top, MuesliTheme.spacing8)

                VStack(spacing: MuesliTheme.spacing12) {
                    ForEach(BackendOption.comingSoon, id: \.model) { option in
                        comingSoonCard(option: option)
                    }
                }
            }
        }
    }

    private var activeFeatureTourTarget: FeatureTourTarget? {
        appState.activeFeatureTourTarget
    }

    private func revealFeatureTourTargetIfNeeded(using proxy: ScrollViewProxy) {
        let target: FeatureTourTarget
        switch activeFeatureTourTarget {
        case .modelLibrary:
            target = .modelLibrary
            appState.selectedModelsCategory = .dictation
        case .appleSpeechCard:
            target = .appleSpeechCard
            appState.selectedModelsCategory = .dictation
        case .streamingModels:
            target = .streamingModels
            appState.selectedModelsCategory = .streaming
        case .experimentalModels:
            target = .experimentalModels
            appState.selectedModelsCategory = .dictation
            showExperimental = true
        default:
            return
        }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(target.rawValue, anchor: .center)
        }
    }

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("LIVE MEETINGS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)

                Text("Choose how words appear while a meeting is in progress. Nemotron also creates the saved transcript; Parakeet prioritizes a faster English preview.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            .padding(.leading, 2)
            .padding(.top, MuesliTheme.spacing8)
            .id(FeatureTourTarget.streamingModels.rawValue)
            .featureTourTarget(.streamingModels)

            ForEach(BackendOption.streaming, id: \.model) { option in
                if let liveCaptionBackend = MeetingLiveCaptionBackend(rawValue: option.backend) {
                    modelCard(
                        option: option,
                        logo: logoForBackend(option),
                        isActive: appState.config.enableLiveStreamingPartials
                            && appState.config.resolvedMeetingLiveCaptionBackend == liveCaptionBackend,
                        onSetActive: {
                            controller.updateConfig {
                                $0.meetingLiveCaptionBackend = liveCaptionBackend.rawValue
                                $0.enableLiveStreamingPartials = true
                            }
                        }
                    )
                }
            }

            liveCaptionModelCard
        }
    }

    private var liveCaptionModelCard: some View {
        let isActive = isLiveCaptionModelDownloaded
            && appState.config.enableLiveStreamingPartials
            && appState.config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                brandLogo("nvidia-logo")
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(MeetingLiveCaptionModelStore.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        Text(MeetingLiveCaptionModelStore.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Text("Fast English captions while a meeting is in progress. They are a provisional preview; your regular meeting model creates the transcript you keep.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isLiveCaptionModelDownloaded {
                    Text("Ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if isDownloadingLiveCaptionModel {
                downloadProgressView(
                    for: MeetingLiveCaptionModelStore.modelID,
                    fallbackProgress: liveCaptionDownloadProgress
                )
            }

            HStack(spacing: MuesliTheme.spacing8) {
                if isDownloadingLiveCaptionModel {
                    Button(isCancellingLiveCaptionModelDownload ? "Pausing…" : "Cancel") {
                        guard !isCancellingLiveCaptionModelDownload else { return }
                        let task = liveCaptionDownloadTask
                        task?.cancel()
                        let cancellationGeneration = liveCaptionDownloadGeneration.begin()
                        isCancellingLiveCaptionModelDownload = true
                        Task {
                            let shouldCancel = await MainActor.run {
                                liveCaptionDownloadGeneration.contains(cancellationGeneration)
                            }
                            guard shouldCancel else { return }
                            await ManagedASRModelDownloader.cancelAndWait(
                                modelID: MeetingLiveCaptionModelStore.modelID
                            )
                            _ = await task?.value
                            await MainActor.run {
                                guard liveCaptionDownloadGeneration.clear(cancellationGeneration) else { return }
                                liveCaptionDownloadTask = nil
                                isDownloadingLiveCaptionModel = false
                                isCancellingLiveCaptionModelDownload = false
                                liveCaptionDownloadProgress = 0
                            }
                        }
                        liveCaptionDownloadProgress = 0
                        if let snapshot = downloadSnapshots[MeetingLiveCaptionModelStore.modelID] {
                            downloadSnapshots[MeetingLiveCaptionModelStore.modelID] = snapshot.replacing(
                                phase: .paused,
                                message: "Paused — select Download to resume"
                            )
                        }
                    }
                    .disabled(isCancellingLiveCaptionModelDownload)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                } else if isLiveCaptionModelDownloaded {
                    if !isActive {
                        Button("Set Active") {
                            controller.updateConfig {
                                $0.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.parakeetRealtimeEOU.rawValue
                                $0.enableLiveStreamingPartials = true
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.accent)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }

                    Button {
                        showDeleteLiveCaptionModelConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Delete live caption model")
                } else {
                    Button("Download") {
                        startLiveCaptionModelDownload()
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
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.6) : MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func startLiveCaptionModelDownload() {
        guard !isDownloadingLiveCaptionModel else { return }
        isCancellingLiveCaptionModelDownload = false
        isDownloadingLiveCaptionModel = true
        liveCaptionDownloadProgress = 0
        downloadSnapshots.removeValue(forKey: MeetingLiveCaptionModelStore.modelID)
        let generation = liveCaptionDownloadGeneration.begin()
        liveCaptionDownloadTask = Task {
            do {
                try await MeetingLiveCaptionModelStore.download { progress in
                    Task { @MainActor in
                        guard liveCaptionDownloadGeneration.contains(generation) else { return }
                        liveCaptionDownloadProgress = progress
                    }
                } progressSnapshot: { snapshot in
                    Task { @MainActor in
                        guard liveCaptionDownloadGeneration.contains(generation) else { return }
                        downloadSnapshots[MeetingLiveCaptionModelStore.modelID] = snapshot
                        if let fraction = snapshot.fractionCompleted {
                            liveCaptionDownloadProgress = fraction
                        }
                    }
                }
                guard !Task.isCancelled,
                      liveCaptionDownloadGeneration.contains(generation)
                else { return }
                isLiveCaptionModelDownloaded = true
            } catch is CancellationError {
                // Cancellation is an expected user action.
            } catch {
                fputs("[muesli-native] live caption model download failed: \(error)\n", stderr)
            }
            guard liveCaptionDownloadGeneration.clear(generation) else { return }
            isDownloadingLiveCaptionModel = false
            isCancellingLiveCaptionModelDownload = false
            liveCaptionDownloadProgress = 0
            liveCaptionDownloadTask = nil
            if isLiveCaptionModelDownloaded {
                downloadSnapshots.removeValue(forKey: MeetingLiveCaptionModelStore.modelID)
            }
        }
    }

    private func deleteLiveCaptionModel() {
        do {
            try MeetingLiveCaptionModelStore.delete()
            isLiveCaptionModelDownloaded = false
            if appState.config.resolvedMeetingLiveCaptionBackend == .parakeetRealtimeEOU {
                controller.updateConfig { $0.enableLiveStreamingPartials = false }
            }
        } catch {
            fputs("[muesli-native] live caption model delete failed: \(error)\n", stderr)
        }
    }

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Button {
                showExperimental.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing12) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        HStack(spacing: 6) {
                            Image(systemName: showExperimental ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textTertiary)

                            Text("Experimental")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }

                        Text("Early models for specific languages and evaluation. Expect less consistent transcripts, and try them with your own voice before relying on them.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .opacity(0.8)
                    }

                    Spacer()

                    Text("Early access")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .featureTourTarget(.experimentalModels)

            if showExperimental {
                VStack(spacing: MuesliTheme.spacing12) {
                    ForEach(BackendOption.experimental, id: \.model) { option in
                        if !appState.selectedPostProcessorBackend.isCompatible(with: option) {
                            modelCard(
                                option: option,
                                logo: logoForBackend(option),
                                downloadedLabel: "Used for Cleanup",
                                activationDisabledReason: "Unavailable while Gemma 4 is selected for cleanup. Choose another cleanup backend first."
                            )
                        } else {
                            modelCard(option: option, logo: logoForBackend(option))
                        }
                    }
                }
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .id(FeatureTourTarget.experimentalModels.rawValue)
    }

    private var cohereLanguageSelection: Binding<CohereTranscribeLanguage> {
        Binding(
            get: { appState.config.resolvedCohereLanguage },
            set: { controller.selectCohereLanguage($0) }
        )
    }

    private var indicASRLanguageSelection: Binding<IndicASRLanguage> {
        Binding(
            get: { appState.config.resolvedIndicASRLanguage },
            set: { controller.selectIndicASRLanguage($0) }
        )
    }

    private var nemotron35LanguageSelection: Binding<Nemotron35Language> {
        Binding(
            get: { appState.config.resolvedNemotron35Language },
            set: { language in
                Task { await controller.setNemotron35Language(language) }
            }
        )
    }

    private var whisperLanguageSelection: Binding<WhisperKitLanguage> {
        Binding(
            get: { appState.config.resolvedWhisperLanguage },
            set: { controller.selectWhisperLanguage($0) }
        )
    }

    private var parakeetLanguageSelection: Binding<ParakeetLanguage> {
        Binding(
            get: { appState.config.resolvedParakeetLanguage },
            set: { controller.selectParakeetLanguage($0) }
        )
    }

    private var qwen3AsrLanguageSelection: Binding<Qwen3AsrLanguage> {
        Binding(
            get: { appState.config.resolvedQwen3AsrLanguage },
            set: { controller.selectQwen3AsrLanguage($0) }
        )
    }

    private var appleSpeechLanguageSelection: Binding<String> {
        Binding(
            get: { appState.config.resolvedAppleSpeechLanguage },
            set: { controller.selectAppleSpeechLanguage($0) }
        )
    }

    private var postProcessorSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("CLEANUP")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)

                Text("Optional cleanup after transcription. Use it to remove filler words, follow spoken corrections, format lists, and fix obvious dictation errors.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.leading, 2)
            }
            .padding(.top, MuesliTheme.spacing8)

            VStack(spacing: MuesliTheme.spacing12) {
                ForEach(Gemma4LiteRTModel.allCases) { model in
                    gemmaCleanupModelCard(model)
                }

                ForEach(displayedPostProcessorOptions) { option in
                    postProcModelCard(option)
                }
            }
        }
    }

    private func gemmaCleanupModelCard(_ model: Gemma4LiteRTModel) -> some View {
        let option = BackendOption.gemma4LiteRT(model)
        let isDownloaded = downloadedModels.contains(option.model)
        let isCompatible = TranscriptCleanupBackendOption.gemma4LiteRT
            .isCompatible(with: appState.selectedBackend)

        return modelCard(
            option: option,
            logo: "google-logo",
            isActive: isDownloaded
                && appState.selectedPostProcessorBackend == .gemma4LiteRT
                && appState.config.postProcessorGemmaModel == model.repoID,
            onSetActive: {
                controller.selectGemma4PostProcessor(model)
            },
            description: "An experimental local option for filler removal, formatting, and obvious transcript errors. It shares the \(model.label) download with dictation and Quill.",
            activeLabel: "Cleanup Active",
            downloadedLabel: isCompatible ? "Downloaded" : "Used for Dictation",
            actionTitle: "Use for Cleanup",
            activationDisabledReason: isCompatible
                ? nil
                : "Unavailable while Gemma 4 is selected for dictation. Choose another dictation model first."
        )
    }

    private func postProcModelCard(_ option: PostProcessorOption) -> some View {
        let isDownloaded = downloadedPostProcModels.contains(option.id)
        let isActive = appState.activePostProcessor.id == option.id && isDownloaded
        let isDownloading = downloadingPostProcModels.contains(option.id)
        let progress = downloadProgressPostProc[option.id] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: option.id, isDownloading: isDownloading)

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                brandLogo(option.logoResourceName)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isDownloaded {
                    Text("Downloaded")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if showsDownloadStatus {
                downloadProgressView(
                    for: option.id,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[option.id]
                )
            }

            HStack(spacing: MuesliTheme.spacing8) {
                if isDownloading {
                    Button("Pause") {
                        cancelPostProcDownload(option)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                } else if isDownloaded {
                    if !isActive {
                        Button("Set Active") {
                            controller.selectPostProcessor(option)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.accent)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }

                    Button {
                        postProcModelToDelete = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                } else if option.isDownloadable {
                    Button("Download") {
                        startPostProcDownload(option)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                } else {
                    Text("No longer available")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func familyCard(
        title: String,
        subtitle: String,
        defaultBadge: String,
        logo: String? = nil,
        selection: Binding<String>,
        options: [BackendOption]
    ) -> some View {
        let selectedOption = options.first(where: { $0.model == selection.wrappedValue }) ?? options[0]
        let isActive = appState.selectedBackend == selectedOption
        let isDownloaded = downloadedModels.contains(selectedOption.model)
        let isDownloading = downloadingModels.contains(selectedOption.model)
        let progress = downloadProgress[selectedOption.model] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: selectedOption.model, isDownloading: isDownloading)

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                brandLogo(logo)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(title)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        Text(defaultBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MuesliTheme.accentSubtle)
                            .clipShape(Capsule())
                    }

                    Text(subtitle)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                familyStatusBadge(isActive: isActive, isDownloaded: isDownloaded)
            }

            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                Text("Variant")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 52, alignment: .leading)

                Picker("", selection: selection) {
                    ForEach(options, id: \.model) { option in
                        Text(option.label).tag(option.model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)

                Text(selectedOption.sizeLabel)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            Text(selectedOption.description)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)

            if selectedOption.supportsWhisperLanguageSelection {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: whisperLanguageSelection) {
                        ForEach(WhisperKitLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if selectedOption.backend == BackendOption.parakeetMultilingual.backend {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: parakeetLanguageSelection) {
                        ForEach(ParakeetLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }

                Text("Script filter: keeps the chosen language's writing script in the transcript. Parakeet v3 only — v2 ignores this setting.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            if showsDownloadStatus {
                downloadProgressView(
                    for: selectedOption.model,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[selectedOption.model]
                )
            }

            actionButtons(for: selectedOption, isActive: isActive, isDownloaded: isDownloaded, isDownloading: isDownloading)
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private func familyStatusBadge(isActive: Bool, isDownloaded: Bool) -> some View {
        if isActive {
            Text("Active")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.success)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuesliTheme.success.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if isDownloaded {
            Text("Downloaded")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func downloadProgressView(for modelID: String, fallbackProgress: Double, fallbackMessage: String? = nil) -> some View {
        if let snapshot = downloadSnapshots[modelID] {
            VStack(alignment: .leading, spacing: 4) {
                if snapshot.phase != .preparing {
                    ProgressView(value: snapshot.fractionCompleted ?? fallbackProgress)
                        .tint(MuesliTheme.accent)
                }

                if let currentFile = snapshot.currentFile?.split(separator: "/").last.map(String.init), !currentFile.isEmpty {
                    Text("\(downloadPhaseLabel(snapshot.phase)): \(currentFile)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textSecondary)
                } else {
                    Text(snapshot.message ?? downloadPhaseLabel(snapshot.phase))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                if let detail = downloadDetailText(snapshot), !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fallbackProgress)
                    .tint(MuesliTheme.accent)
                Text(fallbackMessage ?? "\(Int(fallbackProgress * 100))% downloading...")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
    }

    private func downloadPhaseLabel(_ phase: ModelDownloadPhase) -> String {
        switch phase {
        case .downloading: return "Downloading"
        case .preparing: return "Preparing"
        case .ready: return "Ready"
        case .paused: return "Download paused"
        case .failed: return "Failed"
        }
    }

    private func downloadDetailText(_ snapshot: ModelDownloadProgress) -> String? {
        var details: [String] = []
        if snapshot.totalFileCount > 0 {
            let completed = min(max(snapshot.completedFileCount, 0), snapshot.totalFileCount)
            let remaining = snapshot.totalFileCount - completed
            details.append("\(completed) of \(snapshot.totalFileCount) \(downloadFileNoun(snapshot.totalFileCount))")
            if remaining > 0 {
                details.append("\(remaining) \(downloadFileNoun(remaining)) left")
            }
        }
        if let total = snapshot.totalBytes, total > 0 {
            details.append("\(ModelDownloadDisplayFormatting.bytes(snapshot.completedBytes)) / \(ModelDownloadDisplayFormatting.bytes(total))")
            if snapshot.completedBytes < total {
                details.append("\(ModelDownloadDisplayFormatting.bytes(total - snapshot.completedBytes)) left")
            }
        } else if let currentTotal = snapshot.currentFileTotalBytes, currentTotal > 0 {
            details.append("\(ModelDownloadDisplayFormatting.bytes(snapshot.currentFileCompletedBytes)) / \(ModelDownloadDisplayFormatting.bytes(currentTotal))")
            if snapshot.currentFileCompletedBytes < currentTotal {
                details.append("\(ModelDownloadDisplayFormatting.bytes(currentTotal - snapshot.currentFileCompletedBytes)) left in file")
            }
        }
        if snapshot.phase == .downloading {
            if snapshot.bytesPerSecond > 0 {
                details.append("\(ModelDownloadDisplayFormatting.rate(snapshot.bytesPerSecond))")
            }
            if let eta = snapshot.estimatedSecondsRemaining,
               let formattedETA = ModelDownloadDisplayFormatting.eta(eta) {
                details.append("\(formattedETA) left")
            }
            if snapshot.retryCount > 0 {
                details.append("retry \(snapshot.retryCount)/3")
            }
        } else if let message = snapshot.message, !message.isEmpty {
            details.append(message)
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func downloadFileNoun(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }

    private func shouldShowDownloadStatus(for modelID: String, isDownloading: Bool) -> Bool {
        guard let phase = downloadSnapshots[modelID]?.phase else {
            return isDownloading || downloadMessages[modelID] != nil
        }
        return isDownloading || phase == .paused || phase == .failed
    }

    @ViewBuilder
    private func brandLogo(_ name: String?) -> some View {
        if name == "apple-system-logo" {
            Image(systemName: "apple.logo")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(MuesliTheme.textPrimary)
                .frame(width: 24, height: 24)
                .padding(.top, 2)
        } else if let name,
           let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "svg"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.top, 2)
        }
    }

    private func logoForBackend(_ option: BackendOption) -> String? {
        switch option.backend {
        case "fluidaudio": return "nvidia-logo"
        case "parakeet-unified": return "nvidia-logo"
        case "whisper": return "openai-logo"
        case "cohere": return "cohere-logo"
        case "qwen": return "qwen-logo"
        case "nemotron35": return "nvidia-logo"
        case "indicasr": return "ai4bharat-logo"
        case "sensevoice": return "qwen-logo"
        case "gemma4-litert": return "google-logo"
        case "apple-speech": return "apple-system-logo"
        default: return nil
        }
    }

    @ViewBuilder
    private func actionButtons(
        for option: BackendOption,
        isActive: Bool,
        isDownloaded: Bool,
        isDownloading: Bool,
        actionTitle: String = "Set Active",
        activationDisabledReason: String? = nil,
        onSetActive: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if isDownloading {
                Button("Pause") {
                    cancelDownload(option)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 4)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            } else if isDownloaded {
                if !isActive {
                    Button(actionTitle) {
                        if let onSetActive {
                            onSetActive()
                        } else {
                            controller.selectBackend(option)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(activationDisabledReason == nil ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(activationDisabledReason == nil ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .disabled(activationDisabledReason != nil)
                    .help(activationDisabledReason ?? actionTitle)
                }

                if !option.isSystemManaged {
                    Button {
                        modelToDelete = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button("Download") {
                    startDownload(option)
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
    }

    private func modelCard(
        option: BackendOption,
        logo: String? = nil,
        isActive activeOverride: Bool? = nil,
        onSetActive: (() -> Void)? = nil,
        description: String? = nil,
        activeLabel: String = "Active",
        downloadedLabel: String = "Downloaded",
        actionTitle: String = "Set Active",
        activationDisabledReason: String? = nil
    ) -> some View {
        let isActive = activeOverride ?? (appState.selectedBackend == option)
        let isDownloaded = downloadedModels.contains(option.model)
        let isDownloading = downloadingModels.contains(option.model)
        let progress = downloadProgress[option.model] ?? 0
        let showsDownloadStatus = shouldShowDownloadStatus(for: option.model, isDownloading: isDownloading)

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                brandLogo(logo)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        if option.recommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Text(description ?? option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                // Status badge
                if isActive {
                    Text(activeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isDownloaded {
                    Text(downloadedLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if option.backend == BackendOption.cohereTranscribe.backend {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: cohereLanguageSelection) {
                        ForEach(CohereTranscribeLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if option.backend == BackendOption.indicASR.backend {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: indicASRLanguageSelection) {
                        ForEach(IndicASRLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if option.backend == BackendOption.qwen3Asr.backend {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: qwen3AsrLanguageSelection) {
                        ForEach(Qwen3AsrLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if option.backend == BackendOption.appleSpeechAnalyzer.backend {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: appleSpeechLanguageSelection) {
                        ForEach(appleSpeechLanguageOptions) { language in
                            Text(language.label).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if option.supportsWhisperLanguageSelection {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: whisperLanguageSelection) {
                        ForEach(WhisperKitLanguage.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if option.backend == BackendOption.nemotron35Multilingual.backend {
                HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                    Text("Language")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)

                    Picker("", selection: nemotron35LanguageSelection) {
                        ForEach(Nemotron35Language.allCases, id: \.self) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }

                if isDownloaded && nemotron35UpdateAvailable && !isDownloading {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(MuesliTheme.accent)
                        Text("A newer model build is available.")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        Button("Update") { updateNemotron35(option) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MuesliTheme.accent)
                    }
                }
            }

            // Progress bar when downloading
            if showsDownloadStatus {
                downloadProgressView(
                    for: option.model,
                    fallbackProgress: progress,
                    fallbackMessage: downloadMessages[option.model]
                )
            }

            if let activationDisabledReason, isDownloaded, !isActive {
                Label(activationDisabledReason, systemImage: "exclamationmark.lock")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            actionButtons(
                for: option,
                isActive: isActive,
                isDownloaded: isDownloaded,
                isDownloading: isDownloading,
                actionTitle: actionTitle,
                activationDisabledReason: activationDisabledReason,
                onSetActive: onSetActive
            )
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func comingSoonCard(option: BackendOption) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textTertiary)

                        Text("Coming soon")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MuesliTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary.opacity(0.6))
                    }

                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary.opacity(0.7))
                }
                Spacer()
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(0.6)
    }

    // MARK: - Post-Processor Actions

    private func startPostProcDownload(_ option: PostProcessorOption) {
        guard option.isDownloadable else { return }
        withAnimation { _ = downloadingPostProcModels.insert(option.id) }
        downloadProgressPostProc[option.id] = 0.02
        downloadMessages.removeValue(forKey: option.id)
        downloadSnapshots.removeValue(forKey: option.id)
        let generation = UUID()
        downloadGenerations[option.id] = generation

        let task = Task {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: option.cacheDirectory, withIntermediateDirectories: true)

                try await downloadPostProcModel(option, generation: generation)
                try Task.checkCancellation()

                await MainActor.run {
                    guard downloadGenerations[option.id] == generation, !Task.isCancelled else { return }
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadedPostProcModels.insert(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadMessages.removeValue(forKey: option.id)
                        downloadSnapshots.removeValue(forKey: option.id)
                        if downloadGenerations[option.id] == generation {
                            downloadGenerations.removeValue(forKey: option.id)
                        }
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                    if appState.config.enablePostProcessor && !appState.activePostProcessor.isDownloaded {
                        controller.selectPostProcessor(option)
                        controller.preloadExperimentalTranscriptionFeatures()
                    }
                }
            } catch {
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    guard downloadGenerations[option.id] == generation else { return }
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadMessages[option.id] = isCancelled
                            ? "Paused — select Download to resume"
                            : error.localizedDescription
                        if let snapshot = downloadSnapshots[option.id] {
                            downloadSnapshots[option.id] = snapshot.replacing(
                                phase: isCancelled ? .paused : .failed,
                                message: downloadMessages[option.id]
                            )
                        }
                        if downloadGenerations[option.id] == generation {
                            downloadGenerations.removeValue(forKey: option.id)
                        }
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                }
                if !isCancelled {
                    fputs("[muesli-native] Post-processor download failed: \(error)\n", stderr)
                }
            }
        }
        downloadTasksPostProc[option.id] = task
    }

    private func downloadPostProcModel(_ option: PostProcessorOption, generation: UUID) async throws {
        let manifest = ModelDownloadManifest(
            id: option.id,
            version: "main",
            files: [ModelDownloadFile(relativePath: option.filename, remoteURL: option.downloadURL)],
            maximumConcurrency: 1
        )
        try await ModelDownloadCoordinator.shared.download(manifest, to: option.cacheDirectory) { snapshot in
            DispatchQueue.main.async {
                guard downloadGenerations[option.id] == generation else { return }
                downloadProgressPostProc[option.id] = max(snapshot.fractionCompleted ?? 0.02, 0.02)
                downloadSnapshots[option.id] = snapshot
            }
        }
        try Task.checkCancellation()
        do {
            try validateGGUFHeader(at: option.modelURL)
        } catch {
            try? FileManager.default.removeItem(at: option.modelURL)
            throw error
        }
    }

    private func validateGGUFHeader(at url: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let header = try fh.read(upToCount: 4) ?? Data()
        guard header == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw NSError(domain: "PostProcDownload", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded post-processor file is not a GGUF model",
            ])
        }
    }

    private func cancelPostProcDownload(_ option: PostProcessorOption) {
        let task = downloadTasksPostProc[option.id]
        let cancellationGeneration = UUID()
        task?.cancel()
        Task {
            await ModelDownloadCoordinator.shared.cancel(modelID: option.id)
            _ = await task?.value
            await MainActor.run {
                guard downloadGenerations[option.id] == cancellationGeneration else { return }
                if option.isDownloaded {
                    downloadedPostProcModels.insert(option.id)
                    downloadMessages.removeValue(forKey: option.id)
                    downloadSnapshots.removeValue(forKey: option.id)
                } else {
                    downloadMessages[option.id] = "Paused — select Download to resume"
                }
                downloadGenerations.removeValue(forKey: option.id)
            }
        }
        withAnimation {
            downloadingPostProcModels.remove(option.id)
            downloadProgressPostProc.removeValue(forKey: option.id)
            // Invalidate callbacks from the cancelled task, but retain a
            // generation until it has fully unwound so a race that finalizes
            // the file can refresh the card immediately.
            downloadGenerations[option.id] = cancellationGeneration
            if let snapshot = downloadSnapshots[option.id] {
                downloadSnapshots[option.id] = snapshot.replacing(phase: .paused, message: "Paused — select Download to resume")
            }
            downloadTasksPostProc.removeValue(forKey: option.id)
        }
    }

    private func deletePostProcModel(_ option: PostProcessorOption) {
        if appState.activePostProcessor.id == option.id {
            let remainingDownloadedIDs = downloadedPostProcModels.subtracting([option.id])
            if let fallback = PostProcessorOption.firstDownloaded(excluding: option.id, downloadedIDs: remainingDownloadedIDs) {
                controller.selectPostProcessor(fallback)
            } else {
                controller.setPostProcessorEnabled(false)
            }
        }
        try? FileManager.default.removeItem(at: option.cacheDirectory)
        downloadedPostProcModels.remove(option.id)
        downloadSnapshots.removeValue(forKey: option.id)
        downloadGenerations.removeValue(forKey: option.id)
    }

    private func checkDownloadedPostProcModels() {
        downloadedPostProcModels.removeAll()
        for option in PostProcessorOption.downloaded {
            if option.isDownloaded {
                downloadedPostProcModels.insert(option.id)
            }
        }
    }

    /// The retired v2 cleanup model stays visible only for people who already
    /// have it installed. Deleting it removes the card, and the model cannot
    /// be downloaded again.
    private var displayedPostProcessorOptions: [PostProcessorOption] {
        PostProcessorOption.all
            + (downloadedPostProcModels.contains(PostProcessorOption.legacyV2.id)
                ? [.legacyV2]
                : [])
    }

    // MARK: - Actions

    private func startDownload(_ option: BackendOption) {
        withAnimation { _ = downloadingModels.insert(option.model) }
        downloadProgress[option.model] = 0.05  // Show initial progress immediately
        downloadMessages.removeValue(forKey: option.model)
        downloadSnapshots.removeValue(forKey: option.model)
        let generation = UUID()
        downloadGenerations[option.model] = generation

        let startTime = Date()
        let task = Task {
            do {
                try await controller.transcriptionCoordinator.preloadRequired(
                    backend: option,
                    includeMeetingHelpers: false,
                    meetingHelperTrigger: .modelLibrary,
                    appleSpeechLanguage: appState.config.resolvedAppleSpeechLanguage
                ) { progress, message in
                    DispatchQueue.main.async {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadProgress[option.model] = max(progress, 0.05)
                        if let message { downloadMessages[option.model] = message }
                    }
                } progressSnapshot: { snapshot in
                    DispatchQueue.main.async {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadSnapshots[option.model] = snapshot
                        if let fraction = snapshot.fractionCompleted {
                            downloadProgress[option.model] = max(fraction, 0.05)
                        }
                    }
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard downloadGenerations[option.model] == generation else { return }
                        withAnimation {
                            downloadingModels.remove(option.model)
                            downloadProgress.removeValue(forKey: option.model)
                            downloadMessages[option.model] = "Paused — select Download to resume"
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                            downloadGenerations.removeValue(forKey: option.model)
                            downloadTasks.removeValue(forKey: option.model)
                        }
                    }
                    return
                }
                guard isModelDownloaded(option, fm: FileManager.default) else {
                    throw NSError(
                        domain: "MuesliModelDownload",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "\(option.label) was not downloaded successfully."]
                    )
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard downloadGenerations[option.model] == generation else { return }
                        withAnimation {
                            downloadingModels.remove(option.model)
                            downloadProgress.removeValue(forKey: option.model)
                            downloadMessages[option.model] = "Paused — select Download to resume"
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                            downloadGenerations.removeValue(forKey: option.model)
                            downloadTasks.removeValue(forKey: option.model)
                        }
                    }
                    return
                }
                // Ensure the downloading state is visible for at least 1.5s
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < 1.5 {
                    try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
                }
                await MainActor.run {
                    guard downloadGenerations[option.model] == generation, !Task.isCancelled else { return }
                    withAnimation {
                        downloadingModels.remove(option.model)
                        downloadedModels.insert(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        downloadMessages.removeValue(forKey: option.model)
                        downloadSnapshots.removeValue(forKey: option.model)
                        downloadGenerations.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
            } catch {
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                await MainActor.run {
                    withAnimation {
                        guard downloadGenerations[option.model] == generation else { return }
                        downloadingModels.remove(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        if isCancelled {
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .paused,
                                    message: "Paused — select Download to resume"
                                )
                            }
                        } else {
                            downloadMessages[option.model] = error.localizedDescription
                            if let snapshot = downloadSnapshots[option.model] {
                                downloadSnapshots[option.model] = snapshot.replacing(
                                    phase: .failed,
                                    message: error.localizedDescription
                                )
                            }
                        }
                        downloadGenerations.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
                if !isCancelled {
                    fputs("[muesli-native] model download failed for \(option.backend)/\(option.model): \(error)\n", stderr)
                }
            }
        }
        downloadTasks[option.model] = task
    }

    private func loadAppleSpeechLanguageOptions() {
        guard #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem else {
            appleSpeechLanguageOptions = [.system]
            return
        }

        Task {
            var options = await AppleSpeechLanguageOption.supportedOptions()
            let selectedIdentifier = appState.config.resolvedAppleSpeechLanguage
            if selectedIdentifier != AppleSpeechLanguageOption.systemIdentifier,
               !options.contains(where: { $0.id == selectedIdentifier }) {
                options.append(.locale(Locale(identifier: selectedIdentifier)))
            }
            appleSpeechLanguageOptions = options
        }
    }

    private func cancelDownload(_ option: BackendOption) {
        let modelID = option.model
        let task = downloadTasks[modelID]
        let cancellationGeneration = UUID()
        task?.cancel()
        withAnimation {
            downloadingModels.remove(modelID)
            downloadProgress.removeValue(forKey: modelID)
            downloadMessages[modelID] = "Paused — select Download to resume"
            // Keep a cancellation generation until the caller task has fully
            // unwound. If a replacement starts first, this generation changes
            // and the old cancellation must not stop the replacement transfer.
            downloadGenerations[modelID] = cancellationGeneration
            downloadTasks.removeValue(forKey: modelID)
            if let snapshot = downloadSnapshots[modelID] {
                downloadSnapshots[modelID] = snapshot.replacing(
                    phase: .paused,
                    message: "Paused — select Download to resume"
                )
            }
        }
        Task {
            let shouldCancel = await MainActor.run {
                downloadGenerations[modelID] == cancellationGeneration
            }
            guard shouldCancel else { return }

            await ManagedASRModelDownloader.cancel(modelID: modelID)
            _ = await task?.value

            await MainActor.run {
                guard downloadGenerations[modelID] == cancellationGeneration else { return }
                downloadGenerations.removeValue(forKey: modelID)
            }
        }
    }

    /// Re-download Nemotron 3.5 to pick up a newer upstream build: delete the cached
    /// files (so the download isn't skipped), then start a fresh download.
    private func updateNemotron35(_ option: BackendOption) {
        Task {
            do {
                await controller.transcriptionCoordinator.unloadNemotron35Transcriber()
                try await deleteModelFiles(option)
                await MainActor.run {
                    downloadedModels.remove(option.model)
                    nemotron35UpdateAvailable = false
                    startDownload(option)
                }
            } catch {
                fputs("[muesli-native] model update cleanup failed for \(option.backend)/\(option.model): \(error)\n", stderr)
            }
        }
    }

    private func deleteModel(_ option: BackendOption) {
        if option == .nemotron35Multilingual,
           appState.config.resolvedMeetingLiveCaptionBackend == .nemotron35 {
            controller.updateConfig { $0.enableLiveStreamingPartials = false }
        }
        if appState.selectedPostProcessorBackend == .gemma4LiteRT,
           appState.config.postProcessorGemmaModel == option.model {
            controller.selectPostProcessorBackend(.local)
        }
        if appState.selectedBackend == option {
            let fallback = downloadedModels
                .compactMap { model in BackendOption.all.first(where: { $0.model == model && $0 != option }) }
                .first ?? (option == .parakeetUnified ? .parakeetMultilingual : .parakeetUnified)
            controller.selectBackend(fallback)
        }
        let task = downloadTasks[option.model]
        task?.cancel()
        let deletionGeneration = UUID()
        downloadGenerations[option.model] = deletionGeneration
        downloadTasks.removeValue(forKey: option.model)

        // Stop any transfer before removing files so a late write cannot recreate
        // part of the model after the deletion has completed.
        Task {
            let deletionToken = await ManagedASRModelDownloader.beginDeletion(
                modelID: option.model
            )
            do {
                _ = await task?.value
                let shouldDelete = await MainActor.run {
                    downloadGenerations[option.model] == deletionGeneration
                }
                guard shouldDelete else {
                    await ManagedASRModelDownloader.endDeletion(deletionToken)
                    return
                }
                try await deleteModelFiles(option)
                await MainActor.run {
                    _ = downloadedModels.remove(option.model)
                    if appState.selectedMeetingTranscriptionBackend == option {
                        controller.refreshMeetingTranscriptionSelectionForAvailability()
                    }
                    downloadSnapshots.removeValue(forKey: option.model)
                    downloadMessages.removeValue(forKey: option.model)
                    downloadGenerations.removeValue(forKey: option.model)
                }
            } catch {
                fputs("[muesli-native] model delete failed for \(option.backend)/\(option.model): \(error)\n", stderr)
            }
            await ManagedASRModelDownloader.endDeletion(deletionToken)
        }
    }

    private func deleteModelFiles(_ option: BackendOption) async throws {
        let fm = FileManager.default
        switch option.backend {
        case "whisper":
            WhisperKitTranscriber.deleteModel(option.model)
        case "nemotron35":
            try removeItemIfPresent(at: Nemotron35ModelStore.cacheDirectory(fileManager: fm), fileManager: fm)
        case "cohere":
            try removeItemIfPresent(at: CohereTranscribeModelStore.cacheDirectory(), fileManager: fm)
        case "indicasr":
            if IndicASRModelStore.localOverrideDirectory() == nil {
                try removeItemIfPresent(at: IndicASRModelStore.cacheDirectory(), fileManager: fm)
            }
        case "sensevoice":
            SenseVoiceTranscriber.deleteModelFiles(fileManager: fm)
        case "gemma4-litert":
            await controller.transcriptionCoordinator.unloadGemma4LiteRTTranscriber()
            try Gemma4LiteRTModelStore.deleteModelFiles(
                model: Gemma4LiteRTModel.resolved(option.model),
                fileManager: fm
            )
        case "fluidaudio":
            let version: AsrModelVersion = option.model.contains("v2") ? .v2 : .v3
            await controller.transcriptionCoordinator.unloadFluidAudioTranscriber(
                ifLoadedVersion: version
            )
            let plan = version == .v2
                ? ManagedASRModelPlans.parakeetV2()
                : ManagedASRModelPlans.parakeetV3()
            try plan.delete(fileManager: fm)
        case "parakeet-unified":
            await controller.transcriptionCoordinator.unloadParakeetUnifiedTranscriber()
            try ManagedASRModelPlans.parakeetUnified().delete(fileManager: fm)
        case "qwen":
            await controller.transcriptionCoordinator.unloadQwen3Transcriber()
            try Qwen3AsrModelStore.deleteModelFiles(fileManager: fm)
        default:
            break
        }
    }

    private func removeItemIfPresent(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: - Check Downloaded Status

    private func checkDownloadedModels() {
        let fm = FileManager.default
        for option in BackendOption.all {
            if isModelDownloaded(option, fm: fm) {
                downloadedModels.insert(option.model)
            }
        }
    }

    /// Background check: does FluidInference's repo have a newer commit than what's
    /// installed for Nemotron 3.5? Never auto-downloads — just surfaces a badge.
    private func checkNemotron35Update() {
        guard #available(macOS 15, *),
              isModelDownloaded(.nemotron35Multilingual, fm: FileManager.default) else { return }
        Task {
            let available = await Nemotron35StreamingTranscriber.updateAvailable()
            await MainActor.run { nemotron35UpdateAvailable = available }
        }
    }

    private func syncSelectionsFromActiveBackend() {
        let active = appState.selectedBackend
        if BackendOption.parakeetFamily.contains(active) {
            selectedParakeetModel = active.model
        }
        if BackendOption.whisperFamily.contains(active) {
            selectedWhisperModel = active.model
        }
        if BackendOption.experimental.contains(active) {
            showExperimental = true
        }
    }

    private func isModelDownloaded(_ option: BackendOption, fm: FileManager) -> Bool {
        switch option.backend {
        case "whisper":
            return WhisperKitTranscriber.isModelDownloaded(option.model)
        case "nemotron35":
            return Nemotron35ModelStore.isModelDownloaded(fileManager: fm)
        case "fluidaudio":
            let plan = option.model.contains("v2")
                ? ManagedASRModelPlans.parakeetV2()
                : ManagedASRModelPlans.parakeetV3()
            return plan.isAvailableLocally(fileManager: fm)
        case "parakeet-unified":
            return ManagedASRModelPlans.parakeetUnified().isAvailableLocally(fileManager: fm)
        case "qwen":
            return Qwen3AsrModelStore.isModelDownloaded(fileManager: fm)
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        case "indicasr":
            return IndicASRModelStore.isAvailableLocally()
        case "sensevoice":
            return SenseVoiceTranscriber.isModelDownloaded(fileManager: fm)
        case "gemma4-litert":
            return Gemma4LiteRTModelStore.isAvailableLocally(
                model: Gemma4LiteRTModel.resolved(option.model),
                fileManager: fm
            )
        case "apple-speech":
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem
            }
            return false
        default:
            return false
        }
    }
}

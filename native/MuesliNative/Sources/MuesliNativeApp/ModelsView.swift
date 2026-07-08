import SwiftUI
import MuesliCore

struct ModelsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var nemotron35UpdateAvailable = false
    @State private var downloadingModels: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var modelToDelete: BackendOption?
    @State private var selectedParakeetModel: String
    @State private var selectedWhisperModel: String
    @State private var showExperimental: Bool

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
        _selectedParakeetModel = State(initialValue: BackendOption.parakeetFamily.contains(active) ? active.model : BackendOption.parakeetMultilingual.model)
        _selectedWhisperModel = State(initialValue: BackendOption.whisperFamily.contains(active) ? active.model : BackendOption.whisperSmall.model)
        _showExperimental = State(initialValue: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Models")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Download and manage transcription models. The active model is used for dictation.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)

                familyCard(
                    title: "Parakeet Family",
                    subtitle: "NVIDIA speech models for fast everyday dictation.",
                    defaultBadge: "Default: v3",
                    logo: "nvidia-logo",
                    selection: $selectedParakeetModel,
                    options: BackendOption.parakeetFamily
                )

                familyCard(
                    title: "Whisper",
                    subtitle: "OpenAI Whisper variants. Runs on Apple Neural Engine via CoreML.",
                    defaultBadge: "Default: Small",
                    logo: "openai-logo",
                    selection: $selectedWhisperModel,
                    options: BackendOption.whisperFamily
                )

                modelCard(option: .cohereTranscribe, logo: "cohere-logo")

                modelCard(option: .nemotron35Multilingual, logo: "nvidia-logo")

                experimentalSection

                postProcessorSection

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
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
        .onAppear {
            checkDownloadedModels()
            checkDownloadedPostProcModels()
            syncSelectionsFromActiveBackend()
            checkNemotron35Update()
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
            Text("The downloaded model files will be removed from this Mac. You can download the model again later.")
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

                        Text("SenseVoice, Qwen, Indic ASR, and legacy streaming backends. Hidden by default because these are still slower and less polished.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .opacity(0.8)
                    }

                    Spacer()

                    Text("IYKYK")
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

            if showExperimental {
                VStack(spacing: MuesliTheme.spacing12) {
                    ForEach(BackendOption.experimental, id: \.model) { option in
                        modelCard(option: option, logo: logoForBackend(option))
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

    private var postProcessorSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("POST-PROCESSING")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)

                Text("Optional LLM cleanup layer applied after transcription. Removes filler words, formats spoken lists, and corrects common dictation errors.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.leading, 2)
            }
            .padding(.top, MuesliTheme.spacing8)

            VStack(spacing: MuesliTheme.spacing12) {
                ForEach(PostProcessorOption.all) { option in
                    postProcModelCard(option)
                }
            }
        }
    }

    private func postProcModelCard(_ option: PostProcessorOption) -> some View {
        let isDownloaded = downloadedPostProcModels.contains(option.id)
        let isActive = appState.activePostProcessor.id == option.id && isDownloaded
        let isDownloading = downloadingPostProcModels.contains(option.id)
        let progress = downloadProgressPostProc[option.id] ?? 0

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                brandLogo("qwen-logo")
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

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                if isDownloading {
                    Button("Cancel") {
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
                } else {
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

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
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
    private func brandLogo(_ name: String?) -> some View {
        if let name,
           let url = Bundle.main.url(forResource: name, withExtension: "png"),
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
        case "whisper": return "openai-logo"
        case "cohere": return "cohere-logo"
        case "qwen": return "qwen-logo"
        case "nemotron35": return "nvidia-logo"
        case "indicasr": return "ai4bharat-logo"
        case "sensevoice": return "qwen-logo"
        default: return nil
        }
    }

    @ViewBuilder
    private func actionButtons(for option: BackendOption, isActive: Bool, isDownloaded: Bool, isDownloading: Bool) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if isDownloading {
                Button("Cancel") {
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
                    Button("Set Active") {
                        controller.selectBackend(option)
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
                    modelToDelete = option
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.6))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
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

    private func modelCard(option: BackendOption, logo: String? = nil) -> some View {
        let isActive = appState.selectedBackend == option
        let isDownloaded = downloadedModels.contains(option.model)
        let isDownloading = downloadingModels.contains(option.model)
        let progress = downloadProgress[option.model] ?? 0

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

                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                // Status badge
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
            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            actionButtons(for: option, isActive: isActive, isDownloaded: isDownloaded, isDownloading: isDownloading)
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

                        Text("Experimental")
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
        withAnimation { _ = downloadingPostProcModels.insert(option.id) }
        downloadProgressPostProc[option.id] = 0.02

        let task = Task {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: option.cacheDirectory, withIntermediateDirectories: true)

                try await downloadPostProcModel(option)

                await MainActor.run {
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadedPostProcModels.insert(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                    if appState.config.enablePostProcessor && !appState.activePostProcessor.isDownloaded {
                        controller.selectPostProcessor(option)
                        controller.preloadExperimentalTranscriptionFeatures()
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                }
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !isCancelled {
                    fputs("[muesli-native] Post-processor download failed: \(error)\n", stderr)
                }
            }
        }
        downloadTasksPostProc[option.id] = task
    }

    private func downloadPostProcModel(_ option: PostProcessorOption, maxRetries: Int = 3) async throws {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            try Task.checkCancellation()
            if attempt > 0 {
                let delay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                fputs("[download] retry \(attempt)/\(maxRetries) for \(option.filename)\n", stderr)
                await MainActor.run {
                    downloadProgressPostProc[option.id] = 0.02
                }
            }
            do {
                let tmpURL = try await downloadPostProcTempFile(option)
                try installPostProcModel(from: tmpURL, option: option)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        let underlying = lastError ?? NSError(domain: "PostProcDownload", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "No download attempts were made",
        ])
        throw DownloadError.retriesExhausted(option.filename, underlying)
    }

    private func downloadPostProcTempFile(_ option: PostProcessorOption) async throws -> URL {
        let delegate = PostProcDownloadDelegate { progress in
            DispatchQueue.main.async {
                downloadProgressPostProc[option.id] = max(progress, 0.02)
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let invalidator = URLSessionInvalidator()
        do {
            let downloadedURL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.setContinuation(continuation)
                    session.downloadTask(with: option.downloadURL).resume()
                }
            } onCancel: {
                invalidator.cancel(session)
            }
            invalidator.finish(session)
            return downloadedURL
        } catch {
            if error is CancellationError {
                invalidator.cancel(session)
            } else {
                invalidator.finish(session)
            }
            throw error
        }
    }

    private func installPostProcModel(from tmpURL: URL, option: PostProcessorOption) throws {
        let fm = FileManager.default
        let stagingURL = option.cacheDirectory.appendingPathComponent(".\(option.filename).download")
        defer {
            try? fm.removeItem(at: tmpURL)
            try? fm.removeItem(at: stagingURL)
        }
        try? fm.removeItem(at: stagingURL)
        try fm.moveItem(at: tmpURL, to: stagingURL)
        if fm.fileExists(atPath: option.modelURL.path) {
            _ = try fm.replaceItemAt(
                option.modelURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fm.moveItem(at: stagingURL, to: option.modelURL)
        }
    }

    private func cancelPostProcDownload(_ option: PostProcessorOption) {
        downloadTasksPostProc[option.id]?.cancel()
        withAnimation {
            downloadingPostProcModels.remove(option.id)
            downloadProgressPostProc.removeValue(forKey: option.id)
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
    }

    private func checkDownloadedPostProcModels() {
        downloadedPostProcModels.removeAll()
        for option in PostProcessorOption.all {
            if option.isDownloaded {
                downloadedPostProcModels.insert(option.id)
            }
        }
    }

    // MARK: - Actions

    private func startDownload(_ option: BackendOption) {
        withAnimation { _ = downloadingModels.insert(option.model) }
        downloadProgress[option.model] = 0.05  // Show initial progress immediately

        let startTime = Date()
        let task = Task {
            do {
                try await controller.transcriptionCoordinator.preloadRequired(
                    backend: option,
                    includeMeetingHelpers: controller.config.resolvedOnboardingUseCase.includesMeetings
                ) { progress, _ in
                    DispatchQueue.main.async {
                        downloadProgress[option.model] = max(progress, 0.05)
                    }
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
                        withAnimation {
                            downloadingModels.remove(option.model)
                            downloadProgress.removeValue(forKey: option.model)
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
                    withAnimation {
                        downloadingModels.remove(option.model)
                        downloadedModels.insert(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        downloadingModels.remove(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
                if !(error is CancellationError) {
                    fputs("[muesli-native] model download failed for \(option.backend)/\(option.model): \(error)\n", stderr)
                }
            }
        }
        downloadTasks[option.model] = task
    }

    private func cancelDownload(_ option: BackendOption) {
        downloadTasks[option.model]?.cancel()
        withAnimation {
            downloadingModels.remove(option.model)
            downloadProgress.removeValue(forKey: option.model)
            downloadTasks.removeValue(forKey: option.model)
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
        if appState.selectedBackend == option {
            let fallback = downloadedModels
                .compactMap { model in BackendOption.all.first(where: { $0.model == model && $0 != option }) }
                .first ?? .parakeetMultilingual
            controller.selectBackend(fallback)
        }
        // Remove cached model files
        Task {
            do {
                try await deleteModelFiles(option)
                await MainActor.run {
                    _ = downloadedModels.remove(option.model)
                }
            } catch {
                fputs("[muesli-native] model delete failed for \(option.backend)/\(option.model): \(error)\n", stderr)
            }
        }
    }

    private func deleteModelFiles(_ option: BackendOption) async throws {
        let fm = FileManager.default
        switch option.backend {
        case "whisper":
            WhisperKitTranscriber.deleteModel(option.model)
        case "nemotron35":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron35-multilingual-2240ms")
            try removeItemIfPresent(at: path, fileManager: fm)
        case "cohere":
            try removeItemIfPresent(at: CohereTranscribeModelStore.cacheDirectory(), fileManager: fm)
        case "indicasr":
            if IndicASRModelStore.localOverrideDirectory() == nil {
                try removeItemIfPresent(at: IndicASRModelStore.cacheDirectory(), fileManager: fm)
            }
        case "sensevoice":
            SenseVoiceTranscriber.deleteModelFiles(fileManager: fm)
        case "fluidaudio":
            // FluidAudio models are in ~/Library/Application Support/FluidAudio/Models/
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if option.model.contains("parakeet") {
                let version = option.model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    for dir in contents where dir.lastPathComponent.contains("parakeet") && dir.lastPathComponent.contains(version) {
                        try removeItemIfPresent(at: dir, fileManager: fm)
                    }
                }
            }
        case "qwen":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            try removeItemIfPresent(at: path, fileManager: fm)
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
            return
        }
    }

    private func isModelDownloaded(_ option: BackendOption, fm: FileManager) -> Bool {
        switch option.backend {
        case "whisper":
            return WhisperKitTranscriber.isModelDownloaded(option.model)
        case "nemotron35":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron35-multilingual-2240ms/encoder.mlmodelc/coremldata.bin")
            return fm.fileExists(atPath: path.path)
        case "fluidaudio":
            // Check FluidAudio's cache
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if option.model.contains("parakeet") {
                let version = option.model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    return contents.contains { $0.lastPathComponent.contains("parakeet") && $0.lastPathComponent.contains(version) }
                }
            }
            return false
        case "qwen":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            return fm.fileExists(atPath: supportDir.appendingPathComponent("int8/vocab.json").path)
                || fm.fileExists(atPath: supportDir.appendingPathComponent("f32/vocab.json").path)
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        case "indicasr":
            return IndicASRModelStore.isAvailableLocally()
        case "sensevoice":
            return SenseVoiceTranscriber.isModelDownloaded()
        default:
            return false
        }
    }
}

private final class URLSessionInvalidator: @unchecked Sendable {
    private let lock = NSLock()
    private var didInvalidate = false

    func finish(_ session: URLSession) {
        invalidate(session, action: { $0.finishTasksAndInvalidate() })
    }

    func cancel(_ session: URLSession) {
        invalidate(session, action: { $0.invalidateAndCancel() })
    }

    private func invalidate(_ session: URLSession, action: (URLSession) -> Void) {
        lock.lock()
        guard !didInvalidate else {
            lock.unlock()
            return
        }
        didInvalidate = true
        lock.unlock()
        action(session)
    }
}

/// URLSessionDownloadDelegate bridge for post-processor GGUF downloads.
/// Uses OS-level buffered download task instead of byte-by-byte async iteration.
private final class PostProcDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func setContinuation(_ c: CheckedContinuation<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuation = c
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        var dest: URL?
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw NSError(domain: "PostProcDownload", code: response.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Post-processor download failed with HTTP \(response.statusCode)",
                ])
            }

            // URLSession deletes the temp file after this returns — move it first.
            let movedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".gguf.tmp")
            try FileManager.default.moveItem(at: location, to: movedURL)
            dest = movedURL
            try validateGGUFHeader(at: movedURL)
            resumeOnce(.success(movedURL))
        } catch {
            if let dest { try? FileManager.default.removeItem(at: dest) }
            resumeOnce(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resumeOnce(.failure(error))
    }

    private func resumeOnce(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
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
}

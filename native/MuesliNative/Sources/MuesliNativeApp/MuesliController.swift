import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Sparkle
import TelemetryDeck
import MuesliCore

private enum DictationOutputMode {
    case paste
    case voiceNote

    var pasteMethod: String {
        switch self {
        case .paste:
            return "clipboard_restore"
        case .voiceNote:
            return "voice_note"
        }
    }
}

private enum DictationAudioRouteTiming {
    static let stabilizationDelay: TimeInterval = 1.0
}

struct MeetingResummarizationPlan: Equatable {
    let promptTitle: String
    let persistedTitle: String
}

enum MeetingResummarizationPolicy {
    static func plan(for meeting: MeetingRecord) -> MeetingResummarizationPlan {
        let trimmed = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTitle = trimmed.isEmpty ? "Meeting" : trimmed
        return MeetingResummarizationPlan(
            promptTitle: promptTitle,
            persistedTitle: meeting.title
        )
    }
}

enum MeetingSummaryPersistenceError: Error, LocalizedError {
    case failedToSaveSummary(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveSummary(let underlying):
            let detail = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "The updated meeting notes could not be saved."
            }
            return "The updated meeting notes could not be saved. \(detail)"
        }
    }
}

enum MeetingTemplateSelectionError: Error, LocalizedError {
    case templateNoLongerExists

    var errorDescription: String? {
        switch self {
        case .templateNoLongerExists:
            return "That template no longer exists. Choose another template and try again."
        }
    }
}

enum MeetingRetranscriptionError: Error, LocalizedError {
    case controllerUnavailable
    case recordingUnavailable
    case noDownloadedTranscriptionModel
    case emptyTranscript
    case failedToSave(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .controllerUnavailable:
            return "Meeting re-transcription could not continue because Muesli is no longer available."
        case .recordingUnavailable:
            return "The saved meeting recording is no longer available on disk."
        case .noDownloadedTranscriptionModel:
            return "Download a transcription model before re-transcribing this meeting."
        case .emptyTranscript:
            return "Re-transcription finished, but no speech was detected in the saved recording."
        case .failedToSave(let underlying):
            return "The re-transcribed meeting could not be saved. \(underlying.localizedDescription)"
        }
    }
}

enum MeetingLifecycleError: Error, LocalizedError {
    case failedToSaveRecording(underlying: Error)
    case failedToDeleteRecording(underlying: Error)
    case failedToDeleteMeeting(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveRecording(let underlying):
            return "The meeting finished transcribing, but the recording could not be saved. \(underlying.localizedDescription)"
        case .failedToDeleteRecording(let underlying):
            return "The saved meeting recording could not be deleted, so the meeting was left in place. \(underlying.localizedDescription)"
        case .failedToDeleteMeeting(let underlying):
            return "The meeting could not be deleted. \(underlying.localizedDescription)"
        }
    }
}

struct CompletedMeetingPersistenceResult {
    let meetingID: Int64
    let recordingSaveError: MeetingLifecycleError?
}

private final class DictationLatencyLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.muesli.dictation-latency-log")
    private let url: URL
    private var hasCreatedDirectory = false

    init(url: URL) {
        self.url = url
    }

    func append(_ line: String) {
        queue.async { [self] in
            do {
                if !hasCreatedDirectory {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    hasCreatedDirectory = true
                }
                try Self.trimIfNeeded(at: url)
                let data = Data((line + "\n").utf8)
                do {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                fputs("[dictation-latency] failed to append log: \(error)\n", stderr)
            }
        }
    }

    private static func trimIfNeeded(at url: URL) throws {
        let maxBytes: UInt64 = 2 * 1024 * 1024
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes?[.size] as? UInt64,
              fileSize > maxBytes else { return }

        let data = try Data(contentsOf: url)
        let keepCount = min(data.count, Int(maxBytes / 2))
        let tail = data.suffix(keepCount)
        let newlineIndex = tail.firstIndex(of: UInt8(ascii: "\n"))
        let trimmed = newlineIndex.map { tail[tail.index(after: $0)...] } ?? tail[...]
        try Data(trimmed).write(to: url, options: .atomic)
    }
}

@MainActor
final class MuesliController: NSObject {
    private let runtime: RuntimePaths
    private let configStore = ConfigStore()
    private let dictationStore: DictationStore
    private let meetingHookDispatcher: MeetingHookDispatching
    private let launchAtLoginCoordinator: LaunchAtLoginCoordinator
    let transcriptionCoordinator = TranscriptionCoordinator()
    private let hotkeyMonitor = HotkeyMonitor()
    private let computerUseHotkeyMonitor = HotkeyMonitor()
    private let recorder = MicrophoneRecorder()
    private let audioDuckingController: AudioDuckingManaging
    private let dictationAudioRoutingController: DictationAudioRouting
    private lazy var dictationAudioSessionManager = DictationAudioSessionManager(
        recorder: recorder,
        duckingController: audioDuckingController,
        routingController: dictationAudioRoutingController
    )
    private let dictationLatencyLogWriter = DictationLatencyLogWriter(
        url: AppIdentity.supportDirectoryURL.appendingPathComponent("dictation-latency.log")
    )
    private let dictationLatencyTimestampFormatter = ISO8601DateFormatter()
    private let indicator: FloatingIndicatorController
    private let calendarMonitor = CalendarMonitor()
    private let meetingMonitor = MeetingMonitor()
    private let meetingNotification = MeetingNotificationController()
    private let meetingSourceWindowLocator = MeetingSourceWindowLocator()

    private let chatGPTAuth = ChatGPTAuthManager.shared
    private let googleCalAuth = GoogleCalendarAuthManager.shared
    private let googleCalClient = GoogleCalendarClient()
    private var calendarCheckTimer: Timer?
    private var meetingStartingNowTimers = [String: Timer]()
    private var notifiedUpcomingEventIDs = Set<String>()
    private var meetingFeatureMonitorsAllowed = false
    private var meetingDetectionMonitorStarted = false

    private var searchTask: Task<Void, Never>?
    private var onboardingModelPreparationTask: Task<Void, Never>?
    private var maraudersMapCountdown: MaraudersMapCountdownController?

    private var statusBarController: StatusBarController?
    private var historyWindowController: RecentHistoryWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    var updaterController: SPUStandardUpdaterController?
    private var busyStatusGeneration = 0

    let appState = AppState()

    private(set) var config: AppConfig
    private(set) var selectedBackend: BackendOption
    private(set) var selectedMeetingTranscriptionBackend: BackendOption
    private(set) var selectedMeetingSummaryBackend: MeetingSummaryBackendOption
    private var activeMeetingSession: MeetingSession?
    private var activeMeetingID: Int64?
    private var liveMeetingTitleCache: [Int64: String] = [:]
    private var liveManualNotesCache: [Int64: String] = [:]
    private var liveManualNotesLastPersistedAt: [Int64: Date] = [:]
    private var liveManualNotesLastPersistedValue: [Int64: String] = [:]
    private var liveManualNotesPersistWorkItems: [Int64: DispatchWorkItem] = [:]
    private let liveManualNotesPersistInterval: TimeInterval = 0.75
    private var staleLiveMeetingRecoveryFailures = Set<Int64>()
    private var dictationState: DictationState = .idle
    private var dictationStartedAt: Date?
    private var dictationLatencyTraceID: UUID?
    private var dictationLatencyTraceStartedAt: Date?
    private var currentDictationOutputMode: DictationOutputMode = .paste
    private var pendingDictationStopStartedAt: Date?
    private var pendingDictationStopSessionID: UUID?
    private var pendingReleaseSoundSessionID: UUID?
    private var computerUseCommandStartedAt: Date?
    private var computerUseCommandTask: Task<Void, Never>?
    private var computerUseFloatingStatusWorkItem: DispatchWorkItem?
    private var computerUseLastFloatingStatusAt = Date.distantPast
    private var computerUseLastFloatingStatus = ""
    private var computerUseTranscriptVisible = false
    private let computerUseFloatingStatusMinimumDwell: TimeInterval = 0.85
    private var _streamingDictationController: Any?  // StreamingDictationController (macOS 15+)
    private var isNemotronStreaming = false
    private var nemotronStreamingSessionID: UUID?
    private var previousStreamText = ""
    private var openWindowCount = 0
    private var lastExternalApp: NSRunningApplication?
    private var capturedDictationContext: DictationContext?
    private var workspaceObserver: NSObjectProtocol?
    private var dataDidChangeObserver: NSObjectProtocol?
    private var isStartingMeetingRecording = false
    private var meetingStartStatus: String?
    private var isShowingCalendarNotification = false
    private var presentedMeetingCandidate: MeetingCandidate?
    private var meetingEndTimer: Timer?
    private var activeMeetingCalendarEndDate: Date?
    private var meetingActivity: NSObjectProtocol?
    private var isStoppingMeetingRecording = false
    private var meetingStartTask: Task<Void, Never>?
    private var meetingStartMeetingID: Int64?
    private var canceledMeetingStartIDs = Set<Int64>()
    private var hasStarted = false

    init(
        runtime: RuntimePaths,
        dictationStore: DictationStore? = nil,
        meetingHookDispatcher: MeetingHookDispatching = MeetingHookRunner(),
        launchAtLoginManager: LaunchAtLoginManaging = SystemLaunchAtLoginManager(),
        audioDuckingController: AudioDuckingManaging = AudioDuckingController(),
        dictationAudioRoutingController: DictationAudioRouting = DictationAudioRouteController()
    ) {
        let loadedConfig = configStore.load()
        self.runtime = runtime
        self.dictationStore = dictationStore ?? DictationStore(
            databaseURL: MuesliPaths.defaultDatabaseURL(appName: AppIdentity.supportDirectoryName)
        )
        self.meetingHookDispatcher = meetingHookDispatcher
        self.launchAtLoginCoordinator = LaunchAtLoginCoordinator(manager: launchAtLoginManager)
        self.audioDuckingController = audioDuckingController
        self.dictationAudioRoutingController = dictationAudioRoutingController
        self.config = loadedConfig
        if loadedConfig.recordingColorHex != "1e1e2e" {
            MuesliTheme.accentOverrideHex = loadedConfig.recordingColorHex
        }
        self.selectedBackend = BackendOption.all.first(where: {
            $0.backend == loadedConfig.sttBackend && $0.model == loadedConfig.sttModel
        }) ?? .whisper
        let configuredMeetingBackend = BackendOption.resolve(
            backend: loadedConfig.meetingTranscriptionBackend,
            model: loadedConfig.meetingTranscriptionModel
        )
        self.selectedMeetingTranscriptionBackend = Self.availableMeetingTranscriptionBackend(
            config: loadedConfig,
            dictationBackend: self.selectedBackend,
            downloadedOptions: BackendOption.downloaded
        ) ?? configuredMeetingBackend ?? self.selectedBackend
        self.selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == loadedConfig.meetingSummaryBackend
        }) ?? .chatGPT
        self.indicator = FloatingIndicatorController(configStore: configStore)
        ComputerUseCursorOverlay.shared.attachIndicator(self.indicator)
        super.init()
        dictationAudioSessionManager.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDictationAudioSessionEvent(event)
            }
        }
        dictationAudioRoutingController.onPreferredInputDeviceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncDictationRecorderWarmup(
                    reason: "route-change",
                    delay: DictationAudioRouteTiming.stabilizationDelay
                )
            }
        }
    }

    func start() {
        hasStarted = true
        do {
            try dictationStore.migrateIfNeeded()
        } catch {
            fputs("[muesli-native] startup error: \(error)\n", stderr)
        }
        recoverStaleLiveMeetings()
        normalizeMeetingTranscriptionSelectionForAvailability()
        SoundController.prewarmLifecycleSounds()

        // Clean up phantom aggregate devices left by a previous crash
        CoreAudioSystemRecorder.cleanupStaleDevices()

        syncLaunchAtLoginConfigWithSystem()

        // Clean up leftover audio temp files from previous sessions.
        cleanupTemporaryDirectory(
            named: "muesli-system-audio",
            logDescription: "leftover temp audio files"
        )
        cleanupTemporaryDirectory(
            named: "muesli-meeting-recordings",
            logDescription: "leftover temp meeting recording files"
        )

        hotkeyMonitor.onArm = { [weak self] in self?.handleArm() }
        hotkeyMonitor.onPrepare = { [weak self] in self?.handlePrepare() }
        hotkeyMonitor.onStart = { [weak self] in self?.handleStart() }
        hotkeyMonitor.onStop = { [weak self] in self?.handleStop() }
        hotkeyMonitor.onCancel = { [weak self] in self?.handleCancel() }
        hotkeyMonitor.onToggleStart = { [weak self] in self?.handleToggleStart() }
        hotkeyMonitor.onToggleStop = { [weak self] in self?.handleToggleStop() }
        hotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        configureHotkeyMonitorTiming()
        computerUseHotkeyMonitor.onPrepare = { [weak self] in self?.handleComputerUsePrepare() }
        computerUseHotkeyMonitor.onStart = { [weak self] in self?.handleComputerUseStart() }
        computerUseHotkeyMonitor.onStop = { [weak self] in self?.handleComputerUseStop() }
        computerUseHotkeyMonitor.onCancel = { [weak self] in self?.handleComputerUseCancel() }
        computerUseHotkeyMonitor.onToggleStart = { [weak self] in self?.handleComputerUseToggleStart() }
        computerUseHotkeyMonitor.onToggleStop = { [weak self] in self?.handleComputerUseToggleStop() }
        computerUseHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        let canRunMainApp = config.hasCompletedOnboarding
            && hasRequiredStartupPermissions(for: config.resolvedOnboardingUseCase)
        meetingFeatureMonitorsAllowed = canRunMainApp

        // Defer permission-triggering monitors until after onboarding
        if canRunMainApp && config.resolvedOnboardingUseCase.includesPushToTalk {
            hotkeyMonitor.targetKeyCode = config.dictationHotkey.keyCode
            hotkeyMonitor.start()
            startComputerUseHotkeyMonitorIfNeeded()
        }
        syncDictationRecorderWarmup(reason: "startup")
        indicator.onStopMeeting = { [weak self] in self?.stopMeetingRecording() }
        indicator.onDiscardMeeting = { [weak self] in self?.discardMeetingWithConfirmation() }
        indicator.onToggleMeetingPause = { [weak self] in self?.toggleMeetingRecordingPause() }
        indicator.onStopToggleDictation = { [weak self] in
            guard let self else { return }
            if self.hotkeyMonitor.isToggleRecording {
                self.hotkeyMonitor.stopToggleMode()
            } else if self.computerUseHotkeyMonitor.isToggleRecording {
                self.computerUseHotkeyMonitor.stopToggleMode()
            } else if self.computerUseCommandStartedAt != nil {
                self.handleComputerUseStop()
            } else {
                self.handleStop()
            }
        }
        indicator.onCancelToggleDictation = { [weak self] in
            guard let self else { return }
            if self.computerUseHotkeyMonitor.isToggleRecording || self.computerUseCommandStartedAt != nil {
                self.handleComputerUseCancel()
                self.computerUseHotkeyMonitor.cancelToggleMode()
            } else {
                self.handleCancel()
                self.hotkeyMonitor.cancelToggleMode()
            }
            self.indicator.isToggleDictation = false
        }
        indicator.onPositionSaved = { [weak self] center in
            self?.updateConfig {
                $0.indicatorAnchor = .custom
                $0.indicatorOrigin = CGPointCodable(x: center.x, y: center.y)
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app != NSRunningApplication.current
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastExternalApp = app
            }
        }
        dataDidChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: MuesliNotifications.dataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historyWindowController?.reload()
                self.syncAppState()
            }
        }

        statusBarController = StatusBarController(controller: self, runtime: runtime)
        preferencesWindowController = PreferencesWindowController(controller: self)
        historyWindowController = RecentHistoryWindowController(store: dictationStore, controller: self)
        refreshUI()

        meetingMonitor.calendarEventProvider = { [weak self] in
            self?.currentOrNearbyCachedCalendarEvent()
        }
        meetingMonitor.detectionEnabledProvider = { [weak self] in
            self?.config.showMeetingDetectionNotification ?? false
        }
        meetingMonitor.mutedDetectionBundleIDsProvider = { [weak self] in
            Set(self?.config.mutedMeetingDetectionAppBundleIDs ?? [])
        }
        meetingMonitor.isRecordingProvider = { [weak self] in
            guard let self else { return false }
            return self.isMeetingRecording() || self.isDictationActivityInProgress
        }
        meetingMonitor.isStartingRecordingProvider = { [weak self] in
            self?.isStartingMeetingRecording ?? false
        }
        meetingMonitor.isCalendarNotificationVisibleProvider = { [weak self] in
            self?.isShowingCalendarNotification ?? false
        }
        meetingMonitor.promptVisibilityProvider = { [weak self] in
            guard let self else {
                return MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil)
            }
            return MeetingPromptVisibility(
                isVisible: self.meetingNotification.isVisible,
                currentPromptID: self.meetingNotification.currentPromptID,
                shownAt: self.meetingNotification.shownAt
            )
        }
        meetingMonitor.onPromptCandidateChanged = { [weak self] candidate in
            guard let self else { return }
            if let candidate {
                self.presentMeetingDetection(candidate)
            } else {
                self.dismissPresentedMeetingDetection()
            }
        }

        // Defer permission-triggering monitors until after onboarding
        if canRunMainApp && shouldRunMeetingFeatureMonitors {
            startMeetingFeatureMonitors(includeMaraudersMap: true)
        }

        if canRunMainApp {
            Task { [weak self] in
                guard let self else { return }
                let includesMeetings = self.config.resolvedOnboardingUseCase.includesMeetings
                let ppOption = self.runtimePostProcessorOption()
                if #available(macOS 15, *) {
                    if let ppOption {
                        await self.transcriptionCoordinator.setActivePostProcessor(
                            option: ppOption,
                            systemPrompt: self.config.postProcessorSystemPrompt
                        )
                    }
                }
                await self.transcriptionCoordinator.preload(
                    backend: self.selectedBackend,
                    enablePostProcessor: self.config.enablePostProcessor && ppOption != nil,
                    includeMeetingHelpers: includesMeetings
                )
                if includesMeetings, self.selectedMeetingTranscriptionBackend != self.selectedBackend {
                    await self.transcriptionCoordinator.preload(
                        backend: self.selectedMeetingTranscriptionBackend,
                        enablePostProcessor: false,
                        includeMeetingHelpers: true
                    )
                }
                await MainActor.run {
                    self.refreshUI()
                }
            }
        }

        if !canRunMainApp {
            if let progress = OnboardingProgress.load() {
                showOnboarding(resumeFrom: progress)
            } else if config.hasCompletedOnboarding {
                showOnboarding(resumeFrom: onboardingProgressForPermissionRepair())
            } else {
                showOnboarding()
            }
        } else if config.openDashboardOnLaunch {
            openHistoryWindow()
        }

        if canRunMainApp {
            PostInstallChecker.check()
        }
    }

    func shutdown() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let dataDidChangeObserver {
            DistributedNotificationCenter.default().removeObserver(dataDidChangeObserver)
            self.dataDidChangeObserver = nil
        }
        hotkeyMonitor.stop()
        computerUseHotkeyMonitor.stop()
        computerUseCommandTask?.cancel()
        computerUseCommandTask = nil
        calendarMonitor.stop()
        meetingStartingNowTimers.values.forEach { $0.invalidate() }
        meetingStartingNowTimers.removeAll()
        meetingFeatureMonitorsAllowed = false
        meetingMonitor.stop()
        meetingDetectionMonitorStarted = false
        dismissPresentedMeetingDetection()
        meetingNotification.close()
        activeMeetingSession?.discard()
        activeMeetingSession = nil
        if let activeMeetingID {
            resolveLiveMeetingAfterStopFailure(id: activeMeetingID)
            self.activeMeetingID = nil
        }
        endMeetingActivity()
        recorder.cancel()
        Task {
            await transcriptionCoordinator.shutdown()
        }
        indicator.close()
        CoreAudioSystemRecorder.cleanupStaleDevices()
    }

    func recentDictations() -> [DictationRecord] {
        (try? dictationStore.recentDictations(limit: 10)) ?? []
    }

    func recentMeetings() -> [MeetingRecord] {
        (try? dictationStore.recentMeetings(limit: 10)) ?? []
    }

    func meeting(id: Int64) -> MeetingRecord? {
        if let row = appState.meetingRows.first(where: { $0.id == id }) {
            return row
        }
        return try? dictationStore.meeting(id: id)
    }

    func dictationStats() -> DictationStats {
        (try? dictationStore.dictationStats()) ?? DictationStats(
            totalWords: 0,
            totalSessions: 0,
            averageWordsPerSession: 0,
            averageWPM: 0,
            currentStreakDays: 0,
            longestStreakDays: 0
        )
    }

    func meetingStats() -> MeetingStats {
        (try? dictationStore.meetingStats()) ?? MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)
    }

    func truncate(_ text: String, limit: Int) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 3)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    func refreshIndicatorVisibility() {
        if config.showFloatingIndicator {
            indicator.ensureVisible(config: config)
        } else {
            indicator.closeIfIdle()
        }
    }

    func refreshUI() {
        statusBarController?.setStatus("Idle")
        statusBarController?.refresh()
        historyWindowController?.updateBackendLabel()
        historyWindowController?.reload()
        preferencesWindowController?.refresh()
        refreshIndicatorVisibility()
        syncAppState()
    }

    func syncAppState() {
        let rows = (try? dictationStore.recentDictations(
            limit: appState.dictationPageSize,
            offset: 0,
            fromDate: appState.dictationFromDate,
            toDate: appState.dictationToDate
        )) ?? []
        appState.dictationRows = rows
        appState.hasMoreDictations = rows.count >= appState.dictationPageSize
        appState.meetingRows = (try? dictationStore.recentMeetings(limit: 200, folderID: appState.selectedFolderID)) ?? []
        let counts = (try? dictationStore.meetingCounts()) ?? (total: 0, byFolder: [:])
        appState.totalMeetingCount = counts.total
        appState.meetingCountsByFolder = counts.byFolder
        if let selectedMeetingID = appState.selectedMeetingID {
            appState.selectedMeetingRecord = appState.meetingRows.first(where: { $0.id == selectedMeetingID })
                ?? meeting(id: selectedMeetingID)
        } else {
            appState.selectedMeetingRecord = nil
        }
        let allFolders = (try? dictationStore.listFolders()) ?? []
        if config.folderOrder.isEmpty && !allFolders.isEmpty {
            updateConfig { $0.folderOrder = allFolders.map(\.id) }
        }
        let order = config.folderOrder
        appState.folders = allFolders.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            return ai < bi
        }
        appState.dictationStats = dictationStats()
        appState.meetingStats = meetingStats()
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.activePostProcessor = PostProcessorOption.resolve(id: config.activePostProcessorId)
        appState.config = config
        appState.isMeetingRecording = isMeetingRecording()
        appState.isMeetingRecordingPaused = isMeetingRecordingPaused()
        appState.isMeetingStarting = isStartingMeetingRecording
        appState.meetingStartStatus = meetingStartStatus
        indicator.setMeetingRecordingPaused(appState.isMeetingRecordingPaused, config: config)
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
        appState.isGoogleCalendarAvailable = googleCalAuth.isAvailable
        appState.isGoogleCalendarVerified = googleCalAuth.isVerified
        appState.isGoogleCalendarAuthenticated = googleCalAuth.isAuthenticated
        // Keep appState in sync with persisted hidden event IDs
        let persisted = Set(config.hiddenCalendarEventIDs)
        if appState.hiddenCalendarEventIDs != persisted {
            appState.hiddenCalendarEventIDs = persisted
        }
    }

    func recoverStaleLiveMeetings() {
        guard !isMeetingRecording(),
              !isStartingMeetingRecording else { return }
        let meetings: [MeetingRecord]
        do {
            meetings = try dictationStore.staleLiveMeetings()
        } catch {
            fputs("[muesli-native] failed to load stale live meetings: \(error)\n", stderr)
            return
        }

        for meeting in meetings {
            do {
                try dictationStore.updateMeetingStatus(id: meeting.id, status: .failed)
                staleLiveMeetingRecoveryFailures.remove(meeting.id)
            } catch {
                staleLiveMeetingRecoveryFailures.insert(meeting.id)
                fputs("[muesli-native] failed to recover stale meeting \(meeting.id): \(error)\n", stderr)
            }
        }

        if !meetings.isEmpty {
            syncAppState()
        }
    }

    func performSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.searchQuery = trimmed
        guard !trimmed.isEmpty else {
            appState.searchResultDictations = []
            appState.searchResultMeetings = []
            return
        }
        let store = self.dictationStore
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let (dictations, meetings) = await Task.detached(priority: .userInitiated) {
                let d = (try? store.searchDictations(query: trimmed)) ?? []
                let m = (try? store.searchMeetings(query: trimmed)) ?? []
                return (d, m)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.appState.searchResultDictations = dictations
            self.appState.searchResultMeetings = meetings
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        appState.searchQuery = ""
        appState.searchResultDictations = []
        appState.searchResultMeetings = []
    }

    private static func availableMeetingTranscriptionBackend(
        config: AppConfig,
        dictationBackend: BackendOption,
        downloadedOptions: [BackendOption] = BackendOption.downloaded
    ) -> BackendOption? {
        BackendOption.resolveDownloaded(
            backend: config.meetingTranscriptionBackend,
            model: config.meetingTranscriptionModel,
            fallback: dictationBackend,
            downloadedOptions: downloadedOptions
        )
    }

    @discardableResult
    private func normalizeMeetingTranscriptionSelectionForAvailability(
        downloadedOptions: [BackendOption] = BackendOption.downloaded
    ) -> BackendOption? {
        let dictationBackend = BackendOption.resolve(
            backend: config.sttBackend,
            model: config.sttModel
        ) ?? selectedBackend
        guard let resolved = Self.availableMeetingTranscriptionBackend(
            config: config,
            dictationBackend: dictationBackend,
            downloadedOptions: downloadedOptions
        ) else {
            selectedMeetingTranscriptionBackend = BackendOption.resolve(
                backend: config.meetingTranscriptionBackend,
                model: config.meetingTranscriptionModel
            ) ?? dictationBackend
            appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
            appState.config = config
            return nil
        }

        selectedMeetingTranscriptionBackend = resolved
        activeMeetingSession?.updateBackend(resolved)
        if config.meetingTranscriptionBackend != resolved.backend ||
            config.meetingTranscriptionModel != resolved.model {
            config.meetingTranscriptionBackend = resolved.backend
            config.meetingTranscriptionModel = resolved.model
            configStore.save(config)
            fputs("[muesli-native] meeting transcription model unavailable; switched to \(resolved.label)\n", stderr)
        }
        appState.selectedMeetingTranscriptionBackend = resolved
        appState.config = config
        return resolved
    }

    @discardableResult
    func refreshMeetingTranscriptionSelectionForAvailability() -> BackendOption? {
        normalizeMeetingTranscriptionSelectionForAvailability()
    }

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        let previousHotkeyTriggerThresholdMS = config.hotkeyTriggerThresholdMS
        mutate(&config)
        config.hotkeyTriggerThresholdMS = HotkeyTriggerTiming.clampedMilliseconds(config.hotkeyTriggerThresholdMS)
        let hotkeyTriggerThresholdChanged = config.hotkeyTriggerThresholdMS != previousHotkeyTriggerThresholdMS
        configStore.save(config)
        MuesliTheme.accentOverrideHex = config.recordingColorHex == "1e1e2e" ? nil : config.recordingColorHex
        selectedBackend = BackendOption.all.first(where: {
            $0.backend == config.sttBackend && $0.model == config.sttModel
        }) ?? .whisper
        selectedMeetingTranscriptionBackend = BackendOption.all.first(where: {
            $0.backend == config.meetingTranscriptionBackend && $0.model == config.meetingTranscriptionModel
        }) ?? selectedBackend
        selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == config.meetingSummaryBackend
        }) ?? .chatGPT
        statusBarController?.refresh()
        statusBarController?.refreshIcon()
        indicator.refreshIcon()
        hotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        computerUseHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        if hotkeyTriggerThresholdChanged {
            configureHotkeyMonitorTiming()
        }
        historyWindowController?.updateBackendLabel()
        if config.showFloatingIndicator {
            indicator.ensureVisible(config: config)
        } else {
            indicator.closeIfIdle()
        }
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingTranscriptionBackend = selectedMeetingTranscriptionBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.config = config
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
        syncMeetingDetectionMonitor()
        updateMeetingNotificationVisibility()
        syncDictationRecorderWarmup(reason: "config")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let result = launchAtLoginCoordinator.setEnabled(enabled, config: config)
        if let error = result.error {
            fputs("[launch-at-login] failed to set enabled=\(enabled): \(error)\n", stderr)
        }
        appState.launchAtLoginRegistrationState = result.registrationState
        updateConfig { $0.launchAtLogin = result.config.launchAtLogin }
        if enabled, result.registrationState == .requiresApproval {
            launchAtLoginCoordinator.openSystemSettingsLoginItems()
        }
    }

    func openLaunchAtLoginSettings() {
        launchAtLoginCoordinator.openSystemSettingsLoginItems()
    }

    func refreshLaunchAtLoginState() {
        let result = launchAtLoginCoordinator.refreshStatus(config: config)
        appState.launchAtLoginRegistrationState = result.registrationState
        let refreshed = result.config
        guard refreshed.launchAtLogin != config.launchAtLogin else { return }
        updateConfig { $0.launchAtLogin = refreshed.launchAtLogin }
    }

    private func syncLaunchAtLoginConfigWithSystem() {
        let result = launchAtLoginCoordinator.reconcileOnStartup(config: config)
        if let error = result.error {
            fputs("[launch-at-login] failed to apply saved launch-at-login setting: \(error)\n", stderr)
        }
        appState.launchAtLoginRegistrationState = result.registrationState
        let reconciled = result.config
        guard reconciled.launchAtLogin != config.launchAtLogin else { return }
        updateConfig { $0.launchAtLogin = reconciled.launchAtLogin }
    }

    func selectBackend(_ option: BackendOption) {
        updateConfig {
            $0.sttBackend = option.backend
            $0.sttModel = option.model
        }
        Task { [weak self] in
            guard let self else { return }
            let needsWarmup = option.backend == "whisper"
            if needsWarmup {
                await MainActor.run {
                    self.indicator.showLoading("Warming up...")
                }
            }
            let ppOption = self.runtimePostProcessorOption()
            if #available(macOS 15, *) {
                if let ppOption {
                    await self.transcriptionCoordinator.setActivePostProcessor(
                        option: ppOption,
                        systemPrompt: self.config.postProcessorSystemPrompt
                    )
                }
            }
            await self.transcriptionCoordinator.preload(
                backend: option,
                enablePostProcessor: self.config.enablePostProcessor && ppOption != nil,
                includeMeetingHelpers: self.config.resolvedOnboardingUseCase.includesMeetings
            )
            await MainActor.run {
                if needsWarmup {
                    self.indicator.hideLoading()
                }
                self.statusBarController?.refresh()
                self.historyWindowController?.updateBackendLabel()
            }
        }
    }

    func selectMeetingTranscriptionBackend(_ option: BackendOption, requireDownloaded: Bool = true) {
        guard !requireDownloaded || option.isDownloaded else {
            presentErrorAlert(
                title: "Meeting model unavailable",
                message: "Download \(option.label) before using it for meeting transcription."
            )
            normalizeMeetingTranscriptionSelectionForAvailability()
            return
        }
        updateConfig {
            $0.meetingTranscriptionBackend = option.backend
            $0.meetingTranscriptionModel = option.model
        }
        activeMeetingSession?.updateBackend(option)
        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.preload(
                backend: option,
                enablePostProcessor: false,
                includeMeetingHelpers: true
            )
            await MainActor.run {
                self.statusBarController?.refresh()
            }
        }
    }

    func selectCohereLanguage(_ language: CohereTranscribeLanguage) {
        updateConfig {
            $0.cohereLanguage = language.rawValue
        }
    }

    var isPostProcessorReady: Bool {
        config.enablePostProcessor && runtimePostProcessorOption() != nil
    }

    @discardableResult
    private func normalizePostProcessorSelectionForAvailability() -> PostProcessorOption? {
        guard let option = runtimePostProcessorOption() else {
            appState.activePostProcessor = PostProcessorOption.resolve(id: config.activePostProcessorId)
            return nil
        }
        if config.activePostProcessorId != option.id {
            updateConfig { $0.activePostProcessorId = option.id }
        }
        appState.activePostProcessor = option
        return option
    }

    private func runtimePostProcessorOption() -> PostProcessorOption? {
        PostProcessorOption.runtimeOption(id: config.activePostProcessorId)
    }

    func setPostProcessorEnabled(_ enabled: Bool) {
        if enabled {
            guard normalizePostProcessorSelectionForAvailability() != nil else {
                updateConfig { $0.enablePostProcessor = false }
                appState.selectedTab = .models
                return
            }
        }
        updateConfig { $0.enablePostProcessor = enabled }
        preloadExperimentalTranscriptionFeatures()
    }

    func preloadExperimentalTranscriptionFeatures() {
        let ppOption = runtimePostProcessorOption()
        let enabled = config.enablePostProcessor && ppOption != nil
        let ppPrompt = config.postProcessorSystemPrompt
        Task { [weak self] in
            guard let self else { return }
            if let ppOption, #available(macOS 15, *) {
                await self.transcriptionCoordinator.setActivePostProcessor(
                    option: ppOption,
                    systemPrompt: ppPrompt
                )
            }
            await self.transcriptionCoordinator.preloadPostProcessorIfNeeded(enabled: enabled)
        }
    }

    func selectPostProcessor(_ option: PostProcessorOption) {
        updateConfig { $0.activePostProcessorId = option.id }
        appState.activePostProcessor = option
        guard config.enablePostProcessor else { return }
        let systemPrompt = config.postProcessorSystemPrompt
        Task { [weak self] in
            guard let self else { return }
            if #available(macOS 15, *) {
                await self.transcriptionCoordinator.setActivePostProcessor(
                    option: option,
                    systemPrompt: systemPrompt
                )
            }
        }
    }

    func updatePostProcessorSystemPrompt(_ prompt: String) {
        updateConfig { $0.postProcessorSystemPrompt = prompt }
        let ppOption = runtimePostProcessorOption()
        guard config.enablePostProcessor else { return }
        Task { [weak self] in
            guard let self else { return }
            if let ppOption, #available(macOS 15, *) {
                await self.transcriptionCoordinator.setActivePostProcessor(
                    option: ppOption,
                    systemPrompt: prompt
                )
            }
        }
    }

    func selectMeetingSummaryBackend(_ option: MeetingSummaryBackendOption) {
        updateConfig {
            $0.meetingSummaryBackend = option.backend
        }
    }

    func availableMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.allDefinitions(customTemplates: config.customMeetingTemplates)
    }

    func builtInMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.builtIns
    }

    func customMeetingTemplates() -> [CustomMeetingTemplate] {
        config.customMeetingTemplates
    }

    func defaultMeetingTemplate() -> MeetingTemplateSnapshot {
        MeetingTemplates.resolveSnapshot(
            id: config.defaultMeetingTemplateID,
            customTemplates: config.customMeetingTemplates
        )
    }

    func meetingTemplateSnapshot(for meeting: MeetingRecord) -> MeetingTemplateSnapshot {
        MeetingTemplates.snapshot(for: meeting, customTemplates: config.customMeetingTemplates)
    }

    func updateDefaultMeetingTemplate(id: String) {
        let resolved = MeetingTemplates.resolveSnapshot(id: id, customTemplates: config.customMeetingTemplates)
        updateConfig {
            $0.defaultMeetingTemplateID = resolved.id
        }
    }

    func createCustomMeetingTemplate(name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            $0.customMeetingTemplates.append(
                CustomMeetingTemplate(
                    name: trimmedName,
                    prompt: trimmedPrompt,
                    icon: MeetingTemplates.normalizedCustomIcon(named: icon)
                )
            )
        }
    }

    func updateCustomMeetingTemplate(id: String, name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            guard let index = $0.customMeetingTemplates.firstIndex(where: { $0.id == id }) else { return }
            $0.customMeetingTemplates[index].name = trimmedName
            $0.customMeetingTemplates[index].prompt = trimmedPrompt
            $0.customMeetingTemplates[index].icon = MeetingTemplates.normalizedCustomIcon(named: icon)
        }
    }

    func deleteCustomMeetingTemplate(id: String) {
        updateConfig {
            $0.customMeetingTemplates.removeAll { $0.id == id }
            if $0.defaultMeetingTemplateID == id {
                $0.defaultMeetingTemplateID = MeetingTemplates.autoID
            }
        }
    }

    /// Returns nil on success, or an error message on failure.
    func signInWithChatGPT() async -> String? {
        do {
            try await chatGPTAuth.signIn()
            selectMeetingSummaryBackend(.chatGPT)
            syncAppState()
            return nil
        } catch {
            fputs("[muesli-native] ChatGPT sign-in failed: \(error)\n", stderr)
            return error.localizedDescription
        }
    }

    func signOutChatGPT() {
        chatGPTAuth.signOut()
        if selectedMeetingSummaryBackend == .chatGPT {
            selectMeetingSummaryBackend(.openAI)
        }
        syncAppState()
    }

    // MARK: - Google Calendar

    func signInWithGoogleCalendar() async -> String? {
        do {
            try await googleCalAuth.signIn()
            syncAppState()
            Task {
                await refreshUpcomingCalendarEvents()
                await refreshGoogleCalendarList()
            }
            return nil
        } catch {
            fputs("[muesli-native] Google Calendar sign-in failed: \(error)\n", stderr)
            return error.localizedDescription
        }
    }

    func signOutGoogleCalendar() {
        invalidateGoogleCalendarAuth()
        Task { await refreshUpcomingCalendarEvents() }
    }

    private func invalidateGoogleCalendarAuth() {
        googleCalAuth.signOut()
        googleCalClient.resetSync()
        appState.availableGoogleCalendars = []
        appState.googleCalendarListLoadState = .idle
        syncAppState()
    }

    /// Refresh the EventKit-available calendars list. Cheap (no network), safe
    /// to call frequently — driven by Settings panel onAppear and by the
    /// EKEventStoreChangedNotification handler.
    func refreshAvailableEventKitCalendars() {
        appState.availableEventKitCalendars = calendarMonitor.availableCalendars()
    }

    /// Refresh the Google calendar list via the Calendar API. No-op when OAuth
    /// is not available or the user is not authenticated.
    func refreshGoogleCalendarList() async {
        guard googleCalAuth.isAuthenticated else {
            appState.availableGoogleCalendars = []
            appState.googleCalendarListLoadState = .idle
            return
        }
        appState.googleCalendarListLoadState = .loading
        do {
            let list = try await googleCalClient.fetchCalendarList()
            appState.availableGoogleCalendars = list
            appState.googleCalendarListLoadState = .loaded
        } catch GoogleCalendarAuthError.notAuthenticated {
            invalidateGoogleCalendarAuth()
            fputs("[muesli-native] Google Calendar token invalid while loading calendar list, signed out\n", stderr)
        } catch GoogleCalendarAuthError.refreshFailed(let message) {
            fputs("[muesli-native] Google Calendar token refresh failed while loading calendar list: \(message)\n", stderr)
            appState.googleCalendarListLoadState = .failed("Token refresh failed: \(message)")
        } catch {
            fputs("[muesli-native] Google calendarList fetch failed: \(error)\n", stderr)
            appState.googleCalendarListLoadState = .failed(error.localizedDescription)
        }
    }

    func refreshUpcomingCalendarEvents() async {
        let disabledIDs = Set(config.disabledCalendarIDs)
        var ekEvents = calendarMonitor.upcomingEvents(daysAhead: 7, disabledCalendarIDs: disabledIDs)

        if googleCalAuth.isAuthenticated {
            do {
                let googleEvents = try await googleCalClient.fetchUpcomingEvents(
                    daysAhead: 7,
                    disabledCalendarIDs: disabledIDs
                )
                ekEvents = GoogleCalendarClient.mergeEvents(eventKit: ekEvents, google: googleEvents)
            } catch GoogleCalendarAuthError.notAuthenticated {
                invalidateGoogleCalendarAuth()
                fputs("[muesli-native] Google Calendar token invalid, signed out\n", stderr)
            } catch GoogleCalendarAuthError.refreshFailed(let message) {
                fputs("[muesli-native] Google Calendar token refresh failed: \(message)\n", stderr)
            } catch {
                fputs("[muesli-native] Google Calendar fetch failed: \(error)\n", stderr)
            }
        }

        appState.upcomingCalendarEvents = ekEvents

        // Prune hidden IDs for events that no longer exist in the calendar
        let currentEventIDs = Set(ekEvents.map(\.id))
        let staleIDs = appState.hiddenCalendarEventIDs.subtracting(currentEventIDs)
        if !staleIDs.isEmpty {
            appState.hiddenCalendarEventIDs.subtract(staleIDs)
            updateConfig { $0.hiddenCalendarEventIDs = self.appState.hiddenCalendarEventIDs.sorted() }
        }

        statusBarController?.updateMenuBarTitle()
    }

    func startCalendarMonitoring() {
        // Event-driven: refresh when macOS reports calendar changes.
        // EKEventStoreChangedNotification is delivered via NotificationCenter,
        // which is immune to App Nap timer suspension in LSUIElement apps.
        calendarMonitor.onCalendarChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshAvailableEventKitCalendars()
                await self.refreshUpcomingCalendarEvents()
                self.checkUpcomingCalendarNotifications()
                self.meetingMonitor.refreshState(trigger: .calendarChanged)
            }
        }

        // 60s fallback timer: polls Google Calendar API (sync token makes this
        // efficient) and checks the notification window for time-based triggers.
        // EKEventStoreChangedNotification handles EventKit reactively, but Google
        // Calendar OAuth has no push mechanism — this timer is the only way to
        // pick up new/moved events from the API. May be suspended by App Nap on
        // macOS 26, but combined with the EventKit push path, most cases are covered.
        calendarCheckTimer?.invalidate()
        calendarCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshUpcomingCalendarEvents()
                self.checkUpcomingCalendarNotifications()
                self.meetingMonitor.refreshState(trigger: .calendarChanged)
            }
        }

        // Run first cycle immediately
        Task { @MainActor in
            self.refreshAvailableEventKitCalendars()
            await self.refreshUpcomingCalendarEvents()
            self.checkUpcomingCalendarNotifications()
            self.meetingMonitor.refreshState(trigger: .calendarChanged)
        }
    }

    private func currentOrNearbyCachedCalendarEvent() -> CalendarEventContext? {
        selectCurrentOrNearbyCachedCalendarEvent(from: appState.upcomingCalendarEvents)
    }

    private func startMeetingFeatureMonitors(includeMaraudersMap: Bool) {
        calendarMonitor.start()
        startCalendarMonitoring()
        if includeMaraudersMap, config.maraudersMapUnlocked {
            startMaraudersMapMonitoring()
        }
        syncMeetingDetectionMonitor()
    }

    private var shouldRunMeetingFeatureMonitors: Bool {
        config.showMeetingDetectionNotification
            || config.showScheduledMeetingNotifications
            || config.autoRecordMeetings
    }

    private func syncMeetingDetectionMonitor() {
        let shouldRun = meetingFeatureMonitorsAllowed
            && config.showMeetingDetectionNotification
        if shouldRun && !meetingDetectionMonitorStarted {
            meetingMonitor.start()
            meetingDetectionMonitorStarted = true
        } else if !shouldRun && meetingDetectionMonitorStarted {
            meetingMonitor.stop()
            meetingDetectionMonitorStarted = false
            dismissPresentedMeetingDetection()
        }
    }

    /// Check all upcoming calendar events (EventKit + Google) for events starting within 5 minutes.
    /// Shows a notification when the event enters the 5-minute window, and schedules a second
    /// "Meeting starting now" notification at event start time.
    /// This is the single notification path for all calendar sources.
    /// Composite dedup key: same event rescheduled to a new time gets a fresh notification.
    private func notificationKey(id: String, startDate: Date) -> String {
        "\(id)|\(Int(startDate.timeIntervalSince1970))"
    }

    private func checkUpcomingCalendarNotifications() {
        guard !isMeetingRecording(),
              !isStartingMeetingRecording else { return }

        let now = Date()
        let fiveMinutesFromNow = now.addingTimeInterval(5 * 60)

        // Prune stale entries (events that started more than 1 hour ago)
        let cutoff = now.addingTimeInterval(-3600)
        notifiedUpcomingEventIDs = notifiedUpcomingEventIDs.filter { key in
            guard let tsString = key.split(separator: "|").last,
                  let ts = TimeInterval(tsString) else { return false }
            return Date(timeIntervalSince1970: ts) > cutoff
        }

        let candidates = appState.upcomingCalendarEvents.filter {
            !$0.isAllDay && $0.startDate > now && $0.startDate <= fiveMinutesFromNow
        }
        for event in candidates {
            let key = notificationKey(id: event.id, startDate: event.startDate)
            guard !notifiedUpcomingEventIDs.contains(key) else { continue }

            notifiedUpcomingEventIDs.insert(key)

            let upcomingEvent = UpcomingMeetingEvent(
                id: event.id,
                title: event.title,
                startDate: event.startDate,
                meetingURL: event.meetingURL
            )

            // Show "starts in X min" notification now
            handleUpcomingMeeting(upcomingEvent)

            // Schedule a second "Meeting starting now" notification at event start time
            let delay = event.startDate.timeIntervalSinceNow
            if delay > 15 { // Only if there's enough gap after the first notification auto-dismisses
                let meetingURL = event.meetingURL
                let endDate = event.endDate
                let title = event.title
                meetingStartingNowTimers[key]?.invalidate()
                meetingStartingNowTimers[key] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isMeetingRecording() else { return }
                        self.meetingStartingNowTimers.removeValue(forKey: key)
                        self.showMeetingStartingNowNotification(title: title, calendarEventID: key, meetingURL: meetingURL, endDate: endDate)
                    }
                }
            }

            return // Show one notification at a time
        }
    }

    /// Show a "Meeting starting now" notification — independent of Marauder's Map.
    private func showMeetingStartingNowNotification(title: String, calendarEventID: String?, meetingURL: URL?, endDate: Date?) {
        guard config.showScheduledMeetingNotifications,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return }
        isShowingCalendarNotification = true

        meetingNotification.show(
            title: "Meeting starting now",
            subtitle: title,
            meetingURL: meetingURL,
            dismissAfter: 30,
            onStartRecording: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.startForegroundMeetingRecording(title: title, calendarEventID: calendarEventID, endDate: endDate)
            },
            onJoinAndRecord: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinAndRecord(title: title, meetingURL: meetingURL!, endDate: endDate, calendarEventID: calendarEventID)
            } : nil,
            onJoinOnly: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinOnly(meetingURL: meetingURL!, endDate: endDate)
            } : nil,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                let remaining = endDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
                self.meetingMonitor.suppress(for: remaining)
                self.meetingMonitor.refreshState()
            },
            onClose: { [weak self] in self?.isShowingCalendarNotification = false }
        )
    }

    func addCustomWord(_ word: CustomWord) {
        updateConfig { $0.customWords.append(word) }
    }

    func updateCustomWord(_ word: CustomWord) {
        updateConfig { config in
            guard let index = config.customWords.firstIndex(where: { $0.id == word.id }) else { return }
            config.customWords[index] = word
        }
    }

    func removeCustomWord(id: UUID) {
        updateConfig { $0.customWords.removeAll { $0.id == id } }
    }

    @discardableResult
    func updateDictationHotkey(_ hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        let result = ShortcutHotkeyPolicy.validateDictationHotkey(
            hotkey,
            computerUseHotkey: config.computerUseHotkey,
            isComputerUseEnabled: config.enableComputerUseHotkey
        )
        guard result.didUpdate else {
            fputs("[hotkeys] rejected dictation hotkey because it matches computer use hotkey\n", stderr)
            return result
        }
        updateConfig { $0.dictationHotkey = hotkey }
        hotkeyMonitor.configure(keyCode: hotkey.keyCode)
        configureComputerUseHotkeyMonitor()
        return result
    }

    @discardableResult
    func updateComputerUseHotkey(_ hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        let result = ShortcutHotkeyPolicy.validateComputerUseHotkey(
            hotkey,
            dictationHotkey: config.dictationHotkey,
            isComputerUseEnabled: config.enableComputerUseHotkey
        )
        guard result.didUpdate else {
            fputs("[hotkeys] rejected computer use hotkey because it matches dictation hotkey\n", stderr)
            return result
        }
        updateConfig { $0.computerUseHotkey = hotkey }
        configureComputerUseHotkeyMonitor()
        return result
    }

    @discardableResult
    func updateComputerUseHotkeyEnabled(_ enabled: Bool) -> ShortcutHotkeyUpdateResult {
        if enabled {
            let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
                currentHotkey: config.computerUseHotkey,
                dictationHotkey: config.dictationHotkey
            )
            updateConfig { config in
                config.computerUseHotkey = resolution.hotkey
                config.enableComputerUseHotkey = true
            }
            configureComputerUseHotkeyMonitor()
            return resolution.result
        }
        updateConfig { $0.enableComputerUseHotkey = enabled }
        configureComputerUseHotkeyMonitor()
        return .updated
    }

    func resetShortcutDefaults() {
        updateConfig { config in
            config.dictationHotkey = .default
            config.computerUseHotkey = .computerUseDefault
            config.enableComputerUseHotkey = false
        }
        hotkeyMonitor.configure(keyCode: HotkeyConfig.default.keyCode)
        configureComputerUseHotkeyMonitor()
    }

    // MARK: - Onboarding

    func showOnboarding(resumeFrom progress: OnboardingProgress? = nil) {
        let wc = OnboardingWindowController(controller: self, resumeProgress: progress)
        self.onboardingWindowController = wc
        wc.show()
    }

    @MainActor
    func bringOnboardingToFront() {
        onboardingWindowController?.bringToFront()
    }

    @MainActor
    func yieldOnboardingFocusToSystemSettings() {
        onboardingWindowController?.yieldFocusToSystemSettings()
    }

    @MainActor
    func prepareOnboardingForNativePermissionPrompt() {
        onboardingWindowController?.prepareForNativePermissionPrompt()
    }

    @MainActor
    func notifyOnboardingModelReady() {
        guard onboardingWindowController != nil else { return }
        SoundController.playModelReady(enabled: config.soundEnabled)
        bringOnboardingToFront()
    }

    func continueModelPreparationAfterOnboarding(
        _ backend: BackendOption,
        onboardingUseCase: OnboardingUseCase,
        initialProgress: Double?,
        initialStatus: String?,
        isPreparing: Bool
    ) {
        onboardingModelPreparationTask?.cancel()
        updateModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: initialStatus ?? "Preparing \(backend.label)...",
            progress: initialProgress,
            isPreparing: isPreparing,
            isComplete: false
        )

        onboardingModelPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadModelForOnboarding(
                    backend,
                    onboardingUseCase: onboardingUseCase
                ) { progress, status in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.applyModelPreparationProgress(
                            progress,
                            status: status,
                            backend: backend
                        )
                    }
                }
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                    self.updateModelPreparationStatus(
                        title: "\(backend.label) ready",
                        detail: "Ready for transcription",
                        progress: 1.0,
                        isPreparing: false,
                        isComplete: true
                    )
                    SoundController.playModelReady(enabled: self.config.soundEnabled)
                    self.statusBarController?.refresh()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                }
            } catch {
                await MainActor.run {
                    self.onboardingModelPreparationTask = nil
                    self.updateModelPreparationStatus(
                        title: backend.isDownloaded ? "Model setup paused" : "Download paused",
                        detail: self.modelPreparationFailureMessage(for: backend),
                        progress: nil,
                        isPreparing: false,
                        isComplete: false
                    )
                }
                fputs("[muesli-native] post-onboarding model preparation failed: \(error)\n", stderr)
            }
        }
    }

    func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        // Defer to next run-loop to escape any SwiftUI animation context
        DispatchQueue.main.async {
            // Launch a detached process that waits for us to die, then reopens the app.
            // Uses /bin/sh only for the sleep; the path is passed as a positional arg
            // to avoid shell interpolation of special characters.
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", "sleep 1; open -- \"$1\"", "--", bundlePath]
            do {
                try shell.run()
            } catch {
                fputs("[muesli-native] relaunch failed: \(error)\n", stderr)
            }
            // Use exit(0) instead of NSApp.terminate(nil) — terminate can be
            // blocked by SwiftUI animation contexts or applicationShouldTerminate,
            // leaving the old process alive with stale floating indicator and
            // status bar icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                exit(0)
            }
        }
    }

    // MARK: - Dictation Test Mode (onboarding)

    /// When set, handleStop routes transcribed text to this callback instead of pasting.
    /// The floating indicator and sounds are suppressed during test mode.
    var dictationTestCallback: ((String) -> Void)?
    var dictationTestFailureCallback: ((String) -> Void)?
    var dictationTestRecordingStarted: (() -> Void)?
    var dictationTestBackend: BackendOption?
    var dictationTestCohereLanguage: CohereTranscribeLanguage?
    private var dictationTestTask: Task<Void, Never>?

    var isDictationTestMode: Bool { dictationTestCallback != nil }

    func cancelTestDictation() {
        dictationTestTask?.cancel()
        dictationTestTask = nil
        recorder.cancel()
        setState(.idle)
    }

    func startHotkeyMonitor(keyCode: UInt16? = nil) {
        if let keyCode {
            hotkeyMonitor.configure(keyCode: keyCode)
        }
        hotkeyMonitor.start()
        startComputerUseHotkeyMonitorIfNeeded()
    }

    func stopHotkeyMonitor() {
        hotkeyMonitor.stop()
        computerUseHotkeyMonitor.stop()
    }

    func downloadModelForOnboarding(
        _ backend: BackendOption,
        onboardingUseCase: OnboardingUseCase,
        progress: @escaping (Double, String?) -> Void
    ) async throws {
        let wasDownloaded = backend.isDownloaded
        progress(
            wasDownloaded ? 0.75 : 0.0,
            wasDownloaded ? "Warming up \(backend.label)..." : "Downloading \(backend.label)..."
        )
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: isPostProcessorReady,
            includeMeetingHelpers: onboardingUseCase.includesMeetings,
            progress: { value, status in
                if wasDownloaded,
                   value < 0.85,
                   status?.localizedCaseInsensitiveContains("preparing") == true {
                    return
                }
                if status?.localizedCaseInsensitiveContains("download") == true {
                    progress(value, "\(status ?? "Downloading \(backend.label)...")")
                } else if value >= 0.9 {
                    progress(value, status ?? "Warming up \(backend.label)...")
                } else {
                    progress(value, status ?? "Preparing \(backend.label)...")
                }
            }
        )
        guard backend.isDownloaded else {
            throw NSError(
                domain: "MuesliOnboardingModelDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(backend.label) was not downloaded successfully."]
            )
        }
        progress(1.0, "\(backend.label) ready")
    }

    private func applyModelPreparationProgress(_ progress: Double, status: String?, backend: BackendOption) {
        let detail = status ?? "Preparing \(backend.label)..."
        let lowercasedDetail = detail.lowercased()
        let isPreparing = lowercasedDetail.contains("compiling")
            || lowercasedDetail.contains("warming")
            || lowercasedDetail.contains("readying")

        if isPreparing {
            updateModelPreparationStatus(
                title: "Preparing \(backend.label)",
                detail: "Optimizing \(backend.label) for this Mac...",
                progress: nil,
                isPreparing: true,
                isComplete: false
            )
            return
        }

        updateModelPreparationStatus(
            title: "Preparing \(backend.label)",
            detail: detail,
            progress: progress,
            isPreparing: false,
            isComplete: false
        )
    }

    private func updateModelPreparationStatus(
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

    private func modelPreparationFailureMessage(for backend: BackendOption) -> String {
        backend.isDownloaded
            ? "Model setup failed. Restart Muesli or retry from Models."
            : "Download failed. Check your connection and retry."
    }

    func completeOnboarding(
        userName: String,
        backend: BackendOption,
        cohereLanguage: CohereTranscribeLanguage,
        hotkey: HotkeyConfig,
        onboardingUseCase: OnboardingUseCase,
        summaryBackend: MeetingSummaryBackendOption?,
        apiKey: String?
    ) {
        updateConfig { config in
            config.hasCompletedOnboarding = true
            config.userName = userName
            config.sttBackend = backend.backend
            config.sttModel = backend.model
            config.cohereLanguage = cohereLanguage.rawValue
            config.meetingTranscriptionBackend = backend.backend
            config.meetingTranscriptionModel = backend.model
            config.dictationHotkey = hotkey
            config.computerUseHotkey = HotkeyConfig.computerUseDefault(avoiding: hotkey)
            config.enableComputerUseHotkey = false
            config.enableComputerUsePlanner = true
            config.onboardingUseCase = onboardingUseCase.rawValue
            if let summaryBackend {
                config.meetingSummaryBackend = summaryBackend.backend
            }
            if let apiKey, !apiKey.isEmpty {
                if summaryBackend == .openAI {
                    config.openAIAPIKey = apiKey
                } else if summaryBackend == .openRouter {
                    config.openRouterAPIKey = apiKey
                }
                // ChatGPT backend uses OAuth tokens stored in app support dir, not an API key
            }
        }
        selectBackend(backend)
        hotkeyMonitor.configure(keyCode: hotkey.keyCode)
        configureComputerUseHotkeyMonitor()
        dictationTestCallback = nil
        dictationTestFailureCallback = nil
        dictationTestRecordingStarted = nil
        dictationTestBackend = nil
        dictationTestCohereLanguage = nil

        onboardingWindowController?.close()
        onboardingWindowController = nil
        if hasRequiredStartupPermissions(for: onboardingUseCase) {
            meetingFeatureMonitorsAllowed = true
            if onboardingUseCase.includesPushToTalk {
                hotkeyMonitor.start()
                startComputerUseHotkeyMonitorIfNeeded()
            }
            // Start monitors that were deferred during onboarding
            if shouldRunMeetingFeatureMonitors {
                startMeetingFeatureMonitors(includeMaraudersMap: false)
            }
            TelemetryDeck.signal("onboarding.completed", parameters: [
                "use_case": onboardingUseCase.rawValue,
                "voice_notes_selected": onboardingUseCase.includesVoiceNotes ? "true" : "false",
                "dictation_selected": onboardingUseCase.includesDictation ? "true" : "false",
                "meetings_selected": onboardingUseCase.includesMeetings ? "true" : "false",
                "microphone_granted": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "true" : "false",
                "accessibility_granted": AXIsProcessTrusted() ? "true" : "false",
                "input_monitoring_granted": CGPreflightListenEventAccess() ? "true" : "false",
            ])
            let completionTab = OnboardingFlow.completionTab(for: onboardingUseCase)
            openHistoryWindow(tab: completionTab)
        } else {
            showOnboarding(resumeFrom: onboardingProgressForPermissionRepair())
        }
    }

    @objc func openHistoryWindow() {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return }
        showActiveMeetingDocumentIfNeeded()
        presentHistoryWindow()
    }

    private func presentHistoryWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show()
        }
    }

    func openHistoryWindow(tab: DashboardTab) {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return }
        presentHistoryWindow(tab: tab)
    }

    private func presentHistoryWindow(tab: DashboardTab) {
        appState.selectedTab = tab
        syncAppState()
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show()
        }
    }

    private func hasRequiredStartupPermissions(for useCase: OnboardingUseCase) -> Bool {
        OnboardingPermissionGate.hasRequiredPermissions(
            OnboardingPermissionSnapshot(
                microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                accessibility: AXIsProcessTrusted(),
                inputMonitoring: CGPreflightListenEventAccess(),
                systemAudio: false,
                screenRecording: false
            ),
            for: useCase
        )
    }

    func reclassifyVoiceNotesAsDictationIfReady(
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) {
        guard config.resolvedOnboardingUseCase == .voiceNotes else { return }
        guard OnboardingPermissionGate.hasRequiredDictationPermissions(
            OnboardingPermissionSnapshot(
                microphone: microphoneGranted,
                accessibility: accessibilityGranted,
                inputMonitoring: inputMonitoringGranted,
                systemAudio: false,
                screenRecording: false
            )
        ) else { return }

        updateConfig { $0.onboardingUseCase = OnboardingUseCase.dictation.rawValue }
        hotkeyMonitor.configure(keyCode: config.dictationHotkey.keyCode)
        hotkeyMonitor.start()
        startComputerUseHotkeyMonitorIfNeeded()
        syncDictationRecorderWarmup(reason: "permissions-ready")
        TelemetryDeck.signal("onboarding.use_case_reclassified", parameters: [
            "from_use_case": OnboardingUseCase.voiceNotes.rawValue,
            "to_use_case": OnboardingUseCase.dictation.rawValue,
            "reason": "dictation_permissions_granted",
        ])
    }

    private func ensureBasicDictationPermissionsBeforeDashboard() -> Bool {
        guard hasRequiredStartupPermissions(for: config.resolvedOnboardingUseCase) else {
            historyWindowController?.close()
            if let progress = OnboardingProgress.load() {
                showOnboarding(resumeFrom: progress)
            } else {
                showOnboarding(resumeFrom: onboardingProgressForPermissionRepair())
            }
            return false
        }
        return true
    }

    private func onboardingProgressForPermissionRepair() -> OnboardingProgress {
        OnboardingProgress(
            currentStep: OnboardingView.permissionsStep,
            userName: config.userName,
            selectedBackendKey: config.sttBackend,
            selectedModelKey: config.sttModel,
            selectedCohereLanguageCode: config.cohereLanguage,
            hotkeyKeyCode: config.dictationHotkey.keyCode,
            hotkeyLabel: config.dictationHotkey.label,
            systemAudioRequested: false,
            onboardingUseCaseRawValue: config.onboardingUseCase
        )
    }

    func showMeetingsHome(folderID: Int64? = nil) {
        appState.selectedTab = .meetings
        appState.selectedFolderID = folderID
        appState.meetingsNavigationState = .browser
        syncAppState()
    }

    func showMeetingDocument(id: Int64) {
        appState.selectedTab = .meetings
        appState.selectedMeetingID = id
        appState.selectedMeetingRecord = meeting(id: id)
        appState.meetingsNavigationState = .document(id)
    }

    private func showActiveMeetingDocumentIfNeeded() {
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else {
            return
        }
        showMeetingDocument(id: activeMeetingID)
    }

    func showMeetingTemplatesManager() {
        appState.selectedTab = .meetings
        appState.isMeetingTemplatesManagerPresented = true
    }

    @objc func openPreferences() {
        openHistoryWindow(tab: .settings)
    }

    @objc func openSettingsTab() {
        openHistoryWindow(tab: .settings)
    }

    @objc func checkForUpdates() {
        presentStandardUpdateCheck()
    }

    func retryUpdateCheck() {
        presentStandardUpdateCheck()
    }

    func installAvailableUpdate() {
        switch UpdateInteractionPolicy.installAction(for: appState.sparkleUpdateStatus) {
        case .presentStandardUpdater:
            presentStandardUpdateCheck()
        case .showBusy(let message):
            showBusyStatus(
                message,
                restoring: appState.sparkleUpdateStatus
            )
        }
    }

    private func presentStandardUpdateCheck() {
        guard let updaterController else {
            appState.sparkleUpdateStatus = .disabled(message: "Update checks are disabled for this build.")
            return
        }
        guard updaterController.updater.canCheckForUpdates else {
            showBusyStatus(
                "Sparkle cannot start a new update check yet. Try again in a moment.",
                restoring: appState.sparkleUpdateStatus
            )
            return
        }
        updaterController.checkForUpdates(nil)
    }

    private func showBusyStatus(_ message: String, restoring previousStatus: SparkleUpdateStatus) {
        busyStatusGeneration += 1
        let generation = busyStatusGeneration
        let restoreStatus = nonBusyStatus(previousStatus)
        appState.sparkleUpdateStatus = .busy(message: message)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.busyStatusGeneration == generation else { return }
            guard case .busy = self.appState.sparkleUpdateStatus else { return }
            self.appState.sparkleUpdateStatus = restoreStatus
        }
    }

    private func nonBusyStatus(_ status: SparkleUpdateStatus) -> SparkleUpdateStatus {
        if case .busy = status {
            return .idle
        }
        return status
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func copyRecentDictation(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func copyRecentMeeting(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func selectBackendFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let option = BackendOption.all.first(where: { $0.label == label }) else { return }
        selectBackend(option)
    }

    @objc func selectMeetingSummaryBackendFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) else { return }
        if option == .chatGPT, !chatGPTAuth.isAuthenticated {
            Task { await signInWithChatGPT() }
            return
        }
        selectMeetingSummaryBackend(option)
    }

    func resummarize(meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        let templateSnapshot = meetingTemplateSnapshot(for: meeting)
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    func applyMeetingTemplate(id: String, to meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let templateSnapshot = MeetingTemplates.resolveExactSnapshot(
            id: id,
            customTemplates: config.customMeetingTemplates
        ) else {
            completion(.failure(MeetingTemplateSelectionError.templateNoLongerExists))
            return
        }
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    private func resummarize(
        meeting: MeetingRecord,
        using templateSnapshot: MeetingTemplateSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            let plan = MeetingResummarizationPolicy.plan(for: meeting)
            do {
                let notes = try await MeetingSummaryClient.summarize(
                    transcript: meeting.rawTranscript,
                    meetingTitle: plan.promptTitle,
                    config: self.config,
                    template: templateSnapshot,
                    existingNotes: self.notesContextForResummary(meeting),
                    manualNotesToRetain: meeting.manualNotes
                )
                try self.dictationStore.updateMeetingSummary(
                    id: meeting.id,
                    title: plan.persistedTitle,
                    formattedNotes: notes,
                    selectedTemplateID: templateSnapshot.id,
                    selectedTemplateName: templateSnapshot.name,
                    selectedTemplateKind: templateSnapshot.kind,
                    selectedTemplatePrompt: templateSnapshot.prompt
                )
                await MainActor.run {
                    self.syncAppState()
                    self.historyWindowController?.reload()
                    completion(.success(()))
                }
            } catch {
                fputs("[muesli-native] failed to generate or persist meeting summary: \(error)\n", stderr)
                await MainActor.run {
                    if error is MeetingSummaryError {
                        completion(.failure(error))
                    } else {
                        completion(.failure(MeetingSummaryPersistenceError.failedToSaveSummary(underlying: error)))
                    }
                }
            }
        }
    }

    func retranscribe(meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failure(MeetingRetranscriptionError.controllerUnavailable))
                return
            }
            var didSetProcessing = false
            do {
                guard let savedRecordingPath = meeting.savedRecordingPath,
                      !savedRecordingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MeetingRetranscriptionError.recordingUnavailable
                }
                let recordingURL = URL(fileURLWithPath: savedRecordingPath)
                guard FileManager.default.fileExists(atPath: recordingURL.path) else {
                    throw MeetingRetranscriptionError.recordingUnavailable
                }
                guard let backend = self.normalizeMeetingTranscriptionSelectionForAvailability() else {
                    throw MeetingRetranscriptionError.noDownloadedTranscriptionModel
                }

                try self.dictationStore.updateMeetingStatus(id: meeting.id, status: .processing)
                didSetProcessing = true
                self.syncAppState()
                self.historyWindowController?.reload()

                try await self.transcriptionCoordinator.preloadRequired(
                    backend: backend,
                    enablePostProcessor: false,
                    includeMeetingHelpers: true
                )
                let transcription = try await self.transcriptionCoordinator.transcribeMeeting(
                    at: recordingURL,
                    backend: backend,
                    cohereLanguage: self.config.resolvedCohereLanguage
                )
                let rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTranscript.isEmpty else {
                    throw MeetingRetranscriptionError.emptyTranscript
                }

                let templateSnapshot = MeetingTemplates.snapshot(
                    for: meeting,
                    customTemplates: self.config.customMeetingTemplates
                )
                let formattedNotes: String
                do {
                    formattedNotes = try await MeetingSummaryClient.summarize(
                        transcript: rawTranscript,
                        meetingTitle: meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting" : meeting.title,
                        config: self.config,
                        template: templateSnapshot,
                        existingNotes: self.notesContextForResummary(meeting),
                        manualNotesToRetain: meeting.manualNotes
                    )
                } catch {
                    fputs("[muesli-native] re-transcription summary generation failed: \(error)\n", stderr)
                    formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                        transcript: rawTranscript,
                        meetingTitle: meeting.title,
                        error: error,
                        manualNotes: meeting.manualNotes
                    )
                }

                do {
                    try self.dictationStore.updateMeetingTranscriptAndSummary(
                        id: meeting.id,
                        rawTranscript: rawTranscript,
                        formattedNotes: formattedNotes,
                        selectedTemplateID: templateSnapshot.id,
                        selectedTemplateName: templateSnapshot.name,
                        selectedTemplateKind: templateSnapshot.kind,
                        selectedTemplatePrompt: templateSnapshot.prompt
                    )
                } catch {
                    throw MeetingRetranscriptionError.failedToSave(underlying: error)
                }

                self.syncAppState()
                self.historyWindowController?.reload()
                completion(.success(()))
            } catch {
                fputs("[muesli-native] failed to re-transcribe meeting \(meeting.id): \(error)\n", stderr)
                if let status = Self.retranscriptionFailureStatus(
                    originalStatus: meeting.status,
                    didSetProcessing: didSetProcessing,
                    error: error
                ) {
                    try? self.dictationStore.updateMeetingStatus(id: meeting.id, status: status)
                }
                self.syncAppState()
                self.historyWindowController?.reload()
                completion(.failure(error))
            }
        }
    }

    static func retranscriptionFailureStatus(
        originalStatus: MeetingStatus,
        didSetProcessing: Bool,
        error: Error
    ) -> MeetingStatus? {
        guard didSetProcessing else { return nil }
        if let retranscriptionError = error as? MeetingRetranscriptionError {
            switch retranscriptionError {
            case .emptyTranscript, .failedToSave:
                return originalStatus
            case .controllerUnavailable, .recordingUnavailable, .noDownloadedTranscriptionModel:
                break
            }
        }
        return .failed
    }

    // MARK: - Meeting Editing

    private func notesContextForResummary(_ meeting: MeetingRecord) -> String? {
        Self.notesContextForResummary(meeting)
    }

    static func notesContextForResummary(_ meeting: MeetingRecord) -> String? {
        guard meeting.notesState == .structuredNotes else { return nil }
        let trimmed = stripManualNotesSection(from: meeting.formattedNotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stripManualNotesSection(from notes: String) -> String {
        let markers = [
            "\n\n### Written notes\n\n",
            "\n### Written notes\n\n",
            "### Written notes\n\n",
            "\n\n## Manual Notes\n\n",
            "\n## Manual Notes\n\n",
            "## Manual Notes\n\n"
        ]
        for marker in markers {
            if let range = notes.range(of: marker, options: [.backwards]) {
                return String(notes[..<range.lowerBound])
            }
        }
        return notes
    }

    func updateMeetingTitle(id: Int64, title: String) {
        liveMeetingTitleCache[id] = title
        do {
            try dictationStore.updateMeetingTitle(id: id, title: title)
            liveMeetingTitleCache[id] = nil
        } catch {
            fputs("[muesli-native] failed to update meeting title \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    func cacheMeetingTitle(id: Int64, title: String) {
        liveMeetingTitleCache[id] = title
    }

    func updateMeetingNotes(id: Int64, notes: String) {
        try? dictationStore.updateMeetingNotes(id: id, formattedNotes: notes)
        syncAppState()
    }

    func updateMeetingTranscript(id: Int64, transcript: String) {
        do {
            try dictationStore.updateMeetingTranscript(id: id, rawTranscript: transcript)
        } catch {
            fputs("[muesli-native] failed to update meeting transcript \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    func updateMeetingManualNotes(id: Int64, notes: String) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        liveManualNotesCache[id] = notes
        do {
            try dictationStore.updateMeetingManualNotes(id: id, manualNotes: notes)
            markMeetingManualNotesPersisted(id: id, notes: notes)
        } catch {
            fputs("[muesli-native] failed to update manual notes for \(id): \(error)\n", stderr)
        }
        syncAppState()
    }

    func cacheMeetingManualNotes(id: Int64, notes: String) {
        liveManualNotesCache[id] = notes
        scheduleCachedMeetingManualNotesPersistence(id: id)
    }

    func flushCachedMeetingManualNotes(id: Int64, sync: Bool = true) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        guard let notes = liveManualNotesCache[id] else { return }
        persistCachedMeetingManualNotes(id: id, notes: notes, sync: sync)
    }

    func hasPersistedMeetingManualNotes(id: Int64, notes: String) -> Bool {
        if liveManualNotesLastPersistedValue[id] == notes {
            return true
        }
        return (try? dictationStore.meeting(id: id)?.manualNotes) == notes
    }

    private func scheduleCachedMeetingManualNotesPersistence(id: Int64) {
        guard let notes = liveManualNotesCache[id] else { return }
        if shouldPersistCachedMeetingManualNotesImmediately(id: id, notes: notes) {
            flushCachedMeetingManualNotes(id: id, sync: false)
            return
        }

        let lastPersistedAt = liveManualNotesLastPersistedAt[id] ?? .distantPast
        let delay = max(liveManualNotesPersistInterval - Date().timeIntervalSince(lastPersistedAt), 0)
        liveManualNotesPersistWorkItems[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushCachedMeetingManualNotes(id: id, sync: false)
        }
        liveManualNotesPersistWorkItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func shouldPersistCachedMeetingManualNotesImmediately(id: Int64, notes: String) -> Bool {
        if liveManualNotesLastPersistedValue[id] == nil { return true }
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let lastPersistedAt = liveManualNotesLastPersistedAt[id] ?? .distantPast
        return Date().timeIntervalSince(lastPersistedAt) >= liveManualNotesPersistInterval
    }

    private func persistCachedMeetingManualNotes(id: Int64, notes: String, sync: Bool) {
        if liveManualNotesLastPersistedValue[id] == notes {
            if sync {
                syncAppState()
            }
            return
        }
        do {
            try dictationStore.updateMeetingManualNotes(id: id, manualNotes: notes)
            markMeetingManualNotesPersisted(id: id, notes: notes)
        } catch {
            fputs("[muesli-native] failed to persist manual notes for \(id): \(error)\n", stderr)
        }
        if sync {
            syncAppState()
        }
    }

    private func markMeetingManualNotesPersisted(id: Int64, notes: String) {
        liveManualNotesLastPersistedAt[id] = Date()
        liveManualNotesLastPersistedValue[id] = notes
    }

    private func clearCachedMeetingManualNotes(id: Int64) {
        liveManualNotesPersistWorkItems[id]?.cancel()
        liveManualNotesPersistWorkItems[id] = nil
        liveManualNotesCache[id] = nil
        liveManualNotesLastPersistedAt[id] = nil
        liveManualNotesLastPersistedValue[id] = nil
    }

    private func clearCachedMeetingTitle(id: Int64) {
        liveMeetingTitleCache[id] = nil
    }

    private func flushCachedMeetingTitle(id: Int64) {
        guard let title = liveMeetingTitleCache[id] else { return }
        do {
            try dictationStore.updateMeetingTitle(id: id, title: title)
            liveMeetingTitleCache[id] = nil
        } catch {
            fputs("[muesli-native] failed to flush cached meeting title \(id): \(error)\n", stderr)
        }
    }

    private func clearAllCachedMeetingManualNotes() {
        liveManualNotesPersistWorkItems.values.forEach { $0.cancel() }
        liveManualNotesPersistWorkItems.removeAll()
        liveManualNotesCache.removeAll()
        liveManualNotesLastPersistedAt.removeAll()
        liveManualNotesLastPersistedValue.removeAll()
    }

    private func clearAllCachedMeetingTitles() {
        liveMeetingTitleCache.removeAll()
    }

    private func manualNotesForLiveMeeting(id: Int64) -> String {
        if let cached = liveManualNotesCache[id] {
            return cached
        }
        return (try? dictationStore.meeting(id: id)?.manualNotes) ?? ""
    }

    // MARK: - Folder Management

    @discardableResult
    func createFolder(name: String) -> Int64? {
        let id = try? dictationStore.createFolder(name: name)
        syncAppState()
        return id
    }

    func renameFolder(id: Int64, name: String) {
        try? dictationStore.renameFolder(id: id, name: name)
        syncAppState()
    }

    func reorderFolders(ids: [Int64]) {
        updateConfig { $0.folderOrder = ids }
        syncAppState()
    }

    func createFolderAndMoveMeeting(name: String, meetingID: Int64) {
        guard let folderID = try? dictationStore.createFolder(name: name) else { return }
        try? dictationStore.moveMeeting(id: meetingID, toFolder: folderID)
        syncAppState()
    }

    func deleteFolder(id: Int64) {
        try? dictationStore.deleteFolder(id: id)
        if appState.selectedFolderID == id {
            appState.selectedFolderID = nil
        }
        syncAppState()
    }

    func hideCalendarEvent(_ eventID: String) {
        appState.hiddenCalendarEventIDs.insert(eventID)
        updateConfig { $0.hiddenCalendarEventIDs = self.appState.hiddenCalendarEventIDs.sorted() }
        statusBarController?.refresh()
    }

    func createMeetingFromCalendarEvent(_ event: UnifiedCalendarEvent, folderID: Int64?) {
        // Check ALL folders for existing meeting with this calendar event ID
        if let existing = try? dictationStore.meetingByCalendarEventID(event.id) {
            if let folderID {
                try? dictationStore.moveMeeting(id: existing.id, toFolder: folderID)
            }
            syncAppState()
            fputs("[muesli-native] calendar event already exists as meeting \(existing.id), moved to folder\n", stderr)
            return
        }

        do {
            let meetingID = try dictationStore.insertMeeting(
                title: event.title,
                calendarEventID: event.id,
                startTime: event.startDate,
                endTime: event.endDate,
                rawTranscript: "",
                formattedNotes: "",
                micAudioPath: nil,
                systemAudioPath: nil
            )
            if let folderID {
                try? dictationStore.moveMeeting(id: meetingID, toFolder: folderID)
            }
            syncAppState()
            fputs("[muesli-native] created meeting from calendar event: \(event.title) (folder=\(folderID.map(String.init) ?? "none"))\n", stderr)
        } catch {
            fputs("[muesli-native] failed to create meeting from calendar event: \(error)\n", stderr)
        }
    }

    func moveMeeting(id: Int64, toFolder folderID: Int64?) {
        try? dictationStore.moveMeeting(id: id, toFolder: folderID)
        syncAppState()
    }

    func loadMoreDictations() {
        guard appState.hasMoreDictations else { return }
        let offset = appState.dictationRows.count
        let more = (try? dictationStore.recentDictations(
            limit: appState.dictationPageSize,
            offset: offset,
            fromDate: appState.dictationFromDate,
            toDate: appState.dictationToDate
        )) ?? []
        appState.dictationRows.append(contentsOf: more)
        appState.hasMoreDictations = more.count >= appState.dictationPageSize
    }

    func filterDictations(from: Date?, to: Date?) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        appState.dictationFromDate = from.map { formatter.string(from: $0) }
        appState.dictationToDate = to.map { formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: $0)!) }
        syncAppState()
    }

    func clearDictationFilter() {
        appState.dictationFromDate = nil
        appState.dictationToDate = nil
        syncAppState()
    }

    func deleteDictation(id: Int64) {
        try? dictationStore.deleteDictation(id: id)
        syncAppState()
    }

    func deleteMeeting(id: Int64) {
        guard let meeting = meeting(id: id) else { return }
        guard canDeleteMeeting(meeting) else { return }

        do {
            // Delete the retained file first so a failed file removal does not orphan
            // user-visible recording data after the meeting row disappears.
            if let savedRecordingPath = meeting.savedRecordingPath {
                try deleteSavedMeetingRecording(at: savedRecordingPath)
            }
            try dictationStore.deleteMeeting(id: id)
        } catch let error as MeetingLifecycleError {
            presentErrorAlert(title: "Couldn't Delete Meeting", message: error.localizedDescription)
            return
        } catch {
            presentErrorAlert(
                title: "Couldn't Delete Meeting",
                message: MeetingLifecycleError.failedToDeleteMeeting(underlying: error).localizedDescription
            )
            return
        }

        if appState.selectedMeetingID == id {
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
            if case .document(let selectedID) = appState.meetingsNavigationState, selectedID == id {
                appState.meetingsNavigationState = .browser
            }
        }
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
        staleLiveMeetingRecoveryFailures.remove(id)

        historyWindowController?.reload()
        statusBarController?.refresh()
        syncAppState()
    }

    func clearDictationHistory() {
        try? dictationStore.clearDictations()
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    func canDeleteMeeting(_ meeting: MeetingRecord) -> Bool {
        guard meeting.id != activeMeetingID else { return false }
        if staleLiveMeetingRecoveryFailures.contains(meeting.id) {
            return true
        }
        switch meeting.status {
        case .recording, .processing:
            return false
        case .completed, .noteOnly, .failed:
            return true
        }
    }

    func activeLiveMeetingRecord() -> MeetingRecord? {
        guard let activeMeetingID,
              isMeetingRecording() || isStartingMeetingRecording else {
            return nil
        }
        return meeting(id: activeMeetingID)
    }

    func clearMeetingHistory() {
        guard !isMeetingRecording(), !isStartingMeetingRecording else {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "Stop the current meeting recording before clearing saved meetings."
            )
            return
        }

        do {
            try clearSavedMeetingRecordingsDirectory()
        } catch {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "Saved meeting recordings could not be deleted, so meeting history was left in place. \(error.localizedDescription)"
            )
            return
        }

        try? dictationStore.clearMeetings()
        clearAllCachedMeetingManualNotes()
        clearAllCachedMeetingTitles()
        appState.selectedMeetingID = nil
        appState.selectedMeetingRecord = nil
        appState.meetingsNavigationState = .browser
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    func isMeetingRecording() -> Bool {
        activeMeetingSession?.isRecording == true || isStoppingMeetingRecording
    }

    func isMeetingRecordingPaused() -> Bool {
        activeMeetingSession?.isPaused == true
    }

    private var meetingTerminationState: MeetingTerminationState {
        MeetingTerminationPolicy.state(
            isStarting: isStartingMeetingRecording,
            hasActiveSession: activeMeetingSession != nil,
            isRecording: activeMeetingSession?.isRecording == true,
            isStopping: isStoppingMeetingRecording
        )
    }

    @MainActor
    func shouldTerminateApplication() -> Bool {
        let state = meetingTerminationState
        let messageText: String
        let informativeText: String

        switch state {
        case .none:
            return true
        case .starting:
            messageText = "Meeting recording is starting"
            informativeText = "Quitting now will cancel the meeting recording before it has been saved."
        case .recording:
            messageText = "Meeting recording in progress"
            informativeText = "Quitting now will stop the meeting recording and the current transcript may be lost. Stop the recording first if you want Muesli to save notes."
        case .processing:
            messageText = "Meeting transcription in progress"
            informativeText = "Quitting now will interrupt transcription and the meeting notes may not be saved."
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Keep Muesli Running")
        alert.addButton(withTitle: "Quit Anyway")

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else {
            return false
        }

        activeMeetingSession?.discard()
        activeMeetingSession = nil
        if let meetingStartMeetingID {
            canceledMeetingStartIDs.insert(meetingStartMeetingID)
            resolveLiveMeetingAfterStartFailure(id: meetingStartMeetingID)
        }
        meetingStartTask?.cancel()
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        isStoppingMeetingRecording = false
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        endMeetingActivity()
        syncAppState()
        return true
    }

    @objc func toggleMeetingRecording() {
        if isMeetingRecording() {
            stopMeetingRecording()
        } else {
            startForegroundMeetingRecording()
        }
    }

    @objc func toggleMeetingRecordingPause() {
        if isMeetingRecordingPaused() {
            resumeMeetingRecording()
        } else {
            pauseMeetingRecording()
        }
    }

    func pauseMeetingRecording() {
        guard let activeMeetingSession,
              activeMeetingSession.isRecording,
              !activeMeetingSession.isPaused,
              !isStoppingMeetingRecording else { return }
        activeMeetingSession.pause()
        indicator.setMeetingRecordingPaused(true, config: config)
        statusBarController?.setStatus("Meeting paused")
        statusBarController?.refresh()
        syncAppState()
    }

    func resumeMeetingRecording() {
        guard let activeMeetingSession,
              activeMeetingSession.isRecording,
              activeMeetingSession.isPaused,
              !isStoppingMeetingRecording else { return }
        activeMeetingSession.resume()
        indicator.setMeetingRecordingPaused(false, config: config)
        statusBarController?.setStatus("Meeting: \(activeMeetingDisplayTitle())")
        statusBarController?.refresh()
        syncAppState()
    }

    @objc func startMeetingFromCalendarMenuItem(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        startForegroundMeetingRecording(title: title)
    }

    @discardableResult
    func startForegroundMeetingRecording(title: String = "Meeting", calendarEventID: String? = nil, endDate: Date? = nil) -> Bool {
        guard ensureBasicDictationPermissionsBeforeDashboard() else { return false }
        if isMeetingRecording() {
            presentHistoryWindow(tab: .meetings)
            return false
        }
        guard !isStartingMeetingRecording else { return false }
        let didStart = startMeetingRecording(title: title, calendarEventID: calendarEventID, openDocument: true, endDate: endDate)
        guard didStart else { return false }
        presentHistoryWindow(tab: .meetings)
        return true
    }

    @discardableResult
    func startMeetingRecording(title: String = "Meeting", calendarEventID: String? = nil, openDocument: Bool = false, endDate: Date? = nil) -> Bool {
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return false }
        guard let meetingBackend = normalizeMeetingTranscriptionSelectionForAvailability() else {
            presentErrorAlert(
                title: "Meeting failed to start",
                message: "Download a transcription model before recording a meeting."
            )
            return false
        }
        let templateSnapshot = defaultMeetingTemplate()
        let meetingID: Int64
        do {
            meetingID = try dictationStore.createLiveMeeting(
                title: title,
                calendarEventID: calendarEventID,
                startTime: Date(),
                selectedTemplateID: templateSnapshot.id,
                selectedTemplateName: templateSnapshot.name,
                selectedTemplateKind: templateSnapshot.kind,
                selectedTemplatePrompt: templateSnapshot.prompt
            )
            activeMeetingID = meetingID
            syncAppState()
            if openDocument {
                showMeetingDocument(id: meetingID)
            }
        } catch {
            fputs("[muesli-native] failed to create live meeting: \(error)\n", stderr)
            presentErrorAlert(title: "Meeting failed to start", message: error.localizedDescription)
            return false
        }
        isStartingMeetingRecording = true
        // Keep this after backend normalization and live-meeting creation so
        // a failed meeting start does not silently cancel an active dictation.
        cancelDictationAudioSessionForMeetingRecordingIfNeeded()
        syncDictationRecorderWarmup(reason: "meeting-start")
        meetingStartMeetingID = meetingID
        updateMeetingStartStatus("Preparing meeting transcription...")
        beginMeetingActivity(reason: "Recording and transcribing a meeting")
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        updateMeetingNotificationVisibility()

        meetingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.startMeetingRecordingWithSystemAudioRecovery(
                    title: title,
                    calendarEventID: calendarEventID,
                    meetingID: meetingID,
                    backend: meetingBackend,
                    endDate: endDate
                )
            } catch is CancellationError {
                if self.meetingStartMeetingID == meetingID {
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.setStatus("Idle")
                    self.statusBarController?.refresh()
                    self.setState(.idle)
                    self.endMeetingActivity()
                    self.syncDictationRecorderWarmup(reason: "meeting-start-cancelled")
                }
            } catch {
                if self.meetingStartMeetingID == meetingID {
                    fputs("[muesli-native] failed to start meeting: \(error)\n", stderr)
                    self.resolveLiveMeetingAfterStartFailure(id: meetingID)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.meetingMonitor.refreshState()
                    self.statusBarController?.setStatus("Idle")
                    self.statusBarController?.refresh()
                    self.setState(.idle)
                    self.endMeetingActivity()
                    self.syncDictationRecorderWarmup(reason: "meeting-start-failed")

                    let isSystemAudioError = error is CoreAudioSystemRecorder.RecorderError
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    if isSystemAudioError {
                        alert.messageText = "System audio capture failed"
                        alert.informativeText = "Could not start system audio recording. Open System Settings > Privacy & Security > Screen & System Audio Recording and enable \(AppIdentity.displayName) under \"System Audio Recording Only\".\n\nError: \(error.localizedDescription)"
                        alert.addButton(withTitle: "Open System Settings")
                        alert.addButton(withTitle: "OK")
                        if alert.runModal() == .alertFirstButtonReturn {
                            CoreAudioSystemRecorder.openSystemAudioSettings()
                        }
                    } else {
                        alert.messageText = "Meeting failed to start"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
            self.finishMeetingStartAttempt(meetingID: meetingID)
        }
        return true
    }

    func startQuickNoteMeeting() {
        startForegroundMeetingRecording(title: "Meeting")
    }

    func cancelMeetingPreparation() {
        guard isStartingMeetingRecording,
              activeMeetingSession == nil,
              let meetingID = meetingStartMeetingID else {
            return
        }
        canceledMeetingStartIDs.insert(meetingID)
        meetingStartTask?.cancel()
        resolveLiveMeetingAfterStartFailure(id: meetingID)
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        statusBarController?.setStatus("Idle")
        statusBarController?.refresh()
        setState(.idle)
        endMeetingActivity()
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        syncAppState()
        syncDictationRecorderWarmup(reason: "meeting-start-cancelled")
    }

    private func finishMeetingStartAttempt(meetingID: Int64) {
        guard meetingStartMeetingID == meetingID else { return }
        canceledMeetingStartIDs.remove(meetingID)
        meetingStartTask = nil
        meetingStartMeetingID = nil
        isStartingMeetingRecording = false
        updateMeetingStartStatus(nil)
        updateMeetingNotificationVisibility()
        syncAppState()
        syncDictationRecorderWarmup(reason: "meeting-start-finished")
    }

    private func startMeetingRecordingWithSystemAudioRecovery(
        title: String,
        calendarEventID: String?,
        meetingID: Int64,
        backend: BackendOption,
        endDate: Date?
    ) async throws {
        var shouldRetryAfterPermissionRequest = config.useCoreAudioTap
        statusBarController?.setStatus("Preparing meeting transcription...")
        statusBarController?.refresh()
        try Task.checkCancellation()
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: false,
            includeMeetingHelpers: true
        )
        try Task.checkCancellation()
        try checkMeetingStartStillCurrent(meetingID)

        while true {
            try Task.checkCancellation()
            try checkMeetingStartStillCurrent(meetingID)
            let meetingSession = MeetingSession(
                title: title,
                calendarEventID: calendarEventID,
                backend: backend,
                runtime: runtime,
                config: config,
                transcriptionCoordinator: transcriptionCoordinator
            )

            do {
                meetingSession.manualNotesProvider = { [weak self] in
                    await MainActor.run {
                        guard let self else { return nil }
                        return self.manualNotesForLiveMeeting(id: meetingID)
                    }
                }
                meetingSession.liveTitleProvider = { [weak self] in
                    await MainActor.run {
                        guard let self else { return nil }
                        return self.liveMeetingTitle(id: meetingID)
                    }
                }
                try await meetingSession.start()
                if Task.isCancelled || canceledMeetingStartIDs.contains(meetingID) {
                    meetingSession.discard()
                    throw CancellationError()
                }
                activeMeetingSession = meetingSession
                activeMeetingID = meetingID
                meetingMonitor.suppressWhileActive()
                meetingMonitor.refreshState()
                statusBarController?.setStatus("Meeting: \(title)")
                indicator.powerProvider = { [weak meetingSession] in
                    meetingSession?.currentPower() ?? -160
                }
                indicator.setMeetingRecording(true, config: config)
                statusBarController?.refresh()
                syncAppState()
                scheduleMeetingEndNotification(endDate: endDate, title: title)
                return
            } catch {
                guard shouldRetryAfterPermissionRequest,
                      case .tapCreationFailed = error as? CoreAudioSystemRecorder.RecorderError else {
                    throw error
                }

                shouldRetryAfterPermissionRequest = false
                meetingSession.discard()
                try Task.checkCancellation()
                try checkMeetingStartStillCurrent(meetingID)
                updateMeetingStartStatus("Requesting system audio permission...")
                statusBarController?.setStatus("Requesting system audio permission...")
                statusBarController?.refresh()
                let granted = await CoreAudioSystemRecorder.requestSystemAudioAccess()
                try Task.checkCancellation()
                try checkMeetingStartStillCurrent(meetingID)
                if granted {
                    updateMeetingStartStatus("Retrying meeting start...")
                    statusBarController?.setStatus("Retrying meeting start...")
                    statusBarController?.refresh()
                    continue
                }
                throw error
            }
        }
    }

    private func checkMeetingStartStillCurrent(_ meetingID: Int64) throws {
        if canceledMeetingStartIDs.contains(meetingID) || meetingStartMeetingID != meetingID {
            throw CancellationError()
        }
    }

    /// Open meeting URL, start recording, schedule end notification, and suppress detection.
    /// Single entry point for "Join & Record" from both notification panel and Coming Up section.
    func joinAndRecord(title: String, meetingURL: URL, endDate: Date?, calendarEventID: String? = nil) {
        NSWorkspace.shared.open(meetingURL)
        startForegroundMeetingRecording(title: title, calendarEventID: calendarEventID, endDate: endDate)
    }

    /// Open meeting URL and suppress detection for the event duration.
    /// Single entry point for "Join Only" from both notification panel and Coming Up section.
    func joinOnly(meetingURL: URL, endDate: Date?) {
        let remaining = endDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
        meetingMonitor.suppress(for: remaining)
        meetingMonitor.refreshState()
        NSWorkspace.shared.open(meetingURL)
    }

    enum MeetingDiscardResolution: Equatable {
        case discardRecording
        case keepManualNotes
        case deleteDraft
    }

    private struct MeetingDiscardAccessory {
        let view: NSView
        let manualNotesCheckbox: NSButton
    }

    private final class MeetingDiscardAccessoryView: NSView {
        var titleUpdater: AnyObject?
    }

    private final class MeetingDiscardButtonTitleUpdater: NSObject {
        weak var discardButton: NSButton?

        init(discardButton: NSButton?) {
            self.discardButton = discardButton
        }

        @MainActor @objc func manualNotesCheckboxChanged(_ sender: NSButton) {
            discardButton?.title = sender.state == .on ? "Discard" : "Discard Recording"
        }
    }

    @objc func discardMeetingWithConfirmation() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        let hasManualNotes = activeMeetingID.map { id in
            !manualNotesForLiveMeeting(id: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        alert.messageText = "Discard recording?"
        alert.alertStyle = .warning
        var manualNotesCheckbox: NSButton?
        if hasManualNotes {
            alert.informativeText = "This will stop the meeting. Choose whether to delete the written notes too."
            let accessory = Self.makeDiscardMeetingAccessoryView()
            manualNotesCheckbox = accessory.manualNotesCheckbox
            alert.accessoryView = accessory.view
            alert.addButton(withTitle: "Discard Recording")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            let titleUpdater = MeetingDiscardButtonTitleUpdater(discardButton: alert.buttons.first)
            manualNotesCheckbox?.target = titleUpdater
            manualNotesCheckbox?.action = #selector(MeetingDiscardButtonTitleUpdater.manualNotesCheckboxChanged(_:))
            (accessory.view as? MeetingDiscardAccessoryView)?.titleUpdater = titleUpdater
        } else {
            alert.informativeText = "This will stop the meeting recording and delete all captured audio. This cannot be undone."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
        }
        presentDiscardMeetingAlert(alert, manualNotesCheckbox: manualNotesCheckbox)
    }

    private static func makeDiscardMeetingAccessoryView() -> MeetingDiscardAccessory {
        let label = NSTextField(labelWithString: "Will delete:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor

        let recordingCheckbox = NSButton(checkboxWithTitle: "Recording audio", target: nil, action: nil)
        recordingCheckbox.state = .on
        recordingCheckbox.isEnabled = false

        let notesCheckbox = NSButton(checkboxWithTitle: "Manual notes", target: nil, action: nil)
        notesCheckbox.state = .off

        let container = MeetingDiscardAccessoryView(frame: NSRect(x: 0, y: 0, width: 230, height: 76))
        let stack = NSStackView(views: [label, recordingCheckbox, notesCheckbox])
        stack.frame = container.bounds
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        return MeetingDiscardAccessory(view: container, manualNotesCheckbox: notesCheckbox)
    }

    private func presentDiscardMeetingAlert(_ alert: NSAlert, manualNotesCheckbox: NSButton?, attempt: Int = 0) {
        if let window = confirmationAnchorWindow() {
            beginDiscardMeetingAlert(alert, for: window, manualNotesCheckbox: manualNotesCheckbox)
            return
        }

        showActiveMeetingDocumentIfNeeded()
        historyWindowController?.show()
        if let window = confirmationAnchorWindow() {
            beginDiscardMeetingAlert(alert, for: window, manualNotesCheckbox: manualNotesCheckbox)
            return
        }

        guard attempt < 20 else {
            NSLog("Unable to present discard meeting confirmation: no anchor window became available")
            NSSound.beep()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, alert] in
            self?.presentDiscardMeetingAlert(alert, manualNotesCheckbox: manualNotesCheckbox, attempt: attempt + 1)
        }
    }

    private func beginDiscardMeetingAlert(_ alert: NSAlert, for window: NSWindow, manualNotesCheckbox: NSButton?) {
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let resolution = Self.discardResolution(
                for: response,
                deleteManualNotes: manualNotesCheckbox.map { $0.state == .on }
            ) else { return }
            Task { @MainActor [weak self] in
                self?.discardMeetingRecording(resolution: resolution)
            }
        }
    }

    static func discardResolution(for response: NSApplication.ModalResponse, deleteManualNotes: Bool?) -> MeetingDiscardResolution? {
        guard response == .alertFirstButtonReturn else { return nil }
        if let deleteManualNotes {
            return deleteManualNotes ? .deleteDraft : .keepManualNotes
        }
        return .discardRecording
    }

    private func confirmationAnchorWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible &&
                !window.isMiniaturized &&
                !(window is NSPanel) &&
                window.canBecomeKey
        } ?? NSApp.windows.first { window in
            window.isVisible &&
                !window.isMiniaturized &&
                window.canBecomeKey
        }
    }

    private func discardMeetingRecording(resolution: MeetingDiscardResolution = .discardRecording) {
        guard let sessionToDiscard = activeMeetingSession else {
            // Fallback recovery: reset indicator if session is nil
            guard !isStartingMeetingRecording else { return }
            indicator.setMeetingRecording(false, config: config)
            if let meetingID = activeMeetingID {
                activeMeetingID = nil
                resolveLiveMeetingAfterDiscard(id: meetingID, resolution: resolution)
            } else {
                finishDiscardMeetingRecording()
            }
            return
        }
        sessionToDiscard.discard()
        self.activeMeetingSession = nil
        indicator.setMeetingRecording(false, config: config)
        if let meetingID = activeMeetingID {
            activeMeetingID = nil
            resolveLiveMeetingAfterDiscard(id: meetingID, resolution: resolution)
        } else {
            finishDiscardMeetingRecording()
        }
    }

    private func finishDiscardMeetingRecording() {
        isStoppingMeetingRecording = false
        endMeetingActivity()
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        setState(.idle)
        statusBarController?.refresh()
        syncAppState()
        updateMeetingNotificationVisibility()
        syncDictationRecorderWarmup(reason: "meeting-discard")
    }

    private func resolveLiveMeetingAfterDiscard(id: Int64, resolution: MeetingDiscardResolution) {
        switch resolution {
        case .keepManualNotes:
            keepManualNotesAfterDiscard(id: id)
        case .deleteDraft:
            deleteManualNotesDraftAfterDiscard(id: id)
        case .discardRecording:
            let manualNotes = manualNotesForLiveMeeting(id: id)
            if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deleteManualNotesDraftAfterDiscard(id: id)
            } else {
                // Defensive fallback: the UI routes manual-note meetings through
                // explicit Keep Notes/Delete Draft choices. If notes appear after
                // the simpler discard alert was built, preserve user-written text.
                keepManualNotesAfterDiscard(id: id)
            }
        }
        finishDiscardMeetingRecording()
    }

    private func deleteManualNotesDraftAfterDiscard(id: Int64) {
        try? dictationStore.deleteMeeting(id: id)
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
        if appState.selectedMeetingID == id {
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
            appState.meetingsNavigationState = .browser
        }
    }

    private func keepManualNotesAfterDiscard(id: Int64) {
        flushCachedMeetingTitle(id: id)
        flushCachedMeetingManualNotes(id: id, sync: false)
        try? dictationStore.updateMeetingStatus(id: id, status: .noteOnly)
        clearCachedMeetingManualNotes(id: id)
        clearCachedMeetingTitle(id: id)
    }

    private func resolveLiveMeetingAfterStartFailure(id: Int64) {
        let manualNotes = manualNotesForLiveMeeting(id: id)
        if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? dictationStore.deleteMeeting(id: id)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
            if appState.selectedMeetingID == id {
                appState.selectedMeetingID = nil
                appState.selectedMeetingRecord = nil
                appState.meetingsNavigationState = .browser
            }
        } else {
            flushCachedMeetingTitle(id: id)
            flushCachedMeetingManualNotes(id: id, sync: false)
            try? dictationStore.updateMeetingStatus(id: id, status: .failed)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
        }
        if activeMeetingID == id {
            activeMeetingID = nil
        }
        syncAppState()
    }

    private func resolveLiveMeetingAfterStopFailure(id: Int64) {
        let manualNotes = manualNotesForLiveMeeting(id: id)
        if manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? dictationStore.deleteMeeting(id: id)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
            if appState.selectedMeetingID == id {
                appState.selectedMeetingID = nil
                appState.selectedMeetingRecord = nil
                appState.meetingsNavigationState = .browser
            }
        } else {
            flushCachedMeetingTitle(id: id)
            flushCachedMeetingManualNotes(id: id, sync: false)
            try? dictationStore.updateMeetingStatus(id: id, status: .failed)
            clearCachedMeetingManualNotes(id: id)
            clearCachedMeetingTitle(id: id)
        }
        syncAppState()
    }

    func stopMeetingRecording() {
        guard !isStoppingMeetingRecording else { return }
        guard let sessionToStop = activeMeetingSession else {
            // Fallback recovery: reset indicator if session is nil
            guard !isStartingMeetingRecording else { return }
            if let activeMeetingID {
                resolveLiveMeetingAfterStopFailure(id: activeMeetingID)
                self.activeMeetingID = nil
            }
            indicator.setMeetingRecording(false, config: config)
            isStoppingMeetingRecording = false
            endMeetingActivity()
            setState(.idle)
            return
        }
        isStoppingMeetingRecording = true
        meetingEndTimer?.invalidate()
        meetingEndTimer = nil
        meetingNotification.close()
        let liveMeetingID = activeMeetingID
        if let liveMeetingID {
            flushCachedMeetingManualNotes(id: liveMeetingID, sync: false)
            try? dictationStore.updateMeetingStatus(id: liveMeetingID, status: .processing)
            syncAppState()
        }
        indicator.setMeetingRecording(false, config: config)
        indicator.setTranscribingTitle("Transcribing", config: config)
        setState(.transcribing)
        sessionToStop.onProgress = { [weak self] stage in
            Task { @MainActor [weak self] in
                self?.setMeetingProcessingStage(stage)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            var meetingTitle = "Meeting"
            var completedMeetingID: Int64?
            var meetingResult: MeetingSessionResult?
            var failedLiveMeetingID: Int64?
            do {
                let result = try await sessionToStop.stop()
                meetingResult = result
                meetingTitle = result.title
                await MainActor.run {
                    self.setMeetingProcessingStatus("Finalizing")
                }
                let persistenceResult = try await MainActor.run {
                    try self.persistCompletedMeetingResultAndDispatchHook(result, existingMeetingID: liveMeetingID)
                }
                completedMeetingID = persistenceResult.meetingID
                if let recordingSaveError = persistenceResult.recordingSaveError {
                    await MainActor.run {
                        self.presentErrorAlert(title: "Meeting Recording", message: recordingSaveError.localizedDescription)
                    }
                }
            } catch {
                fputs("[muesli-native] meeting transcription failed: \(error)\n", stderr)
                let message: String
                if let lifecycleError = error as? MeetingLifecycleError {
                    message = lifecycleError.localizedDescription
                } else {
                    message = error.localizedDescription
                }
                failedLiveMeetingID = liveMeetingID
                await MainActor.run {
                    self.presentErrorAlert(title: "Meeting Recording", message: message)
                }
            }
            await MainActor.run {
                if let failedLiveMeetingID {
                    self.resolveLiveMeetingAfterStopFailure(id: failedLiveMeetingID)
                }
                self.activeMeetingSession = nil
                self.activeMeetingID = nil
                self.isStoppingMeetingRecording = false
                self.endMeetingActivity()
                self.setState(.idle)
                self.meetingMonitor.resumeAfterCooldown()
                self.meetingMonitor.refreshState()
                self.statusBarController?.refresh()
                self.historyWindowController?.reload()
                self.syncAppState()
                self.syncDictationRecorderWarmup(reason: "meeting-stop")
                if let meetingResult {
                    self.cleanupTemporaryMeetingAudioFiles(for: meetingResult)
                }
                TelemetryDeck.signal("meeting.completed")

                self.presentedMeetingCandidate = nil
                let savedMeetingID = completedMeetingID
                self.meetingNotification.show(
                    title: "Transcription complete",
                    subtitle: meetingTitle,
                    actionLabel: "View Notes",
                    onStartRecording: { [weak self] in
                        guard let self else { return }
                        if let savedMeetingID {
                            self.showMeetingDocument(id: savedMeetingID)
                        }
                        self.syncAppState()
                        self.historyWindowController?.show()
                    }
                )
                self.updateMeetingNotificationVisibility()
            }
        }
    }

    func revealMeetingRecordingInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentErrorAlert(
                title: "Recording Not Found",
                message: "The saved meeting recording is no longer available on disk."
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func persistCompletedMeetingResult(_ result: MeetingSessionResult, existingMeetingID: Int64? = nil) throws -> CompletedMeetingPersistenceResult {
        let meetingID: Int64
        var savedRecordingPath: String?
        var recordingSaveError: MeetingLifecycleError?
        do {
            savedRecordingPath = try persistMeetingRecordingIfNeeded(for: result)
        } catch let error as MeetingLifecycleError {
            recordingSaveError = error
        } catch {
            recordingSaveError = .failedToSaveRecording(underlying: error)
        }

        if let existingMeetingID {
            let persistedTitle = completedLiveMeetingTitle(for: result, existingMeetingID: existingMeetingID)
            try dictationStore.completeLiveMeeting(
                id: existingMeetingID,
                title: persistedTitle,
                calendarEventID: result.calendarEventID,
                startTime: result.startTime,
                endTime: result.endTime,
                rawTranscript: result.rawTranscript,
                formattedNotes: result.formattedNotes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: result.templateSnapshot.id,
                selectedTemplateName: result.templateSnapshot.name,
                selectedTemplateKind: result.templateSnapshot.kind,
                selectedTemplatePrompt: result.templateSnapshot.prompt
            )
            meetingID = existingMeetingID
            clearCachedMeetingManualNotes(id: existingMeetingID)
            clearCachedMeetingTitle(id: existingMeetingID)
        } else {
            meetingID = try dictationStore.insertMeeting(
                title: result.title,
                calendarEventID: result.calendarEventID,
                startTime: result.startTime,
                endTime: result.endTime,
                rawTranscript: result.rawTranscript,
                formattedNotes: result.formattedNotes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: result.templateSnapshot.id,
                selectedTemplateName: result.templateSnapshot.name,
                selectedTemplateKind: result.templateSnapshot.kind,
                selectedTemplatePrompt: result.templateSnapshot.prompt
            )
        }
        return CompletedMeetingPersistenceResult(meetingID: meetingID, recordingSaveError: recordingSaveError)
    }

    private func liveMeetingTitle(id: Int64) -> String? {
        if let cached = liveMeetingTitleCache[id] {
            return cached
        }
        return try? dictationStore.meeting(id: id)?.title
    }

    private func activeMeetingDisplayTitle() -> String {
        guard let activeMeetingID,
              let title = liveMeetingTitle(id: activeMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "Meeting"
        }
        return title
    }

    private func completedLiveMeetingTitle(for result: MeetingSessionResult, existingMeetingID: Int64) -> String {
        guard let liveTitle = liveMeetingTitle(id: existingMeetingID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !liveTitle.isEmpty,
              liveTitle != result.originalTitle.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return result.title
        }
        return liveTitle
    }

    func persistCompletedMeetingResultAndDispatchHook(_ result: MeetingSessionResult, existingMeetingID: Int64? = nil) throws -> CompletedMeetingPersistenceResult {
        let persistenceResult = try persistCompletedMeetingResult(result, existingMeetingID: existingMeetingID)
        meetingHookDispatcher.dispatchCompletedMeetingHook(
            meetingID: persistenceResult.meetingID,
            completedAt: result.endTime,
            config: config
        )
        return persistenceResult
    }

    private func persistMeetingRecordingIfNeeded(for result: MeetingSessionResult) throws -> String? {
        let shouldSave: Bool
        switch config.meetingRecordingSavePolicy {
        case .never:
            shouldSave = false
        case .always:
            shouldSave = true
        case .prompt:
            shouldSave = promptToSaveMeetingRecording(for: result.title)
        }

        guard shouldSave else {
            if let retainedRecordingURL = result.retainedRecordingURL {
                try? FileManager.default.removeItem(at: retainedRecordingURL)
            }
            return nil
        }

        if let retainedRecordingError = result.retainedRecordingError {
            throw MeetingLifecycleError.failedToSaveRecording(underlying: retainedRecordingError)
        }

        guard let retainedRecordingURL = result.retainedRecordingURL else {
            return nil
        }

        do {
            let outputURL = try MeetingRecordingWriter.persistTemporaryRecording(
                from: retainedRecordingURL,
                meetingTitle: result.title,
                startedAt: result.startTime,
                supportDirectory: AppIdentity.supportDirectoryURL
            )
            return outputURL.path
        } catch {
            throw MeetingLifecycleError.failedToSaveRecording(underlying: error)
        }
    }

    private func cleanupTemporaryMeetingAudioFiles(for result: MeetingSessionResult) {
        if let retainedRecordingURL = result.retainedRecordingURL {
            try? FileManager.default.removeItem(at: retainedRecordingURL)
        }
        if let systemRecordingURL = result.systemRecordingURL {
            try? FileManager.default.removeItem(at: systemRecordingURL)
        }
    }

    private func cleanupTemporaryDirectory(named directoryName: String, logDescription: String) {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files {
            try? FileManager.default.removeItem(at: file)
        }

        if !files.isEmpty {
            fputs("[muesli-native] cleaned up \(files.count) \(logDescription)\n", stderr)
        }
    }

    private func clearSavedMeetingRecordingsDirectory() throws {
        let recordingsDirectory = AppIdentity.supportDirectoryURL
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return }
        try FileManager.default.removeItem(at: recordingsDirectory)
    }

    private func deleteSavedMeetingRecording(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw MeetingLifecycleError.failedToDeleteRecording(underlying: error)
        }
    }

    private func promptToSaveMeetingRecording(for title: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save meeting recording?"
        alert.informativeText = "Keep a merged audio file for \"\(title)\" so you can inspect it later in Finder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save Recording")
        alert.addButton(withTitle: "Don't Save")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentErrorAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func noteWindowOpened() {
        openWindowCount += 1
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func noteWindowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func setState(_ state: DictationState) {
        dictationState = state
        appState.dictationState = state
        let status: String
        switch state {
        case .idle: status = "Idle"
        case .preparing: status = "Preparing"
        case .recording: status = "Recording"
        case .transcribing: status = "Transcribing"
        }
        statusBarController?.setStatus(status)
        if !isDictationTestMode {
            indicator.setState(state, config: config)
        }
    }

    private var isDictationActivityInProgress: Bool {
        dictationState != .idle || dictationStartedAt != nil || computerUseCommandStartedAt != nil || isNemotronStreaming
    }

    private func configureComputerUseHotkeyMonitor() {
        guard config.enableComputerUseHotkey else {
            computerUseHotkeyMonitor.stop()
            return
        }
        computerUseHotkeyMonitor.configure(keyCode: config.computerUseHotkey.keyCode)
        startComputerUseHotkeyMonitorIfNeeded()
    }

    private func configureHotkeyMonitorTiming() {
        let threshold = config.hotkeyTriggerThresholdMS
        hotkeyMonitor.configureTriggerThreshold(milliseconds: threshold)
        computerUseHotkeyMonitor.configureTriggerThreshold(milliseconds: threshold)
    }

    private func startComputerUseHotkeyMonitorIfNeeded() {
        guard config.enableComputerUseHotkey else {
            computerUseHotkeyMonitor.stop()
            return
        }
        guard config.resolvedOnboardingUseCase.includesDictation else {
            computerUseHotkeyMonitor.stop()
            return
        }
        guard config.computerUseHotkey.keyCode != config.dictationHotkey.keyCode else {
            computerUseHotkeyMonitor.stop()
            fputs("[cua] computer use hotkey disabled because it matches dictation hotkey\n", stderr)
            return
        }
        computerUseHotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        computerUseHotkeyMonitor.targetKeyCode = config.computerUseHotkey.keyCode
        computerUseHotkeyMonitor.start()
    }

    private func beginMeetingActivity(reason: String) {
        guard meetingActivity == nil else { return }
        meetingActivity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiatedAllowingIdleSystemSleep,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled,
            ],
            reason: reason
        )
    }

    private func updateMeetingStartStatus(_ status: String?) {
        meetingStartStatus = status
        appState.isMeetingStarting = isStartingMeetingRecording
        appState.meetingStartStatus = status
    }

    private func endMeetingActivity() {
        guard let activity = meetingActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        meetingActivity = nil
    }

    private func dismissPresentedMeetingDetection() {
        guard let candidate = presentedMeetingCandidate else { return }
        presentedMeetingCandidate = nil
        meetingMonitor.markPromptClosed(candidate)
        if !isShowingCalendarNotification,
           meetingNotification.currentPromptID == candidate.id {
            meetingNotification.close()
        }
    }

    private func updateMeetingNotificationVisibility() {
        meetingMonitor.refreshState()
    }

    private func presentMeetingDetection(_ candidate: MeetingCandidate) {
        guard config.showMeetingDetectionNotification,
              !isShowingCalendarNotification,
              !isMeetingRecording(),
              !isStartingMeetingRecording else { return }

        guard meetingNotification.currentPromptID != candidate.id || !meetingNotification.isVisible else {
            presentedMeetingCandidate = candidate
            return
        }

        let title = candidate.subtitle
        presentedMeetingCandidate = candidate
        let preferredScreen = meetingSourceWindowLocator.screen(for: candidate)
        let didShow = meetingNotification.show(
            promptID: candidate.id,
            title: "Meeting detected",
            subtitle: title,
            preferredScreen: preferredScreen,
            platform: MeetingPlatform(candidate.platform),
            onStartRecording: { [weak self] in
                guard let self else { return }
                if self.startForegroundMeetingRecording(title: title) {
                    self.meetingMonitor.markRecordingStarted(candidate)
                    self.presentedMeetingCandidate = nil
                } else {
                    self.meetingMonitor.refreshState()
                }
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.presentedMeetingCandidate = nil
                self.meetingMonitor.markPromptUserDismissed(candidate)
                self.meetingMonitor.refreshState()
            },
            onAutoDismiss: { [weak self] in
                guard let self else { return }
                self.meetingMonitor.markPromptAutoDismissed(candidate)
                if self.presentedMeetingCandidate == candidate {
                    self.presentedMeetingCandidate = nil
                }
                self.meetingMonitor.refreshState()
            },
            onClose: { [weak self] in
                guard let self, self.presentedMeetingCandidate == candidate else { return }
                self.presentedMeetingCandidate = nil
                self.meetingMonitor.markPromptClosed(candidate)
            }
        )
        if didShow {
            meetingMonitor.markPromptShown(candidate)
        } else if presentedMeetingCandidate == candidate {
            presentedMeetingCandidate = nil
        }
    }

    @MainActor
    private func setMeetingProcessingStage(_ stage: MeetingProcessingStage) {
        switch stage {
        case .transcribingAudio:
            setMeetingProcessingStatus("Transcribing")
        case .cleaningAudio:
            setMeetingProcessingStatus("Cleaning")
        case .generatingTitle:
            setMeetingProcessingStatus("Titling")
        case .summarizingNotes:
            setMeetingProcessingStatus("Summarizing")
        }
    }

    @MainActor
    private func setMeetingProcessingStatus(_ status: String) {
        statusBarController?.setStatus(status)
        statusBarController?.refresh()
        indicator.setTranscribingTitle(status, config: config)
    }

    private func handleComputerUsePrepare() {
        guard canPrepareComputerUseCommand else { return }
        fputs("[cua] prepare\n", stderr)
        meetingMonitor.suppressWhileActive()
        meetingMonitor.refreshState()
        recorder.preferredInputDeviceID = nil
        setState(.preparing)
        do {
            try recorder.prepare()
        } catch {
            fputs("[cua] recorder prepare failed: \(error)\n", stderr)
            recorder.cancel()
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
        }
    }

    private func handleComputerUseStart() {
        guard canStartComputerUseCommand else { return }
        fputs("[cua] recording start\n", stderr)
        meetingMonitor.suppressWhileActive()
        recorder.preferredInputDeviceID = nil
        do {
            try recorder.start()
            computerUseCommandStartedAt = Date()
            indicator.powerProvider = { [weak self] in
                self?.recorder.currentPower() ?? -160
            }
            setState(.recording)
            SoundController.playDictationStart(enabled: shouldPlayDictationLifecycleSounds && !isDictationTestMode)
        } catch {
            fputs("[cua] recorder start failed: \(error)\n", stderr)
            recorder.cancel()
            computerUseCommandStartedAt = nil
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
        }
    }

    private func handleComputerUseToggleStart() {
        guard canStartComputerUseCommand else {
            computerUseHotkeyMonitor.cancelToggleMode()
            return
        }
        fputs("[cua] toggle command start\n", stderr)
        indicator.isToggleDictation = true
        handleComputerUseStart()
    }

    private func handleComputerUseToggleStop() {
        fputs("[cua] toggle command stop\n", stderr)
        indicator.isToggleDictation = false
        handleComputerUseStop()
    }

    private func handleComputerUseCancel() {
        fputs("[cua] cancel\n", stderr)
        computerUseCommandTask?.cancel()
        computerUseCommandTask = nil
        recorder.cancel()
        computerUseCommandStartedAt = nil
        indicator.isToggleDictation = false
        setState(.idle)
        meetingMonitor.resumeAfterCooldown()
    }

    private func handleComputerUseStop() {
        fputs("[cua] stop\n", stderr)
        indicator.isToggleDictation = false
        let startedAt = computerUseCommandStartedAt ?? Date()
        computerUseCommandStartedAt = nil

        guard let wavURL = recorder.stop() else {
            fputs("[cua] stop without wav\n", stderr)
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            return
        }
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        if duration < 0.3 {
            fputs("[cua] discarded short recording\n", stderr)
            try? FileManager.default.removeItem(at: wavURL)
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            return
        }

        indicator.setTranscribingTitle("Parsing command", config: config)
        setState(.transcribing)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            do {
                let result = try await self.transcriptionCoordinator.transcribeDictation(
                    at: wavURL,
                    backend: self.selectedBackend,
                    cohereLanguage: self.config.resolvedCohereLanguage,
                    enablePostProcessor: false,
                    customWords: self.serializedCustomWords(),
                    appContext: nil
                )
                try Task.checkCancellation()
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    TelemetryDeck.signal("computer_use.command_parsed", parameters: [
                        "planner_enabled": self.config.enableComputerUsePlanner ? "true" : "false",
                    ])
                }
                guard !text.isEmpty else {
                    fputs("[cua] empty transcript, skipping planner\n", stderr)
                    await MainActor.run {
                        self.computerUseCommandTask = nil
                        self.setState(.idle)
                        self.meetingMonitor.resumeAfterCooldown()
                    }
                    return
                }
                let commandEndedAt = Date()
                let dictationID = try? self.dictationStore.insertDictation(
                    text: text,
                    durationSeconds: duration,
                    source: "cua",
                    startedAt: startedAt,
                    endedAt: commandEndedAt
                )
                await self.handleComputerUseCommand(transcript: text, dictationID: dictationID)
            } catch is CancellationError {
                fputs("[cua] command parsing cancelled\n", stderr)
                await MainActor.run {
                    self.computerUseCommandTask = nil
                    self.setState(.idle)
                    self.meetingMonitor.resumeAfterCooldown()
                }
            } catch {
                fputs("[cua] transcription failed: \(error)\n", stderr)
                await MainActor.run {
                    self.computerUseCommandTask = nil
                    self.setState(.idle)
                    self.indicator.showWarning("CUA command failed", icon: "!")
                    self.meetingMonitor.resumeAfterCooldown()
                }
            }
        }
        computerUseCommandTask?.cancel()
        computerUseCommandTask = task
    }

    private var canPrepareComputerUseCommand: Bool {
        !isMeetingRecording()
            && !isDictationTestMode
            && dictationStartedAt == nil
            && computerUseCommandStartedAt == nil
            && !isNemotronStreaming
            && dictationState == .idle
    }

    private var canStartComputerUseCommand: Bool {
        !isMeetingRecording()
            && !isDictationTestMode
            && dictationStartedAt == nil
            && computerUseCommandStartedAt == nil
            && !isNemotronStreaming
            && (dictationState == .idle || dictationState == .preparing)
    }

    @MainActor
    private func handleComputerUseCommand(transcript: String, dictationID: Int64?) async {
        resetComputerUseFloatingStatus()
        presentComputerUseTranscript(transcript)
        setState(.transcribing)
        let runtime = ComputerUsePlannerRuntime(config: config) { [weak self] status in
            guard let self else { return }
            self.presentComputerUseFloatingStatus(status)
        }

        let result = await runtime.run(command: transcript)
        indicator.hideComputerUseCursor()
        if result.status == .cancelled {
            computerUseCommandTask = nil
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            TelemetryDeck.signal("computer_use.command_finished", parameters: [
                "status": "\(result.status)",
            ])
            return
        }
        persistComputerUseTrace(result, dictationID: dictationID)
        computerUseCommandTask = nil
        await waitForComputerUseFloatingStatusDwell()
        presentComputerUseRuntimeResult(result)
        meetingMonitor.resumeAfterCooldown()
        TelemetryDeck.signal("computer_use.command_finished", parameters: [
            "status": "\(result.status)",
        ])
    }

    @MainActor
    private func resetComputerUseFloatingStatus() {
        computerUseFloatingStatusWorkItem?.cancel()
        computerUseFloatingStatusWorkItem = nil
        computerUseLastFloatingStatusAt = .distantPast
        computerUseLastFloatingStatus = ""
        computerUseTranscriptVisible = false
    }

    @MainActor
    private func presentComputerUseTranscript(_ transcript: String) {
        computerUseTranscriptVisible = true
        computerUseLastFloatingStatusAt = .distantPast
        computerUseLastFloatingStatus = ""
        indicator.showComputerUseTranscript(transcript, config: config)
    }

    @MainActor
    private func presentComputerUseFloatingStatus(_ status: String) {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        statusBarController?.setStatus(trimmed)
        guard dictationState == .transcribing else { return }
        guard let floatingStatus = computerUseFloatingStatusLabel(for: trimmed) else { return }
        if computerUseTranscriptVisible && !shouldReplaceComputerUseTranscript(with: floatingStatus) {
            return
        }
        guard floatingStatus != computerUseLastFloatingStatus else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(computerUseLastFloatingStatusAt)
        if shouldShowComputerUseStatusImmediately(floatingStatus, elapsed: elapsed) {
            computerUseFloatingStatusWorkItem?.cancel()
            computerUseFloatingStatusWorkItem = nil
            applyComputerUseFloatingStatus(floatingStatus, at: now)
            return
        }

        let delay = max(0.08, computerUseFloatingStatusMinimumDwell - elapsed)
        computerUseFloatingStatusWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.dictationState == .transcribing else { return }
                self.applyComputerUseFloatingStatus(floatingStatus, at: Date())
                self.computerUseFloatingStatusWorkItem = nil
            }
        }
        computerUseFloatingStatusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @MainActor
    private func computerUseFloatingStatusLabel(for status: String) -> String? {
        if status.hasPrefix("Planning step") {
            return computerUseLastFloatingStatus.isEmpty ? "Thinking..." : nil
        }
        if status == "Observing screen" {
            return "Reading screen"
        }
        if status == "Screen fallback" {
            return "Using screen"
        }
        if status == "Retrying planner" {
            return "Retrying"
        }
        return status
    }

    @MainActor
    private func shouldShowComputerUseStatusImmediately(_ status: String, elapsed: TimeInterval) -> Bool {
        guard !computerUseLastFloatingStatus.isEmpty else { return true }
        if elapsed >= computerUseFloatingStatusMinimumDwell { return true }
        if status == "Done" || status == "Failed" || status == "Confirm" { return true }
        if computerUseLastFloatingStatus == "Thinking...", elapsed >= 0.25 {
            return true
        }
        if isConcreteComputerUseFloatingStatus(status) {
            return elapsed >= 0.2
        }
        return false
    }

    @MainActor
    private func shouldReplaceComputerUseTranscript(with status: String) -> Bool {
        if status == "Thinking..." || status == "Reading screen" {
            return false
        }
        return true
    }

    @MainActor
    private func isConcreteComputerUseFloatingStatus(_ status: String) -> Bool {
        status.hasPrefix("Opening")
            || status.hasPrefix("Opened")
            || status.hasPrefix("Clicked")
            || status.hasPrefix("Typed")
            || status.hasPrefix("Navigated")
            || status == "Navigating"
            || status == "Typing"
            || status == "Moving cursor"
            || status.hasPrefix("Moving to")
            || status == "Clicking"
            || status == "Scrolling"
            || status == "Pressing key"
            || status == "Using screen"
    }

    @MainActor
    private func applyComputerUseFloatingStatus(_ status: String, at date: Date) {
        computerUseTranscriptVisible = false
        computerUseLastFloatingStatus = status
        computerUseLastFloatingStatusAt = date
        indicator.setTranscribingTitle(status, config: config)
    }

    @MainActor
    private func waitForComputerUseFloatingStatusDwell() async {
        computerUseFloatingStatusWorkItem?.cancel()
        computerUseFloatingStatusWorkItem = nil
        let elapsed = Date().timeIntervalSince(computerUseLastFloatingStatusAt)
        let remaining = computerUseLastFloatingStatus.isEmpty
            ? 0
            : computerUseFloatingStatusMinimumDwell - elapsed
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    private func persistComputerUseTrace(_ result: ComputerUsePlannerRuntimeResult, dictationID: Int64?) {
        guard let dictationID else { return }
        try? dictationStore.insertComputerUseTrace(
            dictationID: dictationID,
            finalStatus: computerUseTraceStatus(result.status),
            finalMessage: result.message,
            events: result.traceEvents
        )
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    private func computerUseTraceStatus(_ status: ComputerUsePlannerRuntimeResult.Status) -> String {
        switch status {
        case .done:
            return "done"
        case .timedOut:
            return "timed_out"
        case .needsConfirmation:
            return "confirm"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        }
    }

    private func presentComputerUseRuntimeResult(_ result: ComputerUsePlannerRuntimeResult) {
        setState(.idle)
        let message: String
        let floatingMessage: String
        let icon: String
        switch result.status {
        case .done:
            message = result.message.hasPrefix("Done") ? result.message : "Done: \(result.message)"
            floatingMessage = "Done"
            icon = ""
        case .timedOut:
            message = result.message
            floatingMessage = "Timed out"
            icon = "!"
        case .needsConfirmation:
            message = result.message.hasPrefix("Confirm") ? result.message : "Confirm: \(result.message)"
            floatingMessage = "Confirm"
            icon = "!"
        case .failed:
            message = result.message
            floatingMessage = "Failed"
            icon = "!"
        case .cancelled:
            message = result.message
            floatingMessage = "Cancelled"
            icon = ""
        }
        statusBarController?.setStatus(message)
        indicator.showWarning(floatingMessage, icon: icon, duration: 3.0)
    }

    private func handlePrepare() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] prepare\n", stderr)
        if dictationLatencyTraceID == nil {
            beginDictationLatencyTrace(reason: "prepare")
        }
        markDictationLatency("prepare_requested")
        guard selectedBackend.backend != "nemotron" else {
            return
        }
        if !dictationAudioSessionManager.hasActiveSession {
            meetingMonitor.suppressWhileActive()
            meetingMonitor.refreshState()
            setState(.preparing)
        }
    }

    private func handleArm() {
        if isMeetingRecording() { return }
        if dictationLatencyTraceID == nil {
            beginDictationLatencyTrace(reason: "hotkey")
        }
        if selectedBackend.backend != "nemotron" {
            setState(.preparing)
            meetingMonitor.suppressWhileActive()
            meetingMonitor.refreshState()
            dictationAudioSessionManager.arm(source: "hotkey_arm")
        }
    }

    private var defaultDictationOutputMode: DictationOutputMode {
        config.resolvedOnboardingUseCase.includesVoiceNotes ? .voiceNote : .paste
    }

    private func beginDictationOutput(mode: DictationOutputMode? = nil) {
        currentDictationOutputMode = mode ?? defaultDictationOutputMode
        appState.isVoiceNoteRecording = currentDictationOutputMode == .voiceNote
    }

    private func resetDictationOutputMode() {
        currentDictationOutputMode = .paste
        appState.isVoiceNoteRecording = false
    }

    private var canPrimeDictationRecorder: Bool {
        config.hasCompletedOnboarding
            && hasStarted
            && config.resolvedOnboardingUseCase.includesPushToTalk
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && dictationState == .idle
            && computerUseCommandStartedAt == nil
            && !isMeetingRecording()
            && !isStartingMeetingRecording
            && !isStoppingMeetingRecording
    }

    private func coolDownDictationRecorder(reason: String) {
        dictationAudioSessionManager.coolDown(reason: reason)
    }

    private func syncDictationRecorderWarmup(reason: String, delay: TimeInterval = 0) {
        dictationAudioSessionManager.refreshRoute(
            reason: reason,
            delay: delay,
            canWarmUp: canPrimeDictationRecorder && selectedBackend.backend != "nemotron"
        )
    }

    private func beginDictationLatencyTrace(reason: String) {
        dictationLatencyTraceID = UUID()
        dictationLatencyTraceStartedAt = Date()
        markDictationLatency("trace_begin:\(reason)")
    }

    private func markDictationLatency(_ event: String) {
        markDictationLatency(event, at: Date())
    }

    private func markDictationLatency(_ event: String, at date: Date) {
        guard let traceID = dictationLatencyTraceID,
              let startedAt = dictationLatencyTraceStartedAt else { return }
        let elapsedMS = Int(date.timeIntervalSince(startedAt) * 1000)
        let timestamp = dictationLatencyTimestampFormatter.string(from: date)
        let routeKind = dictationAudioRoutingController.currentOutputRouteKindForDebug()
        let routeDescription = dictationAudioRoutingController.currentRouteDebugDescription()
        let line = "[dictation-latency] ts=\(timestamp) id=\(traceID.uuidString) event=\(event) elapsed_ms=\(elapsedMS) profile=\(dictationLatencyProfile(routeKind: routeKind)) \(routeDescription)"
        fputs("\(line)\n", stderr)
        appendDictationLatencyLog(line)
    }

    private func dictationLatencyProfile(routeKind: AudioOutputRouteKind) -> String {
        switch routeKind {
        case .speakerLike:
            return "speaker"
        case .headphoneLike:
            return "headphone"
        case .unknown:
            return "unknown"
        }
    }

    private func appendDictationLatencyLog(_ line: String) {
        dictationLatencyLogWriter.append(line)
    }

    private func finishDictationLatencyTrace(_ event: String) {
        markDictationLatency(event)
        dictationLatencyTraceID = nil
        dictationLatencyTraceStartedAt = nil
    }

    private func cachedPreferredDictationInputDeviceID() -> AudioObjectID? {
        dictationAudioRoutingController.cachedPreferredInputDeviceIDForDictation()
    }

    private var shouldPlayDictationLifecycleSounds: Bool {
        config.soundEnabled && !dictationAudioRoutingController.isDefaultOutputHeadphoneLike()
    }

    private func handleDictationAudioSessionEvent(_ event: DictationAudioSessionEvent) {
        switch event {
        case .armed:
            break
        case .acquiringAudio:
            markDictationLatency("acquiring_audio")
        case .streamActive(_, let capturedAt):
            handleDictationStreamActive(capturedAt: capturedAt)
        case .speechDetected(_, let capturedAt):
            handleDictationSpeechDetected(capturedAt: capturedAt)
        case .noAudioTimeout:
            statusBarController?.setStatus("Mic waiting for speech")
        case .stopped(let eventSessionID, let wavURL):
            guard pendingDictationStopSessionID == eventSessionID else {
                fputs("[muesli-native] ignoring stale stopped event\n", stderr)
                if let wavURL {
                    try? FileManager.default.removeItem(at: wavURL)
                }
                break
            }
            guard dictationAudioSessionManager.currentSessionID == nil else {
                fputs("[muesli-native] ignoring stopped event while a new session is active\n", stderr)
                if let wavURL {
                    try? FileManager.default.removeItem(at: wavURL)
                }
                break
            }
            let startedAt = pendingDictationStopStartedAt ?? dictationStartedAt ?? Date()
            pendingDictationStopSessionID = nil
            pendingDictationStopStartedAt = nil
            finishStandardDictationStop(wavURL: wavURL, startedAt: startedAt)
        case .audioRestored(let eventSessionID):
            guard pendingReleaseSoundSessionID == eventSessionID else { break }
            pendingReleaseSoundSessionID = nil
            guard dictationAudioSessionManager.currentSessionID == nil else { break }
            // Reuse the insert cue as the hotkey-release cue once ducked audio has
            // been restored; waiting for transcription would make release feedback lag.
            SoundController.playDictationInsert(enabled: shouldPlayDictationLifecycleSounds)
        case .cancelled:
            break
        case .failed(_, let error):
            fputs("[muesli-native] recorder start failed: \(error)\n", stderr)
            resetDictationOutputMode()
            dictationStartedAt = nil
            pendingDictationStopSessionID = nil
            pendingDictationStopStartedAt = nil
            pendingReleaseSoundSessionID = nil
            capturedDictationContext = nil
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            finishDictationLatencyTrace("audio_session_failed")
        case .latency(let event, let date):
            markDictationLatency(event, at: date)
        }
    }

    private func handleDictationStreamActive(capturedAt: Date) {
        if dictationStartedAt == nil {
            dictationStartedAt = capturedAt
        }
        capturedDictationContext = nil
        if hotkeyMonitor.isToggleRecording {
            setState(.recording)
            indicator.setToggleDictation(true, config: config)
            indicator.setRecordingWaveformLevel(config: config)
        } else {
            setState(.recording)
            indicator.setRecordingWaveformLevel(config: config)
        }
        if !isDictationTestMode {
            indicator.powerProvider = { [weak self] in
                self?.dictationAudioSessionManager.currentPower() ?? -160
            }
        }
        markDictationLatency("sound_start_requested:stream-active")
        SoundController.playDictationStart(enabled: shouldPlayDictationLifecycleSounds && !isDictationTestMode)
        markDictationLatency("ui_stream_active")
        logDictationPowerSample(label: "ui_power_sample_350ms", delay: 0.35)
        logDictationPowerSample(label: "ui_power_sample_1000ms", delay: 1.0)
        if isDictationTestMode {
            dictationTestRecordingStarted?()
        }
        if shouldCaptureDictationContext {
            captureDictationContextAsync()
        }
    }

    private func handleDictationSpeechDetected(capturedAt: Date) {
        markDictationLatency("ui_speech_active", at: capturedAt)
    }

    private func logDictationPowerSample(label: String, delay: TimeInterval) {
        let traceID = dictationLatencyTraceID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, traceID] in
            guard let self,
                  self.dictationLatencyTraceID == traceID,
                  self.dictationState == .recording else { return }
            let power = Int(self.dictationAudioSessionManager.currentPower().rounded())
            self.markDictationLatency("\(label)_db:\(power)")
        }
    }

    private var shouldCaptureDictationContext: Bool {
        config.enableScreenContext && config.enablePostProcessor && !isDictationTestMode
    }

    private func captureDictationContextAsync() {
        guard shouldCaptureDictationContext else { return }
        let traceID = dictationLatencyTraceID
        markDictationLatency("context_capture_enqueue")
        DispatchQueue.global(qos: .utility).async { [weak self, traceID] in
            guard CGPreflightScreenCaptureAccess() else { return }
            let context = DictationContextCapture.capture()
            DispatchQueue.main.async { [weak self, traceID] in
                guard let self,
                      self.dictationLatencyTraceID == traceID,
                      self.shouldCaptureDictationContext,
                      self.dictationState == .recording else { return }
                self.capturedDictationContext = context
                self.markDictationLatency("context_capture_ready")
            }
        }
    }

    private func handleStart() {
        if isMeetingRecording() { return }

        // Nemotron is handsfree-only — block hold-to-talk and show a hint
        if selectedBackend.backend == "nemotron" {
            dictationAudioSessionManager.cancel(reason: "nemotron-hold-blocked")
            fputs("[muesli-native] hold-to-talk blocked for Nemotron, showing warning\n", stderr)
            indicator.showWarning("Double-tap for Nemotron handsfree mode", icon: "⚡")
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            meetingMonitor.refreshState()
            finishDictationLatencyTrace("nemotron_hold_blocked")
            return
        }

        fputs("[muesli-native] recording start\n", stderr)
        meetingMonitor.suppressWhileActive()
        beginDictationOutput()
        dictationStartedAt = nil
        capturedDictationContext = nil
        setState(.preparing)
        dictationAudioSessionManager.beginRecording(
            mode: "hold-start",
            duckingEnabled: config.muteSystemAudioDuringDictation,
            mediaPauseEnabled: config.pauseMediaDuringDictation
        )
    }

    @available(macOS 15, *)
    private func startNemotronStreamingAsync(
        sessionID: UUID
    ) {
        Task {
            let transcriber = await transcriptionCoordinator.getNemotronTranscriber()
            fputs("[muesli-native] got Nemotron transcriber\n", stderr)

            await MainActor.run {
                guard self.isNemotronStreaming, self.nemotronStreamingSessionID == sessionID else {
                    fputs("[muesli-native] Nemotron session cancelled before transcriber ready\n", stderr)
                    return
                }
                let currentPreferredInputDeviceID =
                    self.dictationAudioRoutingController.cachedPreferredInputDeviceIDForDictation()
                let controller = StreamingDictationController(
                    transcriber: transcriber,
                    preferredInputDeviceID: currentPreferredInputDeviceID
                )
                controller.onPartialText = { [weak self] fullText in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        guard self.isNemotronStreaming, self.nemotronStreamingSessionID == sessionID else { return }
                        let delta = String(fullText.dropFirst(self.previousStreamText.count))
                        fputs("[muesli-native] streaming partial: +\"\(delta)\" (total \(fullText.count) chars)\n", stderr)
                        if !delta.isEmpty {
                            self.previousStreamText = fullText
                            if self.currentDictationOutputMode != .voiceNote {
                                PasteController.typeText(delta)
                            }
                        }
                    }
                }
                controller.onFailure = { [weak self] error in
                    DispatchQueue.main.async {
                        self?.handleNemotronStreamingRuntimeFailure(error: error, sessionID: sessionID)
                    }
                }
                self._streamingDictationController = controller
                guard controller.start() else {
                    self.handleNemotronStreamingStartFailure()
                    return
                }
                fputs("[muesli-native] Nemotron streaming controller started\n", stderr)
            }
        }
    }

    @MainActor
    private func handleNemotronStreamingStartFailure() {
        fputs("[muesli-native] Nemotron streaming controller failed to start\n", stderr)
        isNemotronStreaming = false
        _streamingDictationController = nil
        nemotronStreamingSessionID = nil
        previousStreamText = ""
        dictationStartedAt = nil
        dictationAudioSessionManager.endExternalSession(reason: "nemotron-start-failed")
        indicator.setToggleDictation(false, config: config)
        resetDictationOutputMode()
        setState(.idle)
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        finishDictationLatencyTrace("nemotron_start_failed")
        syncDictationRecorderWarmup(reason: "nemotron-start-failed")
    }

    @MainActor
    private func handleNemotronStreamingRuntimeFailure(error: Error, sessionID: UUID) {
        guard isNemotronStreaming, nemotronStreamingSessionID == sessionID else { return }
        fputs("[muesli-native] Nemotron streaming failed after mic start: \(error)\n", stderr)
        isNemotronStreaming = false
        _streamingDictationController = nil
        nemotronStreamingSessionID = nil
        previousStreamText = ""
        dictationStartedAt = nil
        dictationAudioSessionManager.endExternalSession(reason: "nemotron-runtime-failed")
        indicator.setToggleDictation(false, config: config)
        resetDictationOutputMode()
        setState(.idle)
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        finishDictationLatencyTrace("nemotron_runtime_failed")
        syncDictationRecorderWarmup(reason: "nemotron-runtime-failed")
    }

    private func handleCancel() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] cancel\n", stderr)
        resetDictationOutputMode()

        if isNemotronStreaming {
            isNemotronStreaming = false
            if #available(macOS 15, *), let sdc = _streamingDictationController as? StreamingDictationController {
                sdc.cancel()
            }
            _streamingDictationController = nil
            nemotronStreamingSessionID = nil
            previousStreamText = ""
        }

        dictationAudioSessionManager.cancel(reason: "user-cancel")
        capturedDictationContext = nil
        dictationStartedAt = nil
        pendingDictationStopSessionID = nil
        pendingDictationStopStartedAt = nil
        pendingReleaseSoundSessionID = nil
        setState(.idle)
        meetingMonitor.resumeAfterCooldown()
        meetingMonitor.refreshState()
        finishDictationLatencyTrace("cancelled")
        syncDictationRecorderWarmup(reason: "cancel")
    }

    private func handleToggleStart(outputMode: DictationOutputMode? = nil) {
        if isMeetingRecording() { return }
        fputs("[muesli-native] toggle dictation start\n", stderr)
        if dictationLatencyTraceID == nil {
            beginDictationLatencyTrace(reason: "toggle")
        }
        markDictationLatency("toggle_start")
        meetingMonitor.suppressWhileActive()
        beginDictationOutput(mode: outputMode)
        dictationStartedAt = nil
        setState(.preparing)

        // Nemotron streaming: live text at cursor in handsfree mode too
        if selectedBackend.backend == "nemotron" {
            if #available(macOS 15, *) {
                let sessionID = UUID()
                isNemotronStreaming = true
                nemotronStreamingSessionID = sessionID
                previousStreamText = ""
                dictationStartedAt = Date()
                markDictationLatency("sound_start_requested:nemotron-toggle")
                SoundController.playDictationStart(enabled: shouldPlayDictationLifecycleSounds && !isDictationTestMode)
                setState(.recording)
                indicator.setToggleDictation(true, config: config)
                dictationAudioSessionManager.beginExternalSession(
                    source: "nemotron-toggle",
                    duckingEnabled: config.muteSystemAudioDuringDictation,
                    mediaPauseEnabled: config.pauseMediaDuringDictation
                )
                meetingMonitor.refreshState()
                fputs("[muesli-native] Nemotron streaming toggle mode active\n", stderr)
                startNemotronStreamingAsync(
                    sessionID: sessionID
                )
                return
            }
        }

        dictationAudioSessionManager.beginRecording(
            mode: "toggle",
            duckingEnabled: config.muteSystemAudioDuringDictation,
            mediaPauseEnabled: config.pauseMediaDuringDictation
        )
    }

    private func handleToggleStop() {
        fputs("[muesli-native] toggle dictation stop\n", stderr)
        indicator.isToggleDictation = false
        handleStop()
    }

    func toggleVoiceNoteRecording() {
        if dictationStartedAt != nil || dictationAudioSessionManager.hasActiveSession || isNemotronStreaming {
            handleToggleStop()
        } else if dictationState == .idle {
            handleToggleStart(outputMode: .voiceNote)
        }
    }

    private func handleStop() {
        if isMeetingRecording() {
            cancelDictationAudioSessionForMeetingRecordingIfNeeded()
            return
        }
        fputs("[muesli-native] stop\n", stderr)
        let startedAt = dictationStartedAt ?? Date()
        dictationStartedAt = nil

        // Nemotron streaming: text already typed — just finalize and store
        if isNemotronStreaming {
            let sessionID = nemotronStreamingSessionID
            if #available(macOS 15, *), let controller = _streamingDictationController as? StreamingDictationController {
                controller.stop { [weak self] finalText in
                    DispatchQueue.main.async {
                        self?.finishNemotronStreamingStop(
                            finalText: finalText,
                            startedAt: startedAt,
                            sessionID: sessionID
                        )
                    }
                }
            } else {
                fputs("[muesli-native] Nemotron streaming stop, controller not ready (short press)\n", stderr)
                finishNemotronStreamingStop(
                    finalText: "",
                    startedAt: startedAt,
                    sessionID: sessionID
                )
            }
            dictationAudioSessionManager.endExternalSession(reason: "nemotron-stop")
            setState(.transcribing)
            return
        }

        markDictationLatency("sound_release_requested:stop")
        pendingDictationStopSessionID = dictationAudioSessionManager.currentSessionID
        pendingReleaseSoundSessionID = shouldPlayDictationLifecycleSounds && !isDictationTestMode
            ? pendingDictationStopSessionID
            : nil
        pendingDictationStopStartedAt = startedAt
        dictationAudioSessionManager.stop()
    }

    private func cancelDictationAudioSessionForMeetingRecordingIfNeeded() {
        guard dictationAudioSessionManager.hasActiveSession || isNemotronStreaming else { return }
        fputs("[muesli-native] cancelling dictation audio session because meeting is active\n", stderr)

        if isNemotronStreaming {
            isNemotronStreaming = false
            if #available(macOS 15, *), let controller = _streamingDictationController as? StreamingDictationController {
                controller.cancel()
            }
            _streamingDictationController = nil
            nemotronStreamingSessionID = nil
            previousStreamText = ""
            indicator.setToggleDictation(false, config: config)
            dictationAudioSessionManager.endExternalSession(reason: "meeting-active")
        } else {
            dictationAudioSessionManager.cancel(reason: "meeting-active")
        }

        dictationStartedAt = nil
        capturedDictationContext = nil
        pendingDictationStopSessionID = nil
        pendingDictationStopStartedAt = nil
        pendingReleaseSoundSessionID = nil
        resetDictationOutputMode()
        setState(.idle)
        if activeMeetingID != nil || isStartingMeetingRecording || isMeetingRecording() {
            meetingMonitor.suppressWhileActive()
        } else {
            meetingMonitor.resumeAfterCooldown()
        }
        meetingMonitor.refreshState()
        finishDictationLatencyTrace("meeting_active_cancel")
        syncDictationRecorderWarmup(reason: "meeting-active")
    }

    private func finishNemotronStreamingStop(
        finalText: String,
        startedAt: Date,
        sessionID: UUID?
    ) {
        guard isNemotronStreaming, nemotronStreamingSessionID == sessionID else {
            fputs("[muesli-native] ignoring stale Nemotron stop completion\n", stderr)
            return
        }
        isNemotronStreaming = false
        _streamingDictationController = nil
        nemotronStreamingSessionID = nil
        previousStreamText = ""
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        fputs("[muesli-native] Nemotron streaming stop, got \(finalText.count) chars\n", stderr)
        let cleaned = FillerWordFilter.apply(finalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !config.maraudersMapUnlocked { checkMaraudersMapActivation(cleaned) }

        if !cleaned.isEmpty {
            _ = try? dictationStore.insertDictation(
                text: cleaned,
                durationSeconds: duration,
                startedAt: startedAt,
                endedAt: Date()
            )
        }

        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
        resetDictationOutputMode()
        setState(.idle)
        meetingMonitor.resumeAfterCooldown()
        fputs("[muesli-native] Nemotron streaming done (\(String(format: "%.1f", duration))s)\n", stderr)
        finishDictationLatencyTrace("nemotron_stop")
        syncDictationRecorderWarmup(reason: "nemotron-stop")
    }

    private func finishStandardDictationStop(wavURL stoppedWavURL: URL?, startedAt: Date) {
        markDictationLatency("stop_finished")
        guard let wavURL = stoppedWavURL else {
            fputs("[muesli-native] stop without wav\n", stderr)
            resetDictationOutputMode()
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            finishDictationLatencyTrace("stop_without_wav")
            syncDictationRecorderWarmup(reason: "stop-without-wav")
            return
        }
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        if duration < 0.3 {
            fputs("[muesli-native] discarded short recording\n", stderr)
            try? FileManager.default.removeItem(at: wavURL)
            if isDictationTestMode {
                dictationTestCallback?("")
            }
            resetDictationOutputMode()
            setState(.idle)
            meetingMonitor.resumeAfterCooldown()
            finishDictationLatencyTrace("short_recording")
            syncDictationRecorderWarmup(reason: "short-recording")
            return
        }

        setState(.transcribing)
        finishDictationLatencyTrace("ready_for_transcription")
        syncDictationRecorderWarmup(reason: "dictation-stop")
        let isTestMode = isDictationTestMode
        let outputMode = currentDictationOutputMode
        let transcriptionBackend = isTestMode ? (dictationTestBackend ?? selectedBackend) : selectedBackend
        let transcriptionLanguage = isTestMode ? (dictationTestCohereLanguage ?? config.resolvedCohereLanguage) : config.resolvedCohereLanguage
        let capturedContext = capturedDictationContext
        let promptContext = capturedContext.map { DictationContextCapture.formatForPrompt($0) }
        let storageContext = capturedContext.map { DictationContextCapture.formatForStorage($0) } ?? ""
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            do {
                let result = try await self.transcriptionCoordinator.transcribeDictation(
                    at: wavURL,
                    backend: transcriptionBackend,
                    cohereLanguage: transcriptionLanguage,
                    enablePostProcessor: self.isPostProcessorReady,
                    customWords: self.serializedCustomWords(),
                    appContext: promptContext
                )
                // Drop result if test was cancelled (user navigated away)
                try Task.checkCancellation()
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Test mode: route result to callback, skip history/paste
                if isTestMode {
                    await MainActor.run {
                        self.dictationTestCallback?(text)
                        self.resetDictationOutputMode()
                        self.setState(.idle)
                        self.meetingMonitor.resumeAfterCooldown()
                        self.syncDictationRecorderWarmup(reason: "transcription-complete")
                    }
                    return
                }

                if !self.config.maraudersMapUnlocked {
                    await MainActor.run { self.checkMaraudersMapActivation(text) }
                }
                guard !text.isEmpty else {
                    await MainActor.run {
                        self.resetDictationOutputMode()
                        self.setState(.idle)
                        self.meetingMonitor.resumeAfterCooldown()
                        self.syncDictationRecorderWarmup(reason: "transcription-complete")
                    }
                    return
                }
                _ = try? self.dictationStore.insertDictation(
                    text: text,
                    durationSeconds: duration,
                    appContext: storageContext,
                    startedAt: startedAt,
                    endedAt: Date()
                )
                await MainActor.run {
                    self.capturedDictationContext = nil
                    self.statusBarController?.refresh()
                    self.historyWindowController?.reload()
                    self.syncAppState()
                    if outputMode != .voiceNote {
                        PasteController.paste(text: text)
                    }
                    self.resetDictationOutputMode()
                    self.setState(.idle)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.syncDictationRecorderWarmup(reason: "transcription-complete")
                    TelemetryDeck.signal("dictation.completed", parameters: [
                        "backend": self.selectedBackend.backend,
                        "paste_method": outputMode.pasteMethod,
                    ])
                }
            } catch is CancellationError {
                fputs("[muesli-native] test dictation cancelled\n", stderr)
                await MainActor.run {
                    self.resetDictationOutputMode()
                    self.setState(.idle)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.syncDictationRecorderWarmup(reason: "transcription-cancelled")
                }
            } catch {
                fputs("[muesli-native] transcription failed: \(error)\n", stderr)
                await MainActor.run {
                    if self.isDictationTestMode {
                        self.dictationTestFailureCallback?(self.userFacingDictationTestError(error))
                    }
                    self.resetDictationOutputMode()
                    self.setState(.idle)
                    self.meetingMonitor.resumeAfterCooldown()
                    self.syncDictationRecorderWarmup(reason: "transcription-failed")
                }
            }
        }
        if isTestMode { dictationTestTask = task }
    }

    private func userFacingDictationTestError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "MuesliTranscriptionRuntime" {
            switch nsError.code {
            case 1:
                return "Nemotron requires macOS 15 or later. Choose another model to test dictation."
            case 2:
                return "Qwen3 ASR requires macOS 15 or later. Choose another model to test dictation."
            case 3:
                return "Canary Qwen requires macOS 15 or later. Choose another model to test dictation."
            case 4:
                return "Cohere Transcribe requires macOS 15 or later. Choose another model to test dictation."
            default:
                return "The selected model is not available. Choose another model and try again."
            }
        }

        let rawMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedMessage = rawMessage.lowercased()

        if lowercasedMessage.contains("not loaded") || lowercasedMessage.contains("loadmodels") {
            return "The model was not ready yet. We are preparing it again, then try once more."
        }
        if lowercasedMessage.contains("network") || lowercasedMessage.contains("internet") || lowercasedMessage.contains("timed out") {
            return "The model could not finish downloading. Check your connection and retry."
        }
        if lowercasedMessage.contains("permission") || lowercasedMessage.contains("microphone") {
            return "Muesli could not access the microphone. Check Microphone permission and try again."
        }
        return "Dictation could not start. Try again in a moment."
    }

    // MARK: - Marauder's Map

    private func checkMaraudersMapActivation(_ text: String) {
        guard !config.maraudersMapUnlocked else { return }
        guard MaraudersMapDetector.containsActivationPhrase(text) else { return }

        fputs("[muesli-native] Marauder's Map unlocked!\n", stderr)
        updateConfig { $0.maraudersMapUnlocked = true }
        SoundController.playMaraudersMapUnlock()
        indicator.showWarning("Mischief Managed", icon: "\u{26A1}", duration: 3.0)
        startMaraudersMapMonitoring()
    }

    private func startMaraudersMapMonitoring() {
        guard config.maraudersMapUnlocked else { return }

        let countdown = MaraudersMapCountdownController()
        self.maraudersMapCountdown = countdown

        countdown.startMonitoring(
            eventProvider: { [weak self] in
                guard let self else { return nil }
                let now = Date()
                let hidden = self.appState.hiddenCalendarEventIDs
                guard let event = self.appState.upcomingCalendarEvents
                    .filter({ !$0.isAllDay && $0.startDate > now && !hidden.contains($0.id) })
                    .min(by: { $0.startDate < $1.startDate }) else { return nil }
                return (id: event.id, title: event.title, startDate: event.startDate)
            },
            audioClipID: config.maraudersMapAudioClip,
            customAudioPath: config.maraudersMapCustomAudioPath,
            onStatusBarUpdate: { [weak self] text in
                self?.statusBarController?.setCountdownOverride(text)
            },
            onCountdownFinished: { [weak self] info in
                guard let self, !self.isMeetingRecording() else { return }
                // Cancel any scheduled "starting now" timer for this event.
                // Match by event ID prefix so deleted/cancelled events (no longer
                // in upcomingCalendarEvents) still get their timers cancelled.
                let prefix = "\(info.id)|"
                let matchingTimerKeys = self.meetingStartingNowTimers.keys.filter { $0.hasPrefix(prefix) }
                for key in matchingTimerKeys {
                    guard let timer = self.meetingStartingNowTimers[key] else { continue }
                    timer.invalidate()
                    self.meetingStartingNowTimers.removeValue(forKey: key)
                }
                let event = self.appState.upcomingCalendarEvents.first(where: { $0.id == info.id })
                // Reuse the same notification method as the timer path
                self.showMeetingStartingNowNotification(
                    title: info.title,
                    calendarEventID: info.id,
                    meetingURL: event?.meetingURL,
                    endDate: event?.endDate
                )
            }
        )
    }

    func updateMaraudersMapAudioClip() {
        maraudersMapCountdown?.updateAudioClip(config.maraudersMapAudioClip, customPath: config.maraudersMapCustomAudioPath)
    }

    func resetMaraudersMap() {
        maraudersMapCountdown?.stopMonitoring()
        maraudersMapCountdown = nil
        updateConfig {
            $0.maraudersMapUnlocked = false
            $0.maraudersMapAudioClip = "bbc_world_news"
            $0.maraudersMapCustomAudioPath = nil
        }
    }

    private func handleUpcomingMeeting(_ event: UpcomingMeetingEvent) {
        // Look up end date and meeting URL from unified calendar events
        let calendarEvent = appState.upcomingCalendarEvents
            .first(where: { $0.id == event.id })
        let calendarEndDate = calendarEvent?.endDate
        let meetingURL = event.meetingURL ?? calendarEvent?.meetingURL

        if config.autoRecordMeetings, !isMeetingRecording() {
            startMeetingRecording(title: event.title, calendarEventID: event.id, openDocument: true, endDate: calendarEndDate)
            return
        }

        // Show notification panel for calendar events (if not auto-recording)
        guard config.showScheduledMeetingNotifications,
              !isMeetingRecording(),
              !isStartingMeetingRecording else {
            return
        }
        isShowingCalendarNotification = true

        let minutesUntil = Int(ceil(event.startDate.timeIntervalSinceNow / 60))
        let timeLabel: String
        if minutesUntil > 0 {
            timeLabel = "starts in \(minutesUntil) min"
        } else if minutesUntil == 0 {
            timeLabel = "starting now"
        } else {
            timeLabel = "started \(abs(minutesUntil)) min ago"
        }

        let title = event.title
        meetingNotification.show(
            title: "Upcoming meeting",
            subtitle: "\(title) · \(timeLabel)",
            meetingURL: meetingURL,
            onStartRecording: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.startForegroundMeetingRecording(title: title, calendarEventID: event.id, endDate: calendarEndDate)
            },
            onJoinAndRecord: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinAndRecord(title: title, meetingURL: meetingURL!, endDate: calendarEndDate, calendarEventID: event.id)
            } : nil,
            onJoinOnly: meetingURL != nil ? { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                self.joinOnly(meetingURL: meetingURL!, endDate: calendarEndDate)
            } : nil,
            onDismiss: { [weak self] in
                guard let self else { return }
                self.isShowingCalendarNotification = false
                let remaining = calendarEndDate.map { max($0.timeIntervalSinceNow, 120) } ?? 120
                self.meetingMonitor.suppress(for: remaining)
                self.meetingMonitor.refreshState()
            },
            onClose: { [weak self] in self?.isShowingCalendarNotification = false }
        )
    }

    private func scheduleMeetingEndNotification(endDate: Date?, title: String) {
        meetingEndTimer?.invalidate()
        meetingEndTimer = nil

        guard let endDate else { return }

        let delay = endDate.timeIntervalSinceNow
        guard delay > 0 else {
            showMeetingEndNotification(title: title)
            return
        }

        meetingEndTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.showMeetingEndNotification(title: title)
            }
        }
    }

    private func showMeetingEndNotification(title: String) {
        guard isMeetingRecording() else { return }
        meetingNotification.show(
            title: "Meeting ended",
            subtitle: "\(title) · scheduled time is over",
            actionLabel: "Stop Recording",
            dismissAfter: 45,
            onStartRecording: { [weak self] in
                self?.stopMeetingRecording()
            },
            onDismiss: nil
        )
    }

    func serializedCustomWords() -> [[String: Any]] {
        config.customWords.map { word in
            var dict: [String: Any] = ["word": word.word]
            if let replacement = word.replacement {
                dict["replacement"] = replacement
            }
            dict["matchingThreshold"] = word.matchingThreshold
            return dict
        }
    }
}

func selectCurrentOrNearbyCachedCalendarEvent(
    from events: [UnifiedCalendarEvent],
    now: Date = Date()
) -> CalendarEventContext? {
    let searchEnd = now.addingTimeInterval(5 * 60)
    let candidates = events
        .filter { event in
            !event.isAllDay && event.endDate > now && event.startDate < searchEnd
        }
        .sorted { $0.startDate < $1.startDate }

    if let active = candidates.first(where: { $0.startDate <= now && $0.endDate > now }) {
        return CalendarEventContext(id: active.id, title: active.title)
    }

    return candidates.first(where: { $0.startDate > now })
        .map { CalendarEventContext(id: $0.id, title: $0.title) }
}

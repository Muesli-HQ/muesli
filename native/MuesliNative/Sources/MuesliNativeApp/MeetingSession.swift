import FluidAudio
import ApplicationServices
import CoreAudio
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct PendingTask {
        let id: UUID
        let task: Task<[SpeechSegment], Never>
    }

    private struct State {
        // Only in-flight tasks live here. Completed tasks are retired into
        // completedSegments so Task objects and their captured state don't
        // accumulate for the full meeting duration.
        var pendingTasks: [PendingTask] = []
        var completedSegments: [SpeechSegment] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Register a transcription task. Returns the retire ID to pass to retire(id:segments:)
    /// once the task completes.
    func add(_ task: Task<[SpeechSegment], Never>) -> (registered: Bool, retireID: UUID) {
        let id = UUID()
        let registered = lock.withLock { state in
            guard !state.isClosed else { return false }
            state.pendingTasks.append(PendingTask(id: id, task: task))
            return true
        }
        return (registered, id)
    }

    /// Move a completed task's result into the collector and drop the Task reference.
    /// Must be called from the watcher Task after awaiting the transcription task's value.
    func retire(id: UUID, segments: [SpeechSegment]) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.completedSegments.append(contentsOf: segments)
            state.pendingTasks.removeAll { $0.id == id }
            return true
        }
    }

    func closeAndDrainSortedSegments() async -> [SpeechSegment] {
        let (tasksToAwait, alreadyCompleted) = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            let completed = state.completedSegments
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return (tasks, completed)
        }

        var segments = alreadyCompleted
        for task in tasksToAwait {
            segments.append(contentsOf: await task.value)
        }

        return segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func waitUntilRetired() async {
        while true {
            let tasks = lock.withLock { $0.pendingTasks.map(\.task) }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                _ = await task.value
            }
            await Task.yield()
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return tasks
        }
        tasksToCancel.forEach { $0.cancel() }
    }
}

struct MeetingSessionResult {
    let title: String
    let originalTitle: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let retainedRecordingURL: URL?
    let retainedRecordingError: Error?
    let systemRecordingURL: URL?
    let templateSnapshot: MeetingTemplateSnapshot
    var visualContext: String? = nil
}

extension MeetingSessionResult {
    /// Returns a copy with transcript, notes, and optional timing overrides.
    /// Used by the resume-recording flow to persist the merged transcript while
    /// keeping the original meeting date and accumulating only recorded duration.
    func overriding(
        startTime newStartTime: Date? = nil,
        durationSeconds newDurationSeconds: Double? = nil,
        rawTranscript: String,
        formattedNotes: String,
        visualContext newVisualContext: String? = nil
    ) -> MeetingSessionResult {
        let resolvedStart = newStartTime ?? startTime
        let resolvedDuration = newDurationSeconds ?? durationSeconds
        return MeetingSessionResult(
            title: title,
            originalTitle: originalTitle,
            calendarEventID: calendarEventID,
            startTime: resolvedStart,
            endTime: endTime,
            durationSeconds: resolvedDuration,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingError,
            systemRecordingURL: systemRecordingURL,
            templateSnapshot: templateSnapshot,
            visualContext: newVisualContext ?? visualContext
        )
    }
}

enum MeetingProcessingStage {
    case stoppingCapture
    case transcribingAudio
    case cleaningAudio
    case generatingTitle
    case summarizingNotes

    var allowsDictation: Bool {
        switch self {
        case .stoppingCapture, .transcribingAudio, .cleaningAudio:
            false
        case .generatingTitle, .summarizingNotes:
            true
        }
    }
}

private enum MeetingTranscriptRecoveryResult {
    case none
    case append([SpeechSegment])
    case replace([SpeechSegment])
}

final class MeetingSession {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSession")

    private let title: String
    private let calendarEventID: String?
    private let backendLock = OSAllocatedUnfairLock(initialState: BackendOption.whisper)
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let templateSnapshot: MeetingTemplateSnapshot
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder: SystemAudioCapturing
    private let captureLifecycle: MeetingCaptureLifecycle
    private let discardCleanup = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    var capturePhase: MeetingCapturePhase { captureLifecycle.phase }
    func beginStoppingCapture() { captureLifecycle.requestStop() }
    private let neuralAec = MeetingNeuralAec()
    private let inputObservationQueue = DispatchQueue(label: "com.muesli.meeting-input-controls")
    private let inputMuted = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private let inputObserver: CoreAudioMicrophoneActivityObserver

    /// Route-aware mic recorder with real-time 16 kHz mono PCM access.
    private var meetingMicRecorder: MeetingMicRecording
    private var rawMicChunkRecorder: PCMChunkRecorder?
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private var systemVadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    private let micChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let systemChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let micHealthTracker = MeetingMicHealthTracker()
    private let micRecoveryCoordinator = MeetingMicRecoveryCoordinator()
    private let systemAudioWatchdog = MeetingSystemAudioWatchdog()
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkRecorder: PCMChunkRecorder?
    var onProgress: ((MeetingProcessingStage) -> Void)?
    var onCaptureQuiesced: (() -> Void)? {
        get { captureLifecycle.onQuiesced }
        set { captureLifecycle.onQuiesced = newValue ?? {} }
    }
    var onCaptureShutdownTimedOut: (() -> Void)?
    var onMicHealthChanged: ((MeetingMicHealthSnapshot) -> Void)?
    /// Episode-level mic-health events: one degraded/recovered pair per actual
    /// degradation episode, or a single unrecovered event if the meeting ends
    /// while degraded. Feed telemetry here; keep per-snapshot UI updates on
    /// onMicHealthChanged.
    var onMicHealthEpisode: ((MeetingMicHealthEpisodeEvent) -> Void)?
    /// Fired at most once per meeting when confirmed degradation is classified
    /// as user-muted input (no recovery episode is opened in that case).
    var onMicHealthUserMuted: (() -> Void)?
    /// Episode-level system-audio (tap) health events: degraded after positive
    /// recorder failure evidence, recovered when capture resumes, unrecovered
    /// if the meeting ends dead.
    var onSystemAudioHealthEpisode: ((MeetingSystemAudioHealthEvent) -> Void)?
    var manualNotesProvider: (() async -> String?)?
    var liveTitleProvider: (() async -> String?)?
    /// Formatted notes of the predecessor meeting when this session records a
    /// follow-up; injected into the summary prompt for action-item carry-forward.
    var previousMeetingNotes: String?
    var onChunkTranscribed: (([SpeechSegment], String) -> Void)?
    /// Display-only streaming partial for a source ("You"/"Others", tail text).
    /// Empty text clears the source's tail. Called on a background thread.
    var onPartialTranscript: ((String, String) -> Void)?
    /// Lock-guarded because sessions are installed by an async model-loading
    /// task, fed on chunkRotationQueue, and committed by chunk-completion tasks.
    /// `isShutDown` closes the async-setup race with meeting teardown.
    private struct PartialSessionsStorage {
        var mic: MeetingStreamingPartialSession?
        var system: MeetingStreamingPartialSession?
        var isShutDown = false
    }
    private let partialSessionsStorage = OSAllocatedUnfairLock(initialState: PartialSessionsStorage())
    private let screenContextCollector = MeetingScreenContextCollector()
    private var diagnostics: MeetingSessionDiagnostics?

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        if isPaused {
            return -160
        }
        guard let lastCallback = micHealthTracker.snapshot().lastRawMicCallbackAt,
              Date().timeIntervalSince(lastCallback) < 1 else { return -160 }
        return meetingMicRecorder.currentPower()
    }

    private(set) var startTime: Date?
    var isRecording: Bool { capturePhase.isRecording }
    var isPaused: Bool { capturePhase == .paused }

    init(
        title: String,
        calendarEventID: String?,
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        templateSnapshot: MeetingTemplateSnapshot,
        transcriptionCoordinator: TranscriptionCoordinator,
        meetingMicRecorder: MeetingMicRecording = RouteAwareMeetingMicRecorder()
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        backendLock.withLock { $0 = backend }
        self.runtime = runtime
        self.config = config
        self.templateSnapshot = templateSnapshot
        self.transcriptionCoordinator = transcriptionCoordinator
        self.meetingMicRecorder = meetingMicRecorder
        if config.useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
        inputObserver = CoreAudioMicrophoneActivityObserver(queue: inputObservationQueue, observesMute: true)
        captureLifecycle = MeetingCaptureLifecycle(microphone: meetingMicRecorder, systemAudio: systemAudioRecorder)
        micRecoveryCoordinator.recoveryRequest = { [weak meetingMicRecorder] trigger in
            guard let meetingMicRecorder else { return .unavailable }
            return meetingMicRecorder.requestHealthRecovery(trigger)
        }
        // Recovery handoffs mid-transition reliably fail their first-buffer
        // window; defer them until the daemon settles (same signal the tap
        // watchdog uses — BT transitions move input and output together).
        micRecoveryCoordinator.isRouteSettling = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isRouteSettling ?? false
        }
        micRecoveryCoordinator.onEpisodeEvent = { [weak self] event in
            self?.onMicHealthEpisode?(event)
        }
        micRecoveryCoordinator.isInputMuted = { [weak self] in
            self?.inputMuted.withLock { $0 }
        }
        micRecoveryCoordinator.onUserMuted = { [weak self] in
            self?.onMicHealthUserMuted?()
        }
        micRecoveryCoordinator.contextProvider = { [weak meetingMicRecorder] in
            guard let snapshot = meetingMicRecorder?.diagnosticsSnapshot() else {
                return MeetingMicEpisodeContext()
            }
            return MeetingMicEpisodeContext(
                recorderKind: snapshot.recorderKind.rawValue,
                routeCategory: snapshot.route?.outputRouteKind,
                selectedInputResolved: snapshot.route?.selectedInputDeviceResolved
            )
        }
        meetingMicRecorder.onHandoffOutcome = { [weak micRecoveryCoordinator, weak systemAudioWatchdog] outcome in
            micRecoveryCoordinator?.noteHandoffOutcome(outcome)
            systemAudioWatchdog?.noteRouteChange()
        }
        systemAudioWatchdog.isCaptureActive = { [weak systemAudioRecorder] in
            guard let recorder = systemAudioRecorder else { return false }
            return recorder.isRecording
                && !recorder.isPaused
                && !recorder.isRebuilding
                && !recorder.captureIsDead
        }
        systemAudioWatchdog.isPaused = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isPaused ?? false
        }
        systemAudioWatchdog.isRouteSettling = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isRouteSettling ?? false
        }
        systemAudioWatchdog.lastMicCallbackAt = { [weak self] in
            self?.micHealthTracker.snapshot().lastRawMicCallbackAt
        }
        systemAudioWatchdog.recoveryRequest = { [weak systemAudioRecorder] reason in
            systemAudioRecorder?.rebuildForHealthRecovery(reason: reason) ?? false
        }
        systemAudioWatchdog.onMicBlindnessDegradation = { [weak self] reason in
            guard let self, let snapshot = self.micHealthTracker.noteRouteCallbackLoss() else { return }
            self.onMicHealthChanged?(snapshot)
            self.micRecoveryCoordinator.noteExternalDegradation(reason: reason)
        }
        systemAudioWatchdog.onEpisodeEvent = { [weak self] event in
            self?.onSystemAudioHealthEpisode?(event)
        }
        systemAudioRecorder.onRouteChange = { [weak systemAudioWatchdog] in
            systemAudioWatchdog?.noteRouteChange()
        }
        systemAudioRecorder.onCaptureFailure = { [weak systemAudioWatchdog] error in
            systemAudioWatchdog?.noteCaptureFailure(reason: "rebuild_exhausted: \(error.localizedDescription)")
        }
    }

    func updateBackend(_ backend: BackendOption) {
        backendLock.withLock { $0 = backend }
    }

    func setPreferredMicrophoneInputDeviceID(_ deviceID: AudioObjectID?) {
        inputMuted.withLock { $0 = nil }
        inputObservationQueue.async { [inputObserver] in inputObserver.selectInput(deviceID) }
        meetingMicRecorder.preferredInputDeviceID = deviceID
    }

    private func currentBackend() -> BackendOption {
        backendLock.withLock { $0 }
    }

    func start() async throws {
        try Task.checkCancellation()
        guard !captureLifecycle.isEnding else { throw CancellationError() }
        let inputDeviceID = meetingMicRecorder.preferredInputDeviceID
        inputObservationQueue.async { [inputObserver, inputMuted, captureLifecycle] in
            guard !captureLifecycle.isEnding else { return }
            inputObserver.onActivityChanged = { snapshot in
                inputMuted.withLock { $0 = snapshot.isMuted }
            }
            inputObserver.selectInput(inputDeviceID)
            inputObserver.start()
        }
        let vadManager = await transcriptionCoordinator.getVadManager()
        let now = Date()
        diagnostics = MeetingSessionDiagnostics(title: title, startedAt: now)

        // AEC must be loaded before audio pipeline starts (streaming mode)
        await neuralAec.preload()

        try Task.checkCancellation()
        guard !captureLifecycle.isEnding else { throw CancellationError() }
        // The controller owns failure disposition; an explicit Stop may already
        // be saving this session when a cancelled startup continuation returns.
        try chunkRotationQueue.sync {
            guard !captureLifecycle.isEnding else { throw CancellationError() }
            startTime = now
            chunkTimingTracker.start()
            systemChunkTimingTracker.start()
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            setupRetainedRecordingWriterIfNeeded()
        }
        try await captureLifecycle.start()
        try Task.checkCancellation()
        guard !captureLifecycle.isEnding else { throw CancellationError() }
        if vadController != nil {
            fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
        } else {
            fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
        }
        if config.enableScreenContext && CGPreflightScreenCaptureAccess() {
            // OCR screenshots are safe when using CoreAudio tap (no SCStream conflict)
            await screenContextCollector.startPeriodicCapture(useOCR: config.useCoreAudioTap)
        }
        setupStreamingPartialsIfAvailable()
    }

    /// Display-only streaming partials (#99). The selected live-caption model
    /// consumes the same cleaned mic and raw system streams as the VAD pipeline;
    /// VAD chunk transcription remains the durable source of truth.
    private func setupStreamingPartialsIfAvailable() {
        guard config.enableLiveStreamingPartials else { return }
        let backend = config.resolvedMeetingLiveCaptionBackend
        guard backend.isDownloaded else {
            fputs("[meeting-partials] \(backend.label) not downloaded; using committed live captions only\n", stderr)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let engines = try await MeetingLiveCaptionModelStore.makeEngines(
                    backend: backend,
                    nemotronPromptId: self.config.resolvedNemotron35Language.promptId
                )
                guard self.chunkRotationQueue.sync(execute: { self.isRecording }),
                      self.partialSessionsStorage.withLock({ !$0.isShutDown }) else {
                    await engines.mic.shutdown()
                    await engines.system.shutdown()
                    return
                }

                let mic = MeetingStreamingPartialSession(engine: engines.mic, label: "You")
                mic.onPartialUpdate = { [weak self] text in self?.onPartialTranscript?("You", text) }
                await mic.connect()
                let system = MeetingStreamingPartialSession(engine: engines.system, label: "Others")
                system.onPartialUpdate = { [weak self] text in self?.onPartialTranscript?("Others", text) }
                await system.connect()

                let stillRecording = self.chunkRotationQueue.sync { self.isRecording }
                guard stillRecording else {
                    mic.stop()
                    system.stop()
                    return
                }
                let installed = self.partialSessionsStorage.withLock { s -> Bool in
                    guard !s.isShutDown else { return false }
                    s.mic = mic
                    s.system = system
                    return true
                }
                guard installed else {
                    mic.stop()
                    system.stop()
                    return
                }
                fputs("[meeting-partials] \(backend.label) active for mic and system audio\n", stderr)
            } catch {
                fputs("[meeting-partials] \(backend.label) setup failed: \(error)\n", stderr)
            }
        }
    }

    private func micPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.mic }
    }

    private func systemPartialSession() -> MeetingStreamingPartialSession? {
        partialSessionsStorage.withLock { $0.system }
    }

    private func feedMicPartialSession(_ samples: [Float]) {
        micPartialSession()?.enqueue(samples)
    }

    private func feedSystemPartialSession(_ samples: [Float]) {
        systemPartialSession()?.enqueue(samples)
    }

    private func markMicPartialBoundary(id: UUID) {
        micPartialSession()?.markSegmentBoundary(id: id)
    }

    private func markSystemPartialBoundary(id: UUID) {
        systemPartialSession()?.markSegmentBoundary(id: id)
    }

    private func commitMicPartialSegment(id: UUID) {
        micPartialSession()?.commitSegment(id: id)
    }

    private func commitSystemPartialSegment(id: UUID) {
        systemPartialSession()?.commitSegment(id: id)
    }

    private func segmentsUsingStreamingTranscript(
        _ segments: [SpeechSegment],
        partialSession: MeetingStreamingPartialSession?,
        segmentID: UUID,
        start: TimeInterval,
        end: TimeInterval
    ) -> [SpeechSegment] {
        let prefersStreamingTranscript = config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .nemotron35
        guard (segments.isEmpty || prefersStreamingTranscript),
              let text = partialSession?.pendingSegmentText(id: segmentID) else { return segments }
        return [SpeechSegment(start: start, end: max(end, start + 0.1), text: text)]
    }

    private func suspendPartialSessions() {
        micPartialSession()?.suspend()
        systemPartialSession()?.suspend()
    }

    private func resumePartialSessions() {
        micPartialSession()?.resume()
        systemPartialSession()?.resume()
    }

    private func stopPartialSessions() {
        let sessions = partialSessionsStorage.withLock { s -> (MeetingStreamingPartialSession?, MeetingStreamingPartialSession?) in
            let taken = (s.mic, s.system)
            s.mic = nil
            s.system = nil
            s.isShutDown = true
            return taken
        }
        sessions.0?.stop()
        sessions.1?.stop()
    }

    func stopStreamingPartials() {
        stopPartialSessions()
    }

    func pause() {
        let shouldPause = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, !isPaused else { return false }
            appendFlushedStreamingMicOnQueue()
            rotateChunkOnQueue()
            rotateSystemChunkOnQueue()
            retainedRecordingWriter?.markPauseBoundary()
            neuralAec.resetForStreaming()
            guard captureLifecycle.setPaused(true) else { return false }
            suspendPartialSessions()
            return true
        }
        guard shouldPause else { return }
        systemAudioWatchdog.suspendVerification()

        Task { await screenContextCollector.setPaused(true) }
        fputs("[meeting] recording paused\n", stderr)
    }

    func resume() {
        let shouldResume = chunkRotationQueue.sync { () -> Bool in
            guard captureLifecycle.setPaused(false) else { return false }
            resumePartialSessions()
            return true
        }
        guard shouldResume else { return }

        systemAudioWatchdog.noteRouteChange()
        Task { await screenContextCollector.setPaused(false) }
        fputs("[meeting] recording resumed\n", stderr)
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        let shutdown = captureLifecycle.requestStop()
        discardCleanup.withLock { cleanup in
            guard cleanup == nil else { return }
            cleanup = Task.detached { [self] in
                discardPipeline()
                let result = await shutdown.value
                for url in [result.microphone, result.systemAudio].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(at: url)
                }
                if result.timedOut { onCaptureShutdownTimedOut?() }
            }
        }
    }

    private func discardPipeline() {
        Task { await screenContextCollector.stopAndDrain() }
        let (rawRecorder, systemRecorder) = chunkRotationQueue.sync { () -> (PCMChunkRecorder?, PCMChunkRecorder?) in
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            let rawRecorder = rawMicChunkRecorder
            let systemRecorder = systemChunkRecorder
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            return (rawRecorder, systemRecorder)
        }
        // Same contract as stop(): the queue barrier above drains pending
        // sample callbacks; only then is episode state final.
        micRecoveryCoordinator.finishMeeting()
        stopSystemAudioWatchdog()
        stopPartialSessions()
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        rawRecorder?.cancel()
        systemRecorder?.cancel()
        meetingMicRecorder.onRawPCMSamples = nil
        systemAudioRecorder.onPCMSamples = nil
        systemAudioRecorder.onRouteChange = nil
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        onProgress?(.stoppingCapture)
        let shutdown = captureLifecycle.requestStop()
        let endTime = Date()
        var micSegments: [SpeechSegment] = []
        var systemSegments: [SpeechSegment] = []
        let usesUnifiedNemotronTranscript = config.enableLiveStreamingPartials
            && config.resolvedMeetingLiveCaptionBackend == .nemotron35

        // Stop VAD controller
        if !usesUnifiedNemotronTranscript {
            stopPartialSessions()
        }
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        meetingMicRecorder.onRawPCMSamples = nil
        systemAudioRecorder.onPCMSamples = nil
        systemAudioRecorder.onRouteChange = nil
        let (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL) = chunkRotationQueue.sync { () -> (Date, MeetingChunkTimingSnapshot?, URL?, MeetingChunkTimingSnapshot?, URL?) in

            // Flush partial AEC frame before stopping chunk recorder
            appendFlushedStreamingMicOnQueue()

            let meetingStart = self.startTime ?? Date()
            let lastRawMicURL = rawMicChunkRecorder?.stop()
            let lastSystemChunkURL = systemChunkRecorder?.stop()
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            let lastChunkTiming = chunkTimingTracker.finish()
            let lastSystemChunkTiming = systemChunkTimingTracker.finish()
            return (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL)
        }
        // The chunkRotationQueue barrier above guarantees every sample callback
        // enqueued before teardown has been processed and that later callbacks
        // reject samples in the stopping phase. Only now is the coordinator's episode
        // state final; close any open degradation episode as unrecovered.
        micRecoveryCoordinator.finishMeeting()
        // Cancel the watchdog before stopping the recorder so no late tick can
        // request a rebuild mid-teardown, then terminalize any open tap
        // episode.
        stopSystemAudioWatchdog()
        let retainedRecordingURL = retainedRecordingWriter?.stop()
        retainedRecordingWriter = nil
        let stoppedCapture = await shutdown.value
        if stoppedCapture.timedOut {
            fputs("[meeting] capture shutdown deadline exceeded; preserving completed chunks while drivers retire\n", stderr)
            onCaptureShutdownTimedOut?()
        }
        onProgress?(.transcribingAudio)
        let rawStreamingMicURL = stoppedCapture.microphone
        let systemAudioURL = stoppedCapture.systemAudio
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
        }

        if usesUnifiedNemotronTranscript {
            async let micRetirement: Void = micChunkCollector.waitUntilRetired()
            async let systemRetirement: Void = systemChunkCollector.waitUntilRetired()
            _ = await (micRetirement, systemRetirement)

            async let micTail = micPartialSession()?.finish()
            async let systemTail = systemPartialSession()?.finish()
            let (finalMicText, finalSystemText) = await (micTail, systemTail)
            if let finalMicText, let timing = lastChunkTiming {
                micSegments.append(SpeechSegment(
                    start: timing.startTimeSeconds,
                    end: timing.startTimeSeconds + max(timing.durationSeconds, 0.1),
                    text: finalMicText
                ))
            }
            if let finalSystemText, let timing = lastSystemChunkTiming {
                systemSegments.append(SpeechSegment(
                    start: timing.startTimeSeconds,
                    end: timing.startTimeSeconds + max(timing.durationSeconds, 0.1),
                    text: finalSystemText
                ))
            }
            stopPartialSessions()
        }

        // The configured meeting model fills only a tail Nemotron could not finalize.
        if !usesUnifiedNemotronTranscript || micSegments.isEmpty {
            let finalMicSegments = await transcribeMicChunk(
                rawURL: lastRawMicURL,
                chunkTiming: lastChunkTiming,
                isFinalChunk: true
            )
            micSegments.append(contentsOf: finalMicSegments)
        } else if let lastRawMicURL {
            try? FileManager.default.removeItem(at: lastRawMicURL)
        }

        if let lastSystemChunkURL {
            let chunkOffset = lastSystemChunkTiming?.startTimeSeconds ?? 0
            let chunkDuration = lastSystemChunkTiming?.durationSeconds ?? 0
            if !usesUnifiedNemotronTranscript || systemSegments.isEmpty {
                fputs("[meeting] transcribing final system chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
                do {
                    let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                        at: lastSystemChunkURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguage,
                        indicASRLanguage: config.resolvedIndicASRLanguage,
                        whisperLanguage: config.resolvedWhisperLanguage,
                        parakeetLanguage: config.resolvedParakeetLanguage,
                        appleSpeechLanguage: config.resolvedAppleSpeechLanguage
                    )
                    let normalizedSegments = normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    systemSegments.append(contentsOf: normalizedSegments)
                } catch {
                    systemChunkHealthTracker.noteFailedChunk()
                    fputs("[meeting] final system chunk transcription failed: \(error)\n", stderr)
                }
            }
            try? FileManager.default.removeItem(at: lastSystemChunkURL)
        }

        var diarizationSegments: [TimedSpeakerSegment]?
        if let systemAudioURL {
            // Run speaker diarization on system audio (batch post-processing)
            if let diarizationResult = try? await transcriptionCoordinator.diarizeSystemAudio(at: systemAudioURL) {
                diarizationSegments = diarizationResult.segments
            }
        }

        micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        systemSegments.append(contentsOf: await systemChunkCollector.closeAndDrainSortedSegments())
        systemSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        if let systemAudioURL,
           Self.shouldAttemptSystemRecovery(
               usesUnifiedNemotronTranscript: usesUnifiedNemotronTranscript,
               hasSystemSegments: !systemSegments.isEmpty
           ) {
            let systemRecovery = await repairSystemSegmentsIfNeeded(
                existingSystemSegments: systemSegments,
                systemAudioURL: systemAudioURL,
                meetingStart: meetingStart,
                endTime: endTime
            )
            switch systemRecovery {
            case .none:
                break
            case .append(let repairedSystemSegments):
                systemSegments.append(contentsOf: repairedSystemSegments)
                systemSegments.sort { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            case .replace(let fallbackSystemSegments):
                systemSegments = fallbackSystemSegments.sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            }
        }

        fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)
        fputs("[meeting] \(systemSegments.count) system chunks transcribed during meeting\n", stderr)

        let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
            micTurns: micSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
        )
        let protectedTranscriptInputs = reconciledTranscriptInputs

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: protectedTranscriptInputs.micSegments,
            systemSegments: protectedTranscriptInputs.systemSegments,
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            meetingStart: meetingStart
        )

        let titleManualNotes = await manualNotesProvider?()
        let generatedTitle: String
        onProgress?(.generatingTitle)
        if let liveTitle = await userEditedLiveTitle() {
            generatedTitle = liveTitle
        } else if let calendarTitle = Self.calendarTitleCandidate(
            originalTitle: title,
            calendarEventID: calendarEventID
        ) {
            generatedTitle = calendarTitle
        } else if let autoTitle = await MeetingSummaryClient.generateTitle(
            transcript: rawTranscript,
            manualNotes: titleManualNotes,
            config: config
        ),
           !autoTitle.isEmpty {
            generatedTitle = autoTitle
            fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
        } else {
            generatedTitle = title
        }

        let visualContext = await screenContextCollector.stopAndDrain()
        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        onProgress?(.summarizingNotes)
        let manualNotes = await manualNotesProvider?()
        let formattedNotes: String
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: manualNotes,
                visualContext: visualContext.isEmpty ? nil : visualContext,
                previousMeetingNotes: previousMeetingNotes
            )
        } catch {
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes
            )
        }

        diagnostics?.writeFinalReport(
            title: generatedTitle,
            startedAt: meetingStart,
            endedAt: endTime,
            rawTranscript: rawTranscript,
            rawMicURL: rawStreamingMicURL,
            systemAudioURL: systemAudioURL,
            systemCapture: (systemAudioRecorder as? SystemAudioDiagnosticsProviding)?.diagnosticsSnapshot,
            micRecorder: meetingMicRecorder.diagnosticsSnapshot(),
            micHealth: micHealthTracker.snapshot(),
            aec: neuralAec.diagnosticsSnapshot,
            micChunks: micChunkHealthTracker.snapshot(),
            systemChunks: systemChunkHealthTracker.snapshot(),
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            protectedSystemSegmentCount: protectedTranscriptInputs.systemSegments.count
        )

        return MeetingSessionResult(
            title: generatedTitle,
            originalTitle: title,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError,
            systemRecordingURL: systemAudioURL,
            templateSnapshot: templateSnapshot,
            visualContext: visualContext.isEmpty ? nil : visualContext
        )
    }

    static func calendarTitleCandidate(originalTitle: String, calendarEventID: String?) -> String? {
        guard calendarEventID != nil else { return nil }
        guard !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return originalTitle
    }

    static func shouldAttemptSystemRecovery(
        usesUnifiedNemotronTranscript: Bool,
        hasSystemSegments: Bool
    ) -> Bool {
        !usesUnifiedNemotronTranscript || !hasSystemSegments
    }

    private func userEditedLiveTitle() async -> String? {
        guard let candidate = await liveTitleProvider?() else { return nil }
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return nil }
        guard trimmedCandidate != trimmedOriginal else { return nil }
        return trimmedCandidate
    }

    private func appendFlushedStreamingMicOnQueue() {
        let flushed = neuralAec.flushStreamingMic()
        appendCleanedMicSamplesOnQueue(flushed)
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates the streaming mic file and sends the completed chunk for transcription.
    private func rotateChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateChunkOnQueue()
        }
    }

    private func rotateChunkOnQueue() {
        guard capturePhase.acceptsSamples else { return }
        appendFlushedStreamingMicOnQueue()
        guard let chunkTiming = chunkTimingTracker.rotate() else {
            return
        }
        let rawChunkURL = rawMicChunkRecorder?.rotateFile()

        guard rawChunkURL != nil else {
            return
        }

        // Transcribe the completed chunk async
        let chunkOffset = chunkTiming.startTimeSeconds

        fputs("[meeting] rotating raw mic chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            guard let self else { return [] }
            if Task.isCancelled {
                self.cleanupTemporaryChunkURLs(rawChunkURL)
                return []
            }
            let segments = await self.transcribeMicChunk(
                rawURL: rawChunkURL,
                chunkTiming: chunkTiming,
                isFinalChunk: false
            )
            return segments
        }
        let (registered, retireID) = micChunkCollector.add(task)
        if registered {
            // Bind this frozen prefix to the collector ID because chunk tasks
            // may finish out of submission order.
            markMicPartialBoundary(id: retireID)
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                let resolvedSegments = self.segmentsUsingStreamingTranscript(
                    segments,
                    partialSession: self.micPartialSession(),
                    segmentID: retireID,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkTiming.durationSeconds, 0.1)
                )
                guard self.micChunkCollector.retire(id: retireID, segments: resolvedSegments) else { return }
                self.commitMicPartialSegment(id: retireID)
                guard !resolvedSegments.isEmpty else { return }
                self.onChunkTranscribed?(resolvedSegments, "You")
            }
        } else {
            task.cancel()
            cleanupTemporaryChunkURLs(rawChunkURL)
        }
    }

    private func rotateSystemChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateSystemChunkOnQueue()
        }
    }

    private func rotateSystemChunkOnQueue() {
        guard capturePhase.acceptsSamples else { return }
        guard let chunkURL = systemChunkRecorder?.rotateFile(),
              let chunkTiming = systemChunkTimingTracker.rotate() else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        fputs("[meeting] rotating system chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return [] }
            do {
                if Task.isCancelled {
                    return []
                }
                let backend = self.currentBackend()
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(
                    at: chunkURL,
                    backend: backend,
                    cohereLanguage: config.resolvedCohereLanguage,
                    indicASRLanguage: config.resolvedIndicASRLanguage,
                    whisperLanguage: config.resolvedWhisperLanguage,
                    parakeetLanguage: config.resolvedParakeetLanguage,
                    appleSpeechLanguage: config.resolvedAppleSpeechLanguage
                )
                if !result.text.isEmpty {
                    fputs("[meeting] system chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    let normalizedSegments = self.normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        self.systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        self.systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    return normalizedSegments
                }
                self.systemChunkHealthTracker.noteEmptyChunk()
            } catch {
                self.systemChunkHealthTracker.noteFailedChunk()
                fputs("[meeting] system chunk transcription failed: \(error)\n", stderr)
            }
            return []
        }
        let (registered, retireID) = systemChunkCollector.add(task)
        if registered {
            markSystemPartialBoundary(id: retireID)
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                let resolvedSegments = self.segmentsUsingStreamingTranscript(
                    segments,
                    partialSession: self.systemPartialSession(),
                    segmentID: retireID,
                    start: chunkOffset,
                    end: chunkOffset + max(chunkDuration, 0.1)
                )
                guard self.systemChunkCollector.retire(id: retireID, segments: resolvedSegments) else { return }
                self.commitSystemPartialSegment(id: retireID)
                guard !resolvedSegments.isEmpty else { return }
                self.onChunkTranscribed?(resolvedSegments, "Others")
            }
        } else {
            task.cancel()
        }
    }

    private func setupRetainedRecordingWriterIfNeeded() {
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil

        guard config.meetingRecordingSavePolicy != .never else { return }

        do {
            retainedRecordingWriter = try MeetingRecordingWriter()
        } catch {
            retainedRecordingWriterError = error
            fputs("[meeting] failed to prepare retained recording writer: \(error)\n", stderr)
        }
    }

    private func stopSystemAudioWatchdog() {
        inputObservationQueue.async { [inputObserver] in inputObserver.stop() }
        systemAudioWatchdog.finishMeeting()
    }

    private func prepareRealtimeAudioPipeline(vadManager: VadManager?) throws {
        rawMicChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-mic-chunks")
        systemChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-system-chunks")
        configureRealtimeAudioCallbacks(vadManager: vadManager)
    }

    private func configureRealtimeAudioCallbacks(vadManager: VadManager?) {
        if let vadManager {
            let controller = StreamingVadController(vadManager: vadManager)
            controller.onChunkBoundary = { [weak self] in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateChunkOnQueue()
                }
            }
            controller.start()
            vadController = controller

            let systemController = StreamingVadController(vadManager: vadManager)
            systemController.onChunkBoundary = { [weak self] in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateSystemChunkOnQueue()
                }
            }
            systemController.start()
            systemVadController = systemController
        } else {
            vadController = nil
            systemVadController = nil
        }
        neuralAec.resetForStreaming()
        meetingMicRecorder.onRawPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeMicSamples(samples)
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeSystemSamples(samples)
        }
    }

    private func enqueueRealtimeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.capturePhase.acceptsSamples else { return }

            let healthSnapshot = self.micHealthTracker.noteRawMicSamples(rawSamples)
            self.onMicHealthChanged?(healthSnapshot)
            self.micRecoveryCoordinator.process(healthSnapshot)
            self.retainedRecordingWriter?.appendMic(rawSamples)

            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // AEC: clean mic using position-aligned system reference
            let cleanedFloat = self.neuralAec.processStreamingMic(floatSamples)
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            // Meeting mic chunks must be driven by the cleaned mic stream. Raw
            // mic VAD sees speaker playback bleed and can create false `You`
            // chunks even when AEC removed that speech from the final mic audio.
            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }
        }
    }

    private func enqueueRealtimeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.capturePhase.acceptsSamples else { return }

            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples)
            self.onMicHealthChanged?(healthSnapshot)
            self.micRecoveryCoordinator.process(healthSnapshot)
            self.retainedRecordingWriter?.appendSystem(samples)
            self.systemChunkRecorder?.append(samples)
            self.systemChunkTimingTracker.append(sampleCount: samples.count)

            let floatSamples = samples.map { Float($0) / 32767.0 }
            self.feedSystemPartialSession(floatSamples)
            self.neuralAec.feedSystemSamples(floatSamples)
            let cleanedFloat = self.neuralAec.processStreamingMic([])
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }

            if let systemVadController = self.systemVadController {
                systemVadController.processAudio(floatSamples)
            }
        }
    }

    private func appendCleanedMicSamplesOnQueue(_ cleanedFloat: [Float]) {
        guard !cleanedFloat.isEmpty else { return }
        // Single funnel for all AEC'd mic audio — the streaming partial tail
        // must consume exactly the stream the mic chunks record.
        feedMicPartialSession(cleanedFloat)
        let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(cleanedInt16)
        chunkTimingTracker.append(sampleCount: cleanedInt16.count)
        diagnostics?.appendCleanedMicSamples(cleanedInt16)
    }

    private func transcribeMicChunk(
        rawURL: URL?,
        chunkTiming: MeetingChunkTimingSnapshot?,
        isFinalChunk: Bool
    ) async -> [SpeechSegment] {
        defer {
            cleanupTemporaryChunkURLs(rawURL)
        }

        guard let chunkTiming, let rawURL else { return [] }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let logPrefix = isFinalChunk ? "[meeting] transcribing final mic chunk" : "[meeting] transcribing mic chunk"

        return await transcribeMicChunk(
            at: rawURL,
            chunkOffset: chunkOffset,
            chunkDuration: chunkDuration,
            logPrefix: logPrefix
        ) ?? []
    }

    private func transcribeMicChunk(
        at url: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        logPrefix: String
    ) async -> [SpeechSegment]? {
        fputs("\(logPrefix) (offset=\(String(format: "%.0f", chunkOffset))s, source=raw)\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                at: url,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage,
                whisperLanguage: config.resolvedWhisperLanguage,
                parakeetLanguage: config.resolvedParakeetLanguage,
                appleSpeechLanguage: config.resolvedAppleSpeechLanguage
            )
            if !result.text.isEmpty {
                fputs("[meeting] mic chunk transcribed (raw): \"\(String(result.text.prefix(60)))...\"\n", stderr)
                let normalizedSegments = MicTurnNormalizer.normalize(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    micChunkHealthTracker.noteEmptyChunk()
                } else {
                    micChunkHealthTracker.noteSuccessfulChunk()
                }
                return normalizedSegments
            }
            micChunkHealthTracker.noteEmptyChunk()
            return []
        } catch {
            micChunkHealthTracker.noteFailedChunk()
            fputs("[meeting] mic chunk transcription failed (raw): \(error)\n", stderr)
            return nil
        }
    }

    private func cleanupTemporaryChunkURLs(_ urls: URL?...) {
        urls.compactMap { $0 }.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeSystemTranscription(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        SystemTurnNormalizer.normalize(
            result: result,
            startTime: startTime,
            endTime: endTime
        )
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    private func repairSystemSegmentsIfNeeded(
        existingSystemSegments: [SpeechSegment],
        systemAudioURL: URL,
        meetingStart: Date,
        endTime: Date
    ) async -> MeetingTranscriptRecoveryResult {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let health = MeetingTranscriptHealthMonitor.evaluate(
                existingSegments: existingSystemSegments,
                offlineSpeechSegments: speechSegments,
                chunkHealth: systemChunkHealthTracker.snapshot()
            )
            fputs("[meeting] system \(health.summaryLine.dropFirst("[meeting] ".count))\n", stderr)

            switch health.action {
            case .accept:
                return .none
            case .fullFallback(let reason):
                fputs("[meeting] transcript health triggered full system fallback: \(reason)\n", stderr)
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            case .selectiveRepair(let repairSegments):
                guard !repairSegments.isEmpty else { return .none }

                fputs("[meeting] repairing \(repairSegments.count) uncovered system speech regions\n", stderr)

                var repairedSegments: [SpeechSegment] = []
                for speechSegment in repairSegments {
                    let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                    let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                    guard endSample > startSample else { continue }

                    let segmentURL = try WavWriter.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample]),
                        directoryName: "muesli-meeting-mic-repair"
                    )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    let result = try await transcriptionCoordinator.transcribeMeeting(
                        at: segmentURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguage,
                        indicASRLanguage: config.resolvedIndicASRLanguage,
                        whisperLanguage: config.resolvedWhisperLanguage,
                        parakeetLanguage: config.resolvedParakeetLanguage,
                        appleSpeechLanguage: config.resolvedAppleSpeechLanguage
                    )
                    repairedSegments.append(contentsOf: normalizeSystemTranscription(
                        result: result,
                        startTime: speechSegment.startTime,
                        endTime: speechSegment.endTime
                    ))
                }
                return repairedSegments.isEmpty ? .none : .append(repairedSegments)
            }
        } catch {
            fputs("[meeting] system repair pass failed: \(error)\n", stderr)
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }
    }

    private func fallbackToFullSessionSystemTranscription(
        systemAudioURL: URL,
        meetingDuration: Double
    ) async -> [SpeechSegment] {
        fputs("[meeting] no system chunks survived, falling back to full-session system transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: systemAudioURL,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguage,
                indicASRLanguage: config.resolvedIndicASRLanguage,
                whisperLanguage: config.resolvedWhisperLanguage,
                parakeetLanguage: config.resolvedParakeetLanguage,
                appleSpeechLanguage: config.resolvedAppleSpeechLanguage
            )
            return normalizeSystemTranscription(
                result: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session system fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}

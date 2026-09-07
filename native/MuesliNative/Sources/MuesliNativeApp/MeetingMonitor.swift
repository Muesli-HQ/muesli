import AppKit
import CoreAudio
import Foundation
import os

@MainActor
final class MeetingMonitor {
    var calendarEventProvider: (() -> CalendarEventContext?)?
    var detectionEnabledProvider: (() -> Bool)?
    var recordingLifecycleProvider: (() -> MeetingRecordingLifecycleSnapshot)?
    var selfAudioActivityActiveProvider: (() -> Bool)?
    var isCalendarNotificationVisibleProvider: (() -> Bool)?
    var promptVisibilityProvider: (() -> MeetingPromptVisibility)?
    var mutedDetectionBundleIDsProvider: (() -> Set<String>)?
    var onActivityCandidateChanged: ((MeetingCandidate?) -> Void)?
    var onPromptCandidateChanged: ((MeetingCandidate?) -> Void)?

    private lazy var detectionService = MeetingDetectionService(
        contextProvider: { [weak self] now in
            self?.makeEvaluationContext(now: now) ?? .disabled
        },
        activityHandler: { [weak self] candidate in
            self?.onActivityCandidateChanged?(candidate)
        },
        promptHandler: { [weak self] update in
            self?.handlePromptUpdate(update)
        }
    )

    private let cameraMonitor = CameraActivityMonitor()
    private let sensorAttributionMonitor = ControlCenterSensorAttributionMonitor()
    private let runningApplicationStore = RunningApplicationStore()

    private let microphoneMonitor = MicrophoneActivityMonitor()
    private var lifecycleGeneration = 0
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        microphoneMonitor.onActivityChanged = { [weak self] in
            self?.scheduleEvaluation(.micChanged)
        }
        microphoneMonitor.start()
        runningApplicationStore.onChanged = { [weak self] trigger in
            self?.scheduleEvaluation(trigger)
        }
        runningApplicationStore.start()

        cameraMonitor.onCameraStateChanged = { [weak self] _ in
            self?.scheduleEvaluation(.cameraChanged)
        }
        cameraMonitor.start()

        sensorAttributionMonitor.onAttributionsChanged = { [weak self] in
            DispatchQueue.main.async { self?.scheduleEvaluation(.sensorAttributionChanged) }
        }
        sensorAttributionMonitor.start()

        let monitoringMode = currentMonitoringMode()
        Task { [detectionService] in
            await detectionService.start(generation: generation, monitoringMode: monitoringMode)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        microphoneMonitor.stop()
        microphoneMonitor.onActivityChanged = nil
        runningApplicationStore.stop()
        runningApplicationStore.onChanged = nil
        cameraMonitor.stop()
        sensorAttributionMonitor.stop()
        Task { [detectionService] in
            await detectionService.stop(generation: generation)
        }
    }

    func refreshState(trigger: MeetingDetectionTrigger = .manualRefresh) {
        scheduleEvaluation(trigger)
    }

    func suppress(for duration: TimeInterval = 120) {
        Task { [detectionService] in
            await detectionService.suppress(for: duration)
        }
    }

    func suppressWhileActive() {
        let monitoringMode = currentMonitoringMode()
        Task { [detectionService] in
            await detectionService.suppressWhileActive(monitoringMode: monitoringMode)
        }
    }

    func resumeAfterCooldown() {
        let monitoringMode = currentMonitoringMode()
        Task { [detectionService] in
            await detectionService.resumeAfterCooldown(monitoringMode: monitoringMode)
        }
    }

    func markPromptShown(_ candidate: MeetingCandidate) {
        Task { [detectionService] in
            await detectionService.markPromptShown(candidate)
        }
    }

    func markPromptAutoDismissed(_ candidate: MeetingCandidate) {
        Task { [detectionService] in
            await detectionService.markPromptAutoDismissed(candidate)
        }
    }

    func markPromptUserDismissed(_ candidate: MeetingCandidate) {
        Task { [detectionService] in
            await detectionService.markPromptUserDismissed(candidate)
        }
    }

    func markPromptClosed(_ candidate: MeetingCandidate) {
        Task { [detectionService] in
            await detectionService.markPromptClosed(candidate)
        }
    }

    func markRecordingStarted(_ candidate: MeetingCandidate?) {
        let monitoringMode = currentMonitoringMode()
        Task { [detectionService] in
            await detectionService.markRecordingStarted(candidate, monitoringMode: monitoringMode)
        }
    }

    private func scheduleEvaluation(_ trigger: MeetingDetectionTrigger) {
        guard isStarted else { return }
        let monitoringMode = currentMonitoringMode()
        Task { [detectionService] in
            await detectionService.scheduleEvaluation(trigger, monitoringMode: monitoringMode)
        }
    }

    private func currentRecordingLifecycle() -> MeetingRecordingLifecycleSnapshot {
        recordingLifecycleProvider?() ?? .idle
    }

    private func currentMonitoringMode() -> MeetingMonitoringMode {
        MeetingMonitoringModePolicy.resolve(currentRecordingLifecycle())
    }

    private func handlePromptUpdate(_ update: MeetingPromptUpdate) {
        switch update {
        case .show(let candidate):
            onPromptCandidateChanged?(candidate)
        case .hide:
            onPromptCandidateChanged?(nil)
        }
    }

    private func makeEvaluationContext(now: Date) -> MeetingDetectionEvaluationContext {
        let runningApplicationState = runningApplicationStore.snapshot()
        let lifecycle = currentRecordingLifecycle()
        return MeetingDetectionEvaluationContext(
            deviceMicActive: microphoneMonitor.snapshot.isActive ?? false,
            cameraActive: cameraMonitor.isCameraActive,
            sensorAttributions: sensorAttributionMonitor.snapshot(),
            calendarEvent: calendarEventProvider?(),
            detectionEnabled: detectionEnabledProvider?() ?? true,
            isRecording: lifecycle.isRecording,
            isStartingRecording: lifecycle.isStarting,
            selfAudioActivityActive: selfAudioActivityActiveProvider?() ?? false,
            monitoringMode: MeetingMonitoringModePolicy.resolve(lifecycle),
            isCalendarNotificationVisible: isCalendarNotificationVisibleProvider?() ?? false,
            promptVisibility: promptVisibilityProvider?()
                ?? MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil),
            mutedBundleIDs: mutedDetectionBundleIDsProvider?() ?? [],
            runningApps: runningApplicationState.runningApps,
            foregroundBundleID: runningApplicationState.foregroundBundleID
        )
    }


}

private enum MeetingPromptUpdate {
    case show(MeetingCandidate)
    case hide
}

private struct MeetingDetectionEvaluationContext {
    let deviceMicActive: Bool
    let cameraActive: Bool
    let sensorAttributions: SensorAttributionSnapshot
    let calendarEvent: CalendarEventContext?
    let detectionEnabled: Bool
    let isRecording: Bool
    let isStartingRecording: Bool
    let selfAudioActivityActive: Bool
    let monitoringMode: MeetingMonitoringMode
    let isCalendarNotificationVisible: Bool
    let promptVisibility: MeetingPromptVisibility
    let mutedBundleIDs: Set<String>
    let runningApps: [RunningAppSnapshot]
    let foregroundBundleID: String?

    static let disabled = MeetingDetectionEvaluationContext(
        deviceMicActive: false,
        cameraActive: false,
        sensorAttributions: .empty,
        calendarEvent: nil,
        detectionEnabled: false,
        isRecording: false,
        isStartingRecording: false,
        selfAudioActivityActive: false,
        monitoringMode: .discovery,
        isCalendarNotificationVisible: false,
        promptVisibility: MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil),
        mutedBundleIDs: [],
        runningApps: [],
        foregroundBundleID: nil
    )
}

struct MeetingMediaSignals: Equatable {
    let micActive: Bool
    let cameraActive: Bool
    let audioInputProcesses: [AudioProcessActivity]

    var hasMicOrCameraSignal: Bool {
        micActive || cameraActive
    }
}

enum MeetingMediaSignalFilter {
    static func apply(
        deviceMicActive: Bool,
        cameraActive: Bool,
        audioInputProcesses: [AudioProcessActivity],
        sensorAttributions: SensorAttributionSnapshot,
        selfAudioActivityActive: Bool = false,
        selfBundleID: String
    ) -> MeetingMediaSignals {
        let externalAudioInputProcesses = audioInputProcesses.filter {
            !isSelfBundleID($0.bundleID, selfBundleID: selfBundleID)
        }
        let selfMicAttributed = audioInputProcesses.contains {
            isSelfBundleID($0.bundleID, selfBundleID: selfBundleID)
        } || sensorAttributions.micBundleIDs.contains {
            isSelfBundleID($0, selfBundleID: selfBundleID)
        } || selfAudioActivityActive
        let hasExternalMicAttribution = !externalAudioInputProcesses.isEmpty
            || sensorAttributions.micBundleIDs.contains {
                !isSelfBundleID($0, selfBundleID: selfBundleID)
            }
        let selfCameraAttributed = sensorAttributions.cameraBundleIDs.contains {
            isSelfBundleID($0, selfBundleID: selfBundleID)
        }
        let hasExternalCameraAttribution = sensorAttributions.cameraBundleIDs.contains {
            !isSelfBundleID($0, selfBundleID: selfBundleID)
        }

        // When Muesli is the only mic/camera attribution, treat the signal as self-owned.
        // External attribution can lag, so this intentionally favors avoiding self-triggered detections.
        return MeetingMediaSignals(
            micActive: hasExternalMicAttribution || (deviceMicActive && !selfMicAttributed),
            cameraActive: hasExternalCameraAttribution || (cameraActive && !selfCameraAttributed),
            audioInputProcesses: externalAudioInputProcesses
        )
    }

    static func hasExternalSensorAttribution(
        _ sensorAttributions: SensorAttributionSnapshot,
        selfBundleID: String
    ) -> Bool {
        sensorAttributions.micBundleIDs.contains {
            !isSelfBundleID($0, selfBundleID: selfBundleID)
        } || sensorAttributions.cameraBundleIDs.contains {
            !isSelfBundleID($0, selfBundleID: selfBundleID)
        }
    }

    static func externalMicBundleIDs(
        _ sensorAttributions: SensorAttributionSnapshot,
        selfBundleID: String
    ) -> Set<String> {
        Set(sensorAttributions.micBundleIDs.filter {
            !isSelfBundleID($0, selfBundleID: selfBundleID)
        })
    }

    private static func isSelfBundleID(_ bundleID: String, selfBundleID: String) -> Bool {
        guard !selfBundleID.isEmpty else { return false }
        let normalizedBundleID = bundleID.lowercased()
        let normalizedSelfBundleID = selfBundleID.lowercased()
        return normalizedBundleID == normalizedSelfBundleID
            || normalizedBundleID.hasPrefix("\(normalizedSelfBundleID).")
    }
}

private actor MeetingDetectionService {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingDetection")

    private let contextProvider: @MainActor (Date) -> MeetingDetectionEvaluationContext
    private let activityHandler: @MainActor (MeetingCandidate?) -> Void
    private let promptHandler: @MainActor (MeetingPromptUpdate) -> Void
    private let resolver = MeetingCandidateResolver()
    private let mediaSessionTracker = MeetingMediaSessionTracker()
    private let signalCollector = MeetingSignalCollector()
    private let audioAttributionService = AudioAttributionService()
    private let promptState = MeetingPromptStateMachine()
    private let refreshPolicy = MeetingSignalRefreshPolicy()

    private var fallbackEvaluationTask: Task<Void, Never>?
    private var debounceEvaluationTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var scheduledTrigger: MeetingDetectionTrigger?
    private var pendingEvaluationTrigger: MeetingDetectionTrigger?
    private var globalSuppressUntil: Date?
    private var lastLoggedCandidateID: String?
    private var lastSuppressionLogKey: String?
    private var signalRefreshState = MeetingSignalRefreshState()
    private var currentFallbackInterval: TimeInterval?
    private var resetTask: Task<Void, Never>?
    private var latestLifecycleGeneration = 0
    private var isStarted = false
    private var monitoringMode: MeetingMonitoringMode = .discovery

    init(
        contextProvider: @escaping @MainActor (Date) -> MeetingDetectionEvaluationContext,
        activityHandler: @escaping @MainActor (MeetingCandidate?) -> Void,
        promptHandler: @escaping @MainActor (MeetingPromptUpdate) -> Void
    ) {
        self.contextProvider = contextProvider
        self.activityHandler = activityHandler
        self.promptHandler = promptHandler
    }

    func start(generation: Int, monitoringMode: MeetingMonitoringMode) async {
        if let resetTask {
            await resetTask.value
            self.resetTask = nil
        }
        guard generation >= latestLifecycleGeneration else { return }
        latestLifecycleGeneration = generation
        guard !isStarted else { return }
        isStarted = true
        self.monitoringMode = monitoringMode
        guard monitoringMode.performsEvaluation else {
            suspendEvaluationLoop()
            return
        }
        installFallbackEvaluationLoop(interval: fallbackInterval(for: monitoringMode))
        scheduleEvaluation(.startup)
    }

    func stop(generation: Int) async {
        guard generation >= latestLifecycleGeneration else { return }
        latestLifecycleGeneration = generation
        await performStop(generation: generation)
    }

    private func performStop(generation: Int) async {
        isStarted = false
        fallbackEvaluationTask?.cancel()
        fallbackEvaluationTask = nil
        debounceEvaluationTask?.cancel()
        debounceEvaluationTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        scheduledTrigger = nil
        pendingEvaluationTrigger = nil
        currentFallbackInterval = nil
        signalRefreshState = MeetingSignalRefreshState()
        monitoringMode = .discovery
        let resetTask = Task { [audioAttributionService, mediaSessionTracker] in
            await audioAttributionService.reset()
            await mediaSessionTracker.reset()
        }
        self.resetTask = resetTask
        await resetTask.value
        guard latestLifecycleGeneration == generation else { return }
        self.resetTask = nil
        promptState.resetVisiblePrompt()
        emitPromptUpdate(.hide)
    }

    func scheduleEvaluation(
        _ trigger: MeetingDetectionTrigger,
        monitoringMode: MeetingMonitoringMode
    ) {
        guard isStarted else { return }
        applyMonitoringMode(monitoringMode)
        guard monitoringMode.performsEvaluation else { return }
        scheduleEvaluation(trigger)
    }

    private func scheduleEvaluation(_ trigger: MeetingDetectionTrigger) {
        guard isStarted, monitoringMode.performsEvaluation else { return }
        scheduledTrigger = mergeTrigger(scheduledTrigger, with: trigger)
        debounceEvaluationTask?.cancel()

        let delay = debounceDelay(for: trigger)
        debounceEvaluationTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.startScheduledEvaluation()
        }
    }

    func suppress(for duration: TimeInterval = 120) {
        globalSuppressUntil = Date().addingTimeInterval(duration)
        dismissVisiblePromptForSuppression()
    }

    func suppressWhileActive(monitoringMode: MeetingMonitoringMode) {
        globalSuppressUntil = .distantFuture
        dismissVisiblePromptForSuppression()
        applyMonitoringMode(monitoringMode)
    }

    func resumeAfterCooldown(monitoringMode: MeetingMonitoringMode) {
        globalSuppressUntil = Date().addingTimeInterval(15)
        applyMonitoringMode(monitoringMode)
        scheduleEvaluation(.promptStateChanged)
    }

    func markPromptShown(_ candidate: MeetingCandidate) {
        promptState.markShown(candidate)
        scheduleEvaluation(.promptStateChanged)
    }

    func markPromptAutoDismissed(_ candidate: MeetingCandidate) {
        promptState.markAutoDismissed(candidate)
        log("prompt_auto_dismissed id=\(candidate.id)")
        scheduleEvaluation(.promptStateChanged)
    }

    func markPromptUserDismissed(_ candidate: MeetingCandidate) {
        promptState.markUserDismissed(candidate)
        log("prompt_suppressed id=\(candidate.id) reason=user_dismissed")
        scheduleEvaluation(.promptStateChanged)
    }

    func markPromptClosed(_ candidate: MeetingCandidate) {
        promptState.markClosed(candidate)
        scheduleEvaluation(.promptStateChanged)
    }

    func markRecordingStarted(
        _ candidate: MeetingCandidate?,
        monitoringMode: MeetingMonitoringMode
    ) {
        if let candidate {
            log("recording_started id=\(candidate.id)")
            associateActiveRecording(with: candidate)
        } else {
            log("recording_started")
        }
        applyMonitoringMode(monitoringMode)
        scheduleEvaluation(.promptStateChanged)
    }

    private func startScheduledEvaluation() async {
        guard isStarted else { return }
        let trigger = scheduledTrigger ?? .manualRefresh
        scheduledTrigger = nil

        if evaluationTask != nil {
            pendingEvaluationTrigger = mergeTrigger(pendingEvaluationTrigger, with: trigger)
            return
        }

        evaluationTask = Task { [weak self] in
            await self?.runScheduledEvaluations(initialTrigger: trigger)
        }
    }

    private func runScheduledEvaluations(initialTrigger: MeetingDetectionTrigger) async {
        var trigger: MeetingDetectionTrigger? = initialTrigger
        repeat {
            let currentTrigger = trigger ?? .manualRefresh
            pendingEvaluationTrigger = nil
            await evaluateNow(trigger: currentTrigger)
            trigger = pendingEvaluationTrigger
        } while trigger != nil && !Task.isCancelled
        evaluationTask = nil
    }

    private func evaluateNow(trigger: MeetingDetectionTrigger) async {
        let totalStart = Date()
        let now = Date()
        let context = await contextProvider(now)
        guard isStarted else { return }
        monitoringMode = context.monitoringMode
        guard context.monitoringMode.performsEvaluation else {
            suspendEvaluationLoop()
            return
        }
        guard context.detectionEnabled else {
            dismissVisiblePromptForSuppression()
            return
        }

        // The observer owns HAL reads. Evaluation only consumes its last event.
        let deviceMicActive = context.deviceMicActive
        let cheapMediaSignals = MeetingMediaSignalFilter.apply(
            deviceMicActive: deviceMicActive,
            cameraActive: context.cameraActive,
            audioInputProcesses: [],
            sensorAttributions: context.sensorAttributions,
            selfAudioActivityActive: context.selfAudioActivityActive,
            selfBundleID: resolver.selfBundleID
        )
        signalRefreshState.hasMicOrCameraSignal = cheapMediaSignals.hasMicOrCameraSignal
        signalRefreshState.hasCalendarEvent = context.calendarEvent != nil
        signalRefreshState.hasPromptVisible = context.promptVisibility.isVisible

        let globallySuppressed = isGloballySuppressed(now: now)
        let audioEvidence = MeetingAudioAttributionEvidence(
            deviceMicActive: deviceMicActive,
            selfAudioActivityActive: context.selfAudioActivityActive,
            externalMicBundleIDs: MeetingMediaSignalFilter.externalMicBundleIDs(
                context.sensorAttributions,
                selfBundleID: resolver.selfBundleID
            )
        )
        let refreshDecision = refreshPolicy.decision(
            trigger: trigger,
            state: signalRefreshState,
            monitoringMode: context.monitoringMode,
            audioEvidence: audioEvidence,
            suppressAudioAttribution: globallySuppressed,
            now: now
        )
        async let audioAttributionResult = audioAttributionService.activeInputProcesses(
            refreshFull: refreshDecision.refreshAudioAttribution,
            refreshTracked: refreshDecision.refreshTrackedAudioProcesses,
            episode: refreshDecision.audioAttributionEpisode,
            onChange: { [weak self] in await self?.scheduleEvaluation(.audioAttributionChanged) }
        )
        let collectedSignals = await signalCollector.collect(
            runningApps: context.runningApps,
            foregroundBundleID: context.foregroundBundleID,
            monitoringMode: context.monitoringMode,
            refreshBrowserMeetings: refreshDecision.refreshBrowserMeetings,
            refreshPolicy: refreshPolicy,
            refreshState: signalRefreshState,
            now: now
        )
        let audioResult = await audioAttributionResult
        guard !Task.isCancelled,
              isStarted,
              monitoringMode == context.monitoringMode else { return }
        if refreshDecision.refreshBrowserMeetings {
            signalRefreshState.lastBrowserRefreshAt = now
        }
        for bundleID in collectedSignals.activeTabFallbackAttemptedBundleIDs {
            signalRefreshState.lastActiveTabFallbackAttemptAtByBundleID[bundleID] = now
        }

        let rawAudioInputProcesses = mergedAudioInputProcesses(
            context.monitoringMode.allowsFullAudioAttribution
                && refreshDecision.audioAttributionEpisode != nil
                ? audioResult.processes
                : [],
            sensorAttributions: context.sensorAttributions,
            runningProcessIDsByBundleID: collectedSignals.runningProcessIDsByBundleID,
            monitoringMode: context.monitoringMode
        )
        let mediaSignals = MeetingMediaSignalFilter.apply(
            deviceMicActive: deviceMicActive,
            cameraActive: context.cameraActive,
            audioInputProcesses: rawAudioInputProcesses,
            sensorAttributions: context.sensorAttributions,
            selfAudioActivityActive: context.selfAudioActivityActive,
            selfBundleID: resolver.selfBundleID
        )

        let snapshot = MeetingSignalSnapshot(
            micActive: mediaSignals.micActive,
            cameraActive: mediaSignals.cameraActive,
            calendarEvent: context.calendarEvent,
            runningApps: collectedSignals.runningApps,
            browserMeetings: collectedSignals.browserMeetings,
            audioInputProcesses: mediaSignals.audioInputProcesses,
            foregroundBundleID: collectedSignals.foregroundBundleID,
            now: now
        )

        let resolverStart = Date()
        let resolvedActivityCandidate = scopedActivityCandidate(
            resolver.resolve(snapshot),
            monitoringMode: context.monitoringMode
        )
        if !refreshDecision.refreshAudioAttribution || audioResult.startedRefresh {
            signalRefreshState.audioAttributionAttempt = refreshPolicy.audioAttributionAttemptState(
                after: refreshDecision,
                current: signalRefreshState.audioAttributionAttempt,
                resolvedCandidate: resolvedActivityCandidate != nil,
                now: now
            )
        }
        let resolverDuration = Date().timeIntervalSince(resolverStart)
        let stabilizedActivityCandidate = await mediaSessionTracker.stabilize(
            candidate: resolvedActivityCandidate,
            snapshot: snapshot
        )
        let activityCandidate = scopedActivityCandidate(
            stabilizedActivityCandidate,
            monitoringMode: context.monitoringMode
        )
        let unmutedActivityCandidate = isMuted(
            activityCandidate,
            mutedBundleIDs: context.mutedBundleIDs
        ) ? nil : activityCandidate
        if context.isRecording,
           let unmutedActivityCandidate {
            // Manual recordings can begin before the meeting app becomes active.
            // Consume a media-backed session only after capture has really started,
            // so failed startups remain retryable and recurring URL-only candidates
            // are not suppressed for the lifetime of the app.
            associateActiveRecording(with: unmutedActivityCandidate)
        }
        emitActivityUpdate(unmutedActivityCandidate)
        let candidate = globallySuppressed ? nil : unmutedActivityCandidate
        logCandidateIfChanged(candidate)
        updateRefreshState(
            micActive: mediaSignals.micActive,
            cameraActive: mediaSignals.cameraActive,
            calendarEvent: context.calendarEvent,
            browserMeetings: collectedSignals.browserMeetings,
            foregroundBundleID: collectedSignals.foregroundBundleID,
            visibility: context.promptVisibility,
            candidate: unmutedActivityCandidate,
            keepSuspicious: context.monitoringMode.performsEvaluation
                && context.monitoringMode != .discovery,
            now: now
        )

        let decision = promptState.evaluate(
            candidate: candidate,
            detectionEnabled: context.detectionEnabled,
            isRecording: context.isRecording,
            isStartingRecording: context.isStartingRecording,
            isCalendarNotificationVisible: context.isCalendarNotificationVisible,
            visibility: context.promptVisibility,
            now: now
        )

        switch decision.action {
        case .show:
            guard let candidate = decision.candidate else { return }
            log("prompt_shown id=\(candidate.id) platform=\(candidate.platform.displayName) app=\(candidate.appName)")
            emitPromptUpdate(.show(candidate))
        case .hide:
            emitPromptUpdate(.hide)
        case .none:
            logSuppressionIfNeeded(decision)
        }

        let nextDecision = refreshPolicy.decision(
            trigger: .fallbackTimer,
            state: signalRefreshState,
            monitoringMode: context.monitoringMode,
            audioEvidence: audioEvidence,
            suppressAudioAttribution: globallySuppressed,
            now: now
        )
        installFallbackEvaluationLoop(interval: nextDecision.fallbackInterval)
        logEvaluation(
            trigger: trigger,
            decision: refreshDecision,
            timings: MeetingCollectionTimings(
                browserDuration: collectedSignals.timings.browserDuration,
                audioAttributionDuration: audioResult.duration
            ),
            resolverDuration: resolverDuration,
            totalDuration: Date().timeIntervalSince(totalStart)
        )
    }

    private func dismissVisiblePromptForSuppression() {
        promptState.resetVisiblePrompt()
        emitPromptUpdate(.hide)
    }

    private func emitPromptUpdate(_ update: MeetingPromptUpdate) {
        Task { @MainActor [promptHandler] in
            promptHandler(update)
        }
    }

    private func emitActivityUpdate(_ candidate: MeetingCandidate?) {
        Task { @MainActor [activityHandler] in
            activityHandler(candidate)
        }
    }

    private func isGloballySuppressed(now: Date) -> Bool {
        guard let until = globalSuppressUntil else { return false }
        if now >= until {
            globalSuppressUntil = nil
            return false
        }
        return true
    }

    private func isMuted(_ candidate: MeetingCandidate?, mutedBundleIDs: Set<String>) -> Bool {
        guard let sourceBundleID = candidate?.sourceBundleID else { return false }
        return mutedBundleIDs.contains(sourceBundleID)
    }

    private func logCandidateIfChanged(_ candidate: MeetingCandidate?) {
        guard candidate?.id != lastLoggedCandidateID else { return }
        lastLoggedCandidateID = candidate?.id
        if let candidate {
            log("candidate_detected id=\(candidate.id) platform=\(candidate.platform.displayName) app=\(candidate.appName)")
        }
    }

    private func logSuppressionIfNeeded(_ decision: MeetingPromptDecision) {
        guard let candidate = decision.candidate else {
            lastSuppressionLogKey = nil
            return
        }
        let key = "\(candidate.id):\(decision.reason)"
        guard key != lastSuppressionLogKey else { return }
        lastSuppressionLogKey = key
        switch decision.reason {
        case .autoDismissedSuppression:
            log("prompt_suppressed id=\(candidate.id) reason=auto_dismissed")
        case .userDismissedSuppression:
            log("prompt_suppressed id=\(candidate.id) reason=user_dismissed")
        case .recordingStartedSuppression:
            log("prompt_suppressed id=\(candidate.id) reason=recording_started")
        case .calendarNotificationVisible:
            log("prompt_suppressed id=\(candidate.id) reason=calendar_notification_visible")
        case .recording:
            log("prompt_suppressed id=\(candidate.id) reason=recording")
        default:
            break
        }
    }

    private func applyMonitoringMode(_ newMode: MeetingMonitoringMode) {
        guard newMode != monitoringMode else { return }

        monitoringMode = newMode
        log("monitoring_mode_changed mode=\(monitoringModeLogName(newMode))")
        if newMode.performsEvaluation {
            installFallbackEvaluationLoop(interval: fallbackInterval(for: newMode))
        } else {
            suspendEvaluationLoop()
        }
    }

    private func suspendEvaluationLoop() {
        fallbackEvaluationTask?.cancel()
        fallbackEvaluationTask = nil
        debounceEvaluationTask?.cancel()
        debounceEvaluationTask = nil
        scheduledTrigger = nil
        pendingEvaluationTrigger = nil
        currentFallbackInterval = nil
        signalRefreshState.hasActiveCandidate = false
        emitActivityUpdate(nil)
    }

    private func fallbackInterval(for mode: MeetingMonitoringMode) -> TimeInterval {
        switch mode {
        case .discovery:
            return refreshPolicy.idleFallbackInterval
        case .sourceLiveness:
            return refreshPolicy.suspiciousFallbackInterval
        case .suspended:
            return refreshPolicy.idleFallbackInterval
        }
    }

    private func monitoringModeLogName(_ mode: MeetingMonitoringMode) -> String {
        switch mode {
        case .discovery:
            return "discovery"
        case .sourceLiveness:
            return "source_liveness"
        case .suspended:
            return "suspended"
        }
    }

    private func installFallbackEvaluationLoop(interval: TimeInterval) {
        guard currentFallbackInterval != interval else { return }
        currentFallbackInterval = interval
        fallbackEvaluationTask?.cancel()
        fallbackEvaluationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.scheduleEvaluation(.fallbackTimer)
            }
        }
    }

    private func mergedAudioInputProcesses(
        _ coreAudioProcesses: [AudioProcessActivity],
        sensorAttributions: SensorAttributionSnapshot,
        runningProcessIDsByBundleID: [String: pid_t],
        monitoringMode: MeetingMonitoringMode
    ) -> [AudioProcessActivity] {
        var processes = coreAudioProcesses
        let existingBundleIDs = Set(coreAudioProcesses.map(\.bundleID))

        let sourceBundleID: String?
        switch monitoringMode {
        case .sourceLiveness(_, let source):
            sourceBundleID = source.sourceBundleID
        case .discovery, .suspended:
            sourceBundleID = nil
        }

        let sensorBundleIDs = sensorAttributions.micBundleIDs
            .union(sensorAttributions.cameraBundleIDs)
            .sorted()

        for attributedBundleID in sensorBundleIDs {
            let bundleID: String
            if let sourceBundleID {
                guard MeetingAutoStopPolicy.bundleIDsReferToSameApp(attributedBundleID, sourceBundleID) else { continue }
                bundleID = sourceBundleID
            } else {
                bundleID = attributedBundleID
            }

            let appName = MeetingCandidateResolver.browserApps[bundleID]
                ?? MeetingCandidateResolver.dedicatedApps[bundleID]?.name
            guard let appName else { continue }
            guard !existingBundleIDs.contains(bundleID),
                  !existingBundleIDs.contains(where: { helperBundleID in
                      MeetingAutoStopPolicy.bundleIDsReferToSameApp(helperBundleID, bundleID)
                  }) else {
                continue
            }

            let isDedicatedSourceLiveness = sourceBundleID != nil
                && MeetingCandidateResolver.dedicatedApps[bundleID] != nil
            processes.append(AudioProcessActivity(
                pid: runningProcessIDsByBundleID[bundleID] ?? 0,
                bundleID: bundleID,
                appName: appName,
                isRunningInput: true,
                // Full-duplex was established during discovery. While tracking
                // that exact source, a current Control Center attribution is
                // sufficient positive liveness evidence without another HAL
                // process enumeration.
                isRunningOutput: isDedicatedSourceLiveness
            ))
        }

        return processes
    }

    private func scopedActivityCandidate(
        _ candidate: MeetingCandidate?,
        monitoringMode: MeetingMonitoringMode
    ) -> MeetingCandidate? {
        guard case .sourceLiveness(_, let source) = monitoringMode else {
            return candidate
        }
        guard let candidate else { return nil }
        return MeetingAutoStopPolicy.matches(candidate: candidate, source: source) ? candidate : nil
    }

    private func debounceDelay(for trigger: MeetingDetectionTrigger) -> TimeInterval {
        switch trigger {
        case .startup, .fallbackTimer:
            return 0
        case .micChanged, .cameraChanged, .sensorAttributionChanged, .audioAttributionChanged, .workspaceActivated,
             .calendarChanged, .promptStateChanged, .manualRefresh:
            return refreshPolicy.debounceDelay
        }
    }

    private func mergeTrigger(
        _ existing: MeetingDetectionTrigger?,
        with newTrigger: MeetingDetectionTrigger
    ) -> MeetingDetectionTrigger {
        guard let existing else { return newTrigger }
        return triggerPriority(newTrigger) >= triggerPriority(existing) ? newTrigger : existing
    }

    private func triggerPriority(_ trigger: MeetingDetectionTrigger) -> Int {
        switch trigger {
        case .startup: return 9
        case .micChanged, .sensorAttributionChanged, .audioAttributionChanged, .cameraChanged: return 8
        case .workspaceActivated, .calendarChanged: return 7
        case .promptStateChanged, .manualRefresh: return 6
        case .fallbackTimer: return 1
        }
    }

    private func updateRefreshState(
        micActive: Bool,
        cameraActive: Bool,
        calendarEvent: CalendarEventContext?,
        browserMeetings: [BrowserMeetingContext],
        foregroundBundleID: String?,
        visibility: MeetingPromptVisibility,
        candidate: MeetingCandidate?,
        keepSuspicious: Bool = false,
        now: Date
    ) {
        signalRefreshState.hasMicOrCameraSignal = micActive || cameraActive
        signalRefreshState.hasRecentBrowserMeeting = !browserMeetings.isEmpty
        signalRefreshState.hasActiveCandidate = candidate != nil || keepSuspicious
        signalRefreshState.hasPromptVisible = visibility.isVisible
        signalRefreshState.hasCalendarEvent = calendarEvent != nil
        signalRefreshState.foregroundIsMeetingCapableApp = foregroundBundleID.map { bundleID in
            MeetingCandidateResolver.browserApps[bundleID] != nil
                || MeetingCandidateResolver.dedicatedApps[bundleID] != nil
        } ?? false
        signalRefreshState.lastSuspicionAt = refreshPolicy.suspicionDate(
            state: signalRefreshState,
            now: now,
            resolvedCandidate: candidate
        )
    }

    private func associateActiveRecording(with candidate: MeetingCandidate) {
        if promptState.markRecordingStarted(candidate) {
            log("recording_session_consumed id=\(candidate.id)")
        }
    }

    private func logEvaluation(
        trigger: MeetingDetectionTrigger,
        decision: MeetingSignalRefreshDecision,
        timings: MeetingCollectionTimings,
        resolverDuration: TimeInterval,
        totalDuration: TimeInterval
    ) {
        Self.logger.notice(
            "evaluation trigger=\(String(describing: trigger), privacy: .public) mode=\(String(describing: decision.mode), privacy: .public) browser_ms=\(timings.browserMilliseconds, privacy: .public) audio_ms=\(timings.audioAttributionMilliseconds, privacy: .public) resolver_ms=\(Int(resolverDuration * 1000), privacy: .public) total_ms=\(Int(totalDuration * 1000), privacy: .public) refresh_browser=\(decision.refreshBrowserMeetings, privacy: .public) refresh_audio=\(decision.refreshAudioAttribution, privacy: .public) refresh_tracked_audio=\(decision.refreshTrackedAudioProcesses, privacy: .public)"
        )
    }

    private func log(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        fputs("[meeting-monitor] \(message)\n", stderr)
    }
}

private struct MeetingCollectedSignals {
    let runningApps: [RunningAppInfo]
    let browserMeetings: [BrowserMeetingContext]
    let foregroundBundleID: String?
    let runningProcessIDsByBundleID: [String: pid_t]
    let activeTabFallbackAttemptedBundleIDs: Set<String>
    let timings: MeetingCollectionTimings
}

private struct MeetingCollectionTimings {
    let browserDuration: TimeInterval
    let audioAttributionDuration: TimeInterval

    var browserMilliseconds: Int { Int(browserDuration * 1000) }
    var audioAttributionMilliseconds: Int { Int(audioAttributionDuration * 1000) }
}

struct AudioAttributionResult {
    let processes: [AudioProcessActivity]
    let duration: TimeInterval
    let startedRefresh: Bool
}

/// A blocked HAL observation never holds the detector actor or queues another
/// scan. Completion is the wake-up event; reset invalidates the result without
/// pretending the native work was cancelled.
actor AudioAttributionService {
    typealias Collect = ([AudioProcessActivity]?) -> [AudioProcessActivity]
    private let collect: Collect
    private let queue = DispatchQueue(label: "com.muesli.meeting-process-observation")
    private var trackedProcesses: [AudioProcessActivity] = []
    private var cachedEpisode: MeetingAudioAttributionEpisode?
    private var observationTask: Task<Void, Never>?
    private var generation = 0

    init(collect: Collect? = nil) {
        self.collect = collect ?? { tracked in
            let collector = AudioProcessAttributionCollector()
            return tracked.map { collector.refreshTrackedProcesses($0) } ?? collector.activeInputProcesses()
        }
    }

    func activeInputProcesses(
        refreshFull: Bool,
        refreshTracked: Bool,
        episode: MeetingAudioAttributionEpisode?,
        onChange: @escaping () async -> Void
    ) -> AudioAttributionResult {
        let started = (refreshFull || refreshTracked) && observationTask == nil && episode != nil
        if started {
            let token = generation
            let tracked = refreshFull ? nil : trackedProcesses
            observationTask = Task { [self, collect, queue] in
                let began = Date()
                let processes: [AudioProcessActivity] = await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: collect(tracked)) }
                }
                let elapsed = Date().timeIntervalSince(began)
                observationTask = nil
                guard generation == token else { return }
                trackedProcesses = processes
                cachedEpisode = episode
                fputs("[meeting-detection] process observation completed duration_ms=\(Int(elapsed * 1000))\n", stderr)
                await onChange()
            }
        }
        return AudioAttributionResult(
            processes: cachedEpisode == episode ? trackedProcesses.filter { $0.isRunningInput } : [],
            duration: 0,
            startedRefresh: started
        )
    }

    func waitForObservation() async {
        await observationTask?.value
    }

    func reset() {
        generation += 1
        trackedProcesses = []
        cachedEpisode = nil
    }
}

private actor MeetingSignalCollector {
    private let browserCollector = BrowserMeetingActivityCollector()

    func collect(
        runningApps: [RunningAppSnapshot],
        foregroundBundleID: String?,
        monitoringMode: MeetingMonitoringMode,
        refreshBrowserMeetings: Bool,
        refreshPolicy: MeetingSignalRefreshPolicy,
        refreshState: MeetingSignalRefreshState,
        now: Date
    ) async -> MeetingCollectedSignals {
        var activeTabFallbackAttemptedBundleIDs = Set<String>()
        let browserStart = Date()
        let browserProbeApps = scopedBrowserProbeApps(
            runningApps,
            monitoringMode: monitoringMode
        )
        let browserMeetings = await browserCollector.collect(
            runningApps: browserProbeApps,
            refresh: refreshBrowserMeetings,
            now: now
        ) { bundleID in
            guard refreshPolicy.allowsActiveTabFallbackProbe(for: bundleID, state: refreshState, now: now) else {
                return false
            }
            activeTabFallbackAttemptedBundleIDs.insert(bundleID)
            return true
        }
        let browserDuration = Date().timeIntervalSince(browserStart)

        return MeetingCollectedSignals(
            runningApps: runningApps.map {
                RunningAppInfo(bundleID: $0.bundleID, isActive: $0.isActive)
            },
            browserMeetings: browserMeetings,
            foregroundBundleID: foregroundBundleID,
            runningProcessIDsByBundleID: runningProcessIDsByBundleID(from: runningApps),
            activeTabFallbackAttemptedBundleIDs: activeTabFallbackAttemptedBundleIDs,
            timings: MeetingCollectionTimings(
                browserDuration: browserDuration,
                audioAttributionDuration: 0
            )
        )
    }

    private func runningProcessIDsByBundleID(from apps: [RunningAppSnapshot]) -> [String: pid_t] {
        var processIDs: [String: pid_t] = [:]
        for app in apps where processIDs[app.bundleID] == nil {
            processIDs[app.bundleID] = app.processIdentifier
        }
        return processIDs
    }

    private func scopedBrowserProbeApps(
        _ apps: [RunningAppSnapshot],
        monitoringMode: MeetingMonitoringMode
    ) -> [RunningAppSnapshot] {
        guard case .sourceLiveness(_, let source) = monitoringMode,
              let sourceBundleID = source.sourceBundleID else {
            return apps
        }
        return apps.filter { MeetingAutoStopPolicy.bundleIDsReferToSameApp($0.bundleID, sourceBundleID) }
    }


}

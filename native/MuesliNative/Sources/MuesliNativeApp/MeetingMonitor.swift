import AppKit
import CoreAudio
import Foundation
import os

@MainActor
final class MeetingMonitor {
    var calendarEventProvider: (() -> CalendarEventContext?)?
    var detectionEnabledProvider: (() -> Bool)?
    var recordingLifecycleProvider: (() -> MeetingRecordingLifecycleSnapshot)?
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

    private var micListenerDeviceID: AudioDeviceID = 0
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var lifecycleGeneration = 0
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        installMicListener()
        installDeviceChangeListener()
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
        removeMicListener()
        removeDeviceChangeListener()
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
            micDeviceID: micListenerDeviceID,
            cameraActive: cameraMonitor.isCameraActive,
            sensorAttributions: sensorAttributionMonitor.snapshot(now: now),
            calendarEvent: calendarEventProvider?(),
            detectionEnabled: detectionEnabledProvider?() ?? true,
            isRecording: lifecycle.isRecording,
            isStartingRecording: lifecycle.isStarting,
            monitoringMode: MeetingMonitoringModePolicy.resolve(lifecycle),
            isCalendarNotificationVisible: isCalendarNotificationVisibleProvider?() ?? false,
            promptVisibility: promptVisibilityProvider?()
                ?? MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil),
            mutedBundleIDs: mutedDetectionBundleIDsProvider?() ?? [],
            runningApps: runningApplicationState.runningApps,
            foregroundBundleID: runningApplicationState.foregroundBundleID
        )
    }

    private func installMicListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else { return }

        micListenerDeviceID = deviceID

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleEvaluation(.micChanged) }
        }
        micListenerBlock = block

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, nil, block)
    }

    private func removeMicListener() {
        guard micListenerDeviceID != 0, let block = micListenerBlock else { return }
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &runningAddress, nil, block)
        micListenerDeviceID = 0
        micListenerBlock = nil
    }

    private func installDeviceChangeListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.removeMicListener()
                self?.installMicListener()
                self?.scheduleEvaluation(.micChanged)
            }
        }
        deviceChangeListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceChangeListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        deviceChangeListenerBlock = nil
    }
}

private enum MeetingPromptUpdate {
    case show(MeetingCandidate)
    case hide
}

private struct MeetingDetectionEvaluationContext {
    let micDeviceID: AudioDeviceID
    let cameraActive: Bool
    let sensorAttributions: SensorAttributionSnapshot
    let calendarEvent: CalendarEventContext?
    let detectionEnabled: Bool
    let isRecording: Bool
    let isStartingRecording: Bool
    let monitoringMode: MeetingMonitoringMode
    let isCalendarNotificationVisible: Bool
    let promptVisibility: MeetingPromptVisibility
    let mutedBundleIDs: Set<String>
    let runningApps: [RunningAppSnapshot]
    let foregroundBundleID: String?

    static let disabled = MeetingDetectionEvaluationContext(
        micDeviceID: 0,
        cameraActive: false,
        sensorAttributions: .empty,
        calendarEvent: nil,
        detectionEnabled: false,
        isRecording: false,
        isStartingRecording: false,
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
        selfBundleID: String
    ) -> MeetingMediaSignals {
        let externalAudioInputProcesses = audioInputProcesses.filter {
            !isSelfBundleID($0.bundleID, selfBundleID: selfBundleID)
        }
        let selfMicAttributed = audioInputProcesses.contains {
            isSelfBundleID($0.bundleID, selfBundleID: selfBundleID)
        } || sensorAttributions.micBundleIDs.contains {
            isSelfBundleID($0, selfBundleID: selfBundleID)
        }
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

        signalRefreshState.hasMicOrCameraSignal = MeetingMediaSignalFilter.apply(
            deviceMicActive: false,
            cameraActive: context.cameraActive,
            audioInputProcesses: [],
            sensorAttributions: context.sensorAttributions,
            selfBundleID: resolver.selfBundleID
        ).hasMicOrCameraSignal
        signalRefreshState.hasCalendarEvent = context.calendarEvent != nil
        signalRefreshState.hasPromptVisible = context.promptVisibility.isVisible

        let refreshDecision = refreshPolicy.decision(
            trigger: trigger,
            state: signalRefreshState,
            monitoringMode: context.monitoringMode,
            now: now
        )
        async let audioAttributionResult = audioAttributionService.activeInputProcesses(
            refresh: refreshDecision.refreshAudioAttribution
        )
        let collectedSignals = await signalCollector.collect(
            micDeviceID: context.micDeviceID,
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
        if refreshDecision.refreshAudioAttribution {
            signalRefreshState.lastAudioAttributionRefreshAt = now
        }
        if refreshDecision.refreshBrowserMeetings {
            signalRefreshState.lastBrowserRefreshAt = now
        }
        for bundleID in collectedSignals.activeTabFallbackAttemptedBundleIDs {
            signalRefreshState.lastActiveTabFallbackAttemptAtByBundleID[bundleID] = now
        }

        let rawAudioInputProcesses = mergedAudioInputProcesses(
            context.monitoringMode.allowsFullAudioAttribution ? audioResult.processes : [],
            sensorAttributions: context.sensorAttributions,
            runningProcessIDsByBundleID: collectedSignals.runningProcessIDsByBundleID,
            monitoringMode: context.monitoringMode
        )
        let mediaSignals = MeetingMediaSignalFilter.apply(
            deviceMicActive: collectedSignals.micActive,
            cameraActive: context.cameraActive,
            audioInputProcesses: rawAudioInputProcesses,
            sensorAttributions: context.sensorAttributions,
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
        let candidate = isGloballySuppressed(now: now) ? nil : unmutedActivityCandidate
        logCandidateIfChanged(candidate)
        updateRefreshState(
            trigger: trigger,
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
                guard bundleIDsReferToSameApp(attributedBundleID, sourceBundleID) else { continue }
                bundleID = sourceBundleID
            } else {
                bundleID = attributedBundleID
            }

            let appName = MeetingCandidateResolver.browserApps[bundleID]
                ?? MeetingCandidateResolver.dedicatedApps[bundleID]?.name
            guard let appName else { continue }
            guard !existingBundleIDs.contains(bundleID),
                  !existingBundleIDs.contains(where: { helperBundleID in
                      bundleIDsReferToSameApp(helperBundleID, bundleID)
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

    private func bundleIDsReferToSameApp(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        return lhs == rhs || lhs.hasPrefix("\(rhs).") || rhs.hasPrefix("\(lhs).")
    }

    private func scopedActivityCandidate(
        _ candidate: MeetingCandidate?,
        monitoringMode: MeetingMonitoringMode
    ) -> MeetingCandidate? {
        guard case .sourceLiveness(_, let source) = monitoringMode else {
            return candidate
        }
        guard let candidate else { return nil }
        if MeetingAutoStopPolicy.matches(candidate: candidate, source: source) {
            return candidate
        }

        // URL-backed sources have room identity and must match it. Native-app
        // sources have no room identifier, so their already-established bundle
        // identity is the narrowest liveness signal macOS exposes.
        guard source.normalizedURL == nil,
              let sourceBundleID = source.sourceBundleID,
              let candidateBundleID = candidate.sourceBundleID,
              bundleIDsReferToSameApp(sourceBundleID, candidateBundleID) else {
            return nil
        }
        return candidate
    }

    private func debounceDelay(for trigger: MeetingDetectionTrigger) -> TimeInterval {
        switch trigger {
        case .startup, .fallbackTimer:
            return 0
        case .micChanged, .cameraChanged, .sensorAttributionChanged, .workspaceActivated,
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
        case .micChanged, .sensorAttributionChanged, .cameraChanged: return 8
        case .workspaceActivated, .calendarChanged: return 7
        case .promptStateChanged, .manualRefresh: return 6
        case .fallbackTimer: return 1
        }
    }

    private func updateRefreshState(
        trigger: MeetingDetectionTrigger,
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
            after: trigger,
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
            "evaluation trigger=\(String(describing: trigger), privacy: .public) mode=\(String(describing: decision.mode), privacy: .public) browser_ms=\(timings.browserMilliseconds, privacy: .public) audio_ms=\(timings.audioAttributionMilliseconds, privacy: .public) resolver_ms=\(Int(resolverDuration * 1000), privacy: .public) total_ms=\(Int(totalDuration * 1000), privacy: .public) refresh_browser=\(decision.refreshBrowserMeetings, privacy: .public) refresh_audio=\(decision.refreshAudioAttribution, privacy: .public)"
        )
    }

    private func log(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        fputs("[meeting-monitor] \(message)\n", stderr)
    }
}

private struct MeetingCollectedSignals {
    let micActive: Bool
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

private struct AudioAttributionResult {
    let processes: [AudioProcessActivity]
    let duration: TimeInterval
}

private actor AudioAttributionService {
    private let collector = AudioProcessAttributionCollector()
    private var cachedInputProcesses: [AudioProcessActivity] = []

    func activeInputProcesses(refresh: Bool) -> AudioAttributionResult {
        guard refresh else {
            return AudioAttributionResult(processes: cachedInputProcesses, duration: 0)
        }

        let start = Date()
        let processes = collector.activeInputProcesses()
        cachedInputProcesses = processes
        return AudioAttributionResult(
            processes: processes,
            duration: Date().timeIntervalSince(start)
        )
    }

    func reset() {
        cachedInputProcesses = []
    }
}

private actor MeetingSignalCollector {
    private let browserCollector = BrowserMeetingActivityCollector()

    func collect(
        micDeviceID: AudioDeviceID,
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
            micActive: isMicActive(deviceID: micDeviceID),
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
        let sourceBundleIDLowercased = sourceBundleID.lowercased()
        return apps.filter { app in
            let bundleID = app.bundleID.lowercased()
            return bundleID == sourceBundleIDLowercased
                || bundleID.hasPrefix("\(sourceBundleIDLowercased).")
                || sourceBundleIDLowercased.hasPrefix("\(bundleID).")
        }
    }

    private func isMicActive(deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }

        var isRunning: UInt32 = 0
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &size,
            &isRunning
        ) == noErr else { return false }

        return isRunning != 0
    }
}

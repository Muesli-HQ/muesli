import AppKit
import CoreAudio
import Foundation
import os

@MainActor
final class MeetingMonitor {
    var calendarEventProvider: (() -> CalendarEventContext?)?
    var detectionEnabledProvider: (() -> Bool)?
    var isRecordingProvider: (() -> Bool)?
    var isStartingRecordingProvider: (() -> Bool)?
    var isCalendarNotificationVisibleProvider: (() -> Bool)?
    var promptVisibilityProvider: (() -> MeetingPromptVisibility)?
    var mutedDetectionBundleIDsProvider: (() -> Set<String>)?
    var onPromptCandidateChanged: ((MeetingCandidate?) -> Void)?

    private lazy var detectionService = MeetingDetectionService(
        contextProvider: { [weak self] now in
            self?.makeEvaluationContext(now: now) ?? .disabled
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

        Task { [detectionService] in
            await detectionService.start(generation: generation)
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
        Task { [detectionService] in
            await detectionService.suppressWhileActive()
        }
    }

    func resumeAfterCooldown() {
        Task { [detectionService] in
            await detectionService.resumeAfterCooldown()
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
        Task { [detectionService] in
            await detectionService.markRecordingStarted(candidate)
        }
    }

    private func scheduleEvaluation(_ trigger: MeetingDetectionTrigger) {
        guard isStarted else { return }
        Task { [detectionService] in
            await detectionService.scheduleEvaluation(trigger)
        }
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
        return MeetingDetectionEvaluationContext(
            micDeviceID: micListenerDeviceID,
            cameraActive: cameraMonitor.isCameraActive,
            sensorAttributions: sensorAttributionMonitor.snapshot(now: now),
            calendarEvent: calendarEventProvider?(),
            detectionEnabled: detectionEnabledProvider?() ?? true,
            isRecording: isRecordingProvider?() ?? false,
            isStartingRecording: isStartingRecordingProvider?() ?? false,
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
        isCalendarNotificationVisible: false,
        promptVisibility: MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil),
        mutedBundleIDs: [],
        runningApps: [],
        foregroundBundleID: nil
    )
}

private actor MeetingDetectionService {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingDetection")

    private let contextProvider: @MainActor (Date) -> MeetingDetectionEvaluationContext
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

    init(
        contextProvider: @escaping @MainActor (Date) -> MeetingDetectionEvaluationContext,
        promptHandler: @escaping @MainActor (MeetingPromptUpdate) -> Void
    ) {
        self.contextProvider = contextProvider
        self.promptHandler = promptHandler
    }

    func start(generation: Int) async {
        if let resetTask {
            await resetTask.value
            self.resetTask = nil
        }
        guard generation >= latestLifecycleGeneration else { return }
        latestLifecycleGeneration = generation
        guard !isStarted else { return }
        isStarted = true
        installFallbackEvaluationLoop(interval: refreshPolicy.idleFallbackInterval)
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

    func scheduleEvaluation(_ trigger: MeetingDetectionTrigger) {
        guard isStarted else { return }
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

    func suppressWhileActive() {
        globalSuppressUntil = .distantFuture
        dismissVisiblePromptForSuppression()
    }

    func resumeAfterCooldown() {
        globalSuppressUntil = Date().addingTimeInterval(15)
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

    func markRecordingStarted(_ candidate: MeetingCandidate?) {
        if let candidate {
            log("recording_started id=\(candidate.id)")
        } else {
            log("recording_started")
        }
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
        guard context.detectionEnabled else {
            dismissVisiblePromptForSuppression()
            return
        }

        signalRefreshState.hasMicOrCameraSignal = context.cameraActive
            || !context.sensorAttributions.micBundleIDs.isEmpty
            || !context.sensorAttributions.cameraBundleIDs.isEmpty
        signalRefreshState.hasCalendarEvent = context.calendarEvent != nil
        signalRefreshState.hasPromptVisible = context.promptVisibility.isVisible

        let refreshDecision = refreshPolicy.decision(trigger: trigger, state: signalRefreshState, now: now)
        async let audioAttributionResult = audioAttributionService.activeInputProcesses(
            refresh: refreshDecision.refreshAudioAttribution
        )
        let collectedSignals = await signalCollector.collect(
            micDeviceID: context.micDeviceID,
            runningApps: context.runningApps,
            foregroundBundleID: context.foregroundBundleID,
            refreshBrowserMeetings: refreshDecision.refreshBrowserMeetings,
            refreshPolicy: refreshPolicy,
            refreshState: signalRefreshState,
            now: now
        )
        let audioResult = await audioAttributionResult
        guard !Task.isCancelled, isStarted else { return }
        if refreshDecision.refreshAudioAttribution {
            signalRefreshState.lastAudioAttributionRefreshAt = now
        }
        if refreshDecision.refreshBrowserMeetings {
            signalRefreshState.lastBrowserRefreshAt = now
        }
        for bundleID in collectedSignals.appleScriptAttemptedBundleIDs {
            signalRefreshState.lastAppleScriptAttemptAtByBundleID[bundleID] = now
        }

        let audioInputProcesses = mergedAudioInputProcesses(
            audioResult.processes,
            sensorAttributions: context.sensorAttributions,
            runningProcessIDsByBundleID: collectedSignals.runningProcessIDsByBundleID
        )
        let micActive = collectedSignals.micActive
            || !audioInputProcesses.isEmpty
            || !context.sensorAttributions.micBundleIDs.isEmpty
        let cameraActive = context.cameraActive || !context.sensorAttributions.cameraBundleIDs.isEmpty

        let snapshot = MeetingSignalSnapshot(
            micActive: micActive,
            cameraActive: cameraActive,
            calendarEvent: context.calendarEvent,
            runningApps: collectedSignals.runningApps,
            browserMeetings: collectedSignals.browserMeetings,
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: collectedSignals.foregroundBundleID,
            now: now
        )

        let resolverStart = Date()
        let resolvedCandidate = isGloballySuppressed(now: now) ? nil : resolver.resolve(snapshot)
        let resolverDuration = Date().timeIntervalSince(resolverStart)
        let unmutedCandidate = isMuted(resolvedCandidate, mutedBundleIDs: context.mutedBundleIDs) ? nil : resolvedCandidate
        let candidate = await mediaSessionTracker.stabilize(
            candidate: unmutedCandidate,
            snapshot: snapshot
        )
        logCandidateIfChanged(candidate)
        updateRefreshState(
            trigger: trigger,
            micActive: micActive,
            cameraActive: cameraActive,
            calendarEvent: context.calendarEvent,
            browserMeetings: collectedSignals.browserMeetings,
            foregroundBundleID: collectedSignals.foregroundBundleID,
            visibility: context.promptVisibility,
            candidate: candidate,
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

        let nextDecision = refreshPolicy.decision(trigger: .fallbackTimer, state: signalRefreshState, now: now)
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
        case .calendarNotificationVisible:
            log("prompt_suppressed id=\(candidate.id) reason=calendar_notification_visible")
        case .recording:
            log("prompt_suppressed id=\(candidate.id) reason=recording")
        default:
            break
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
        runningProcessIDsByBundleID: [String: pid_t]
    ) -> [AudioProcessActivity] {
        var processes = coreAudioProcesses
        let existingBundleIDs = Set(coreAudioProcesses.map(\.bundleID))

        for bundleID in sensorAttributions.micBundleIDs.sorted() {
            guard let appName = MeetingCandidateResolver.browserApps[bundleID] else { continue }
            guard !existingBundleIDs.contains(bundleID),
                  !existingBundleIDs.contains(where: { helperBundleID in
                      helperBundleID.lowercased().hasPrefix("\(bundleID.lowercased()).")
                  }) else {
                continue
            }

            processes.append(AudioProcessActivity(
                pid: runningProcessIDsByBundleID[bundleID] ?? 0,
                bundleID: bundleID,
                appName: appName,
                isRunningInput: true,
                isRunningOutput: false
            ))
        }

        return processes
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
        now: Date
    ) {
        signalRefreshState.hasMicOrCameraSignal = micActive || cameraActive
        signalRefreshState.hasRecentBrowserMeeting = !browserMeetings.isEmpty
        signalRefreshState.hasActiveCandidate = candidate != nil
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
    let appleScriptAttemptedBundleIDs: Set<String>
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
        refreshBrowserMeetings: Bool,
        refreshPolicy: MeetingSignalRefreshPolicy,
        refreshState: MeetingSignalRefreshState,
        now: Date
    ) async -> MeetingCollectedSignals {
        var appleScriptAttemptedBundleIDs = Set<String>()
        let browserStart = Date()
        let browserMeetings = await browserCollector.collect(
            runningApps: runningApps,
            refresh: refreshBrowserMeetings,
            now: now
        ) { bundleID in
            guard refreshPolicy.allowsAppleScript(for: bundleID, state: refreshState, now: now) else {
                return false
            }
            appleScriptAttemptedBundleIDs.insert(bundleID)
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
            appleScriptAttemptedBundleIDs: appleScriptAttemptedBundleIDs,
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

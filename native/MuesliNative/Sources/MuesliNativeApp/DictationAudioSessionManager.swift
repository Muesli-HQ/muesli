import CoreAudio
import Foundation

enum DictationAudioSessionState: Equatable {
    case idle
    case armed(UUID)
    case acquiringAudio(UUID)
    case streamActive(UUID)
    case speechDetected(UUID)

    var sessionID: UUID? {
        switch self {
        case .idle:
            return nil
        case .armed(let id), .acquiringAudio(let id), .streamActive(let id), .speechDetected(let id):
            return id
        }
    }
}

enum DictationAudioSessionEvent {
    case armed(UUID, source: String)
    case acquiringAudio(UUID)
    case streamActive(UUID, capturedAt: Date)
    case speechDetected(UUID, capturedAt: Date)
    case noAudioTimeout(UUID, at: Date)
    case startupWarning(UUID)
    case stopped(UUID?, wavURL: URL?)
    case audioRestored(UUID?)
    case cancelled(UUID?, reason: String)
    case failed(UUID?, error: Error)
    case latency(String, Date)
}

enum DictationWarmupIntent: Equatable {
    case idlePrewarm(IdlePrewarmTrigger)
    case postDictation(PostDictationTrigger)

    var debugName: String {
        switch self {
        case .idlePrewarm(let trigger):
            return "idle_\(trigger.debugName)"
        case .postDictation(let trigger):
            return "post_dictation_\(trigger.debugName)"
        }
    }
}

enum IdlePrewarmTrigger: String {
    case startup
    case routeChange
    case configChange
    case permissionsReady
    case meetingStateChanged
    case backendRecovery

    var debugName: String { rawValue }
}

enum PostDictationTrigger: String {
    case cancel
    case stopWithoutWav
    case shortRecording
    case dictationStop
    case transcriptionComplete
    case transcriptionCancelled
    case transcriptionFailed

    var debugName: String { rawValue }
}

protocol DictationAudioRecording: AnyObject {
    var preferredInputDeviceID: AudioObjectID? { get set }
    var keepsAudioGraphWarm: Bool { get set }
    var onFirstCapturedAudioBuffer: ((Date) -> Void)? { get set }
    var onFirstSpeechDetected: ((Date) -> Void)? { get set }
    var onNoAudioTimeout: ((Date) -> Void)? { get set }
    var onRecordingFailed: ((Error, UUID) -> Void)? { get set }
    var onLatencyEvent: ((String, Date) -> Void)? { get set }
    var onAudioBuffer: (([Float]) -> Void)? { get set }

    func prepare() throws
    func beginExplicitWarmup(preferredInputDeviceID: AudioObjectID?)
    func warmUp(preferredInputDeviceID: AudioObjectID?) throws
    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws
    func coolDown()
    func start() throws -> UUID
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float
}

extension DictationAudioRecording {
    var onAudioBuffer: (([Float]) -> Void)? {
        get { nil }
        set {}
    }
}

extension MicrophoneRecorder: DictationAudioRecording {}

final class DictationAudioSessionManager: @unchecked Sendable {
    private struct RouteSnapshot {
        let routeKind: AudioOutputRouteKind
        let preferredInputDeviceID: AudioObjectID?
        let systemDefaultInputIsBuiltIn: Bool
        let debugDescription: String

        var usesSpeakerDefaultRecorder: Bool {
            routeKind == .speakerLike && preferredInputDeviceID == nil
        }

        var usesAppScopedRecorder: Bool {
            preferredInputDeviceID != nil
        }

        var canSpeculativelyWarmRecorder: Bool {
            usesSpeakerDefaultRecorder && systemDefaultInputIsBuiltIn
        }

        var shouldDuck: Bool {
            // Unknown routes are ducked to avoid speaker bleed during route
            // transitions. Lifecycle sounds separately avoid unknown outputs.
            routeKind != .headphoneLike
        }
    }

    private let recorder: DictationAudioRecording
    private let duckingController: AudioDuckingManaging
    private let mediaPlaybackController: MediaPlaybackManaging
    private let routingController: DictationAudioRouting
    private let queue: DispatchQueue
    private let eventQueue: DispatchQueue

    private var stateStorage: DictationAudioSessionState = .idle
    private var routeSnapshot: RouteSnapshot
    private var duckingEnabledForSession = false
    private var externalSessionActive = false
    private var routeRefreshGeneration = 0
    private var activeRecorderRunID: UUID?
    private var endCaptureInterval: (() -> Void)?
    private var failedSessionID: UUID?
    private let sessionHintLock = NSLock()
    private var sessionHint: UUID?
    private var recorderRunHint: UUID?
    private var nativeStartupSessionID: UUID?
    private var externalSessionHint = false
    private var retiringSessionID: UUID?
    private let inputObserver: DictationInputObserving?
    private let startupWatchdog: DictationStartupWatchdog?
    private let startupTelemetry: ((DictationStartupReport) -> Void)?
    private let telemetryQueue = DispatchQueue(label: "com.muesli.microphone-startup-telemetry", qos: .utility)

    #if DEBUG
    var devFaults: DictationDevFaults?
    var devStartupWait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    #endif

    var onEvent: ((DictationAudioSessionEvent) -> Void)?

    var onAudioBuffer: (([Float]) -> Void)? {
        get { recorder.onAudioBuffer }
        set { recorder.onAudioBuffer = newValue }
    }

    init(
        recorder: DictationAudioRecording,
        duckingController: AudioDuckingManaging,
        mediaPlaybackController: MediaPlaybackManaging = MediaPlaybackController(),
        routingController: DictationAudioRouting,
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.dictation-audio-session-manager"),
        eventQueue: DispatchQueue = .main,
        inputObserver: DictationInputObserving? = nil,
        startupOwner: DictationStartupOwner = .dictation,
        startupWarningDelay: TimeInterval? = DictationStartupWatchdog.defaultWarningDelay,
        startupScheduler: DictationStartupWatchdog.Scheduler? = nil,
        startupTelemetry: ((DictationStartupReport) -> Void)? = nil
    ) {
        self.startupWatchdog = startupWarningDelay.map {
            DictationStartupWatchdog(warningDelay: $0, owner: startupOwner, schedule: startupScheduler)
        }
        self.inputObserver = inputObserver
        self.startupTelemetry = startupTelemetry
        self.recorder = recorder
        self.duckingController = duckingController
        self.mediaPlaybackController = mediaPlaybackController
        self.routingController = routingController
        self.queue = queue
        self.eventQueue = eventQueue
        self.routeSnapshot = RouteSnapshot(
            routeKind: routingController.currentOutputRouteKindForDebug(),
            preferredInputDeviceID: routingController.cachedPreferredInputDeviceIDForDictation(),
            systemDefaultInputIsBuiltIn: routingController.systemDefaultInputIsBuiltInForDictation(),
            debugDescription: routingController.currentRouteDebugDescription()
        )

        startupWatchdog?.onReport = { [weak self] report in self?.handleStartupReport(report) }
        recorder.onLatencyEvent = { [weak self] event, date in
            self?.emitLatency(event, at: date)
        }
    }

    var currentState: DictationAudioSessionState {
        queue.sync { stateStorage }
    }

    var currentSessionID: UUID? {
        sessionHintLock.withLock { sessionHint ?? retiringSessionID }
    }

    var hasActiveSession: Bool {
        sessionHintLock.withLock { sessionHint != nil || retiringSessionID != nil || externalSessionHint }
    }

    var isRetiringStartup: Bool {
        sessionHintLock.withLock { retiringSessionID != nil }
    }

    func isStartupPending(_ id: UUID) -> Bool {
        sessionHintMatches(id) && (startupWatchdog?.isPending(id) ?? false)
    }

    func currentPower() -> Float {
        recorder.currentPower()
    }

    @discardableResult
    func arm(source: String) -> UUID {
        let admission = ensureSession()
        let sessionID = admission.id
        if admission.isRetiring {
            rejectRetiringStartup(sessionID)
            return sessionID
        }
        emit(.armed(sessionID, source: source))
        emitLatency("ui_armed")
        queue.async { [self] in
            self.cancelPendingRouteRefreshLocked()
            guard self.sessionHintMatches(sessionID) else {
                self.emitLatency("stale_session_ignored:\(source)")
                return
            }
            guard self.beginStartupWork(sessionID) else { return }
            defer { self.endStartupWork(sessionID) }
            self.ensureSessionStateLocked(sessionID)
            guard self.isCurrent(sessionID) else { return }
            self.stateStorage = .armed(sessionID)
            #if DEBUG
            if self.devFaults?.skipsMicrophoneWarmup == true { return }
            #endif
            self.routeSnapshot = self.makeRouteSnapshot(refreshInput: true)
            self.emitLatency("route_snapshot \(self.routeSnapshot.debugDescription)")
            let recorderInputDeviceID = self.recorderInputDeviceID(for: self.routeSnapshot)
            self.recorder.preferredInputDeviceID = recorderInputDeviceID
            guard self.routeSnapshot.canSpeculativelyWarmRecorder else {
                self.recorder.keepsAudioGraphWarm = false
                if self.routeSnapshot.usesAppScopedRecorder {
                    self.recorder.beginExplicitWarmup(preferredInputDeviceID: recorderInputDeviceID)
                    self.emitLatency("activation_async_prepare_started:\(source):app_scoped_route")
                } else {
                    self.emitLatency("activation_skipped:\(source):\(self.activationWarmupSkipReason(route: self.routeSnapshot))")
                }
                fputs("[dictation-session] armed source=\(source) skipped activation \(self.routeSnapshot.debugDescription)\n", stderr)
                return
            }
            self.recorder.keepsAudioGraphWarm = true
            do {
                self.emitLatency("activation_begin:\(source)")
                try self.recorder.activateWarmEngine(preferredInputDeviceID: recorderInputDeviceID)
                self.emitLatency("activation_end:\(source)")
                fputs("[dictation-session] armed source=\(source) \(self.routeSnapshot.debugDescription)\n", stderr)
            } catch {
                self.emitLatency("activation_failed:\(source)")
                self.failCurrentSession(error: error)
            }
        }
        return sessionID
    }

    @discardableResult
    func beginRecording(mode: String, duckingEnabled: Bool, mediaPauseEnabled: Bool,
                        captureInterval: (() -> Void)? = nil) -> UUID {
        let admission = ensureSession()
        let sessionID = admission.id
        if admission.isRetiring {
            captureInterval?()
            rejectRetiringStartup(sessionID)
            return sessionID
        }
        startupWatchdog?.begin(sessionID)
        queue.async { [self] in
            var adoptedInterval = false
            defer { if !adoptedInterval { captureInterval?() } }
            self.cancelPendingRouteRefreshLocked()
            guard self.sessionHintMatches(sessionID) else {
                self.emitLatency("stale_session_ignored:\(mode)")
                return
            }
            guard self.failedSessionID != sessionID else {
                self.emitLatency("stale_session_ignored:\(mode)")
                return
            }
            let previousState = self.stateStorage
            self.ensureSessionStateLocked(sessionID)
            guard self.isCurrent(sessionID) else { return }
            switch previousState {
            case .acquiringAudio, .streamActive, .speechDetected:
                self.emitLatency("activation_reused:\(mode)")
                return
            default:
                break
            }
            guard self.beginStartupWork(sessionID) else { return }
            defer { self.endStartupWork(sessionID) }
            self.bindStartupCallbacks(sessionID)
            self.endCaptureInterval = captureInterval
            adoptedInterval = true
            self.stateStorage = .acquiringAudio(sessionID)
            self.emit(.acquiringAudio(sessionID))
            #if DEBUG
            if self.devFaults?.consume(.microphoneStartup) == true {
                // Occupy only the capture queue, as a blocked native start would.
                // The real independent timer emits a warning; no mic opens.
                self.startupWatchdog?.phase(.startingRecorder, session: sessionID)
                self.devStartupWait(DictationDevFaults.startupStall)
                return
            }
            #endif
            self.startupWatchdog?.phase(.selectingInput, session: sessionID)
            self.emitLatency("threshold_met:\(mode)")
            if case .armed = previousState {
                // AirPods can become the active route between hotkey arm and
                // threshold. Refresh here so a stale speaker snapshot does not
                // start the system-default recorder while CoreAudio is moving
                // the route to headphones.
                self.routeSnapshot = self.makeRouteSnapshot(refreshInput: true)
                self.emitLatency("route_snapshot_refreshed:\(mode) \(self.routeSnapshot.debugDescription)")
            } else {
                self.routeSnapshot = self.makeRouteSnapshot(refreshInput: true)
            }
            self.startupWatchdog?.phase(.audioControls, session: sessionID, context: self.startupContext())
            self.beginSessionAudioControls(duckingEnabled: duckingEnabled, mediaPauseEnabled: mediaPauseEnabled)
            self.duckingController.ensureCurrentDefaultDucked()
            self.startupWatchdog?.phase(.configuringRecorder, session: sessionID)
            let recorderInputDeviceID = self.recorderInputDeviceID(for: self.routeSnapshot)
            self.inputObserver?.start(sessionID: sessionID, preferredInputDeviceID: recorderInputDeviceID) { [weak self] error in
                self?.retireSession(sessionID, error: error)
            }
            self.recorder.preferredInputDeviceID = recorderInputDeviceID
            self.recorder.keepsAudioGraphWarm = self.routeSnapshot.canSpeculativelyWarmRecorder
            do {
                self.emitLatency("activation_begin:\(mode)")
                self.startupWatchdog?.phase(.preparingRecorder, session: sessionID)
                if self.routeSnapshot.canSpeculativelyWarmRecorder {
                    try self.recorder.activateWarmEngine(preferredInputDeviceID: recorderInputDeviceID)
                } else {
                    self.emitLatency("activation_prepare_skipped:\(mode):\(self.activationWarmupSkipReason(route: self.routeSnapshot))")
                }
                guard self.sessionHintMatches(sessionID) else { return }
                self.startupWatchdog?.phase(.startingRecorder, session: sessionID)
                self.activeRecorderRunID = try self.recorder.start()
                self.sessionHintLock.withLock {
                    if self.sessionHint == sessionID { self.recorderRunHint = self.activeRecorderRunID }
                }
                self.startupWatchdog?.startReturned(sessionID)
                self.emitLatency("activation_end:\(mode)")
                fputs("[dictation-session] recording mode=\(mode) \(self.routeSnapshot.debugDescription)\n", stderr)
            } catch {
                self.emitLatency("activation_failed:\(mode)")
                guard self.sessionHintMatches(sessionID) else { return }
                self.retireSession(sessionID, error: error)
            }
        }
        return sessionID
    }

    func beginExternalSession(source: String, duckingEnabled: Bool, mediaPauseEnabled: Bool) {
        setExternalSessionHint(true)
        queue.async { [self] in
            self.cancelPendingRouteRefreshLocked()
            self.externalSessionActive = true
            self.routeSnapshot = self.makeRouteSnapshot(refreshInput: true)
            self.emitLatency("external_begin:\(source)")
            self.beginSessionAudioControls(duckingEnabled: duckingEnabled, mediaPauseEnabled: mediaPauseEnabled)
            self.duckingController.ensureCurrentDefaultDucked()
        }
    }

    func endExternalSession(reason: String) {
        setExternalSessionHint(false)
        queue.async { [self] in
            guard self.externalSessionActive else { return }
            self.externalSessionActive = false
            self.emitLatency("external_end:\(reason)")
            self.restoreSessionAudioState()
        }
    }

    func stop() {
        let requestedSessionID = detachSessionHint(retire: true)
        startupWatchdog?.finish(requestedSessionID, outcome: .stopped)
        if let requestedSessionID { inputObserver?.stop(sessionID: requestedSessionID) }
        queue.async { [self] in
            guard self.stateStorage.sessionID == nil || self.stateStorage.sessionID == requestedSessionID else { return }
            let sessionID = requestedSessionID
            guard sessionID != nil else {
                self.restoreSessionAudioState(completion: nil)
                return
            }
            self.emitLatency("stop")
            self.recorder.keepsAudioGraphWarm = false
            let wavURL = self.recorder.stop()
            self.finishCaptureInterval()
            self.activeRecorderRunID = nil
            self.recorder.preferredInputDeviceID = nil
            self.stateStorage = .idle
            self.releaseRetiringSession(sessionID)
            self.emit(.stopped(sessionID, wavURL: wavURL))
            self.restoreSessionAudioState {
                self.emit(.audioRestored(sessionID))
            }
        }
    }

    func cancel(reason: String) {
        let requestedSessionID = detachSessionHint(clearExternalSession: true, retire: true)
        startupWatchdog?.finish(requestedSessionID, outcome: .cancelled)
        if let requestedSessionID { inputObserver?.stop(sessionID: requestedSessionID) }
        queue.async { [self] in
            guard self.stateStorage.sessionID == nil || self.stateStorage.sessionID == requestedSessionID else { return }
            let sessionID = requestedSessionID
            self.recorder.keepsAudioGraphWarm = false
            self.recorder.cancel()
            self.finishCaptureInterval()
            self.activeRecorderRunID = nil
            self.recorder.preferredInputDeviceID = nil
            self.stateStorage = .idle
            self.externalSessionActive = false
            self.restoreSessionAudioState()
            self.emitLatency("cancelled:\(reason)")
            self.releaseRetiringSession(sessionID)
            self.emit(.cancelled(sessionID, reason: reason))
        }
    }

    func refreshRoute(
        intent: DictationWarmupIntent,
        delay: TimeInterval = 0,
        canWarmUp: Bool,
        refreshRoutingCache: Bool = true
    ) {
        // A route-controller callback already follows its own cache refresh.
        // Re-entering the controller from that callback performs a second HAL
        // inspection in the same transition and can wedge on CoreAudio's
        // command gate. Other callers retain the explicit refresh by default.
        if refreshRoutingCache {
            routingController.refreshRouteCache()
        }
        queue.async { [self] in
            self.routeRefreshGeneration += 1
            let generation = self.routeRefreshGeneration
            guard delay > 0 else {
                self.performRouteRefreshLocked(intent: intent, canWarmUp: canWarmUp, generation: generation)
                return
            }
            self.emitLatency("route_refresh_deferred:\(intent.debugName)")
            self.queue.asyncAfter(deadline: .now() + delay) { [self] in
                self.performRouteRefreshLocked(intent: intent, canWarmUp: canWarmUp, generation: generation)
            }
        }
    }

    func coolDown(reason: String) {
        queue.async { [self] in
            guard self.stateStorage == .idle, !self.externalSessionActive else { return }
            self.recorder.keepsAudioGraphWarm = false
            self.recorder.coolDown()
            self.emitLatency("cool_down:\(reason)")
        }
    }

    private func ensureSession() -> (id: UUID, isRetiring: Bool) {
        sessionHintLock.withLock {
            // Admission and the retirement check are atomic: cleanup can finish
            // concurrently, but a retry must never reuse the retired ID.
            if let retiringSessionID { return (retiringSessionID, true) }
            if let current = sessionHint { return (current, false) }
            let id = UUID()
            sessionHint = id
            recorderRunHint = nil
            return (id, false)
        }
    }

    private func ensureSessionStateLocked(_ sessionID: UUID) {
        if stateStorage.sessionID == nil {
            stateStorage = .armed(sessionID)
        }
        if failedSessionID != sessionID {
            failedSessionID = nil
        }
    }

    private func clearSessionHint(_ sessionID: UUID?) {
        sessionHintLock.withLock {
            guard self.sessionHint == sessionID || sessionID == nil else { return }
            self.sessionHint = nil
        }
    }

    private func beginStartupWork(_ id: UUID) -> Bool {
        sessionHintLock.withLock {
            guard sessionHint == id else { return false }
            nativeStartupSessionID = id
            return true
        }
    }

    private func endStartupWork(_ id: UUID) {
        sessionHintLock.withLock {
            if nativeStartupSessionID == id { nativeStartupSessionID = nil }
        }
    }

    private func detachSessionHint(clearExternalSession: Bool = false, retire: Bool = false) -> UUID? {
        sessionHintLock.withLock {
            let detachedSessionID = sessionHint
            sessionHint = nil
            recorderRunHint = nil
            if retire, let detachedSessionID, nativeStartupSessionID == detachedSessionID {
                retiringSessionID = detachedSessionID
            }
            if clearExternalSession {
                externalSessionHint = false
            }
            return detachedSessionID
        }
    }

    private func sessionHintMatches(_ sessionID: UUID) -> Bool {
        sessionHintLock.withLock {
            self.sessionHint == sessionID
        }
    }

    private func setExternalSessionHint(_ active: Bool) {
        sessionHintLock.withLock {
            externalSessionHint = active
        }
    }

    private func isCurrent(_ sessionID: UUID) -> Bool {
        stateStorage.sessionID == sessionID
    }

    private func cancelPendingRouteRefreshLocked() {
        routeRefreshGeneration += 1
    }

    private func performRouteRefreshLocked(intent: DictationWarmupIntent, canWarmUp: Bool, generation: Int) {
        guard routeRefreshGeneration == generation else {
            emitLatency("route_refresh_cancelled:\(intent.debugName)")
            return
        }
        routeSnapshot = makeRouteSnapshot(refreshInput: false)
        emitLatency("route_refresh:\(intent.debugName) \(routeSnapshot.debugDescription)")
        if intent == .idlePrewarm(.routeChange) {
            // Persistent-graph policy: route changes are telemetry-only. The
            // warm capture graph is bound to a fixed input device and is
            // indifferent to output-route churn, so there is nothing to
            // rebuild here. Rebuilds happen only at start() after a proven
            // failure or a device-selection change.
            emitLatency("route_refresh_ignored:\(intent.debugName)")
            return
        }
        guard stateStorage == .idle, !externalSessionActive else { return }
        #if DEBUG
        if devFaults?.skipsMicrophoneWarmup == true { return }
        #endif
        if let skipReason = idleWarmupSkipReason(
            route: routeSnapshot,
            canWarmUp: canWarmUp
        ) {
            emitLatency("warmup_skipped:\(intent.debugName):\(skipReason)")
            fputs("[dictation-session] warmup skipped intent=\(intent.debugName) reason=\(skipReason) \(routeSnapshot.debugDescription)\n", stderr)
            return
        }
        recorder.keepsAudioGraphWarm = true
        do {
            // No coolDown before warming: warmUp() is idempotent per bound
            // device, so an already-warm graph is reused. Disposal stays
            // reserved for proven failure / explicit cancellation paths.
            emitLatency("engine_prepare_begin:warmup:\(intent.debugName)")
            try recorder.warmUp(preferredInputDeviceID: routeSnapshot.preferredInputDeviceID)
            emitLatency("engine_prepare_end:warmup:\(intent.debugName)")
            fputs("[dictation-session] warmed intent=\(intent.debugName) \(routeSnapshot.debugDescription)\n", stderr)
        } catch {
            emitLatency("engine_prepare_failed:warmup:\(intent.debugName)")
            fputs("[dictation-session] warmup failed intent=\(intent.debugName) error=\(error)\n", stderr)
        }
    }

    private func idleWarmupSkipReason(
        route: RouteSnapshot,
        canWarmUp: Bool
    ) -> String? {
        guard canWarmUp else { return "not_allowed" }
        switch route.routeKind {
        case .speakerLike:
            if !route.systemDefaultInputIsBuiltIn {
                return "risky_default_input"
            }
            return nil
        case .headphoneLike, .unknown:
            return "risky_route"
        }
    }

    private func activationWarmupSkipReason(route: RouteSnapshot) -> String {
        if route.usesSpeakerDefaultRecorder {
            return route.systemDefaultInputIsBuiltIn ? "not_needed" : "risky_default_input"
        }
        return "app_scoped_route"
    }

    private func recorderInputDeviceID(for route: RouteSnapshot) -> AudioObjectID? {
        route.preferredInputDeviceID
    }

    private func beginSessionAudioControls(duckingEnabled: Bool, mediaPauseEnabled: Bool) {
        mediaPlaybackController.beginDictationMediaPause(
            enabled: mediaPauseEnabled,
            routeKind: routeSnapshot.routeKind
        )
        beginDuckingIfNeeded(duckingEnabled: duckingEnabled)
    }

    private func beginDuckingIfNeeded(duckingEnabled: Bool) {
        duckingEnabledForSession = duckingEnabled && routeSnapshot.shouldDuck
        emitLatency(duckingEnabledForSession ? "duck_begin" : "duck_skip")
        duckingController.beginDictationDucking(enabled: duckingEnabledForSession)
    }

    private func restoreSessionAudioState(completion: (() -> Void)? = nil) {
        duckingController.restoreDictationDucking { [self] in
            self.mediaPlaybackController.restoreDictationMediaPause()
            completion?()
        }
        routingController.refreshRouteAfterDictationSession()
        duckingEnabledForSession = false
    }

    private func makeRouteSnapshot(refreshInput: Bool = false) -> RouteSnapshot {
        let preferredInputDeviceID = refreshInput
            ? routingController.preferredInputDeviceIDForDictation()
            : routingController.cachedPreferredInputDeviceIDForDictation()
        return RouteSnapshot(
            routeKind: routingController.currentOutputRouteKindForDebug(),
            preferredInputDeviceID: preferredInputDeviceID,
            systemDefaultInputIsBuiltIn: routingController.systemDefaultInputIsBuiltInForDictation(),
            debugDescription: routingController.currentRouteDebugDescription()
        )
    }

    private func finishCaptureInterval() {
        let end = endCaptureInterval
        endCaptureInterval = nil
        end?()
    }

    private func failCurrentSession(error: Error) {
        finishCaptureInterval()
        let sessionID = stateStorage.sessionID
        startupWatchdog?.finish(sessionID, outcome: .failed, failureReason: (error as? DictationMicrophoneStartupError)?.reason ?? .recorderError)
        if let sessionID { inputObserver?.stop(sessionID: sessionID) }
        if let sessionID {
            failedSessionID = sessionID
        }
        stateStorage = .idle
        activeRecorderRunID = nil
        recorder.preferredInputDeviceID = nil
        clearSessionHint(sessionID)
        restoreSessionAudioState()
        emit(.failed(sessionID, error: error))
    }

    private func handleFirstAudioBuffer(sessionID: UUID, capturedAt: Date) {
        guard startupWatchdog?.firstBuffer(sessionID) ?? true else { return }
        queue.async { [self] in
            guard self.isCurrent(sessionID), self.sessionHintMatches(sessionID),
                  self.startupWatchdog?.accepts(sessionID) ?? true else { return }
            switch self.stateStorage {
            case .acquiringAudio(let id) where id == sessionID,
                 .armed(let id) where id == sessionID:
                self.stateStorage = .streamActive(sessionID)
            default:
                break
            }
            self.emitLatency("first_buffer", at: capturedAt)
            self.emit(.streamActive(sessionID, capturedAt: capturedAt))
        }
    }

    private func handleFirstSpeech(sessionID: UUID, capturedAt: Date) {
        queue.async { [self] in
            guard self.isCurrent(sessionID), self.sessionHintMatches(sessionID),
                  self.startupWatchdog?.accepts(sessionID) ?? true else { return }
            self.stateStorage = .speechDetected(sessionID)
            self.emitLatency("first_speech", at: capturedAt)
            self.emit(.speechDetected(sessionID, capturedAt: capturedAt))
        }
    }

    private func handleNoAudioTimeout(sessionID: UUID, at: Date) {
        queue.async { [self] in
            guard self.isCurrent(sessionID), self.sessionHintMatches(sessionID),
                  self.startupWatchdog?.accepts(sessionID) ?? true else { return }
            self.emitLatency("no_audio_timeout", at: at)
            // No speech / no buffers is advisory, never evidence of hardware
            // failure. The independent startup timer covers a blocked start.
            if self.startupWatchdog?.isPending(sessionID) == true { return }
            self.emit(.noAudioTimeout(sessionID, at: at))
        }
    }

    private func handleRecordingFailure(error: Error, sessionID: UUID, recorderRunID: UUID) {
        // Callback identity was captured before start(). It must work even when
        // that native call hasn't returned its run ID or released this queue.
        guard sessionHintLock.withLock({ sessionHint == sessionID && (recorderRunHint == nil || recorderRunHint == recorderRunID) }) else { return }
        emitLatency("recorder_failed")
        retireSession(sessionID, error: error)
    }

    private func bindStartupCallbacks(_ id: UUID) {
        recorder.onFirstCapturedAudioBuffer = { [weak self] date in
            self?.handleFirstAudioBuffer(sessionID: id, capturedAt: date)
        }
        recorder.onFirstSpeechDetected = { [weak self] date in
            self?.handleFirstSpeech(sessionID: id, capturedAt: date)
        }
        recorder.onNoAudioTimeout = { [weak self] date in
            self?.handleNoAudioTimeout(sessionID: id, at: date)
        }
        recorder.onRecordingFailed = { [weak self] error, runID in
            self?.handleRecordingFailure(error: error, sessionID: id, recorderRunID: runID)
        }
    }

    private func startupContext() -> DictationStartupContext {
        let route: DictationStartupContext.Route
        switch routeSnapshot.routeKind {
        case .speakerLike: route = .speaker
        case .headphoneLike: route = .headphones
        case .unknown: route = .unknown
        }
        return DictationStartupContext(route: route,
            input: routeSnapshot.preferredInputDeviceID == nil ? .automatic : .explicit)
    }

    func reportBlockedStartupRetry() {
        if let id = sessionHintLock.withLock({ retiringSessionID }) { startupWatchdog?.retryBlocked(id) }
    }

    private func rejectRetiringStartup(_ id: UUID) {
        startupWatchdog?.retryBlocked(id)
        emit(.failed(id, error: DictationMicrophoneStartupError.stillStopping))
    }

    private func handleStartupReport(_ report: DictationStartupReport) {
        if let startupTelemetry {
            telemetryQueue.async { startupTelemetry(report) }
        }
        if report.outcome == .warning, isStartupPending(report.sessionID) {
            emit(.startupWarning(report.sessionID))
        }
    }

    private func retireSession(_ id: UUID, error: Error) {
        let ownsSession = sessionHintLock.withLock {
            guard sessionHint == id else { return false }
            retiringSessionID = id
            sessionHint = nil
            return true
        }
        guard ownsSession else { return }
        startupWatchdog?.finish(id, outcome: .failed,
            failureReason: (error as? DictationMicrophoneStartupError)?.reason ?? .recorderError)
        inputObserver?.stop(sessionID: id)
        emit(.failed(id, error: error))
        queue.async { [self] in
            if stateStorage.sessionID == id {
                recorder.keepsAudioGraphWarm = false
                recorder.cancel()
                finishCaptureInterval()
                activeRecorderRunID = nil
                recorder.preferredInputDeviceID = nil
                failedSessionID = id
                stateStorage = .idle
                restoreSessionAudioState()
            }
            releaseRetiringSession(id)
        }
    }

    private func releaseRetiringSession(_ id: UUID?) {
        guard let id else { return }
        // Clear ownership before notifying the controller that stop completed.
        sessionHintLock.withLock {
            if retiringSessionID == id { retiringSessionID = nil }
        }
        startupWatchdog?.released(id)
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        emit(.latency(event, date))
    }

    private func emit(_ event: DictationAudioSessionEvent) {
        eventQueue.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}

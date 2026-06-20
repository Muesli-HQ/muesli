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

extension MicrophoneRecorder: DictationAudioRecording {}

final class DictationAudioSessionManager: @unchecked Sendable {
    private enum StartupError: LocalizedError {
        case noAudioBuffer

        var errorDescription: String? {
            switch self {
            case .noAudioBuffer:
                return "Microphone capture did not deliver audio."
            }
        }
    }

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
    private var failedSessionID: UUID?
    private let sessionHintLock = NSLock()
    private var sessionHint: UUID?
    private var externalSessionHint = false

    var onEvent: ((DictationAudioSessionEvent) -> Void)?

    init(
        recorder: DictationAudioRecording,
        duckingController: AudioDuckingManaging,
        mediaPlaybackController: MediaPlaybackManaging = MediaPlaybackController(),
        routingController: DictationAudioRouting,
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.dictation-audio-session-manager"),
        eventQueue: DispatchQueue = .main
    ) {
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

        recorder.onFirstCapturedAudioBuffer = { [weak self] capturedAt in
            self?.handleFirstAudioBuffer(capturedAt: capturedAt)
        }
        recorder.onFirstSpeechDetected = { [weak self] capturedAt in
            self?.handleFirstSpeech(capturedAt: capturedAt)
        }
        recorder.onNoAudioTimeout = { [weak self] at in
            self?.handleNoAudioTimeout(at: at)
        }
        recorder.onRecordingFailed = { [weak self] error, recorderRunID in
            self?.handleRecordingFailure(error: error, recorderRunID: recorderRunID)
        }
        recorder.onLatencyEvent = { [weak self] event, date in
            self?.emitLatency(event, at: date)
        }
    }

    var currentState: DictationAudioSessionState {
        queue.sync { stateStorage }
    }

    var currentSessionID: UUID? {
        sessionHintLock.withLock { sessionHint }
    }

    var hasActiveSession: Bool {
        sessionHintLock.withLock { sessionHint != nil || externalSessionHint }
    }

    func currentPower() -> Float {
        recorder.currentPower()
    }

    func arm(source: String) {
        let sessionID = ensureSession()
        emit(.armed(sessionID, source: source))
        emitLatency("ui_armed")
        queue.async { [self] in
            self.cancelPendingRouteRefreshLocked()
            guard self.sessionHintMatches(sessionID) else {
                self.emitLatency("stale_session_ignored:\(source)")
                return
            }
            self.ensureSessionStateLocked(sessionID)
            guard self.isCurrent(sessionID) else { return }
            self.stateStorage = .armed(sessionID)
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
    }

    func beginRecording(mode: String, duckingEnabled: Bool, mediaPauseEnabled: Bool) {
        let sessionID = ensureSession()
        queue.async { [self] in
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
            self.stateStorage = .acquiringAudio(sessionID)
            self.emit(.acquiringAudio(sessionID))
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
            self.beginSessionAudioControls(duckingEnabled: duckingEnabled, mediaPauseEnabled: mediaPauseEnabled)
            self.duckingController.ensureCurrentDefaultDucked()
            let recorderInputDeviceID = self.recorderInputDeviceID(for: self.routeSnapshot)
            self.recorder.preferredInputDeviceID = recorderInputDeviceID
            self.recorder.keepsAudioGraphWarm = self.routeSnapshot.canSpeculativelyWarmRecorder
            do {
                self.emitLatency("activation_begin:\(mode)")
                if self.routeSnapshot.canSpeculativelyWarmRecorder {
                    try self.recorder.activateWarmEngine(preferredInputDeviceID: recorderInputDeviceID)
                } else {
                    self.emitLatency("activation_prepare_skipped:\(mode):\(self.activationWarmupSkipReason(route: self.routeSnapshot))")
                }
                self.activeRecorderRunID = try self.recorder.start()
                self.emitLatency("activation_end:\(mode)")
                fputs("[dictation-session] recording mode=\(mode) \(self.routeSnapshot.debugDescription)\n", stderr)
            } catch {
                self.emitLatency("activation_failed:\(mode)")
                self.recorder.cancel()
                self.failCurrentSession(error: error)
            }
        }
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
        queue.async { [self] in
            let sessionID = self.stateStorage.sessionID
            guard sessionID != nil else {
                self.restoreSessionAudioState(completion: nil)
                return
            }
            self.emitLatency("stop")
            self.recorder.keepsAudioGraphWarm = false
            let wavURL = self.recorder.stop()
            self.activeRecorderRunID = nil
            self.recorder.preferredInputDeviceID = nil
            self.stateStorage = .idle
            self.clearSessionHint(sessionID)
            self.emit(.stopped(sessionID, wavURL: wavURL))
            self.restoreSessionAudioState {
                self.emit(.audioRestored(sessionID))
            }
        }
    }

    func cancel(reason: String) {
        queue.async { [self] in
            let sessionID = self.stateStorage.sessionID
            self.recorder.keepsAudioGraphWarm = false
            self.recorder.cancel()
            self.activeRecorderRunID = nil
            self.recorder.preferredInputDeviceID = nil
            self.stateStorage = .idle
            self.externalSessionActive = false
            self.clearSessionHint(sessionID)
            self.setExternalSessionHint(false)
            self.restoreSessionAudioState()
            self.emitLatency("cancelled:\(reason)")
            self.emit(.cancelled(sessionID, reason: reason))
        }
    }

    func refreshRoute(intent: DictationWarmupIntent, delay: TimeInterval = 0, canWarmUp: Bool) {
        routingController.refreshRouteCache()
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

    private func ensureSession() -> UUID {
        sessionHintLock.withLock {
            if let current = sessionHint {
                return current
            }
            let id = UUID()
            sessionHint = id
            return id
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
        guard stateStorage == .idle, !externalSessionActive else { return }
        if let skipReason = idleWarmupSkipReason(route: routeSnapshot, canWarmUp: canWarmUp) {
            recorder.keepsAudioGraphWarm = false
            recorder.coolDown()
            emitLatency("warmup_skipped:\(intent.debugName):\(skipReason)")
            fputs("[dictation-session] warmup skipped intent=\(intent.debugName) reason=\(skipReason) \(routeSnapshot.debugDescription)\n", stderr)
            return
        }
        recorder.keepsAudioGraphWarm = true
        recorder.coolDown()
        do {
            emitLatency("engine_prepare_begin:warmup:\(intent.debugName)")
            try recorder.warmUp(preferredInputDeviceID: routeSnapshot.preferredInputDeviceID)
            emitLatency("engine_prepare_end:warmup:\(intent.debugName)")
            fputs("[dictation-session] warmed intent=\(intent.debugName) \(routeSnapshot.debugDescription)\n", stderr)
        } catch {
            emitLatency("engine_prepare_failed:warmup:\(intent.debugName)")
            fputs("[dictation-session] warmup failed intent=\(intent.debugName) error=\(error)\n", stderr)
        }
    }

    private func idleWarmupSkipReason(route: RouteSnapshot, canWarmUp: Bool) -> String? {
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

    private func failCurrentSession(error: Error) {
        let sessionID = stateStorage.sessionID
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

    private func handleFirstAudioBuffer(capturedAt: Date) {
        queue.async { [self] in
            guard let sessionID = self.stateStorage.sessionID else { return }
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

    private func handleFirstSpeech(capturedAt: Date) {
        queue.async { [self] in
            guard let sessionID = self.stateStorage.sessionID else { return }
            self.stateStorage = .speechDetected(sessionID)
            self.emitLatency("first_speech", at: capturedAt)
            self.emit(.speechDetected(sessionID, capturedAt: capturedAt))
        }
    }

    private func handleNoAudioTimeout(at: Date) {
        queue.async { [self] in
            guard let sessionID = self.stateStorage.sessionID else { return }
            self.emitLatency("no_audio_timeout", at: at)
            switch self.stateStorage {
            case .armed(let id) where id == sessionID,
                 .acquiringAudio(let id) where id == sessionID:
                self.recorder.keepsAudioGraphWarm = false
                self.recorder.cancel()
                self.failCurrentSession(error: StartupError.noAudioBuffer)
                return
            default:
                break
            }
            self.emit(.noAudioTimeout(sessionID, at: at))
        }
    }

    private func handleRecordingFailure(error: Error, recorderRunID: UUID) {
        queue.async { [self] in
            guard self.stateStorage.sessionID != nil,
                  self.activeRecorderRunID == recorderRunID else { return }
            self.emitLatency("recorder_failed")
            self.recorder.keepsAudioGraphWarm = false
            self.recorder.cancel()
            self.failCurrentSession(error: error)
        }
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

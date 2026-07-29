import CoreAudio
import Foundation
import os

enum MeetingMicRecorderKind: String, Codable, Equatable {
    case systemDefaultStreaming
    case appScopedAudioQueue
}

struct MeetingMicRouteDiagnosticsSnapshot: Codable, Equatable {
    let outputRouteKind: String
    let outputIsAmbiguousBluetooth: Bool
    let selectedInputDeviceUID: String?
    let selectedInputDeviceResolved: Bool
    let preferredInputDeviceID: AudioObjectID?
    let preferredInputDeviceName: String?
    let defaultInputDeviceID: AudioObjectID?
    let defaultInputDeviceName: String?
    let builtInInputDeviceID: AudioObjectID?
    let systemDefaultInputIsBuiltIn: Bool
}

struct MeetingMicRecorderDiagnosticsSnapshot: Codable, Equatable {
    let recorderKind: MeetingMicRecorderKind
    let preferredInputDeviceID: AudioObjectID?
    let route: MeetingMicRouteDiagnosticsSnapshot?
}

protocol MeetingMicRecording: AnyObject {
    var preferredInputDeviceID: AudioObjectID? { get set }
    var onRawPCMSamples: (([Int16]) -> Void)? { get set }
    var onRecordingFailed: ((Error) -> Void)? { get set }

    func prepare() throws
    func start() throws
    func pause()
    func resume()
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float
    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot
}

final class StreamingMeetingMicRecorderAdapter: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID? {
        get { recorder.preferredInputDeviceID }
        set { recorder.preferredInputDeviceID = newValue }
    }
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)? {
        get { recorder.onRecordingFailed }
        set { recorder.onRecordingFailed = newValue }
    }

    private let recorder: StreamingDictationRecording
    private let kind: MeetingMicRecorderKind
    private let lock = OSAllocatedUnfairLock(initialState: false)

    init(
        recorder: StreamingDictationRecording,
        kind: MeetingMicRecorderKind
    ) {
        self.recorder = recorder
        self.kind = kind
        wireCallbacks()
    }

    func prepare() throws {
        try recorder.prepare()
    }

    func start() throws {
        lock.withLock { $0 = false }
        try recorder.start()
    }

    func pause() {
        lock.withLock { $0 = true }
        (recorder as? PausableStreamingDictationRecording)?.pause()
    }

    func resume() {
        lock.withLock { $0 = false }
        (recorder as? PausableStreamingDictationRecording)?.resume()
    }

    func stop() -> URL? {
        recorder.stop()
    }

    func cancel() {
        recorder.cancel()
    }

    func currentPower() -> Float {
        recorder.currentPower()
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: kind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }

    private func wireCallbacks() {
        recorder.onAudioBuffer = { [weak self] samples in
            guard let self else { return }
            guard !self.lock.withLock({ $0 }) else { return }
            let int16Samples = samples.map { sample -> Int16 in
                Int16(max(-1.0, min(1.0, sample)) * 32767)
            }
            self.onRawPCMSamples?(int16Samples)
        }
    }
}

final class RouteAwareMeetingMicRecorder: MeetingMicRecording {
    enum ActiveRecorderKind: Equatable { case systemDefault, appScoped }
    private enum LifecycleState { case idle, prepared, running, paused, failed, stopping }
    private struct Child {
        let id: UUID
        let generation: UInt64
        let kind: ActiveRecorderKind
        let recorder: MeetingMicRecording
        let deviceID: AudioObjectID?
    }
    typealias RecorderFactory = () -> MeetingMicRecording
    typealias HandoffTimeoutScheduler = (TimeInterval, DispatchWorkItem) -> Void

    var preferredInputDeviceID: AudioObjectID? {
        get { lock.withLock { $0.preferredInputDeviceIDStorage } }
        set {
            let shouldHandoff = lock.withLock { state -> Bool in
                let changed = state.preferredInputDeviceIDStorage != newValue
                guard changed || state.lifecycleState == .failed else { return false }
                if changed { state.preferredInputDeviceIDStorage = newValue }
                guard state.lifecycleState == .running || state.lifecycleState == .failed else { return false }
                state.generation &+= 1
                return true
            }
            if shouldHandoff {
                lifecycleQueue.async { [weak self] in
                    self?.restartHandoffIfNeeded(force: true)
                }
            }
        }
    }
    var onRawPCMSamples: (([Int16]) -> Void)? {
        get { lock.withLock { $0.onRawPCMSamplesStorage } }
        set { lock.withLock { $0.onRawPCMSamplesStorage = newValue } }
    }
    var onRecordingFailed: ((Error) -> Void)? {
        get { lock.withLock { $0.onRecordingFailedStorage } }
        set { lock.withLock { $0.onRecordingFailedStorage = newValue } }
    }

    private let systemDefaultRecorderFactory: RecorderFactory
    private let appScopedRecorderFactory: RecorderFactory
    private var seededSystemDefaultRecorder: MeetingMicRecording?
    private var seededAppScopedRecorder: MeetingMicRecording?
    private let routeSnapshotProvider: () -> MeetingMicRouteDiagnosticsSnapshot?
    private let lifecycleQueue: DispatchQueue
    private let handoffWorkerQueue: DispatchQueue
    private let cleanupQueue: DispatchQueue
    private let handoffTimeout: TimeInterval
    private let scheduleHandoffTimeout: HandoffTimeoutScheduler
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var preferredInputDeviceIDStorage: AudioObjectID?
        var lifecycleState: LifecycleState = .idle
        var active: Child?
        var pending: Child?
        var generation: UInt64 = 0
        var shouldRecoverOnResume = false
        var onRawPCMSamplesStorage: (([Int16]) -> Void)?
        var onRecordingFailedStorage: ((Error) -> Void)?
    }

    private var preferredInputDeviceIDStorage: AudioObjectID? {
        get { lock.withLock { $0.preferredInputDeviceIDStorage } }
        set { lock.withLock { $0.preferredInputDeviceIDStorage = newValue } }
    }
    private var lifecycleState: LifecycleState { lock.withLock { $0.lifecycleState } }
    private var onRawPCMSamplesStorage: (([Int16]) -> Void)? { lock.withLock { $0.onRawPCMSamplesStorage } }
    private var onRecordingFailedStorage: ((Error) -> Void)? { lock.withLock { $0.onRecordingFailedStorage } }

    init(
        systemDefaultRecorder: MeetingMicRecording? = nil,
        appScopedRecorder: MeetingMicRecording? = nil,
        systemDefaultRecorderFactory: RecorderFactory? = nil,
        appScopedRecorderFactory: RecorderFactory? = nil,
        routeSnapshotProvider: @escaping () -> MeetingMicRouteDiagnosticsSnapshot? = { nil },
        lifecycleQueue: DispatchQueue = DispatchQueue(label: "com.muesli.route-aware-meeting-mic-recorder-lifecycle"),
        handoffWorkerQueue: DispatchQueue = DispatchQueue(
            label: "com.muesli.route-aware-meeting-mic-recorder-handoff",
            attributes: .concurrent
        ),
        cleanupQueue: DispatchQueue = DispatchQueue(
            label: "com.muesli.route-aware-meeting-mic-recorder-cleanup",
            attributes: .concurrent
        ),
        handoffTimeout: TimeInterval = 2,
        handoffTimeoutScheduler: HandoffTimeoutScheduler? = nil
    ) {
        self.seededSystemDefaultRecorder = systemDefaultRecorder
        self.seededAppScopedRecorder = appScopedRecorder
        self.systemDefaultRecorderFactory = systemDefaultRecorderFactory ?? Self.makeSystemDefaultRecorder
        self.appScopedRecorderFactory = appScopedRecorderFactory ?? Self.makeAppScopedRecorder
        self.routeSnapshotProvider = routeSnapshotProvider
        self.lifecycleQueue = lifecycleQueue
        self.handoffWorkerQueue = handoffWorkerQueue
        self.cleanupQueue = cleanupQueue
        self.handoffTimeout = handoffTimeout
        self.scheduleHandoffTimeout = handoffTimeoutScheduler ?? { delay, workItem in
            lifecycleQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func activeRecorderKindForDebug() -> ActiveRecorderKind {
        lock.withLock { $0.active?.kind ?? Self.kind(for: $0.preferredInputDeviceIDStorage) }
    }

    func isTerminallyFailedForDebug() -> Bool {
        lock.withLock { $0.lifecycleState == .failed }
    }

    func prepare() throws {
        try lifecycleQueue.sync {
            let child = try ensureCurrentChild()
            try child.recorder.prepare()
            lock.withLock { $0.lifecycleState = .prepared }
        }
    }

    func start() throws {
        try lifecycleQueue.sync {
            let child = try ensureCurrentChild()
            try child.recorder.start()
            lock.withLock { $0.lifecycleState = .running }
        }
    }

    func pause() {
        lifecycleQueue.sync {
            let result = lock.withLock { state -> (MeetingMicRecording?, Child?) in
                guard state.lifecycleState == .running || state.lifecycleState == .failed else { return (nil, nil) }
                state.shouldRecoverOnResume = state.lifecycleState == .failed
                state.lifecycleState = .paused
                state.generation &+= 1
                let pending = state.pending
                state.pending = nil
                return (state.active?.recorder, pending)
            }
            cancelAsync(result.1)
            result.0?.pause()
        }
    }

    func resume() {
        lifecycleQueue.sync {
            let result = lock.withLock { state -> (recorder: MeetingMicRecording?, shouldRecover: Bool)? in
                guard state.lifecycleState == .paused else { return nil }
                let shouldRecover = state.shouldRecoverOnResume
                state.shouldRecoverOnResume = false
                state.lifecycleState = shouldRecover ? .failed : .running
                return (state.active?.recorder, shouldRecover)
            }
            guard let result else { return }
            if result.shouldRecover {
                restartHandoffIfNeeded(force: true)
            } else {
                result.recorder?.resume()
                restartHandoffIfNeeded()
            }
        }
    }

    func stop() -> URL? {
        let resources = lifecycleQueue.sync { () -> (active: Child?, pending: Child?, unused: [MeetingMicRecording]) in
            let children = lock.withLock { state -> (Child?, Child?) in
                state.lifecycleState = .stopping
                state.generation &+= 1
                let result = (state.active, state.pending)
                state.active = nil
                state.pending = nil
                state.shouldRecoverOnResume = false
                return result
            }
            return (children.0, children.1, takeUnusedSeedRecorders())
        }
        cancelAsync(resources.pending)
        cancelAsync(resources.unused)
        let url = resources.active?.recorder.stop()
        resources.active?.recorder.cancel()
        lock.withLock { $0.lifecycleState = .idle }
        return url
    }

    func cancel() {
        let resources = lifecycleQueue.sync { () -> (Child?, Child?, [MeetingMicRecording]) in
            let children = lock.withLock { state -> (Child?, Child?) in
                state.lifecycleState = .stopping
                state.generation &+= 1
                let result = (state.active, state.pending)
                state.active = nil
                state.pending = nil
                state.shouldRecoverOnResume = false
                return result
            }
            lock.withLock { $0.lifecycleState = .idle }
            return (children.0, children.1, takeUnusedSeedRecorders())
        }
        cancelAsync(resources.0)
        cancelAsync(resources.1)
        cancelAsync(resources.2)
    }

    func currentPower() -> Float {
        lock.withLock { $0.active?.recorder }?.currentPower() ?? -160
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        let child = lock.withLock { $0.active }
        var snapshot = child?.recorder.diagnosticsSnapshot() ?? MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: Self.kind(for: preferredInputDeviceID).diagnosticsKind,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
        if snapshot.route == nil {
            snapshot = MeetingMicRecorderDiagnosticsSnapshot(
                recorderKind: snapshot.recorderKind,
                preferredInputDeviceID: snapshot.preferredInputDeviceID,
                route: routeSnapshotProvider()
            )
        }
        return snapshot
    }

    private func ensureCurrentChild() throws -> Child {
        let desired = preferredInputDeviceID
        if let active = lock.withLock({ $0.active }), active.deviceID == desired { return active }
        let previous = lock.withLock { state -> Child? in
            let old = state.active
            state.active = nil
            return old
        }
        previous?.recorder.cancel()
        let child = makeChild(deviceID: desired, generation: lock.withLock { $0.generation })
        lock.withLock { $0.active = child }
        return child
    }

    private func restartHandoffIfNeeded(force: Bool = false) {
        let stalePending = lock.withLock { state -> Child? in
            let pending = state.pending
            state.pending = nil
            return pending
        }
        cancelAsync(stalePending)
        beginHandoffIfNeeded(force: force)
    }

    private func beginHandoffIfNeeded(force: Bool = false) {
        let request = lock.withLock { state -> (AudioObjectID, UInt64)? in
            guard state.lifecycleState == .running || state.lifecycleState == .failed,
                  state.pending == nil,
                  force || state.active?.deviceID != state.preferredInputDeviceIDStorage else { return nil }
            return (state.preferredInputDeviceIDStorage ?? kAudioObjectUnknown, state.generation)
        }
        guard let (encodedDeviceID, generation) = request else { return }
        let deviceID = encodedDeviceID == kAudioObjectUnknown ? nil : encodedDeviceID
        let candidate = makeChild(deviceID: deviceID, generation: generation)
        lock.withLock { $0.pending = candidate }

        // Schedule the wall-clock deadline before starting the graph. CoreAudio
        // can block inside AudioQueueStart, so a timeout scheduled afterward is
        // not a real bound and can also hold stop/discard behind it.
        scheduleHandoffTimeout(
            handoffTimeout,
            DispatchWorkItem { [weak self] in
                self?.failPendingHandoff(
                    candidateID: candidate.id,
                    generation: generation,
                    error: NSError(domain: "MeetingMicrophoneRoute", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The selected microphone did not produce audio."
                    ])
                )
            }
        )
        handoffWorkerQueue.async { [weak self] in
            do {
                try candidate.recorder.prepare()
                try candidate.recorder.start()
            } catch {
                self?.lifecycleQueue.async { [weak self] in
                    self?.failPendingHandoff(
                        candidateID: candidate.id,
                        generation: generation,
                        error: error
                    )
                }
            }
        }
    }

    private func makeChild(deviceID: AudioObjectID?, generation: UInt64) -> Child {
        let kind = Self.kind(for: deviceID)
        let recorder: MeetingMicRecording
        switch kind {
        case .systemDefault:
            recorder = seededSystemDefaultRecorder ?? systemDefaultRecorderFactory()
            seededSystemDefaultRecorder = nil
        case .appScoped:
            recorder = seededAppScopedRecorder ?? appScopedRecorderFactory()
            seededAppScopedRecorder = nil
        }
        recorder.preferredInputDeviceID = deviceID
        let child = Child(id: UUID(), generation: generation, kind: kind, recorder: recorder, deviceID: deviceID)
        recorder.onRawPCMSamples = { [weak self] samples in self?.receive(samples, from: child.id) }
        recorder.onRecordingFailed = { [weak self] error in self?.receive(error, from: child.id) }
        return child
    }

    private func receive(_ samples: [Int16], from childID: UUID) {
        let role = lock.withLock { state -> (isActive: Bool, isPending: Bool, UInt64) in
            (state.active?.id == childID, state.pending?.id == childID, state.pending?.generation ?? state.generation)
        }
        if role.isActive {
            onRawPCMSamplesStorage?(samples)
        } else if role.isPending {
            lifecycleQueue.async { [weak self] in
                self?.completePendingHandoff(childID: childID, generation: role.2, firstSamples: samples)
            }
        }
    }

    private func receive(_ error: Error, from childID: UUID) {
        let role = lock.withLock { state -> (
            isActive: Bool,
            isPending: Bool,
            generation: UInt64,
            failureHandler: ((Error) -> Void)?,
            shouldRecover: Bool
        ) in
            if state.pending?.id == childID {
                return (false, true, state.pending?.generation ?? state.generation, nil, false)
            }
            guard state.active?.id == childID else {
                return (false, false, state.generation, nil, false)
            }
            if state.lifecycleState == .paused {
                guard !state.shouldRecoverOnResume else {
                    return (false, false, state.generation, nil, false)
                }
                state.shouldRecoverOnResume = true
                return (true, false, state.generation, state.onRecordingFailedStorage, false)
            }
            guard state.lifecycleState == .running else {
                return (false, false, state.generation, nil, false)
            }
            state.lifecycleState = .failed
            let shouldRecover = state.pending == nil
            if shouldRecover { state.generation &+= 1 }
            return (true, false, state.generation, state.onRecordingFailedStorage, shouldRecover)
        }
        if role.isActive {
            role.failureHandler?(error)
            if role.shouldRecover {
                lifecycleQueue.async { [weak self] in
                    self?.beginHandoffIfNeeded(force: true)
                }
            }
        } else if role.isPending {
            lifecycleQueue.async { [weak self] in
                self?.failPendingHandoff(candidateID: childID, generation: role.generation, error: error)
            }
        }
    }

    private func completePendingHandoff(childID: UUID, generation: UInt64, firstSamples: [Int16]) {
        guard !firstSamples.isEmpty else { return }
        let transition = lock.withLock { state -> (completed: Bool, old: Child?) in
            guard state.generation == generation,
                  state.lifecycleState == .running || state.lifecycleState == .failed,
                  state.pending?.id == childID,
                  let candidate = state.pending else { return (false, nil) }
            let old = state.active
            state.active = candidate
            state.pending = nil
            state.lifecycleState = .running
            return (true, old)
        }
        guard transition.completed else { return }
        onRawPCMSamplesStorage?(firstSamples)
        retireAfterHandoffAsync(transition.old)
    }

    private func failPendingHandoff(candidateID: UUID, generation: UInt64, error: Error) {
        let result = lock.withLock { state -> (candidate: Child, isTerminalRecovery: Bool)? in
            guard state.generation == generation,
                  state.pending?.id == candidateID,
                  let candidate = state.pending else { return nil }
            state.pending = nil
            return (candidate, state.lifecycleState == .failed)
        }
        guard let result else { return }
        cancelAsync(result.candidate)
        let outcome = result.isTerminalRecovery
            ? "microphone recovery failed"
            : "microphone handoff failed; continuing current route"
        fputs("[meeting-mic] \(outcome): \(error)\n", stderr)
    }

    private static func kind(for deviceID: AudioObjectID?) -> ActiveRecorderKind {
        deviceID == nil ? .systemDefault : .appScoped
    }

    private func takeUnusedSeedRecorders() -> [MeetingMicRecording] {
        let recorders = [seededSystemDefaultRecorder, seededAppScopedRecorder].compactMap { $0 }
        seededSystemDefaultRecorder = nil
        seededAppScopedRecorder = nil
        return recorders
    }

    private func cancelAsync(_ child: Child?) {
        guard let child else { return }
        cleanupQueue.async { child.recorder.cancel() }
    }

    private func cancelAsync(_ recorders: [MeetingMicRecording]) {
        guard !recorders.isEmpty else { return }
        cleanupQueue.async {
            for recorder in recorders { recorder.cancel() }
        }
    }

    private func retireAfterHandoffAsync(_ child: Child?) {
        guard let child else { return }
        cleanupQueue.async {
            let url = child.recorder.stop()
            child.recorder.cancel()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func makeSystemDefaultRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: StreamingMicRecorder(
                directoryName: "muesli-meeting-mic",
                recoversFromInputConfigurationChanges: true
            ),
            kind: .systemDefaultStreaming
        )
    }

    private static func makeAppScopedRecorder() -> MeetingMicRecording {
        StreamingMeetingMicRecorderAdapter(
            recorder: FallbackStreamingDictationRecorder(
                primary: AudioQueueInputRecorder(directoryName: "muesli-meeting-mic-audioqueue"),
                fallback: StreamingMicRecorder(
                    directoryName: "muesli-meeting-mic-app-scoped-fallback",
                    recoversFromInputConfigurationChanges: true
                )
            ),
            kind: .appScopedAudioQueue
        )
    }
}

private extension RouteAwareMeetingMicRecorder.ActiveRecorderKind {
    var diagnosticsKind: MeetingMicRecorderKind {
        switch self {
        case .systemDefault: return .systemDefaultStreaming
        case .appScoped: return .appScopedAudioQueue
        }
    }
}

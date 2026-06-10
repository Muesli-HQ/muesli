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
    enum ActiveRecorderKind: Equatable {
        case systemDefault
        case appScoped
    }

    var preferredInputDeviceID: AudioObjectID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return preferredInputDeviceIDStorage
        }
        set {
            lifecycleQueue.sync {
                lock.lock()
                preferredInputDeviceIDStorage = newValue
                let recorder = activeRecorderLocked()
                lock.unlock()
                recorder.preferredInputDeviceID = newValue
            }
        }
    }

    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?

    private let systemDefaultRecorder: MeetingMicRecording
    private let appScopedRecorder: MeetingMicRecording
    private let routeSnapshotProvider: () -> MeetingMicRouteDiagnosticsSnapshot?
    private let lifecycleQueue: DispatchQueue
    private let lock = NSRecursiveLock()
    private var preferredInputDeviceIDStorage: AudioObjectID?
    private var activeRecorderKindStorage: ActiveRecorderKind = .systemDefault

    init(
        systemDefaultRecorder: MeetingMicRecording = StreamingMeetingMicRecorderAdapter(
            recorder: StreamingMicRecorder(directoryName: "muesli-meeting-mic"),
            kind: .systemDefaultStreaming
        ),
        appScopedRecorder: MeetingMicRecording = StreamingMeetingMicRecorderAdapter(
            recorder: FallbackStreamingDictationRecorder(
                primary: AudioQueueInputRecorder(directoryName: "muesli-meeting-mic-audioqueue"),
                fallback: StreamingMicRecorder(directoryName: "muesli-meeting-mic-app-scoped-fallback")
            ),
            kind: .appScopedAudioQueue
        ),
        routeSnapshotProvider: @escaping () -> MeetingMicRouteDiagnosticsSnapshot? = { nil },
        lifecycleQueue: DispatchQueue = DispatchQueue(label: "com.muesli.route-aware-meeting-mic-recorder-lifecycle")
    ) {
        self.systemDefaultRecorder = systemDefaultRecorder
        self.appScopedRecorder = appScopedRecorder
        self.routeSnapshotProvider = routeSnapshotProvider
        self.lifecycleQueue = lifecycleQueue
        wireCallbacks()
    }

    func activeRecorderKindForDebug() -> ActiveRecorderKind {
        lock.lock()
        defer { lock.unlock() }
        return activeRecorderKindStorage
    }

    func prepare() throws {
        try lifecycleQueue.sync {
            let recorder = selectRecorder(preferredInputDeviceID: currentPreferredInputDeviceID())
            try recorder.prepare()
        }
    }

    func start() throws {
        try lifecycleQueue.sync {
            let recorder = selectRecorder(preferredInputDeviceID: currentPreferredInputDeviceID())
            try recorder.start()
        }
    }

    func pause() {
        lifecycleQueue.sync {
            activeRecorder().pause()
        }
    }

    func resume() {
        lifecycleQueue.sync {
            activeRecorder().resume()
        }
    }

    func stop() -> URL? {
        lifecycleQueue.sync {
            lock.lock()
            let activeRecorder = activeRecorderLocked()
            let inactiveRecorder = inactiveRecorderLocked()
            lock.unlock()
            let url = activeRecorder.stop()
            inactiveRecorder.cancel()
            return url
        }
    }

    func cancel() {
        lifecycleQueue.sync {
            systemDefaultRecorder.cancel()
            appScopedRecorder.cancel()
        }
    }

    func currentPower() -> Float {
        activeRecorder().currentPower()
    }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        var snapshot = activeRecorder().diagnosticsSnapshot()
        if snapshot.route == nil {
            snapshot = MeetingMicRecorderDiagnosticsSnapshot(
                recorderKind: snapshot.recorderKind,
                preferredInputDeviceID: snapshot.preferredInputDeviceID,
                route: routeSnapshotProvider()
            )
        }
        return snapshot
    }

    private func wireCallbacks() {
        wireCallbacks(for: systemDefaultRecorder, kind: .systemDefault)
        wireCallbacks(for: appScopedRecorder, kind: .appScoped)
    }

    private func wireCallbacks(for recorder: MeetingMicRecording, kind: ActiveRecorderKind) {
        recorder.onRawPCMSamples = { [weak self] samples in
            self?.forwardIfActive(kind) { $0.onRawPCMSamples?(samples) }
        }
        recorder.onRecordingFailed = { [weak self] error in
            self?.forwardIfActive(kind) { $0.onRecordingFailed?(error) }
        }
    }

    private func forwardIfActive(_ kind: ActiveRecorderKind, _ body: (RouteAwareMeetingMicRecorder) -> Void) {
        lock.lock()
        let shouldForward = activeRecorderKindStorage == kind
        lock.unlock()
        guard shouldForward else { return }
        body(self)
    }

    private func currentPreferredInputDeviceID() -> AudioObjectID? {
        lock.lock()
        defer { lock.unlock() }
        return preferredInputDeviceIDStorage
    }

    private func selectRecorder(preferredInputDeviceID: AudioObjectID?) -> MeetingMicRecording {
        lock.lock()
        let nextKind: ActiveRecorderKind = preferredInputDeviceID == nil ? .systemDefault : .appScoped
        let inactiveRecorderToCancel = nextKind == activeRecorderKindStorage ? nil : activeRecorderLocked()
        preferredInputDeviceIDStorage = preferredInputDeviceID
        activeRecorderKindStorage = nextKind
        let selectedRecorder = activeRecorderLocked()
        lock.unlock()

        selectedRecorder.preferredInputDeviceID = preferredInputDeviceID
        inactiveRecorderToCancel?.cancel()
        return selectedRecorder
    }

    private func activeRecorder() -> MeetingMicRecording {
        lock.lock()
        defer { lock.unlock() }
        return activeRecorderLocked()
    }

    private func activeRecorderLocked() -> MeetingMicRecording {
        recorder(for: activeRecorderKindStorage)
    }

    private func inactiveRecorderLocked() -> MeetingMicRecording {
        inactiveRecorder(for: activeRecorderKindStorage)
    }

    private func recorder(for kind: ActiveRecorderKind) -> MeetingMicRecording {
        switch kind {
        case .systemDefault:
            return systemDefaultRecorder
        case .appScoped:
            return appScopedRecorder
        }
    }

    private func inactiveRecorder(for kind: ActiveRecorderKind) -> MeetingMicRecording {
        switch kind {
        case .systemDefault:
            return appScopedRecorder
        case .appScoped:
            return systemDefaultRecorder
        }
    }
}

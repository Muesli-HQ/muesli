import CoreAudio
import Foundation

final class RouteAwareDictationRecorder: DictationAudioRecording {
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
            lock.lock()
            defer { lock.unlock() }
            preferredInputDeviceIDStorage = newValue
            activeRecorderLocked().preferredInputDeviceID = newValue
        }
    }

    var keepsAudioGraphWarm: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return keepsAudioGraphWarmStorage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            keepsAudioGraphWarmStorage = newValue
            systemDefaultRecorder.keepsAudioGraphWarm = newValue
            appScopedRecorder.keepsAudioGraphWarm = newValue
        }
    }

    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?
    var onRecordingFailed: ((Error, UUID) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?

    private let systemDefaultRecorder: DictationAudioRecording
    private let appScopedRecorder: DictationAudioRecording
    private let lock = NSRecursiveLock()
    private var preferredInputDeviceIDStorage: AudioObjectID?
    private var keepsAudioGraphWarmStorage = false
    private var activeRecorderKindStorage: ActiveRecorderKind = .systemDefault

    init(
        systemDefaultRecorder: DictationAudioRecording = MicrophoneRecorder(),
        appScopedRecorder: DictationAudioRecording = AppScopedDictationRecorder()
    ) {
        self.systemDefaultRecorder = systemDefaultRecorder
        self.appScopedRecorder = appScopedRecorder
        wireCallbacks()
    }

    func activeRecorderKindForDebug() -> ActiveRecorderKind {
        lock.lock()
        defer { lock.unlock() }
        return activeRecorderKindStorage
    }

    func prepare() throws {
        let recorder = selectRecorder(preferredInputDeviceID: preferredInputDeviceIDStorage)
        try recorder.prepare()
    }

    func beginExplicitWarmup(preferredInputDeviceID: AudioObjectID?) {
        let recorder = selectRecorder(preferredInputDeviceID: preferredInputDeviceID)
        recorder.beginExplicitWarmup(preferredInputDeviceID: preferredInputDeviceID)
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        let recorder = selectRecorder(preferredInputDeviceID: preferredInputDeviceID)
        try recorder.warmUp(preferredInputDeviceID: preferredInputDeviceID)
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        let recorder = selectRecorder(preferredInputDeviceID: preferredInputDeviceID)
        try recorder.activateWarmEngine(preferredInputDeviceID: preferredInputDeviceID)
    }

    func coolDown() {
        systemDefaultRecorder.coolDown()
        appScopedRecorder.coolDown()
    }

    @discardableResult
    func start() throws -> UUID {
        let recorder = selectRecorder(preferredInputDeviceID: preferredInputDeviceIDStorage)
        return try recorder.start()
    }

    func stop() -> URL? {
        lock.lock()
        let activeRecorder = activeRecorderLocked()
        let inactiveRecorder = inactiveRecorderLocked()
        lock.unlock()
        let url = activeRecorder.stop()
        inactiveRecorder.cancel()
        return url
    }

    func cancel() {
        systemDefaultRecorder.cancel()
        appScopedRecorder.cancel()
    }

    func currentPower() -> Float {
        lock.lock()
        let recorder = activeRecorderLocked()
        lock.unlock()
        return recorder.currentPower()
    }

    private func wireCallbacks() {
        wireCallbacks(for: systemDefaultRecorder, kind: .systemDefault)
        wireCallbacks(for: appScopedRecorder, kind: .appScoped)
    }

    private func wireCallbacks(for recorder: DictationAudioRecording, kind: ActiveRecorderKind) {
        recorder.onFirstCapturedAudioBuffer = { [weak self] date in
            self?.forwardIfActive(kind) { $0.onFirstCapturedAudioBuffer?(date) }
        }
        recorder.onFirstSpeechDetected = { [weak self] date in
            self?.forwardIfActive(kind) { $0.onFirstSpeechDetected?(date) }
        }
        recorder.onNoAudioTimeout = { [weak self] date in
            self?.forwardIfActive(kind) { $0.onNoAudioTimeout?(date) }
        }
        recorder.onRecordingFailed = { [weak self] error, id in
            self?.forwardIfActive(kind) { $0.onRecordingFailed?(error, id) }
        }
        recorder.onLatencyEvent = { [weak self] event, date in
            self?.forwardIfActive(kind) { $0.onLatencyEvent?(event, date) }
        }
    }

    private func forwardIfActive(_ kind: ActiveRecorderKind, _ body: (RouteAwareDictationRecorder) -> Void) {
        lock.lock()
        let shouldForward = activeRecorderKindStorage == kind
        lock.unlock()
        guard shouldForward else { return }
        body(self)
    }

    private func selectRecorder(preferredInputDeviceID: AudioObjectID?) -> DictationAudioRecording {
        lock.lock()
        let nextKind: ActiveRecorderKind = preferredInputDeviceID == nil ? .systemDefault : .appScoped
        let inactiveRecorderToCancel = nextKind == activeRecorderKindStorage ? nil : activeRecorderLocked()
        preferredInputDeviceIDStorage = preferredInputDeviceID
        activeRecorderKindStorage = nextKind
        let selectedRecorder = activeRecorderLocked()
        let keepsAudioGraphWarm = keepsAudioGraphWarmStorage
        lock.unlock()

        selectedRecorder.preferredInputDeviceID = preferredInputDeviceID
        selectedRecorder.keepsAudioGraphWarm = keepsAudioGraphWarm
        inactiveRecorderToCancel?.cancel()
        return selectedRecorder
    }

    private func activeRecorderLocked() -> DictationAudioRecording {
        recorder(for: activeRecorderKindStorage)
    }

    private func inactiveRecorderLocked() -> DictationAudioRecording {
        inactiveRecorder(for: activeRecorderKindStorage)
    }

    private func recorder(for kind: ActiveRecorderKind) -> DictationAudioRecording {
        switch kind {
        case .systemDefault:
            return systemDefaultRecorder
        case .appScoped:
            return appScopedRecorder
        }
    }

    private func inactiveRecorder(for kind: ActiveRecorderKind) -> DictationAudioRecording {
        switch kind {
        case .systemDefault:
            return appScopedRecorder
        case .appScoped:
            return systemDefaultRecorder
        }
    }
}

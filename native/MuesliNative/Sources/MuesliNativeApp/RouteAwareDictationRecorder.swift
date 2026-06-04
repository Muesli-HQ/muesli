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
        lock.lock()
        defer { lock.unlock() }
        selectRecorderLocked(preferredInputDeviceID: preferredInputDeviceIDStorage)
        try activeRecorderLocked().prepare()
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        lock.lock()
        defer { lock.unlock() }
        selectRecorderLocked(preferredInputDeviceID: preferredInputDeviceID)
        try activeRecorderLocked().warmUp(preferredInputDeviceID: preferredInputDeviceID)
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        lock.lock()
        defer { lock.unlock() }
        selectRecorderLocked(preferredInputDeviceID: preferredInputDeviceID)
        try activeRecorderLocked().activateWarmEngine(preferredInputDeviceID: preferredInputDeviceID)
    }

    func coolDown() {
        lock.lock()
        defer { lock.unlock() }
        systemDefaultRecorder.coolDown()
        appScopedRecorder.coolDown()
    }

    @discardableResult
    func start() throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        selectRecorderLocked(preferredInputDeviceID: preferredInputDeviceIDStorage)
        return try activeRecorderLocked().start()
    }

    func stop() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let url = activeRecorderLocked().stop()
        inactiveRecorderLocked().cancel()
        return url
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        systemDefaultRecorder.cancel()
        appScopedRecorder.cancel()
    }

    func currentPower() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return activeRecorderLocked().currentPower()
    }

    private func wireCallbacks() {
        for recorder in [systemDefaultRecorder, appScopedRecorder] {
            recorder.onFirstCapturedAudioBuffer = { [weak self] date in
                self?.onFirstCapturedAudioBuffer?(date)
            }
            recorder.onFirstSpeechDetected = { [weak self] date in
                self?.onFirstSpeechDetected?(date)
            }
            recorder.onNoAudioTimeout = { [weak self] date in
                self?.onNoAudioTimeout?(date)
            }
            recorder.onRecordingFailed = { [weak self] error, id in
                self?.onRecordingFailed?(error, id)
            }
            recorder.onLatencyEvent = { [weak self] event, date in
                self?.onLatencyEvent?(event, date)
            }
        }
    }

    private func selectRecorderLocked(preferredInputDeviceID: AudioObjectID?) {
        let nextKind: ActiveRecorderKind = preferredInputDeviceID == nil ? .systemDefault : .appScoped
        preferredInputDeviceIDStorage = preferredInputDeviceID
        guard nextKind != activeRecorderKindStorage else {
            activeRecorderLocked().preferredInputDeviceID = preferredInputDeviceID
            activeRecorderLocked().keepsAudioGraphWarm = keepsAudioGraphWarmStorage
            return
        }

        inactiveRecorder(for: nextKind).cancel()
        activeRecorderKindStorage = nextKind
        activeRecorderLocked().preferredInputDeviceID = preferredInputDeviceID
        activeRecorderLocked().keepsAudioGraphWarm = keepsAudioGraphWarmStorage
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

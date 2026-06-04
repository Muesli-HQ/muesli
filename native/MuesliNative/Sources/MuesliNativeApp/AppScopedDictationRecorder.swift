import CoreAudio
import Foundation

final class AppScopedDictationRecorder: DictationAudioRecording {
    var preferredInputDeviceID: AudioObjectID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return recorder.preferredInputDeviceID
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            recorder.preferredInputDeviceID = newValue
        }
    }

    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?
    var onRecordingFailed: ((Error, UUID) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?

    private static let speechThresholdDB: Float = -58
    private static let noAudioTimeout: TimeInterval = 1.5

    private let recorder = StreamingMicRecorder(directoryName: "muesli-native-dictation")
    private let lock = NSRecursiveLock()
    private let callbackQueue = DispatchQueue(label: "com.muesli.app-scoped-dictation-recorder-callbacks")
    private var noAudioTimeoutWorkItem: DispatchWorkItem?
    private var activeRecordingID: UUID?
    private var hasReceivedFirstAudioBuffer = false
    private var hasDetectedSpeech = false
    private var hasReportedNoAudioTimeout = false

    init() {
        recorder.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
    }

    deinit {
        cancel()
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }

        try recorder.prepare()
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        lock.lock()
        defer { lock.unlock() }

        recorder.preferredInputDeviceID = preferredInputDeviceID
        try recorder.prepare()
        fputs("[dictation-engine-recorder] warmed preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")\n", stderr)
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        lock.lock()
        defer { lock.unlock() }

        recorder.preferredInputDeviceID = preferredInputDeviceID
        try recorder.prepare()
        fputs("[dictation-engine-recorder] activated preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")\n", stderr)
    }

    func coolDown() {
        lock.lock()
        defer { lock.unlock() }

        guard activeRecordingID == nil else { return }
        recorder.cancel()
    }

    @discardableResult
    func start() throws -> UUID {
        lock.lock()
        defer { lock.unlock() }

        if let activeRecordingID { return activeRecordingID }

        resetCaptureStateLocked()
        configureRecorderCallbacksLocked()
        let recordingID = UUID()
        activeRecordingID = recordingID
        do {
            try recorder.start()
        } catch {
            activeRecordingID = nil
            recorder.cancel()
            throw error
        }
        scheduleNoAudioTimeoutLocked()
        return recordingID
    }

    func stop() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        cancelTimersLocked()
        activeRecordingID = nil
        return recorder.stop()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        cancelTimersLocked()
        activeRecordingID = nil
        recorder.cancel()
    }

    func currentPower() -> Float {
        recorder.currentPower()
    }

    private func configureRecorderCallbacksLocked() {
        recorder.onAudioBuffer = { [weak self] samples in
            self?.handleAudioBuffer(samples)
        }
        recorder.onRecordingFailed = { [weak self] error in
            self?.handleRecordingFailed(error)
        }
    }

    private func resetCaptureStateLocked() {
        hasReceivedFirstAudioBuffer = false
        hasDetectedSpeech = false
        hasReportedNoAudioTimeout = false
    }

    private func handleAudioBuffer(_ samples: [Float]) {
        lock.lock()
        let firstBuffer = !hasReceivedFirstAudioBuffer && !samples.isEmpty
        if firstBuffer {
            hasReceivedFirstAudioBuffer = true
        }
        let power = Self.powerDB(samples)
        let firstSpeech = !hasDetectedSpeech && power >= Self.speechThresholdDB
        if firstSpeech {
            hasDetectedSpeech = true
        }
        lock.unlock()

        if firstBuffer {
            onFirstCapturedAudioBuffer?(Date())
        }
        if firstSpeech {
            onFirstSpeechDetected?(Date())
        }
    }

    private func handleRecordingFailed(_ error: Error) {
        lock.lock()
        guard let activeRecordingID else {
            lock.unlock()
            return
        }
        lock.unlock()
        onRecordingFailed?(error, activeRecordingID)
    }

    private func scheduleNoAudioTimeoutLocked() {
        noAudioTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.notifyNoAudioTimeoutIfNeeded()
        }
        noAudioTimeoutWorkItem = workItem
        callbackQueue.asyncAfter(deadline: .now() + Self.noAudioTimeout, execute: workItem)
    }

    private func notifyNoAudioTimeoutIfNeeded() {
        lock.lock()
        guard activeRecordingID != nil, !hasDetectedSpeech, !hasReportedNoAudioTimeout else {
            lock.unlock()
            return
        }
        hasReportedNoAudioTimeout = true
        lock.unlock()
        onNoAudioTimeout?(Date())
    }

    private func cancelTimersLocked() {
        noAudioTimeoutWorkItem?.cancel()
        noAudioTimeoutWorkItem = nil
    }

    private static func powerDB(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        let rawDB = rms > 0.000_001 ? 20 * log10(rms) : -160
        return max(-160, min(0, rawDB))
    }
}

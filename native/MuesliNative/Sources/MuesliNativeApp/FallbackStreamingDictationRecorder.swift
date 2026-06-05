import CoreAudio
import Foundation

final class FallbackStreamingDictationRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    var preferredInputDeviceID: AudioObjectID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return preferredInputDeviceIDStorage
        }
        set {
            lock.lock()
            preferredInputDeviceIDStorage = newValue
            primary.preferredInputDeviceID = newValue
            fallback.preferredInputDeviceID = newValue
            lock.unlock()
        }
    }

    private enum ActiveRecorder {
        case primary
        case fallback
    }

    private let primary: StreamingDictationRecording
    private let fallback: StreamingDictationRecording
    private let lock = NSRecursiveLock()
    private var activeRecorder: ActiveRecorder = .primary
    private var preferredInputDeviceIDStorage: AudioObjectID?

    init(
        primary: StreamingDictationRecording,
        fallback: StreamingDictationRecording
    ) {
        self.primary = primary
        self.fallback = fallback
        wireCallbacks()
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            try preparePrimaryLocked()
        } catch {
            emitLatency("streaming_recorder_primary_prepare_failed")
            primary.cancel()
            wireCallbacks()
            do {
                try prepareFallbackLocked()
            } catch {
                fallback.cancel()
                wireCallbacks()
                throw error
            }
        }
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        switch activeRecorder {
        case .primary:
            do {
                try primary.start()
            } catch {
                emitLatency("streaming_recorder_primary_start_failed")
                primary.cancel()
                wireCallbacks()
                do {
                    try prepareFallbackLocked()
                } catch {
                    fallback.cancel()
                    wireCallbacks()
                    throw error
                }
                do {
                    try fallback.start()
                } catch {
                    fallback.cancel()
                    wireCallbacks()
                    throw error
                }
            }
        case .fallback:
            do {
                try fallback.start()
            } catch {
                fallback.cancel()
                wireCallbacks()
                throw error
            }
        }
    }

    func stop() -> URL? {
        lock.lock()
        let recorder = activeRecorderLocked()
        let inactive = inactiveRecorderLocked()
        lock.unlock()

        let url = recorder.stop()
        inactive.cancel()
        wireCallbacks()
        return url
    }

    func cancel() {
        lock.lock()
        activeRecorder = .primary
        lock.unlock()

        primary.cancel()
        fallback.cancel()
        wireCallbacks()
    }

    func currentPower() -> Float {
        lock.lock()
        let recorder = activeRecorderLocked()
        lock.unlock()
        return recorder.currentPower()
    }

    private func preparePrimaryLocked() throws {
        primary.preferredInputDeviceID = preferredInputDeviceIDStorage
        try primary.prepare()
        activeRecorder = .primary
    }

    private func prepareFallbackLocked() throws {
        fallback.preferredInputDeviceID = preferredInputDeviceIDStorage
        emitLatency("streaming_recorder_fallback_prepare_begin")
        try fallback.prepare()
        activeRecorder = .fallback
        emitLatency("streaming_recorder_fallback_prepare_end")
    }

    private func wireCallbacks() {
        primary.onAudioBuffer = { [weak self] samples in
            self?.forwardAudioBuffer(samples, from: .primary)
        }
        fallback.onAudioBuffer = { [weak self] samples in
            self?.forwardAudioBuffer(samples, from: .fallback)
        }
        primary.onRecordingFailed = { [weak self] error in
            self?.forwardRecordingFailure(error, from: .primary)
        }
        fallback.onRecordingFailed = { [weak self] error in
            self?.forwardRecordingFailure(error, from: .fallback)
        }
        (primary as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
        (fallback as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
    }

    private func forwardAudioBuffer(_ samples: [Float], from recorder: ActiveRecorder) {
        lock.lock()
        let shouldForward = activeRecorder == recorder
        lock.unlock()
        guard shouldForward else { return }
        onAudioBuffer?(samples)
    }

    private func forwardRecordingFailure(_ error: Error, from recorder: ActiveRecorder) {
        lock.lock()
        let shouldForward = activeRecorder == recorder
        lock.unlock()
        guard shouldForward else { return }
        onRecordingFailed?(error)
    }

    private func activeRecorderLocked() -> StreamingDictationRecording {
        switch activeRecorder {
        case .primary:
            return primary
        case .fallback:
            return fallback
        }
    }

    private func inactiveRecorderLocked() -> StreamingDictationRecording {
        switch activeRecorder {
        case .primary:
            return fallback
        case .fallback:
            return primary
        }
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        onLatencyEvent?(event, date)
    }
}

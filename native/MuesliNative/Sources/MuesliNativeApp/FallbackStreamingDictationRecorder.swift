import CoreAudio
import Foundation

final class FallbackStreamingDictationRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting, PausableStreamingDictationRecording {
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
            lock.unlock()
        }
    }

    private enum ActiveRecorder {
        case primary
        case fallback
    }

    private let primary: StreamingDictationRecording
    private let fallback: StreamingDictationRecording
    // Commands are serialized independently of callback selection. A child may
    // wait for its callback during any native command; that callback never takes
    // operationLock, and we never call a child while holding lock.
    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private var activeRecorder: ActiveRecorder? = .primary
    private var generation: UInt64 = 0
    private var invalidated = false
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
        let attempt = lock.withLock { generation }
        operationLock.lock()
        defer { operationLock.unlock() }
        try checkCurrent(attempt)
        do {
            try prepare(.primary, attempt: attempt)
        } catch {
            lock.withLock { activeRecorder = nil }
            primary.cancel()
            wireCallbacks()
            try checkCurrent(attempt)
            emitLatency("streaming_recorder_primary_prepare_failed")
            do {
                try prepare(.fallback, attempt: attempt)
            } catch {
                lock.withLock { activeRecorder = nil }
                fallback.cancel()
                wireCallbacks()
                throw error
            }
        }
    }

    func start() throws {
        let attempt = lock.withLock { generation }
        operationLock.lock()
        defer { operationLock.unlock() }
        try checkCurrent(attempt)
        let selected = lock.withLock { activeRecorder ?? .primary }
        try select(selected, attempt: attempt)
        let child = recorder(for: selected)
        do {
            // Preparation may precede a route update. Apply it under the command
            // lock; child start re-prepares when its selected input changed.
            child.preferredInputDeviceID = preferredInputDeviceID
            try child.start()
            try checkCurrent(attempt)
        } catch {
            lock.withLock { activeRecorder = nil }
            child.cancel()
            wireCallbacks()
            // Cancellation is terminal for this attempt, not a backend failure.
            try checkCurrent(attempt)
            guard selected == .primary else { throw error }
            emitLatency("streaming_recorder_primary_start_failed")
            do {
                try prepare(.fallback, attempt: attempt)
                try checkCurrent(attempt)
                try fallback.start()
                try checkCurrent(attempt)
            } catch {
                lock.withLock { activeRecorder = nil }
                fallback.cancel()
                wireCallbacks()
                throw error
            }
        }
    }

    func stop() -> URL? {
        operationLock.lock()
        defer { operationLock.unlock() }
        let selected = lock.withLock { activeRecorder ?? .primary }
        let url = recorder(for: selected).stop()
        lock.withLock { activeRecorder = nil; generation &+= 1 }
        recorder(for: selected == .primary ? .fallback : .primary).cancel()
        wireCallbacks()
        return url
    }

    func cancel() {
        // Reject callbacks and late fallback activation before waiting for the
        // current native command. Reusable after cancel() finishes.
        lock.withLock { activeRecorder = nil; generation &+= 1 }
        operationLock.lock()
        defer { operationLock.unlock() }
        primary.cancel()
        fallback.cancel()
        wireCallbacks()
    }

    func invalidateForTeardown() {
        lock.withLock { invalidated = true; generation &+= 1 }
        primary.invalidateForTeardown()
        fallback.invalidateForTeardown()
    }

    func pause() {
        operationLock.lock()
        defer { operationLock.unlock() }
        let selected = lock.withLock { activeRecorder }
        if let selected { (recorder(for: selected) as? PausableStreamingDictationRecording)?.pause() }
    }

    func resume() {
        operationLock.lock()
        defer { operationLock.unlock() }
        let selected = lock.withLock { activeRecorder }
        if let selected { (recorder(for: selected) as? PausableStreamingDictationRecording)?.resume() }
    }

    func currentPower() -> Float {
        guard let selected = lock.withLock({ activeRecorder }) else { return -160 }
        return recorder(for: selected).currentPower()
    }

    private func checkCurrent(_ attempt: UInt64) throws {
        guard lock.withLock({ !invalidated && generation == attempt }) else { throw CancellationError() }
    }

    private func select(_ selected: ActiveRecorder, attempt: UInt64) throws {
        try lock.withLock {
            guard !invalidated, generation == attempt else { throw CancellationError() }
            activeRecorder = selected
        }
    }

    private func prepare(_ selected: ActiveRecorder, attempt: UInt64) throws {
        try checkCurrent(attempt)
        let child = recorder(for: selected)
        child.preferredInputDeviceID = preferredInputDeviceID
        if selected == .fallback { emitLatency("streaming_recorder_fallback_prepare_begin") }
        try child.prepare()
        try select(selected, attempt: attempt)
        emitRecorderSelection(slot: selected, recorder: child)
        if selected == .fallback { emitLatency("streaming_recorder_fallback_prepare_end") }
    }

    private func recorder(for selected: ActiveRecorder) -> StreamingDictationRecording {
        selected == .primary ? primary : fallback
    }

    private func emitRecorderSelection(slot: ActiveRecorder, recorder: StreamingDictationRecording) {
        let slotName = slot == .primary ? "primary" : "fallback"
        let preferredInput = preferredInputDeviceID.map(String.init) ?? "default"
        emitLatency(
            "streaming_recorder_selected slot=\(slotName) recorder=\(String(describing: type(of: recorder))) preferredInput=\(preferredInput)"
        )
    }

    private func wireCallbacks() {
        let callbackGeneration = lock.withLock { generation }
        primary.onAudioBuffer = { [weak self] samples in
            self?.forwardAudioBuffer(samples, from: .primary, generation: callbackGeneration)
        }
        fallback.onAudioBuffer = { [weak self] samples in
            self?.forwardAudioBuffer(samples, from: .fallback, generation: callbackGeneration)
        }
        primary.onRecordingFailed = { [weak self] error in
            self?.forwardRecordingFailure(error, from: .primary, generation: callbackGeneration)
        }
        fallback.onRecordingFailed = { [weak self] error in
            self?.forwardRecordingFailure(error, from: .fallback, generation: callbackGeneration)
        }
        (primary as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
        (fallback as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
    }

    private func forwardAudioBuffer(_ samples: [Float], from recorder: ActiveRecorder, generation callbackGeneration: UInt64) {
        lock.lock()
        let shouldForward = activeRecorder == recorder && generation == callbackGeneration
        lock.unlock()
        guard shouldForward else { return }
        onAudioBuffer?(samples)
    }

    private func forwardRecordingFailure(_ error: Error, from recorder: ActiveRecorder, generation callbackGeneration: UInt64) {
        lock.lock()
        let shouldForward = activeRecorder == recorder && generation == callbackGeneration
        lock.unlock()
        guard shouldForward else { return }
        onRecordingFailed?(error)
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        onLatencyEvent?(event, date)
    }
}

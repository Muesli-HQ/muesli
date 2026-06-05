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

    private let recorder: StreamingDictationRecording
    private let lock = NSRecursiveLock()
    private let prepareQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private var noAudioTimeoutWorkItem: DispatchWorkItem?
    private var activeRecordingID: UUID?
    private var explicitPreparation: ExplicitPreparation?
    private var hasReceivedFirstAudioBuffer = false
    private var hasDetectedSpeech = false
    private var hasReportedNoAudioTimeout = false

    private final class ExplicitPreparation {
        let inputDeviceID: AudioObjectID?
        let group = DispatchGroup()
        private let lock = NSLock()
        private var completed = false
        private var cancelled = false
        private var resultStorage: Result<Void, Error>?

        init(inputDeviceID: AudioObjectID?) {
            self.inputDeviceID = inputDeviceID
            group.enter()
        }

        var result: Result<Void, Error>? {
            lock.withLock { resultStorage }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        @discardableResult
        func complete(_ result: Result<Void, Error>) -> Bool {
            lock.withLock {
                guard !completed else { return false }
                resultStorage = result
                completed = true
                group.leave()
                return true
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                guard !completed else { return }
                resultStorage = .failure(Self.cancelledError())
                completed = true
                group.leave()
            }
        }

        private static func cancelledError() -> NSError {
            NSError(domain: "AppScopedDictationRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Dictation microphone preparation was cancelled",
            ])
        }
    }

    init(
        recorder: StreamingDictationRecording = FallbackStreamingDictationRecorder(
            primary: AudioQueueInputRecorder(directoryName: "muesli-native-dictation"),
            fallback: StreamingMicRecorder(directoryName: "muesli-native-dictation")
        ),
        prepareQueue: DispatchQueue = DispatchQueue(label: "com.muesli.app-scoped-dictation-recorder-prepare"),
        callbackQueue: DispatchQueue = DispatchQueue(label: "com.muesli.app-scoped-dictation-recorder-callbacks")
    ) {
        self.recorder = recorder
        self.prepareQueue = prepareQueue
        self.callbackQueue = callbackQueue

        (recorder as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
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

    func beginExplicitWarmup(preferredInputDeviceID: AudioObjectID?) {
        lock.lock()
        if let explicitPreparation,
           explicitPreparation.inputDeviceID == preferredInputDeviceID,
           !explicitPreparation.isCancelled {
            switch explicitPreparation.result {
            case nil, .success?:
                lock.unlock()
                onLatencyEvent?("app_scoped_explicit_prepare_reused", Date())
                return
            case .failure?:
                self.explicitPreparation = nil
                recorder.cancel()
            }
        }
        guard activeRecordingID == nil else {
            lock.unlock()
            return
        }

        recorder.preferredInputDeviceID = preferredInputDeviceID
        let preparation = ExplicitPreparation(inputDeviceID: preferredInputDeviceID)
        explicitPreparation = preparation
        lock.unlock()

        onLatencyEvent?("app_scoped_explicit_prepare_begin", Date())
        prepareQueue.async { [weak self, preparation] in
            guard let self else {
                preparation.complete(.success(()))
                return
            }

            self.lock.lock()
            let shouldPrepare = self.explicitPreparation === preparation && !preparation.isCancelled
            self.lock.unlock()
            guard shouldPrepare else {
                preparation.complete(.failure(Self.cancelledPreparationError()))
                self.onLatencyEvent?("app_scoped_explicit_prepare_cancelled", Date())
                return
            }

            let result = Result { try self.recorder.prepare() }
            var shouldTearDown = false
            self.lock.lock()
            if self.explicitPreparation === preparation && !preparation.isCancelled {
                _ = preparation.complete(result)
                if case .failure = result {
                    if self.activeRecordingID == nil {
                        self.explicitPreparation = nil
                        shouldTearDown = true
                    }
                }
            } else if self.activeRecordingID == nil {
                shouldTearDown = true
            }
            self.lock.unlock()

            if shouldTearDown {
                self.recorder.cancel()
            }
            switch result {
            case .success:
                self.onLatencyEvent?("app_scoped_explicit_prepare_end", Date())
            case .failure:
                self.onLatencyEvent?("app_scoped_explicit_prepare_failed", Date())
            }
        }
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
        explicitPreparation?.cancel()
        explicitPreparation = nil
        recorder.cancel()
    }

    @discardableResult
    func start() throws -> UUID {
        lock.lock()
        if let activeRecordingID {
            lock.unlock()
            return activeRecordingID
        }

        resetCaptureStateLocked()
        configureRecorderCallbacksLocked()
        let recordingID = UUID()
        activeRecordingID = recordingID
        let preparation = explicitPreparation
        lock.unlock()
        do {
            try awaitExplicitPreparationIfNeeded(preparation)
        } catch {
            lock.lock()
            activeRecordingID = nil
            lock.unlock()
            recorder.cancel()
            throw error
        }
        lock.lock()
        guard activeRecordingID == recordingID else {
            lock.unlock()
            throw NSError(domain: "AppScopedDictationRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Dictation recording was cancelled before microphone startup finished",
            ])
        }
        do {
            try recorder.start()
        } catch {
            activeRecordingID = nil
            lock.unlock()
            recorder.cancel()
            throw error
        }
        scheduleNoAudioTimeoutLocked()
        lock.unlock()
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
        explicitPreparation?.cancel()
        explicitPreparation = nil
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

    private func awaitExplicitPreparationIfNeeded(_ preparation: ExplicitPreparation?) throws {
        guard let preparation else { return }
        onLatencyEvent?("app_scoped_explicit_prepare_wait_begin", Date())
        preparation.group.wait()
        onLatencyEvent?("app_scoped_explicit_prepare_wait_end", Date())
        lock.lock()
        let isCurrentPreparation = explicitPreparation === preparation
        if isCurrentPreparation, case .failure? = preparation.result {
            explicitPreparation = nil
        }
        lock.unlock()
        guard isCurrentPreparation, !preparation.isCancelled else {
            throw Self.cancelledPreparationError()
        }
        switch preparation.result {
        case .success?:
            return
        case .failure(let error)?:
            throw error
        case nil:
            return
        }
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

    private static func cancelledPreparationError() -> NSError {
        NSError(domain: "AppScopedDictationRecorder", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Dictation microphone preparation was cancelled",
        ])
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

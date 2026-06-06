import CoreAudio
import Foundation

final class AppScopedDictationRecorder: DictationAudioRecording {
    var preferredInputDeviceID: AudioObjectID? {
        get {
            recorderQueue.sync {
                recorder.preferredInputDeviceID
            }
        }
        set {
            recorderQueue.sync {
                recorder.preferredInputDeviceID = newValue
            }
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
    private let recorderQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private var noAudioTimeoutWorkItem: DispatchWorkItem?
    private var activeRecordingID: UUID?
    private var explicitPreparation: ExplicitPreparation?
    private var lifecycleGeneration: UInt64 = 0
    private var hasReceivedFirstAudioBuffer = false
    private var hasDetectedSpeech = false
    private var hasReportedNoAudioTimeout = false

    private final class ExplicitPreparation {
        let inputDeviceID: AudioObjectID?
        let generation: UInt64
        let group = DispatchGroup()
        private let lock = NSLock()
        private var completed = false
        private var cancelled = false
        private var resultStorage: Result<Void, Error>?

        init(inputDeviceID: AudioObjectID?, generation: UInt64) {
            self.inputDeviceID = inputDeviceID
            self.generation = generation
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
        recorderQueue: DispatchQueue = DispatchQueue(label: "com.muesli.app-scoped-dictation-recorder-child"),
        callbackQueue: DispatchQueue = DispatchQueue(label: "com.muesli.app-scoped-dictation-recorder-callbacks")
    ) {
        self.recorder = recorder
        self.prepareQueue = prepareQueue
        self.recorderQueue = recorderQueue
        self.callbackQueue = callbackQueue

        (recorder as? StreamingDictationLatencyReporting)?.onLatencyEvent = { [weak self] event, date in
            self?.onLatencyEvent?(event, date)
        }
    }

    deinit {
        cancel()
    }

    func prepare() throws {
        try recorderQueue.sync {
            try recorder.prepare()
        }
    }

    func beginExplicitWarmup(preferredInputDeviceID: AudioObjectID?) {
        var shouldCancelRecorder = false
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
                lifecycleGeneration &+= 1
                shouldCancelRecorder = true
            }
        }
        guard activeRecordingID == nil else {
            lock.unlock()
            if shouldCancelRecorder {
                cancelChildRecorder()
            }
            return
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let preparation = ExplicitPreparation(inputDeviceID: preferredInputDeviceID, generation: generation)
        explicitPreparation = preparation
        lock.unlock()

        if shouldCancelRecorder {
            cancelChildRecorder()
        }
        onLatencyEvent?("app_scoped_explicit_prepare_begin", Date())
        prepareQueue.async { [weak self, preparation] in
            guard let self else {
                preparation.complete(.success(()))
                return
            }

            var didTouchChildRecorder = false
            let result = Result {
                try self.recorderQueue.sync {
                    self.lock.lock()
                    let shouldPrepare = self.isCurrentPreparationLocked(preparation)
                    self.lock.unlock()
                    guard shouldPrepare else {
                        throw Self.cancelledPreparationError()
                    }
                    // recorderQueue serializes this prepare against cancelChildRecorder().
                    // If cancellation arrives after this check, cancel() waits behind
                    // the prepare and the post-check below tears the child graph down.
                    didTouchChildRecorder = true
                    self.recorder.preferredInputDeviceID = preferredInputDeviceID
                    try self.recorder.prepare()
                }
            }
            var shouldTearDown = false
            var didCompleteCurrentPreparation = false
            self.lock.lock()
            if self.isCurrentPreparationLocked(preparation) {
                _ = preparation.complete(result)
                didCompleteCurrentPreparation = true
                if case .failure = result {
                    if self.activeRecordingID == nil {
                        self.explicitPreparation = nil
                        self.lifecycleGeneration &+= 1
                        shouldTearDown = true
                    }
                }
            } else {
                _ = preparation.complete(.failure(Self.cancelledPreparationError()))
                if self.activeRecordingID == nil && didTouchChildRecorder {
                    shouldTearDown = true
                }
            }
            self.lock.unlock()

            if shouldTearDown {
                self.cancelChildRecorder()
            }
            switch result {
            case .success:
                self.onLatencyEvent?(didCompleteCurrentPreparation ? "app_scoped_explicit_prepare_end" : "app_scoped_explicit_prepare_cancelled", Date())
            case .failure:
                self.onLatencyEvent?("app_scoped_explicit_prepare_failed", Date())
            }
        }
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        try recorderQueue.sync {
            recorder.preferredInputDeviceID = preferredInputDeviceID
            try recorder.prepare()
        }
        fputs("[dictation-engine-recorder] warmed preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")\n", stderr)
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        try recorderQueue.sync {
            recorder.preferredInputDeviceID = preferredInputDeviceID
            try recorder.prepare()
        }
        fputs("[dictation-engine-recorder] activated preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")\n", stderr)
    }

    func coolDown() {
        lock.lock()
        guard activeRecordingID == nil else {
            lock.unlock()
            return
        }
        explicitPreparation?.cancel()
        explicitPreparation = nil
        lifecycleGeneration &+= 1
        lock.unlock()
        cancelChildRecorder()
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
        let startGeneration = lifecycleGeneration
        let preparation = explicitPreparation
        lock.unlock()
        do {
            try awaitExplicitPreparationIfNeeded(preparation)
        } catch {
            if clearActiveRecordingIfCurrent(recordingID) {
                cancelChildRecorder()
            }
            throw error
        }
        do {
            try startChildRecorderIfCurrent(recordingID: recordingID, generation: startGeneration)
        } catch {
            if clearActiveRecordingIfCurrent(recordingID) {
                cancelChildRecorder()
            }
            throw error
        }
        return recordingID
    }

    func stop() -> URL? {
        lock.lock()
        cancelTimersLocked()
        activeRecordingID = nil
        explicitPreparation = nil
        lifecycleGeneration &+= 1
        lock.unlock()
        return recorderQueue.sync {
            let url = recorder.stop()
            recorder.cancel()
            return url
        }
    }

    func cancel() {
        lock.lock()
        cancelTimersLocked()
        activeRecordingID = nil
        explicitPreparation?.cancel()
        explicitPreparation = nil
        lifecycleGeneration &+= 1
        lock.unlock()
        cancelChildRecorder()
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

    private func isCurrentPreparationLocked(_ preparation: ExplicitPreparation) -> Bool {
        explicitPreparation === preparation
            && preparation.generation == lifecycleGeneration
            && !preparation.isCancelled
    }

    private func clearActiveRecordingIfCurrent(_ recordingID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if activeRecordingID == recordingID {
            activeRecordingID = nil
            return true
        }
        return false
    }

    private func cancelChildRecorder() {
        recorderQueue.sync {
            recorder.cancel()
        }
    }

    private func startChildRecorderIfCurrent(recordingID: UUID, generation: UInt64) throws {
        try recorderQueue.sync {
            lock.lock()
            let shouldStart = activeRecordingID == recordingID && lifecycleGeneration == generation
            lock.unlock()
            guard shouldStart else {
                throw Self.cancelledStartupError()
            }

            do {
                try recorder.start()
            } catch {
                if clearActiveRecordingIfCurrent(recordingID) {
                    recorder.cancel()
                }
                throw error
            }

            lock.lock()
            guard activeRecordingID == recordingID && lifecycleGeneration == generation else {
                let shouldCancel = activeRecordingID == nil
                lock.unlock()
                if shouldCancel {
                    recorder.cancel()
                }
                throw Self.cancelledStartupError()
            }
            scheduleNoAudioTimeoutLocked()
            lock.unlock()
        }
    }

    private func awaitExplicitPreparationIfNeeded(_ preparation: ExplicitPreparation?) throws {
        guard let preparation else { return }
        onLatencyEvent?("app_scoped_explicit_prepare_wait_begin", Date())
        preparation.group.wait()
        onLatencyEvent?("app_scoped_explicit_prepare_wait_end", Date())
        lock.lock()
        let isCurrentPreparation = isCurrentPreparationLocked(preparation)
        if isCurrentPreparation, case .failure? = preparation.result {
            explicitPreparation = nil
            lifecycleGeneration &+= 1
        }
        lock.unlock()
        guard isCurrentPreparation else {
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

    private static func cancelledStartupError() -> NSError {
        NSError(domain: "AppScopedDictationRecorder", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Dictation recording was cancelled before microphone startup finished",
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

import Foundation
import CoreAudio
import os

/// Merges real-time mic recording with Nemotron chunk-by-chunk transcription.
/// Text appears at the cursor as the user speaks (~560ms per chunk).
///
/// Usage:
///   let controller = StreamingDictationController(transcriber: nemotron)
///   controller.onPartialText = { fullText in /* paste delta */ }
///   controller.start()
///   // ... user speaks ...
///   controller.stop { finalText in /* persist final text */ }
@available(macOS 15, *)
protocol NemotronStreamingTranscribing: AnyObject {
    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState
    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String
}

@available(macOS 15, *)
private final class NemotronStreamingTranscriberAdapter: NemotronStreamingTranscribing {
    private let transcriber: NemotronStreamingTranscriber

    init(_ transcriber: NemotronStreamingTranscriber) {
        self.transcriber = transcriber
    }

    func makeStreamState() async throws -> NemotronStreamingTranscriber.StreamState {
        try await transcriber.makeStreamState()
    }

    func transcribeChunk(
        samples: [Float],
        state: inout NemotronStreamingTranscriber.StreamState
    ) async throws -> String {
        try await transcriber.transcribeChunk(samples: samples, state: &state)
    }
}

@available(macOS 15, *)
final class StreamingDictationController {
    private enum DrainResult {
        case finished
        case waitingForStreamState
    }

    private enum StopSetup {
        case start(UUID)
        case attached
        case immediate(String)
    }

    /// Called with the full accumulated transcript so far (on a background thread).
    var onPartialText: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let transcriber: NemotronStreamingTranscribing
    private let recorder: StreamingDictationRecording
    private var streamState: NemotronStreamingTranscriber.StreamState?
    private let streamLock = OSAllocatedUnfairLock()
    private var sampleBuffer: [Float] = []
    private let bufferLock = OSAllocatedUnfairLock()
    private var chunkQueue: [[Float]] = []
    private let queueLock = OSAllocatedUnfairLock()
    private var isDraining = false
    private let drainLock = OSAllocatedUnfairLock()
    private struct StopState {
        let sessionID: UUID
        var completions: [(String) -> Void]
    }
    private var stopState: StopState?
    private let stopLock = OSAllocatedUnfairLock()
    private var fullTranscript = ""
    private var isActive = false
    private var activeSessionID: UUID?
    private var stoppingSessionID: UUID?
    private var streamStateTask: Task<Void, Never>?
    private let chunkSamples = 8960  // 560ms at 16kHz
    private let stopStreamStateTimeout: TimeInterval
    private static let stopDrainTimeout: TimeInterval = 1.0

    init(
        transcriber: NemotronStreamingTranscriber,
        preferredInputDeviceID: AudioObjectID? = nil,
        recorder: StreamingDictationRecording = StreamingMicRecorder(),
        stopStreamStateTimeout: TimeInterval = 1.0
    ) {
        self.transcriber = NemotronStreamingTranscriberAdapter(transcriber)
        self.recorder = recorder
        self.stopStreamStateTimeout = stopStreamStateTimeout
        recorder.preferredInputDeviceID = preferredInputDeviceID
    }

    init(
        transcriber: NemotronStreamingTranscribing,
        preferredInputDeviceID: AudioObjectID? = nil,
        recorder: StreamingDictationRecording = StreamingMicRecorder(),
        stopStreamStateTimeout: TimeInterval = 1.0
    ) {
        self.transcriber = transcriber
        self.recorder = recorder
        self.stopStreamStateTimeout = stopStreamStateTimeout
        recorder.preferredInputDeviceID = preferredInputDeviceID
    }

    /// Pre-warm the ANE so first real chunk is fast. Call this early (e.g., on backend select).
    func warmup() {
        Task {
            do {
                var state = try await transcriber.makeStreamState()
                fputs("[streaming-dictation] warming up ANE...\n", stderr)
                let silence = [Float](repeating: 0, count: chunkSamples)
                _ = try? await transcriber.transcribeChunk(samples: silence, state: &state)
                fputs("[streaming-dictation] warmup done\n", stderr)
            } catch {
                fputs("[streaming-dictation] warmup failed: \(error)\n", stderr)
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        guard stopLock.withLock({ stopState == nil }),
              bufferLock.withLock({ stoppingSessionID == nil })
        else { return false }
        let sessionID = UUID()
        let didStartSession = bufferLock.withLock { () -> Bool in
            guard !isActive else { return false }
            isActive = true
            activeSessionID = sessionID
            sampleBuffer.removeAll()
            return true
        }
        guard didStartSession else { return true }
        streamLock.withLock {
            fullTranscript = ""
            streamState = nil
        }
        queueLock.withLock {
            chunkQueue.removeAll()
        }
        drainLock.withLock {
            isDraining = false
        }

        // Start mic IMMEDIATELY — don't block on state init or warmup
        recorder.onAudioBuffer = { [weak self] samples in
            self?.handleAudioBuffer(samples)
        }
        do {
            try recorder.prepare()
            try recorder.start()
            fputs("[streaming-dictation] mic started\n", stderr)
        } catch {
            fputs("[streaming-dictation] mic start failed: \(error)\n", stderr)
            resetActiveSession(cancelRecorder: true, sessionID: sessionID)
            return false
        }

        // Init stream state in background — audio buffers queue while this runs
        let transcriber = self.transcriber
        let initializationTask = Task { [weak self] in
            do {
                let state = try await transcriber.makeStreamState()
                guard let self, self.isCurrentSession(sessionID) else { return }
                self.streamLock.withLock {
                    self.streamState = state
                }
                fputs("[streaming-dictation] stream state ready, draining queued chunks\n", stderr)
                startDrainIfNeeded(sessionID: sessionID)
            } catch {
                guard let self, self.isCurrentSession(sessionID) else { return }
                fputs("[streaming-dictation] failed to create stream state: \(error)\n", stderr)
                self.failActiveSession(sessionID: sessionID, error: error)
            }
        }
        streamStateTask = initializationTask
        return true
    }

    /// Stop recording and finish queued audio off the caller's thread.
    func stop(completion: @escaping (String) -> Void) {
        let setup = stopLock.withLock { () -> StopSetup in
            let sessionIDs = bufferLock.withLock {
                (active: activeSessionID, stopping: stoppingSessionID)
            }
            if let activeSessionID = sessionIDs.active {
                if var stopState {
                    guard stopState.sessionID == activeSessionID else {
                        return .immediate(currentTranscript())
                    }
                    stopState.completions.append(completion)
                    self.stopState = stopState
                    return .attached
                }
                stopState = StopState(sessionID: activeSessionID, completions: [completion])
                bufferLock.withLock {
                    isActive = false
                    self.activeSessionID = nil
                    stoppingSessionID = activeSessionID
                }
                return .start(activeSessionID)
            }
            if let stoppingSessionID = sessionIDs.stopping {
                guard var stopState, stopState.sessionID == stoppingSessionID else {
                    return .immediate(currentTranscript())
                }
                stopState.completions.append(completion)
                self.stopState = stopState
                return .attached
            }
            return .immediate(currentTranscript())
        }

        let sessionID: UUID
        switch setup {
        case .start(let id):
            sessionID = id
        case .attached:
            return
        case .immediate(let transcript):
            completion(transcript)
            return
        }

        if let wavURL = recorder.stop() {
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Collect remaining buffered samples
        let remaining: [Float] = bufferLock.withLock {
            let samples = sampleBuffer
            sampleBuffer.removeAll()
            return samples
        }

        if !remaining.isEmpty {
            var padded = remaining
            if padded.count < chunkSamples {
                padded.append(contentsOf: [Float](repeating: 0, count: chunkSamples - padded.count))
            }
            let finalChunk = padded
            queueLock.withLock {
                chunkQueue.append(finalChunk)
            }
        }

        startDrainIfNeeded(sessionID: sessionID)
        let initializationTask = streamStateTask
        Task {
            let streamStateReady = await self.waitForStreamStateInitialization(
                initializationTask,
                sessionID: sessionID,
                timeout: self.stopStreamStateTimeout
            )
            guard self.isCurrentSession(sessionID) else {
                self.completeStop(sessionID: sessionID, with: self.currentTranscript())
                return
            }
            guard streamStateReady || self.hasStreamState() else {
                let transcript = self.finishStoppedSession(sessionID: sessionID)
                self.completeStop(sessionID: sessionID, with: transcript)
                return
            }
            self.startDrainIfNeeded(sessionID: sessionID)
            await self.waitForDrain(sessionID: sessionID, timeout: Self.stopDrainTimeout)
            let transcript = self.finishStoppedSession(sessionID: sessionID)
            self.completeStop(sessionID: sessionID, with: transcript)
        }
    }

    func cancel() {
        resetActiveSession(cancelRecorder: true)
    }

    private func failActiveSession(sessionID: UUID, error: Error) {
        guard isCurrentSession(sessionID) else { return }
        resetActiveSession(cancelRecorder: true, sessionID: sessionID)
        onFailure?(error)
    }

    private func resetActiveSession(cancelRecorder: Bool, sessionID expectedSessionID: UUID? = nil) {
        let completionSessionID = bufferLock.withLock { () -> UUID? in
            let sessionID = expectedSessionID ?? activeSessionID ?? stoppingSessionID
            isActive = false
            activeSessionID = nil
            stoppingSessionID = nil
            sampleBuffer.removeAll()
            return sessionID
        }
        streamStateTask?.cancel()
        streamStateTask = nil
        if let completionSessionID {
            completeStop(sessionID: completionSessionID, with: currentTranscript())
        }
        if cancelRecorder {
            recorder.cancel()
        }
        queueLock.withLock {
            chunkQueue.removeAll()
        }
        drainLock.withLock {
            isDraining = false
        }
        streamLock.withLock {
            streamState = nil
        }
    }

    private func completeStop(sessionID: UUID, with transcript: String) {
        let completions: [(String) -> Void] = stopLock.withLock {
            guard let state = stopState else { return [] }
            if state.sessionID != sessionID {
                return []
            }
            stopState = nil
            let completions = state.completions
            return completions
        }
        for completion in completions {
            completion(transcript)
        }
    }

    // MARK: - Audio Buffer Handling

    /// Called on AVAudioEngine's audio processing thread (4096 samples per call).
    private func handleAudioBuffer(_ samples: [Float]) {
        let capture = bufferLock.withLock { () -> (sessionID: UUID?, chunks: [[Float]]) in
            guard isActive, let sessionID = activeSessionID else { return (nil, []) }
            var chunks: [[Float]] = []
            sampleBuffer.append(contentsOf: samples)
            while sampleBuffer.count >= chunkSamples {
                chunks.append(Array(sampleBuffer.prefix(chunkSamples)))
                sampleBuffer.removeFirst(chunkSamples)
            }
            return (sessionID, chunks)
        }

        if !capture.chunks.isEmpty {
            queueLock.withLock {
                chunkQueue.append(contentsOf: capture.chunks)
            }
            // Kick off serial processing if not already running
            guard let sessionID = capture.sessionID else { return }
            startDrainIfNeeded(sessionID: sessionID)
        }
    }

    private func startDrainIfNeeded(sessionID: UUID) {
        guard isCurrentSession(sessionID) else { return }
        guard hasStreamState() else { return }
        let shouldStart = drainLock.withLock {
            if isDraining { return false }
            isDraining = true
            return true
        }
        guard shouldStart else { return }
        Task { [weak self] in
            let result = await self?.drainQueue(sessionID: sessionID)
            switch result {
            case .finished:
                self?.markDrainFinished(sessionID: sessionID)
            case .waitingForStreamState:
                self?.markDrainPausedForStreamState(sessionID: sessionID)
            case .none:
                break
            }
        }
    }

    private func markDrainFinished(sessionID: UUID) {
        let shouldContinue = hasStreamState() && queueLock.withLock { !chunkQueue.isEmpty }
        drainLock.withLock {
            isDraining = false
        }
        if shouldContinue {
            startDrainIfNeeded(sessionID: sessionID)
        }
    }

    private func markDrainPausedForStreamState(sessionID: UUID) {
        let shouldContinue = hasStreamState() && queueLock.withLock { !chunkQueue.isEmpty }
        drainLock.withLock {
            isDraining = false
        }
        if shouldContinue {
            startDrainIfNeeded(sessionID: sessionID)
        }
    }

    private func isCurrentSession(_ sessionID: UUID) -> Bool {
        bufferLock.withLock {
            activeSessionID == sessionID || stoppingSessionID == sessionID
        }
    }

    private func waitForDrain(sessionID: UUID, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isCurrentSession(sessionID) else { return }
            let queueIsEmpty = queueLock.withLock { chunkQueue.isEmpty }
            let currentlyDraining = drainLock.withLock { isDraining }
            if queueIsEmpty && !currentlyDraining { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fputs("[streaming-dictation] stop drain timed out\n", stderr)
    }

    private func waitForStreamStateInitialization(
        _ task: Task<Void, Never>?,
        sessionID: UUID,
        timeout: TimeInterval
    ) async -> Bool {
        guard let task else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isCurrentSession(sessionID) else { return false }
            if hasStreamState() { return true }
            if streamStateTask == nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        if isCurrentSession(sessionID), !hasStreamState() {
            fputs("[streaming-dictation] stream state init timed out during stop\n", stderr)
        }
        return false
    }

    private func finishStoppedSession(sessionID: UUID) -> String {
        let didFinishCurrentSession = bufferLock.withLock { () -> Bool in
            guard activeSessionID == sessionID || stoppingSessionID == sessionID else { return false }
            if activeSessionID == sessionID {
                activeSessionID = nil
                isActive = false
            }
            if stoppingSessionID == sessionID {
                stoppingSessionID = nil
            }
            return true
        }
        guard didFinishCurrentSession else { return currentTranscript() }
        streamStateTask = nil
        queueLock.withLock {
            chunkQueue.removeAll()
        }
        drainLock.withLock {
            isDraining = false
        }
        let transcript = streamLock.withLock { () -> String in
            streamState = nil
            return fullTranscript
        }
        fputs("[streaming-dictation] stopped, transcript (\(transcript.count) chars): \(transcript.prefix(100))...\n", stderr)
        return transcript
    }

    private func currentTranscript() -> String {
        streamLock.withLock { fullTranscript }
    }

    private func hasStreamState() -> Bool {
        streamLock.withLock { streamState != nil }
    }

    /// Process all queued chunks serially, one at a time.
    private func drainQueue(sessionID: UUID) async -> DrainResult {
        while true {
            guard isCurrentSession(sessionID) else { return .finished }
            let chunk: [Float]? = queueLock.withLock {
                chunkQueue.isEmpty ? nil : chunkQueue.removeFirst()
            }
            guard let chunk else { return .finished }

            guard var state = streamLock.withLock({ streamState }) else {
                guard isCurrentSession(sessionID) else { return .finished }
                queueLock.withLock {
                    chunkQueue.insert(chunk, at: 0)
                }
                return .waitingForStreamState
            }

            let start = CFAbsoluteTimeGetCurrent()
            do {
                let newText = try await transcriber.transcribeChunk(samples: chunk, state: &state)
                guard isCurrentSession(sessionID) else { return .finished }
                let elapsed = CFAbsoluteTimeGetCurrent() - start

                let updatedState = state
                let transcript = streamLock.withLock { () -> String? in
                    streamState = updatedState
                    guard !newText.isEmpty else { return nil }
                    fullTranscript += newText
                    return fullTranscript
                }
                if !newText.isEmpty {
                    fputs("[streaming-dictation] chunk → \"\(newText)\" (\(String(format: "%.0f", elapsed * 1000))ms)\n", stderr)
                    if let transcript {
                        onPartialText?(transcript)
                    }
                } else {
                    fputs("[streaming-dictation] chunk → (silence) (\(String(format: "%.0f", elapsed * 1000))ms)\n", stderr)
                }
            } catch {
                fputs("[streaming-dictation] chunk error: \(error)\n", stderr)
                guard isCurrentSession(sessionID) else { return .finished }
                streamLock.withLock {
                    streamState = nil
                }
                failActiveSession(sessionID: sessionID, error: error)
                return .finished
            }
        }
    }
}

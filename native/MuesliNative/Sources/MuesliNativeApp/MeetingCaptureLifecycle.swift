import Foundation
import os

/// The meeting's capture phase. Controller, detector and session consume this
/// value; native recorder replacement states remain private to the recorders.
enum MeetingCapturePhase: Equatable {
    case preparing, capturing, paused, stopping, stopped

    var isRecording: Bool { self == .capturing || self == .paused }
    var acceptsSamples: Bool { self == .preparing || self == .capturing }
    var isEnding: Bool { self == .stopping || self == .stopped }
}

/// Owns the native capture lifetime, including a partially completed start.
/// State never waits for a driver. Each driver's stop waits only for that
/// driver's outstanding start; the other track can retire independently.
final class MeetingCaptureLifecycle: @unchecked Sendable {
    enum StartError: LocalizedError {
        case timedOut
        var errorDescription: String? {
            "The audio device did not finish starting. Muesli is releasing capture before another recording can start."
        }
    }

    private struct State {
        var phase: MeetingCapturePhase = .preparing
        var microphoneOperation: Task<Void, Error>?
        var systemOperation: Task<Void, Error>?
        var waiter: CheckedContinuation<Void, Error>?
        var deadline: DispatchWorkItem?
        var shutdown: Task<MeetingCaptureShutdown.Result, Never>?
        var drainsMicrophoneOnStop = false
        var microphoneDeliveryClosed = false
        var pendingMicrophoneBoundaries = 0
        var microphoneIntervalStart: Int64 = 0
        var nativeStopDrainRange: Range<Int64>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let microphone: MeetingMicRecording
    private let systemAudio: SystemAudioCapturing
    private let microphoneClock: () -> Int64
    private let completion = OSAllocatedUnfairLock<() -> Void>(initialState: {})
    var onQuiesced: () -> Void {
        get { completion.withLock { $0 } }
        set { completion.withLock { $0 = newValue } }
    }

    init(microphone: MeetingMicRecording, systemAudio: SystemAudioCapturing,
         microphoneClock: @escaping () -> Int64 = { MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()) },
         onQuiesced: @escaping () -> Void = {}) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.microphoneClock = microphoneClock
        self.onQuiesced = onQuiesced
        state.withLock { $0.microphoneIntervalStart = microphoneClock() }
        microphone.setSampleAdmissionCheck { [weak self] in
            self?.acceptsLiveSamples ?? false
        }
        microphone.setNativeStopDrainRange { [weak self] in
            guard let self else { return nil }
            return self.state.withLock { state in
                guard !state.microphoneDeliveryClosed, state.pendingMicrophoneBoundaries == 0 else { return nil }
                if state.phase.acceptsSamples {
                    // A child also stops during live route/health handoff. Its
                    // native-held PCM still belongs to this capture interval;
                    // MeetingMicrophoneDelivery applies the old/new cutover.
                    // Resume changes the lower bound, so it cannot reopen a
                    // previous interval. Pause admits no new native buffers.
                    let end = max(state.microphoneIntervalStart, self.microphoneClock())
                    return state.microphoneIntervalStart..<end
                }
                // Stop uses the first request's frozen boundary, never "now".
                return state.phase == .stopping ? state.nativeStopDrainRange : nil
            }
        }
    }

    var phase: MeetingCapturePhase { state.withLock { $0.phase } }
    var isEnding: Bool { phase.isEnding }
    var isMicrophoneDeliveryOpen: Bool { state.withLock { !$0.microphoneDeliveryClosed } }

    /// Logical Resume may be visible before the preceding pause fence completes.
    /// Neither native late admission nor the system/AEC stream may cross it.
    var acceptsLiveSamples: Bool {
        state.withLock { !$0.microphoneDeliveryClosed && $0.pendingMicrophoneBoundaries == 0 && $0.phase.acceptsSamples }
    }

    /// Producers reject new paused input at admission, so delayed pre-pause
    /// buffers retain delivery eligibility while paused and during stop.
    /// Already accepted mic buffers can outlive native quiescence; the session
    /// closes this window at its processing-queue barrier, or immediately on discard.
    func acceptsMicrophoneSamples(_ audio: MicrophoneCaptureAudio? = nil) -> Bool {
        return state.withLock {
            !$0.microphoneDeliveryClosed
                && (audio?.admitted == true || ($0.pendingMicrophoneBoundaries == 0
                    && ($0.phase.acceptsSamples || $0.drainsMicrophoneOnStop)))
        }
    }

    /// Shared by the session's AEC/chunk pipeline and capture-to-file tests.
    /// Check the packet receipt on the destination queue, so pause/stop cannot
    /// erase accepted input and discard still wins against queued delivery.
    func enqueueMicrophoneSamples(_ audio: MicrophoneCaptureAudio, on queue: DispatchQueue,
                                  consume: @escaping () -> Void) {
        guard !audio.samples.isEmpty else { return }
        queue.async { [weak self] in
            guard self?.acceptsMicrophoneSamples(audio) == true else { return }
            consume()
        }
    }

    /// The native recorder calls this after writing each buffer to the full
    /// system recording. Preserve every such buffer until the session barrier,
    /// including in-flight callbacks during Pause and Stop, so chunk offsets
    /// stay aligned with diarization of that recording.
    func enqueueSystemSamples(on queue: DispatchQueue, consume: @escaping () -> Void) {
        state.withLock {
            guard !$0.microphoneDeliveryClosed else { return }
            queue.async { [weak self] in
                guard self?.isMicrophoneDeliveryOpen == true else { return }
                consume()
            }
        }
    }

    /// Permanently reject delivery on discard or after the session's final drain
    /// barrier, even if a timed-out native stop is still retiring in the background.
    func finishMicrophoneDelivery() {
        state.withLock { $0.microphoneDeliveryClosed = true }
    }

    func start(timeout: TimeInterval = 20) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = DispatchWorkItem { [weak self] in
                    _ = self?.requestStop(error: StartError.timedOut)
                }
                let accepted = state.withLock { state in
                    guard state.phase == .preparing, state.waiter == nil,
                          state.microphoneOperation == nil else { return false }
                    state.waiter = continuation
                    state.deadline = deadline
                    return true
                }
                guard accepted else { continuation.resume(throwing: CancellationError()); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                Task { [self] in
                    do {
                        try await performStart(isMicrophone: true) { [microphone] in
                            try await Self.onDriverQueue { try microphone.prepare() }
                        }
                        try await performStart(isMicrophone: false) { [systemAudio] in
                            try await systemAudio.start()
                        }
                        try await performStart(isMicrophone: true) { [microphone] in
                            try await Self.onDriverQueue { try microphone.start() }
                        }
                        let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
                            guard state.phase == .preparing else { return nil }
                            state.phase = .capturing
                            state.deadline?.cancel()
                            state.deadline = nil
                            defer { state.waiter = nil }
                            return state.waiter
                        }
                        waiter?.resume()
                    } catch {
                        _ = requestStop(error: error)
                    }
                }
            }
        } onCancel: {
            _ = self.requestStop()
        }
    }

    /// Registration and shutdown snapshot are atomic. No native call runs under
    /// the state lock, and a late stage cannot register after cancellation.
    private func performStart(isMicrophone: Bool, operation: @escaping () async throws -> Void) async throws {
        guard let task = enqueue(isMicrophone: isMicrophone, operation: operation) else {
            throw CancellationError()
        }
        try await task.value
    }

    private func enqueue(isMicrophone: Bool, operation: @escaping () async throws -> Void) -> Task<Void, Error>? {
        state.withLock { state in
            enqueue(in: &state, isMicrophone: isMicrophone, operation: operation)
        }
    }

    private func enqueue(in state: inout State, isMicrophone: Bool,
                         operation: @escaping () async throws -> Void) -> Task<Void, Error>? {
        guard !state.phase.isEnding else { return nil }
        let previous = isMicrophone ? state.microphoneOperation : state.systemOperation
        let task = Task.detached {
            try await previous?.value
            try await operation()
        }
        if isMicrophone { state.microphoneOperation = task } else { state.systemOperation = task }
        return task
    }

    @discardableResult
    func setPaused(_ paused: Bool, boundary: (() -> Void)? = nil) -> Bool {
        state.withLock { state in
            guard state.phase == (paused ? .capturing : .paused) else { return false }
            if !paused { state.microphoneIntervalStart = microphoneClock() }
            state.phase = paused ? .paused : .capturing
            if boundary != nil { state.pendingMicrophoneBoundaries += 1 }
            // Register under the phase lock: Stop and rapid Resume must observe
            // this operation, not slip between the phase change and its fence.
            _ = enqueue(in: &state, isMicrophone: true) { [self, microphone] in
                try await Self.onDriverQueue {
                    if paused { microphone.pause() }
                    if let boundary {
                        if paused { microphone.drainAcceptedAudio() }
                        if self.state.withLock({ !$0.microphoneDeliveryClosed }) { boundary() }
                        self.state.withLock {
                            $0.pendingMicrophoneBoundaries -= 1
                            if !paused, $0.pendingMicrophoneBoundaries == 0, $0.phase == .capturing {
                                $0.microphoneIntervalStart = self.microphoneClock()
                            }
                        }
                    }
                    if !paused { microphone.resume() }
                }
            }
            _ = enqueue(in: &state, isMicrophone: false) { [systemAudio] in
                try await Self.onDriverQueue { paused ? systemAudio.pause() : systemAudio.resume() }
            }
            return true
        }
    }

    private func takeWaiter() -> CheckedContinuation<Void, Error>? {
        state.withLock { state in
            state.deadline?.cancel()
            state.deadline = nil
            defer { state.waiter = nil }
            return state.waiter
        }
    }

    @discardableResult
    func requestStop(error: Error = CancellationError()) -> Task<MeetingCaptureShutdown.Result, Never> {
        let shutdown = state.withLock { state in
            if let shutdown = state.shutdown { return shutdown }
            if state.phase.acceptsSamples, !state.microphoneDeliveryClosed, state.pendingMicrophoneBoundaries == 0 {
                // Freeze once, before invalidating producers. This is capture
                // time, not the later time at which a driver finishes stopping.
                let end = max(state.microphoneIntervalStart, microphoneClock())
                state.nativeStopDrainRange = state.microphoneIntervalStart..<end
            }
            state.drainsMicrophoneOnStop = state.phase.acceptsSamples && state.pendingMicrophoneBoundaries == 0
            state.phase = .stopping
            let micStart = state.microphoneOperation
            let systemStart = state.systemOperation
            let task = Task { [self, microphone, systemAudio] in
                let result = await MeetingCaptureShutdown.stop(
                    microphone: {
                        _ = try? await micStart?.value
                        return try? await Self.onDriverQueue {
                            let url = microphone.stop()
                            microphone.waitForQuiescence()
                            return url
                        }
                    },
                    systemAudio: {
                        _ = try? await systemStart?.value
                        return try? await Self.onDriverQueue { systemAudio.stop() }
                    },
                    onQuiesced: { [self] in
                        self.state.withLock { $0.phase = .stopped }
                        onQuiesced()
                    }
                )
                return result
            }
            state.shutdown = task
            return task
        }
        // Invalidation is a nonblocking state change. It disqualifies queued
        // microphone replacements immediately, even while native start waits.
        microphone.invalidateForTeardown()
        takeWaiter()?.resume(throwing: error)
        return shutdown
    }

    func stop() async -> MeetingCaptureShutdown.Result { await requestStop().value }

    /// Synchronous HAL calls must not occupy MainActor or a cooperative executor.
    static func onDriverQueue<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}

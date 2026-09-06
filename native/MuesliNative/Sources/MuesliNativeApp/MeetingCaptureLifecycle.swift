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
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let microphone: MeetingMicRecording
    private let systemAudio: SystemAudioCapturing
    private let completion = OSAllocatedUnfairLock<() -> Void>(initialState: {})
    var onQuiesced: () -> Void {
        get { completion.withLock { $0 } }
        set { completion.withLock { $0 = newValue } }
    }

    init(microphone: MeetingMicRecording, systemAudio: SystemAudioCapturing,
         onQuiesced: @escaping () -> Void = {}) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.onQuiesced = onQuiesced
    }

    var phase: MeetingCapturePhase { state.withLock { $0.phase } }
    var isEnding: Bool { phase.isEnding }

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
            guard !state.phase.isEnding else { return nil }
            let previous = isMicrophone ? state.microphoneOperation : state.systemOperation
            let task = Task.detached {
                try await previous?.value
                try await operation()
            }
            if isMicrophone { state.microphoneOperation = task } else { state.systemOperation = task }
            return task
        }
    }

    @discardableResult
    func setPaused(_ paused: Bool) -> Bool {
        let changed = state.withLock { state in
            guard state.phase == (paused ? .capturing : .paused) else { return false }
            state.phase = paused ? .paused : .capturing
            return true
        }
        guard changed else { return false }
        _ = enqueue(isMicrophone: true) { [microphone] in
            try await Self.onDriverQueue { paused ? microphone.pause() : microphone.resume() }
        }
        _ = enqueue(isMicrophone: false) { [systemAudio] in
            try await Self.onDriverQueue { paused ? systemAudio.pause() : systemAudio.resume() }
        }
        return true
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

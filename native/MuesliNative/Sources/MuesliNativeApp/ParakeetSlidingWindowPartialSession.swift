import AVFoundation
import FluidAudio
import Foundation
import os

/// Display-only streaming partials backed by FluidAudio's sliding-window
/// Parakeet engine (issue #99, engine v2). The engine re-decodes overlapping
/// windows and manages its own volatile/confirmed hypothesis split with
/// corrections, so unlike the Nemotron RNN-T session the VAD segment
/// boundary/commit hooks are no-ops: the tail simply mirrors the engine's
/// current volatile hypothesis and clears when text is confirmed. Committed
/// captions still come exclusively from the durable VAD chunk path; a brief
/// tail/caption overlap during the settle window is accepted and visually
/// disambiguated by the dashed provisional styling.
final class ParakeetSlidingWindowPartialSession: MeetingPartialStreaming {
    var onPartialUpdate: ((String) -> Void)?

    private let manager: SlidingWindowAsrManager
    private let source: AudioSource
    private let label: String

    private struct State {
        var sampleBuffer: [Float] = []
        var isForwarding = false
        var isSuspended = false
        var isStopped = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var updatesTask: Task<Void, Never>?

    /// ~0.25s of 16 kHz audio per actor hop keeps forwarding overhead
    /// negligible without adding perceptible latency.
    private let forwardChunkSamples = 4000

    init(manager: SlidingWindowAsrManager, source: AudioSource, label: String) {
        self.manager = manager
        self.source = source
        self.label = label
    }

    /// Start the engine and subscribe to hypothesis updates. Throws when the
    /// engine cannot start; the caller falls back to another partials engine.
    func start() async throws {
        try await manager.startStreaming(source: source)
        let updates = await manager.transcriptionUpdates
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                let tail: String? = self.state.withLock { s in
                    guard !s.isStopped, !s.isSuspended else { return nil }
                    return Self.tailText(text: update.text, isConfirmed: update.isConfirmed)
                }
                if let tail {
                    self.onPartialUpdate?(tail)
                }
            }
        }
    }

    /// Volatile hypotheses become the tail; confirmations clear it — the
    /// confirmed content is covered by the durable VAD caption path.
    static func tailText(text: String, isConfirmed: Bool) -> String {
        isConfirmed ? "" : text
    }

    /// Cheap append; safe to call on the meeting session's serial audio queue.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldForward: Bool = state.withLock { s in
            guard !s.isStopped, !s.isSuspended else { return false }
            s.sampleBuffer.append(contentsOf: samples)
            guard s.sampleBuffer.count >= forwardChunkSamples, !s.isForwarding else { return false }
            s.isForwarding = true
            return true
        }
        if shouldForward {
            Task.detached(priority: .utility) { [weak self] in
                await self?.forward()
            }
        }
    }

    private func forward() async {
        while true {
            let batch: [Float]? = state.withLock { s in
                guard !s.isStopped, !s.isSuspended, s.sampleBuffer.count >= forwardChunkSamples else {
                    s.isForwarding = false
                    return nil
                }
                let batch = Array(s.sampleBuffer.prefix(forwardChunkSamples))
                s.sampleBuffer.removeFirst(forwardChunkSamples)
                return batch
            }
            guard let batch else { return }
            guard let buffer = Self.makePCMBuffer(samples: batch) else { continue }
            await manager.streamAudio(buffer)
        }
    }

    /// 16 kHz mono float32 buffer for the engine's converter (a no-op resample).
    static func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                channel.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    // The sliding-window engine manages its own hypothesis lifecycle; VAD
    // segment hooks are intentionally no-ops (see type comment).
    func markSegmentBoundary() {}
    func commitSegment() {}

    func suspend() {
        state.withLock { s in
            s.isSuspended = true
            s.sampleBuffer.removeAll()
        }
        onPartialUpdate?("")
    }

    func resume() {
        state.withLock { s in
            s.isSuspended = false
        }
    }

    func stop() {
        state.withLock { s in
            s.isStopped = true
            s.sampleBuffer.removeAll()
        }
        updatesTask?.cancel()
        updatesTask = nil
        let manager = self.manager
        Task.detached(priority: .utility) {
            await manager.cancel()
        }
    }
}

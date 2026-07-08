import AVFoundation
import FluidAudio
import Foundation
import os

/// Display-only streaming partials backed by FluidAudio's native streaming
/// engines (issue #99, engine v2) — Parakeet EOU 120M at 160ms chunks, the
/// fastest on-device option. The engine decodes each chunk against a
/// cache-aware streaming encoder and reports the full accumulated transcript
/// per chunk; the tail shown in the live view is that transcript minus the
/// prefix already covered by committed VAD captions, using the same
/// freeze-at-rotation / drop-at-commit arithmetic as the Nemotron session.
final class ParakeetEouPartialSession: MeetingPartialStreaming {
    var onPartialUpdate: ((String) -> Void)?

    private let manager: any StreamingAsrManager
    private let label: String

    /// Pure tail arithmetic over the engine's append-only accumulated
    /// transcript. Extracted for direct unit testing.
    struct TailState {
        /// Engine transcript characters already covered by committed captions.
        var committedPrefixLength = 0
        /// Freeze point captured at the last VAD chunk rotation.
        var pendingCommitPrefixLength: Int?
        var latestFullText = ""

        var tail: String {
            String(latestFullText.dropFirst(min(committedPrefixLength, latestFullText.count)))
        }

        mutating func updated(fullText: String) -> String {
            latestFullText = fullText
            return tail
        }

        mutating func markBoundary() {
            pendingCommitPrefixLength = latestFullText.count
        }

        /// Returns the recomputed tail, or nil when no boundary was pending.
        mutating func commit() -> String? {
            guard let pending = pendingCommitPrefixLength else { return nil }
            committedPrefixLength = max(committedPrefixLength, pending)
            pendingCommitPrefixLength = nil
            return tail
        }

        /// Discard any uncommitted tail (pause): everything decoded so far is
        /// treated as covered, so the tail restarts from new speech.
        mutating func discardTail() {
            committedPrefixLength = latestFullText.count
            pendingCommitPrefixLength = nil
        }
    }

    private struct State {
        var sampleBuffer: [Float] = []
        var isForwarding = false
        var isSuspended = false
        var isStopped = false
        var didFail = false
        var tailState = TailState()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// ~0.32s of 16 kHz audio per actor hop: two 160ms engine chunks per
    /// forward, keeping call overhead low without adding perceptible latency.
    private let forwardChunkSamples = 5120

    init(manager: any StreamingAsrManager, label: String) {
        self.manager = manager
        self.label = label
    }

    /// Subscribe to the engine's per-chunk transcript callback. The manager
    /// must already have its models loaded.
    func start() async {
        await manager.setPartialTranscriptCallback { [weak self] fullText in
            guard let self else { return }
            let tail: String? = self.state.withLock { s in
                guard !s.isStopped, !s.didFail else { return nil }
                let tail = s.tailState.updated(fullText: fullText)
                return s.isSuspended ? nil : tail
            }
            if let tail {
                self.onPartialUpdate?(tail)
            }
        }
    }

    /// Cheap append; safe to call on the meeting session's serial audio queue.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldForward: Bool = state.withLock { s in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
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
                guard !s.isStopped, !s.isSuspended, !s.didFail, s.sampleBuffer.count >= forwardChunkSamples else {
                    s.isForwarding = false
                    return nil
                }
                let batch = Array(s.sampleBuffer.prefix(forwardChunkSamples))
                s.sampleBuffer.removeFirst(forwardChunkSamples)
                return batch
            }
            guard let batch else { return }
            guard let buffer = Self.makePCMBuffer(samples: batch) else { continue }
            do {
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
            } catch {
                goDormant(error: error)
                return
            }
        }
    }

    /// 16 kHz mono float32 buffer matching the engine's expected input.
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

    func markSegmentBoundary() {
        state.withLock { s in
            s.tailState.markBoundary()
        }
    }

    func commitSegment() {
        let tail: String? = state.withLock { s in
            guard !s.isStopped, !s.didFail, !s.isSuspended else {
                _ = s.tailState.commit()
                return nil
            }
            return s.tailState.commit()
        }
        if let tail {
            onPartialUpdate?(tail)
        }
    }

    func suspend() {
        state.withLock { s in
            s.isSuspended = true
            s.sampleBuffer.removeAll()
            s.tailState.discardTail()
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
        let manager = self.manager
        Task.detached(priority: .utility) {
            await manager.cleanup()
        }
    }

    private func goDormant(error: Error) {
        state.withLock { s in
            s.didFail = true
            s.isForwarding = false
            s.sampleBuffer.removeAll()
        }
        fputs("[meeting-partials] \(label) EOU session dormant after error: \(error)\n", stderr)
        onPartialUpdate?("")
    }
}

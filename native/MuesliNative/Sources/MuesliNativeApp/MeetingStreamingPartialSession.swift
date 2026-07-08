import Foundation
import os

/// Engine-agnostic surface MeetingSession drives for display-only streaming
/// partials. Implementations: `MeetingStreamingPartialSession` (Nemotron
/// RNN-T) and `ParakeetSlidingWindowPartialSession` (FluidAudio sliding
/// window). All methods must be cheap and thread-safe; inference happens on
/// implementation-owned background tasks.
protocol MeetingPartialStreaming: AnyObject {
    /// Called with the current provisional tail text on a background thread.
    /// An empty string clears the tail.
    var onPartialUpdate: ((String) -> Void)? { get set }
    func enqueue(_ samples: [Float])
    /// A VAD chunk rotated — the tail accumulated so far belongs to it.
    func markSegmentBoundary()
    /// The rotated chunk's committed caption landed.
    func commitSegment()
    func suspend()
    func resume()
    func stop()
}

/// Display-only streaming partials for one meeting audio source ("You" or "Others").
///
/// Fed the same 16 kHz float samples the source's VAD consumes (on
/// `MeetingSession.chunkRotationQueue`), it slices them into the transcriber's
/// native chunk size and decodes incrementally with a private `RNNTStreamState`,
/// publishing a provisional "tail" for the in-flight VAD segment. The durable
/// pipeline (chunk files → batch transcription → checkpoints) is untouched:
/// when a VAD chunk rotates, the tail accumulated so far is frozen, and when
/// that chunk's committed line lands, the frozen prefix is dropped so the tail
/// keeps only text newer than the committed caption.
///
/// Failure is non-fatal by design — on any transcription error the session
/// logs once, clears its tail, and goes dormant; the committed path is never
/// affected.
@available(macOS 15, *)
final class MeetingStreamingPartialSession: MeetingPartialStreaming {
    /// Called with the current provisional tail text on a background thread.
    /// An empty string clears the tail.
    var onPartialUpdate: ((String) -> Void)?

    private let transcriber: NemotronStreamingTranscribing
    private let chunkSamples: Int
    private let label: String

    /// Backpressure bound: if inference falls behind real time (thermal
    /// throttling, ANE contention), keep only the freshest chunks so the tail
    /// snaps back to near-live audio instead of lagging monotonically. The
    /// dropped audio garbles a couple of words of provisional text — the
    /// committed captions are unaffected.
    static let maxQueuedChunks = 3

    private struct State {
        var sampleBuffer: [Float] = []
        var chunkQueue: [[Float]] = []
        var isDraining = false
        var streamState: RNNTStreamState?
        var accumulatedText = ""
        /// Character count frozen at the last VAD segment boundary. Dropped
        /// when that segment's committed line lands. If a second boundary
        /// arrives before the first commit, the freeze point simply moves
        /// forward — the next commit then clears slightly more than one
        /// chunk's text, which is acceptable for a display-only tail.
        var pendingCommitPrefixLength = 0
        var isStopped = false
        var isSuspended = false
        var didFail = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(transcriber: NemotronStreamingTranscribing, chunkSamples: Int, label: String) {
        precondition(chunkSamples > 0, "MeetingStreamingPartialSession chunkSamples must be positive")
        self.transcriber = transcriber
        self.chunkSamples = chunkSamples
        self.label = label
    }

    /// Cheap append; safe to call on the meeting session's serial audio queue.
    /// Slices full chunks off the buffer and kicks the drain task when needed.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldStartDrain: Bool = state.withLock { s in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
            s.sampleBuffer.append(contentsOf: samples)
            while s.sampleBuffer.count >= chunkSamples {
                s.chunkQueue.append(Array(s.sampleBuffer.prefix(chunkSamples)))
                s.sampleBuffer.removeFirst(chunkSamples)
            }
            if s.chunkQueue.count > Self.maxQueuedChunks {
                s.chunkQueue.removeFirst(s.chunkQueue.count - Self.maxQueuedChunks)
            }
            guard !s.chunkQueue.isEmpty, !s.isDraining else { return false }
            s.isDraining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in
                await self?.drain()
            }
        }
    }

    /// Freeze the tail accumulated so far as belonging to the VAD chunk that
    /// just rotated; it stays visible until `commitSegment()` clears it.
    func markSegmentBoundary() {
        state.withLock { s in
            s.pendingCommitPrefixLength = s.accumulatedText.count
        }
    }

    /// The rotated chunk's committed line has landed — drop the frozen prefix
    /// so the tail shows only text newer than the committed caption.
    func commitSegment() {
        let tail: String? = state.withLock { s in
            guard !s.isStopped, !s.didFail else { return nil }
            guard s.pendingCommitPrefixLength > 0 else { return nil }
            let dropCount = min(s.pendingCommitPrefixLength, s.accumulatedText.count)
            s.accumulatedText = String(s.accumulatedText.dropFirst(dropCount))
            s.pendingCommitPrefixLength = 0
            return s.accumulatedText
        }
        if let tail {
            onPartialUpdate?(tail)
        }
    }

    /// Pause: clear the tail and drop buffered audio. The stream state is kept —
    /// a silence gap is harmless for display-only text.
    func suspend() {
        state.withLock { s in
            s.isSuspended = true
            s.sampleBuffer.removeAll()
            s.chunkQueue.removeAll()
            s.accumulatedText = ""
            s.pendingCommitPrefixLength = 0
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
            s.chunkQueue.removeAll()
            s.accumulatedText = ""
            s.pendingCommitPrefixLength = 0
        }
    }

    private func drain() async {
        while true {
            let chunk: [Float]? = state.withLock { s in
                guard !s.isStopped, !s.isSuspended, !s.didFail, !s.chunkQueue.isEmpty else {
                    s.isDraining = false
                    return nil
                }
                return s.chunkQueue.removeFirst()
            }
            guard let chunk else { return }

            var streamState: RNNTStreamState
            if let existing = state.withLock({ $0.streamState }) {
                streamState = existing
            } else {
                do {
                    streamState = try await transcriber.makeStreamState()
                } catch {
                    goDormant(error: error)
                    return
                }
            }

            do {
                let newText = try await transcriber.transcribeChunk(samples: chunk, state: &streamState)
                let updatedState = streamState
                let tail: String? = state.withLock { s in
                    guard !s.isStopped, !s.didFail else { return nil }
                    s.streamState = updatedState
                    guard !newText.isEmpty, !s.isSuspended else { return nil }
                    // The frozen prefix stays in the published tail until its
                    // committed caption lands (no flicker-to-empty at rotation).
                    s.accumulatedText += newText
                    return s.accumulatedText
                }
                if let tail {
                    onPartialUpdate?(tail)
                }
            } catch {
                goDormant(error: error)
                return
            }
        }
    }

    private func goDormant(error: Error) {
        state.withLock { s in
            s.didFail = true
            s.isDraining = false
            s.sampleBuffer.removeAll()
            s.chunkQueue.removeAll()
            s.accumulatedText = ""
            s.pendingCommitPrefixLength = 0
            s.streamState = nil
        }
        fputs("[meeting-partials] \(label) session dormant after error: \(error)\n", stderr)
        onPartialUpdate?("")
    }
}

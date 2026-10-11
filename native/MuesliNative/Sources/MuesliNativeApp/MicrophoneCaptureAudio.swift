import AVFoundation
import Foundation

/// A 16 kHz mono block. Timing and admission belong to the captured input, not
/// the currently selected recorder or the wall-clock time of delayed delivery.
struct MicrophoneCaptureAudio: Sendable {
    var samples: [Int16]
    var startFrame: Int64
    var admitted: Bool
    var endFrame: Int64 { startFrame + Int64(samples.count) }

    static func frame(atHostTime time: UInt64) -> Int64 {
        Int64((AVAudioTime.seconds(forHostTime: time) * 16_000).rounded())
    }

    func trimming(before lower: Int64, after upper: Int64 = .max) -> Self? {
        let start = max(startFrame, lower)
        let end = min(endFrame, upper)
        guard end > start else { return nil }
        return Self(samples: Array(samples[Int(start - startFrame)..<Int(end - startFrame)]),
                    startFrame: start, admitted: admitted)
    }
}

/// Meeting consumers use this path; dictation keeps its existing Float callback.
protocol MicrophoneCaptureReporting: BufferedMicrophoneAdmissionControlling {
    var onCapturedAudio: ((MicrophoneCaptureAudio) -> Void)? { get set }
    /// Installed before start. During meeting shutdown only, identifies the
    /// captured interval a late native buffer may still deliver. Nil rejects it.
    var nativeStopDrainRange: (() -> Range<Int64>?)? { get set }
}

extension MicrophoneCaptureReporting {
    // Only backends with an explicit native final-buffer drain need this path.
    var nativeStopDrainRange: (() -> Range<Int64>?)? {
        get { nil }
        set {}
    }
}

/// Worker-owned mapping from a converter's continuous output to accepted input
/// spans. In particular, filter output held across Pause retains its OLD time.
final class MicrophoneCaptureTimeline {
    private struct Span { var start: Int64; var count: Int }
    private var spans: [Span] = []
    private var inputFrames: Double = 0
    private var assignedFrames = 0
    private var previousEnd: Int64?

    func append(frames: Int, rate: Double, start: Int64) {
        inputFrames += Double(frames)
        let total = Int(ceil(inputFrames * 16_000 / rate))
        let count = total - assignedFrames
        assignedFrames = total
        if count > 0 {
            // Host ticks and resampling round independently. Join adjacent
            // spans within one output frame, but preserve actual pause gaps.
            let aligned = previousEnd.flatMap { abs(start - $0) <= 1 ? $0 : nil } ?? start
            previousEnd = aligned + Int64(count)
            if let last = spans.indices.last, spans[last].start + Int64(spans[last].count) == aligned {
                spans[last].count += count
            } else {
                spans.append(Span(start: aligned, count: count))
            }
        }
    }

    func take(_ samples: [Int16], deliver: (MicrophoneCaptureAudio) -> Void) {
        var offset = 0
        while offset < samples.count, !spans.isEmpty {
            let count = min(spans[0].count, samples.count - offset)
            deliver(MicrophoneCaptureAudio(samples: Array(samples[offset..<offset + count]),
                startFrame: spans[0].start, admitted: true))
            spans[0].start += Int64(count)
            spans[0].count -= count
            if spans[0].count == 0 { spans.removeFirst() }
            offset += count
        }
    }
}

/// One serial delivery boundary, independent of native lifecycle queues. During
/// handoff, keep old audio below a fixed cut and stage new audio above it. Flush
/// the new side only AFTER the retired producer's synchronous drain completes.
/// Calls carrying audio come from processing workers, never native callbacks.
final class MeetingMicrophoneDelivery {
    private let queue = DispatchQueue(label: "com.muesli.meeting-mic-delivery")
    private let control = NSLock()
    private var epoch: UInt64 = 0
    private var active: UUID?
    private var retiring: UUID?
    private var cut: Int64 = 0
    private var lastEnd: Int64 = .min
    private var staged: [MicrophoneCaptureAudio] = []
    private var stagedCount = 0
    private var failed = false
    private let maximumStagedSamples: Int
    var deliver: ((MicrophoneCaptureAudio) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(maximumStagedSamples: Int = 5 * 16_000) { self.maximumStagedSamples = maximumStagedSamples }

    // Queue lifecycle events asynchronously: no lifecycle/UI worker waits for a
    // consumer. The caller enqueues activation BEFORE publishing its new child.
    func activate(_ id: UUID) {
        let generation = control.withLock { epoch }
        queue.async { [self] in
            guard isCurrent(generation) else { return }
            active = id; retiring = nil; lastEnd = .min
            staged.removeAll(); stagedCount = 0; failed = false
        }
    }

    func beginHandoff(from old: UUID?, to new: UUID, audio: [MicrophoneCaptureAudio]) {
        guard let first = audio.first else { return }
        let generation = control.withLock { epoch }
        queue.async { [self] in
            guard isCurrent(generation) else { return }
            failed = false
            staged.removeAll(); stagedCount = 0
            retiring = old; active = new
            cut = max(lastEnd, first.startFrame)
            for block in audio { stage(block, generation: generation) }
            if old == nil { flush(generation: generation) }
        }
    }

    func receive(_ audio: MicrophoneCaptureAudio, from id: UUID) {
        let generation = control.withLock { epoch }
        queue.sync {
            guard isCurrent(generation), !failed else { return }
            if id == retiring {
                if let kept = audio.trimming(before: lastEnd, after: cut) { emit(kept, generation: generation) }
            } else if id == active {
                if retiring != nil { stage(audio, generation: generation) }
                else if let kept = audio.trimming(before: lastEnd) { emit(kept, generation: generation) }
            }
        }
    }

    // Cleanup worker only, after old.stop returned. Every old callback has now
    // crossed receive's barrier. This join is included in native quiescence.
    func finishRetiring(_ id: UUID) {
        let generation = control.withLock { epoch }
        queue.sync {
            guard isCurrent(generation), retiring == id else { return }
            retiring = nil
            flush(generation: generation)
        }
    }

    func cancel() {
        control.withLock { epoch &+= 1 }
        queue.async { [self] in
            active = nil; retiring = nil; staged.removeAll(); stagedCount = 0
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool { control.withLock { epoch == generation } }

    private func stage(_ audio: MicrophoneCaptureAudio, generation: UInt64) {
        guard !failed, isCurrent(generation) else { return }
        guard let kept = audio.trimming(before: max(cut, staged.last?.endFrame ?? cut)) else { return }
        guard kept.samples.count <= maximumStagedSamples - stagedCount else {
            failed = true
            staged.removeAll(); stagedCount = 0
            onFailure?(NSError(domain: "MeetingMicrophoneDelivery", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Microphone handoff could not drain within its audio buffer budget."
            ]))
            return
        }
        staged.append(kept); stagedCount += kept.samples.count
    }

    private func flush(generation: UInt64) {
        let pending = staged
        staged.removeAll(); stagedCount = 0
        for audio in pending where !failed {
            if let kept = audio.trimming(before: lastEnd) { emit(kept, generation: generation) }
        }
    }

    private func emit(_ audio: MicrophoneCaptureAudio, generation: UInt64) {
        guard isCurrent(generation) else { return }
        lastEnd = audio.endFrame
        deliver?(audio)
    }
}

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

}

/// Meeting consumers use this path; dictation keeps its existing Float callback.
protocol MicrophoneCaptureReporting: BufferedMicrophoneAdmissionControlling {
    var onCapturedAudio: ((MicrophoneCaptureAudio) -> Void)? { get set }
    /// Installed before start. Allowed capture-time interval for native-held
    /// buffers arriving during child retirement or meeting stop. Nil closes
    /// late native admission; the route owner separately enforces source
    /// identity and its cutover.
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

    func reset() {
        spans.removeAll(); inputFrames = 0; assignedFrames = 0; previousEnd = nil
    }

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

/// Serializes source selection with delivery, independently of native teardown.
/// Like main's route switch, a ready replacement owns delivery immediately;
/// old callbacks arriving after that boundary are rejected, not spliced in.
/// FIFO ownership—not timestamps—establishes uniqueness. This deliberately
/// makes no gap-free/overlap-free guarantee across different microphones.
/// Calls carrying audio come from processing workers, never native callbacks.
final class MeetingMicrophoneDelivery {
    private let queue = DispatchQueue(label: "com.muesli.meeting-mic-delivery")
    private let control = NSLock()
    private var epoch: UInt64 = 0
    private var active: UUID?
    // The consumer must enqueue downstream work, never re-enter this boundary
    // or synchronously wait for a producer currently calling receive().
    var deliver: ((MicrophoneCaptureAudio) -> Void)?

    // Queue lifecycle events asynchronously: no lifecycle/UI worker waits for a
    // consumer. The caller enqueues activation BEFORE publishing its new child.
    func activate(_ id: UUID, audio: [MicrophoneCaptureAudio] = []) {
        let generation = control.withLock { epoch }
        queue.async { [self] in
            guard isCurrent(generation) else { return }
            active = id
            for block in audio where !block.samples.isEmpty {
                guard isCurrent(generation) else { return }
                deliver?(block)
            }
        }
    }

    func receive(_ audio: MicrophoneCaptureAudio, from id: UUID) {
        guard !audio.samples.isEmpty else { return }
        let generation = control.withLock { epoch }
        queue.sync {
            guard isCurrent(generation), id == active else { return }
            deliver?(audio)
        }
    }

    // Background pause/stop worker only. Includes the asynchronously submitted
    // first replacement buffers, even if its producer has no further callbacks.
    func drain() { queue.sync {} }

    func cancel() {
        control.withLock { epoch &+= 1 }
        queue.async { [self] in
            active = nil
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool { control.withLock { epoch == generation } }
}

import AVFoundation
import Foundation
import os

/// Owns copies of tap buffers until a serial worker has consumed them. The tap
/// only copies into a preallocated slot and schedules work; conversion, file I/O
/// and arbitrary consumers never run while holding the admission lock.
///
/// One instance belongs to one installed tap. Closing it permanently rejects
/// late callbacks, including callbacks from a graph replaced after a route change.
/// Slots have exclusive ownership: admission removes one under the lock, the
/// worker consumes it, then returns it under the lock. The consumer is worker-only.
final class BufferedMicrophoneCapture: @unchecked Sendable {
    enum Admission { case accepted, ignored, overflow, invalidBuffer }

    private struct State {
        var available: [Int]
        var accepting = true
        var paused = false
    }

    private let buffers: [AVAudioPCMBuffer]
    private let state: OSAllocatedUnfairLock<State>
    private let queue: DispatchQueue
    private let consume: (AVAudioPCMBuffer, Int64) -> Void
    private let shouldAdmitSamples: () -> Bool
    private let nativeStopDrainRange: (() -> Range<Int64>?)?

    init(
        format: AVAudioFormat,
        queue: DispatchQueue,
        capacity: Int = 16,
        maximumFrames: AVAudioFrameCount = 16_384,
        shouldAdmitSamples: @escaping () -> Bool = { true },
        nativeStopDrainRange: (() -> Range<Int64>?)? = nil,
        consume: @escaping (AVAudioPCMBuffer, Int64) -> Void
    ) throws {
        // Bound storage even for pathological device formats. The normal stereo
        // Float32 pool is 2 MiB; all slots are allocated before engine.start().
        let bytesPerSlot = Double(format.streamDescription.pointee.mBytesPerFrame)
            * Double(format.isInterleaved ? 1 : format.channelCount)
            * Double(maximumFrames)
        guard capacity > 0, maximumFrames > 0, bytesPerSlot > 0, bytesPerSlot <= 4 * 1_024 * 1_024 else {
            throw Self.error("Microphone capture format exceeds the buffer budget")
        }
        // High-channel-count interfaces get fewer slots rather than losing
        // support solely because their normal format needs more bytes per frame.
        let slotCount = min(capacity, Int(8 * 1_024 * 1_024 / bytesPerSlot))
        if slotCount < capacity {
            fputs("[mic-capture] buffer budget reduced slots from \(capacity) to \(slotCount) (channels=\(format.channelCount), maxFrames=\(maximumFrames))\n", stderr)
        }
        var slots: [AVAudioPCMBuffer] = []
        for _ in 0..<slotCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
                throw Self.error("Could not allocate microphone capture buffers")
            }
            slots.append(buffer)
        }
        buffers = slots
        state = OSAllocatedUnfairLock(initialState: State(available: Array(slots.indices)))
        self.queue = queue
        self.consume = consume
        self.shouldAdmitSamples = shouldAdmitSamples
        self.nativeStopDrainRange = nativeStopDrainRange
    }

    @discardableResult
    func offer(_ input: AVAudioPCMBuffer, startFrame: Int64? = nil) -> Admission {
        // Some drivers omit host time. Estimate once at capture, never on the
        // delayed worker; hardware timestamps are preferred by both backends.
        var capturedStart = startFrame ?? (MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time())
            - Int64((Double(input.frameLength) * 16_000 / input.format.sampleRate).rounded()))
        return state.withLock { state in
            guard state.accepting, input.frameLength > 0 else { return .ignored }
            var offset = 0, count = Int(input.frameLength)
            if state.paused || !shouldAdmitSamples() {
                // Only timestamped native-held input can cross closed admission.
                // Clip in the hardware format before queuing conversion or file I/O.
                guard let startFrame, let range = nativeStopDrainRange?() else { return .ignored }
                let rate = input.format.sampleRate / 16_000
                let lower = max(0, ceil(Double(range.lowerBound - startFrame) * rate))
                let upper = min(Double(count), floor(Double(range.upperBound - startFrame) * rate))
                guard lower < upper else { return .ignored }
                offset = Int(lower); count = Int(upper - lower)
                capturedStart = startFrame + Int64((Double(offset) / rate).rounded())
            }
            guard let index = state.available.popLast() else {
                // Do not silently drop a middle chunk and compress the recording
                // timeline. Fail this capture episode once and let its existing
                // owner surface/recover the failure; never block the audio thread.
                state.accepting = false
                return .overflow
            }
            let copy = buffers[index]
            guard input.format == copy.format, input.frameLength <= copy.frameCapacity else {
                state.available.append(index)
                state.accepting = false
                return .invalidBuffer
            }
            copy.frameLength = AVAudioFrameCount(count)
            let byteOffset = offset * Int(input.format.streamDescription.pointee.mBytesPerFrame)
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard source.count == target.count else {
                state.available.append(index)
                state.accepting = false
                return .invalidBuffer
            }
            for i in source.indices {
                guard let from = source[i].mData, let to = target[i].mData,
                      Int(source[i].mDataByteSize) >= byteOffset + Int(target[i].mDataByteSize) else {
                    state.available.append(index)
                    state.accepting = false
                    return .invalidBuffer
                }
                memcpy(to, from.advanced(by: byteOffset), Int(target[i].mDataByteSize))
            }
            // Submission and closing are ordered by this short lock. The worker
            // cannot hold the lock while stalled in a consumer or a disk write.
            let admittedStart = capturedStart
            queue.async { [self] in
                consume(buffers[index], admittedStart)
                self.state.withLock { $0.available.append(index) }
            }
            return .accepted
        }
    }

    func setPaused(_ paused: Bool) {
        state.withLock { $0.paused = paused }
    }

    /// Close admission before stopping the native graph. Draining is separate:
    /// native teardown must never wait on a lock held by an audio consumer.
    func close() {
        state.withLock { $0.accepting = false }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "StreamingMicRecorder", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

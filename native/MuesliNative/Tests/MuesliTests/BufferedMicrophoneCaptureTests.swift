import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("BufferedMicrophoneCapture")
struct BufferedMicrophoneCaptureTests {
    @Test("copies callback-owned planar and interleaved memory before returning", arguments: [false, true])
    func ownsBuffer(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        input.frameLength = 32
        let queue = DispatchQueue(label: "buffer-copy-test")
        var observed: [[Float]] = []
        let capture = try BufferedMicrophoneCapture(format: format, queue: queue) { buffer in
            for part in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                let floats = part.mData!.assumingMemoryBound(to: Float.self)
                observed.append(Array(UnsafeBufferPointer(start: floats, count: Int(part.mDataByteSize) / 4)))
            }
        }
        for part in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
            part.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.25, count: Int(part.mDataByteSize) / 4)
        }
        queue.suspend()
        let admission = capture.offer(input)
        for part in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
            part.mData!.assumingMemoryBound(to: Float.self).update(repeating: -0.75, count: Int(part.mDataByteSize) / 4)
        }
        capture.close()
        queue.resume()
        queue.sync {}
        #expect(admission == .accepted)
        #expect(observed.flatMap { $0 } == Array(repeating: Float(0.25), count: 64))
        #expect(capture.offer(input) == .ignored)
    }

    @Test("slow consumer cannot block admission, closing or pause; overload is bounded and terminal")
    func boundedBacklog() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        input.frameLength = 4
        input.floatChannelData![0].update(repeating: 0.5, count: 4)
        let queue = DispatchQueue(label: "blocked-consumer-test")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var deliveries = 0
        let capture = try BufferedMicrophoneCapture(format: format, queue: queue, capacity: 2) { _ in
            deliveries += 1
            if deliveries == 1 {
                entered.signal()
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
        }
        #expect(capture.offer(input) == .accepted)
        #expect(entered.wait(timeout: .now() + 5) == .success)
        capture.setPaused(true)
        #expect(capture.offer(input) == .ignored)
        capture.setPaused(false)
        #expect(capture.offer(input) == .accepted)
        #expect(capture.offer(input) == .overflow)
        #expect(capture.offer(input) == .ignored)
        capture.close()
        release.signal()
        queue.sync {}
        #expect(deliveries == 2)
        #expect(capture.offer(input) == .ignored)
    }

    @Test("unexpected callback sizes/formats fail once without using truncated buffers")
    func invalidFormat() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let queue = DispatchQueue(label: "bad-buffer-test")
        let capture = try BufferedMicrophoneCapture(format: format, queue: queue, maximumFrames: 8) { _ in
            Issue.record("An oversized buffer reached the consumer")
        }
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        input.frameLength = 16
        #expect(capture.offer(input) == .invalidBuffer)
        #expect(capture.offer(input) == .ignored)
    }
}

@Suite("StreamingMicRecorder buffered capture")
struct StreamingMicRecorderBufferTests {
    @Test("slow downstream work stays off tap; Stop flushes accepted buffers in order and fixes WAV header")
    func slowConsumerAndStop() throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var delivered: [Float] = []
        recorder.onAudioBuffer = { samples in
            if delivered.isEmpty {
                entered.signal()
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
            delivered.append(contentsOf: samples)
        }
        let tap = try recorder.testing_startWithTap(format: format)
        tap(try buffer(format, values: [0.25, -0.25]), AVAudioTime(sampleTime: 0, atRate: 16_000))
        #expect(entered.wait(timeout: .now() + 5) == .success)
        // This returns even though the consumer is blocked. Mutating the source
        // afterward must not affect the owned copy waiting behind it.
        let second = try buffer(format, values: [0.5, -0.5])
        tap(second, AVAudioTime(sampleTime: 2, atRate: 16_000))
        second.floatChannelData![0].update(repeating: 0, count: 2)
        #expect(recorder.currentPower() > -160)
        release.signal()
        let url = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        #expect(delivered == [0.25, -0.25, 0.5, -0.5])
        #expect(samples(data) == [8191, -8191, 16383, -16383])
        #expect(data.count == 44 + 8)
        #expect(data[40] == 8)
        tap(second, AVAudioTime(sampleTime: 4, atRate: 16_000))
        #expect(recorder.stop() == nil)
    }

    @Test("pause skips only paused input; rotation and reuse cannot receive an old tap's samples")
    func pauseRotateAndReuse() throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try buffer(format, values: [0.5])
        let time = AVAudioTime(sampleTime: 0, atRate: 16_000)
        let oldTap = try recorder.testing_startWithTap(format: format)
        oldTap(input, time)
        recorder.pause()
        oldTap(input, time)
        let first = try #require(recorder.rotateFile())
        #expect(recorder.currentPower() == -160)
        recorder.resume()
        oldTap(input, time)
        let second = try #require(recorder.stop())
        let newTap = try recorder.testing_startWithTap(format: format)
        oldTap(input, time)
        newTap(input, time)
        let third = try #require(recorder.stop())
        for url in [first, second, third] {
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(samples(try Data(contentsOf: url)) == [16383])
        }
    }

    @Test("hardware-rate stereo conversion and callback delivery run on the worker")
    func conversion() throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        for channel in 0..<2 { input.floatChannelData![channel].update(repeating: 0.25, count: 4_800) }
        let callerQueue = DispatchQueue(label: "simulated-tap")
        let key = DispatchSpecificKey<Bool>()
        callerQueue.setSpecific(key: key, value: true)
        var sampleCount = 0
        recorder.onAudioBuffer = {
            #expect(DispatchQueue.getSpecific(key: key) == nil)
            sampleCount += $0.count
        }
        let tap = try recorder.testing_startWithTap(format: format)
        callerQueue.sync {
            tap(input, AVAudioTime(sampleTime: 0, atRate: 48_000))
            tap(input, AVAudioTime(sampleTime: 4_800, atRate: 48_000))
        }
        let url = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        // AVAudioConverter retains its filter's startup frames. Across two
        // buffers output approaches the 3:1 ratio without resetting per callback.
        #expect(sampleCount > 2_800, "Converted sample count: \(sampleCount)")
        #expect(sampleCount <= 3_200)
        #expect(samples(try Data(contentsOf: url)).count == sampleCount)
    }

    @Test("overflow reports once and preserves every accepted buffer")
    func overflowFailure() throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let failure = DispatchSemaphore(value: 0)
        var calls = 0
        recorder.onAudioBuffer = { _ in
            calls += 1
            if calls == 1 {
                entered.signal()
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
        }
        recorder.onRecordingFailed = { error in
            #expect((error as NSError).code == 10)
            failure.signal()
        }
        let tap = try recorder.testing_startWithTap(format: format)
        let input = try buffer(format, values: [0.5])
        let time = AVAudioTime(sampleTime: 0, atRate: 16_000)
        tap(input, time)
        #expect(entered.wait(timeout: .now() + 5) == .success)
        for _ in 0..<32 { tap(input, time) }
        #expect(failure.wait(timeout: .now() + 5) == .success)
        #expect(failure.wait(timeout: .now()) == .timedOut)
        release.signal()
        let url = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(samples(try Data(contentsOf: url)).count == 16)
        #expect(calls == 16)
        #expect(failure.wait(timeout: .now()) == .timedOut)
    }

    @Test("invalidation rejects new input but Stop retains the accepted tail; cancel deletes the next file")
    func invalidateAndCancel() throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try buffer(format, values: [0.5])
        let time = AVAudioTime(sampleTime: 0, atRate: 16_000)
        let tap = try recorder.testing_startWithTap(format: format)
        tap(input, time)
        recorder.invalidateForTeardown()
        tap(input, time)
        let url = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(samples(try Data(contentsOf: url)) == [16383])

        let cancelled = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let cancelledTap = try cancelled.testing_startWithTap(format: format)
        cancelledTap(input, time)
        cancelled.cancel()
        cancelledTap(input, time)
        #expect(cancelled.stop() == nil)
    }

    private func buffer(_ format: AVAudioFormat, values: [Float]) throws -> AVAudioPCMBuffer {
        let result = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        result.frameLength = AVAudioFrameCount(values.count)
        for (i, value) in values.enumerated() { result.floatChannelData![0][i] = value }
        return result
    }

    private func samples(_ data: Data) -> [Int16] {
        data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

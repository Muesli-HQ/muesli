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
        let capture = try BufferedMicrophoneCapture(format: format, queue: queue) { buffer, _ in
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
        let capture = try BufferedMicrophoneCapture(format: format, queue: queue, capacity: 2) { _, _ in
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
        let capture = try BufferedMicrophoneCapture(format: format, queue: queue, maximumFrames: 8) { _, _ in
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
    @Test("failed native start invalidates queued PCM before draining", arguments: [16_000.0, 48_000.0])
    func failedStartDiscardsQueuedBuffers(sampleRate: Double) throws {
        let directory = "streaming-mic-failed-start-\(UUID().uuidString)"
        let recorder = StreamingMicRecorder(directoryName: directory)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let input = try buffer(format, values: Array(repeating: 0.25, count: 4096))
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let offered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        recorder.testing_enqueueProcessing {
            blocked.signal()
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        defer { release.signal() }
        #expect(blocked.wait(timeout: .now() + 5) == .success)
        recorder.onPCMSamples = { _ in Issue.record("Failed startup delivered PCM") }
        recorder.onCapturedAudio = { _ in Issue.record("Failed startup delivered meeting audio") }
        recorder.onAudioBuffer = { _ in Issue.record("Failed startup delivered VAD audio") }
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try recorder.testing_startWithTap(format: format) { tap in
                    tap(input, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1)))
                    // Model native buffer recycling before the queued worker runs.
                    input.floatChannelData?[0].update(repeating: -0.5, count: 4096)
                    offered.signal()
                    throw NSError(domain: "test.failed-start", code: 1)
                }
                Issue.record("Expected startup to throw")
            } catch {
                #expect((error as NSError).domain == "test.failed-start")
            }
        }
        #expect(offered.wait(timeout: .now() + 5) == .success)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while recorder.testing_hasActiveRecording && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        // The worker is still blocked: cleanup must invalidate BEFORE its fence.
        #expect(!recorder.testing_hasActiveRecording)
        release.signal()
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(recorder.stop() == nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("pause drain flushes fractional converter tail and reopens a clean stream", arguments: [44_100.0, 48_000.0])
    func pauseDrainConversion(sampleRate: Double) throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let input = try buffer(format, values: Array(repeating: 0.25, count: 4096))
        var audio: [MicrophoneCaptureAudio] = []
        recorder.onCapturedAudio = { audio.append($0) }
        let tap = try recorder.testing_startWithTap(format: format)
        for cycle in 0..<3 {
            let before = audio.count
            let host = AVAudioTime.hostTime(forSeconds: Double(cycle + 1))
            tap(input, AVAudioTime(hostTime: host))
            recorder.pause()
            recorder.drainAcceptedAudio()
            let interval = Array(audio.dropFirst(before))
            #expect(abs(interval.flatMap(\.samples).count - Int((4096 * 16_000 / sampleRate).rounded())) <= 1)
            #expect(interval.first?.startFrame == Int64(cycle + 1) * 16_000)
            let drained = audio.count
            recorder.drainAcceptedAudio() // An empty second fence must not duplicate converter output.
            #expect(audio.count == drained)
            tap(input, AVAudioTime(hostTime: host)) // Paused input stays rejected.
            recorder.resume()
        }
        let url = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(samples(try Data(contentsOf: url)) == audio.flatMap(\.samples))
    }

    @Test("fractional hardware-rate batches retain their complete duration at stop", arguments: [48_000.0, 44_100.0], [1, 4096])
    func fractionalConversionTail(sampleRate: Double, frames: Int) throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let input = try buffer(format, values: Array(repeating: 0.25, count: frames))
        var floats: [Float] = []
        var pcm: [Int16] = []
        recorder.onAudioBuffer = { floats.append(contentsOf: $0) }
        recorder.onPCMSamples = { pcm.append(contentsOf: $0) }
        recorder.onRecordingFailed = { Issue.record("Conversion failed: \($0)") }
        let tap = try recorder.testing_startWithTap(format: format)
        for index in 0..<12 {
            tap(input, AVAudioTime(sampleTime: Int64(index * frames), atRate: sampleRate))
        }
        let url = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = Int((Double(12 * frames) * 16_000 / sampleRate).rounded())
        #expect(abs(floats.count - expected) <= 1, "Expected ~\(expected), got \(floats.count)")
        #expect(pcm.count == floats.count)
        #expect(samples(try Data(contentsOf: url)) == pcm)
        let countAfterStop = floats.count
        tap(input, AVAudioTime(sampleTime: 0, atRate: sampleRate))
        #expect(recorder.stop() == nil)
        #expect(floats.count == countAfterStop)
    }

    @Test("conversion survives pause and rotation; reuse and cancel never flush an old stream", arguments: [48_000.0, 44_100.0])
    func convertedPauseRotateReuse(sampleRate: Double) throws {
        let recorder = StreamingMicRecorder(directoryName: "streaming-mic-buffer-tests")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let input = try buffer(format, values: Array(repeating: 0.25, count: 4096))
        let time = AVAudioTime(sampleTime: 0, atRate: sampleRate)
        var delivered: [Int16] = []
        recorder.onPCMSamples = { delivered.append(contentsOf: $0) }
        let oldTap = try recorder.testing_startWithTap(format: format)
        oldTap(input, time)
        recorder.pause()
        oldTap(input, time) // Must not enter the converter.
        let first = try #require(recorder.rotateFile())
        recorder.resume()
        oldTap(input, time)
        recorder.pause()
        let second = try #require(recorder.stop()) // Pre-pause filter tail still belongs to the recording.
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let saved = samples(try Data(contentsOf: first)) + samples(try Data(contentsOf: second))
        let expected = Int((8192 * 16_000 / sampleRate).rounded())
        #expect(abs(saved.count - expected) <= 1)
        #expect(saved == delivered)
        let beforeReuse = delivered.count
        _ = try recorder.testing_startWithTap(format: format)
        oldTap(input, time)
        #expect(recorder.stop() == nil) // Empty recordings are deliberately discarded.
        #expect(delivered.count == beforeReuse)

        let tap = try recorder.testing_startWithTap(format: format)
        tap(input, time)
        recorder.cancel()
        let afterCancel = delivered.count
        tap(input, time)
        #expect(recorder.stop() == nil)
        #expect(delivered.count == afterCancel)
    }

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

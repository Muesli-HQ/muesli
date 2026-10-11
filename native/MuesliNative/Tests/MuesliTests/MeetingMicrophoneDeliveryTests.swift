import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting microphone delivery invariants", .serialized)
struct MeetingMicrophoneDeliveryTests {
    @Test("handoff delivers chronological, non-overlapping audio to saved WAV and transcription input",
          arguments: [false, true], ["running", "paused", "stopped", "discarded"])
    func captureToSinks(oldUsesQueue: Bool, ending: String) async throws {
        let old = ContractProducer(useQueue: oldUsesQueue)
        let next = ContractProducer(useQueue: !oldUsesQueue)
        let delayed = ContractGate()
        let paused = ContractGate()
        old.beforeFirstDelivery = { delayed.block() }
        next.beforePause = { paused.block() }
        defer { delayed.release.signal(); paused.release.signal() }
        let lifecycle = DispatchQueue(label: "test.contract.lifecycle")
        let worker = DispatchQueue(label: "test.contract.worker")
        let route = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: StreamingMeetingMicRecorderAdapter(recorder: old, kind: .systemDefaultStreaming),
            appScopedRecorder: StreamingMeetingMicRecorderAdapter(recorder: next, kind: .appScopedAudioQueue),
            lifecycleQueue: lifecycle, handoffWorkerQueue: worker,
            handoffTimeoutScheduler: { _, _ in }
        )
        let capture = MeetingCaptureLifecycle(microphone: route, systemAudio: ContractSystemAudio())
        let writer = try MeetingRecordingWriter()
        let chunks = try PCMChunkRecorder(directoryName: "meeting-delivery-contract-tests")
        let sink = DispatchQueue(label: "test.contract.session-sink")
        var delivered: [MicrophoneCaptureAudio] = [] // Sink queue only.
        route.onRawPCMSamples = { audio in
            capture.enqueueMicrophoneSamples(audio, on: sink) {
                delivered.append(audio)
                writer.appendMic(audio.samples)
                chunks.append(audio.samples)
            }
        }
        defer { route.onRawPCMSamples = nil; writer.cancel(); chunks.cancel() }
        try await capture.start()
        try old.emit([1, 2, 3, 4], at: 100)
        try await delayed.waitUntilEntered()
        try old.emit([5, 6], at: 104) // Accepted old tail, delayed by its worker.
        #expect(route.requestHealthRecovery(.init(reason: "contract", requiresNonZeroSamples: false)) == .initiated)
        try await MeetingCaptureLifecycle.onDriverQueue { worker.sync {} }
        let promoted = DispatchSemaphore(value: 0)
        route.onHandoffOutcome = { if $0 == .promoted { promoted.signal() } }
        try next.emit([3, 4, 5, 6], at: 102) // Same capture interval, not more speech.
        let didPromote = try await MeetingCaptureLifecycle.onDriverQueue { promoted.wait(timeout: .now() + 5) }
        #expect(didPromote == .success)
        try next.emit([7, 8], at: 106)
        if ending != "running" {
            #expect(capture.setPaused(true))
            try await paused.waitUntilEntered()
            try next.emit([15, 15], at: 108) // Phase is paused, native pause still blocked.
        }
        if ending == "discarded" { capture.finishMicrophoneDelivery() }
        let shutdown = ending == "stopped" || ending == "discarded" ? capture.requestStop() : nil
        paused.release.signal()
        delayed.release.signal()
        // Drain both real producers, including the retired one, before the same
        // final queue barrier used by MeetingSession closes delivery.
        let result = await (shutdown ?? capture.requestStop()).value
        #expect(!result.timedOut)
        if let url = result.microphone { try? FileManager.default.removeItem(at: url) }
        sink.sync { capture.finishMicrophoneDelivery() }
        try old.emit([15], at: 110)
        try next.emit([15], at: 110)
        let audio = sink.sync { delivered }
        let expected: [Int16] = ending == "discarded" ? [] : (1...8).map { Int16(Float($0) / 16 * 32767) }
        #expect(audio.flatMap(\.samples) == expected)
        for pair in zip(audio, audio.dropFirst()) { #expect(pair.0.endFrame <= pair.1.startFrame) }
        let saved = writer.stop()
        let transcription = chunks.stop()
        for url in [saved, transcription].compactMap({ $0 }) {
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try Data(contentsOf: url)
            let pcm = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            #expect(pcm == expected)
        }
        if !expected.isEmpty { #expect(saved != nil); #expect(transcription != nil) }
    }

    @Test("handoff capacity fails visibly once; cancel never flushes staged audio")
    func boundedAndCancelled() {
        for cancel in [false, true] {
            let delivery = MeetingMicrophoneDelivery(maximumStagedSamples: 4)
            let old = UUID(), next = UUID()
            var output: [Int16] = []
            var failures = 0
            delivery.deliver = { output += $0.samples }
            delivery.onFailure = { _ in failures += 1 }
            delivery.activate(old)
            delivery.beginHandoff(from: old, to: next,
                audio: [.init(samples: [3, 4], startFrame: 2, admitted: true)])
            delivery.receive(.init(samples: [5, 6], startFrame: 4, admitted: true), from: next)
            if cancel { delivery.cancel() }
            else {
                delivery.receive(.init(samples: [7], startFrame: 6, admitted: true), from: next)
                delivery.receive(.init(samples: [8], startFrame: 7, admitted: true), from: next)
            }
            delivery.finishRetiring(old)
            #expect(output.isEmpty)
            #expect(failures == (cancel ? 0 : 1))
            // Failure/cancellation must not poison the next positively-ready
            // producer, and stale old callbacks cannot enter that recording.
            let recovered = UUID()
            if cancel { delivery.activate(recovered) }
            else {
                delivery.beginHandoff(from: next, to: recovered,
                    audio: [.init(samples: [9], startFrame: 8, admitted: true)])
                delivery.finishRetiring(next)
            }
            delivery.receive(.init(samples: [99], startFrame: 9, admitted: true), from: old)
            delivery.receive(.init(samples: [10], startFrame: 9, admitted: true), from: recovered)
            #expect(output == (cancel ? [10] : [9, 10]))
            #expect(failures == (cancel ? 0 : 1))
        }
    }

    @Test("AudioQueue overload is bounded and reports failure without waiting for its consumer")
    func nativeQueueCapacity() async throws {
        let producer = ContractProducer(useQueue: true)
        let delayed = ContractGate()
        producer.beforeFirstDelivery = { delayed.block() }
        let failure = DispatchSemaphore(value: 0)
        producer.onRecordingFailed = { _ in failure.signal() }
        defer { delayed.release.signal(); producer.cancel() }
        try producer.start()
        try producer.emit([1], at: 0)
        try await delayed.waitUntilEntered()
        for frame in 1...70 { try producer.emit([1], at: Int64(frame)) }
        let failed = try await MeetingCaptureLifecycle.onDriverQueue { failure.wait(timeout: .now() + 5) }
        #expect(failed == .success)
        delayed.release.signal()
        let url = try #require(try await MeetingCaptureLifecycle.onDriverQueue { producer.stop() })
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url).count == 44 + 64 * 2)
        let duplicate = try await MeetingCaptureLifecycle.onDriverQueue { failure.wait(timeout: .now()) }
        #expect(duplicate == .timedOut)
    }

    @Test("cutover trims overlap regardless of old delivery position", arguments: [0, 1, 2, 3, 4])
    func cutover(oldDelivered: Int) {
        let delivery = MeetingMicrophoneDelivery()
        let old = UUID(), next = UUID()
        var samples: [Int16] = []
        delivery.deliver = { samples += $0.samples }
        delivery.activate(old)
        let original: [Int16] = [1, 2, 3, 4]
        if oldDelivered > 0 {
            delivery.receive(.init(samples: Array(original.prefix(oldDelivered)), startFrame: 0, admitted: true), from: old)
        }
        delivery.beginHandoff(from: old, to: next,
            audio: [.init(samples: [3, 4, 5], startFrame: 2, admitted: true)])
        delivery.receive(.init(samples: [6], startFrame: 5, admitted: true), from: next)
        delivery.receive(.init(samples: Array(original.dropFirst(oldDelivered)), startFrame: Int64(oldDelivered), admitted: true), from: old)
        delivery.finishRetiring(old)
        delivery.receive(.init(samples: [99], startFrame: 6, admitted: true), from: old)
        #expect(samples == [1, 2, 3, 4, 5, 6])
    }

    @Test("converter timing keeps fractional-rate output and real pause gaps", arguments: [44_100.0, 48_000.0])
    func converterTiming(rate: Double) {
        let timeline = MicrophoneCaptureTimeline()
        var audio: [MicrophoneCaptureAudio] = []
        for index in 0..<30 {
            timeline.append(frames: 101, rate: rate,
                start: Int64((Double(index * 101) * 16_000 / rate).rounded()))
        }
        let count = Int(ceil(3030 * 16_000 / rate))
        timeline.take(Array(repeating: 1, count: count)) { audio.append($0) }
        #expect(audio.flatMap(\.samples).count == count)
        #expect(audio.first?.startFrame == 0)
        #expect(audio.last?.endFrame == Int64(count))
        for pair in zip(audio, audio.dropFirst()) { #expect(pair.0.endFrame == pair.1.startFrame) }
        timeline.append(frames: 101, rate: rate, start: 10_000)
        let remaining = Int(ceil(3131 * 16_000 / rate)) - count
        timeline.take(Array(repeating: 2, count: remaining)) { audio.append($0) }
        #expect(audio.last?.startFrame == 10_000)
        #expect(audio.last?.samples.count == remaining)
    }
}

private final class ContractGate {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func block() { entered.signal(); #expect(release.wait(timeout: .now() + 10) == .success) }
    func waitUntilEntered() async throws {
        let result = try await MeetingCaptureLifecycle.onDriverQueue { self.entered.wait(timeout: .now() + 5) }
        #expect(result == .success)
    }
}

/// Real producer, adapter and lifecycle; only the native device is
/// replaced. Every output block goes through production admission and queues.
private final class ContractProducer: StreamingDictationRecording, PausableStreamingDictationRecording, MicrophoneCaptureReporting {
    private let driver: ContractQueueDriver?
    private let streaming: StreamingMicRecorder?
    private let child: StreamingDictationRecording & MicrophoneCaptureReporting
    private var tap: AVAudioNodeTapBlock?
    private var first = true
    var beforeFirstDelivery: (() -> Void)?
    var beforePause: (() -> Void)?
    var onAudioBuffer: (([Float]) -> Void)?
    var onCapturedAudio: ((MicrophoneCaptureAudio) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var shouldAdmitSamples: (() -> Bool)? {
        get { child.shouldAdmitSamples }
        set { child.shouldAdmitSamples = newValue }
    }
    init(useQueue: Bool) {
        if useQueue {
            let driver = ContractQueueDriver()
            self.driver = driver; streaming = nil
            child = AudioQueueInputRecorder(directoryName: "meeting-delivery-contract-tests", native: driver.operations)
        } else {
            driver = nil
            let stream = StreamingMicRecorder(directoryName: "meeting-delivery-contract-tests")
            streaming = stream; child = stream
        }
    }
    func prepare() throws { if streaming == nil { try child.prepare() } }
    func start() throws {
        child.onCapturedAudio = { [weak self] audio in
            guard let self else { return }
            if first { first = false; beforeFirstDelivery?() }
            onCapturedAudio?(audio)
        }
        child.onRecordingFailed = { [weak self] in self?.onRecordingFailed?($0) }
        if let streaming { tap = try streaming.testing_startWithTap(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!) }
        else { try child.start() }
    }
    func emit(_ values: [Int], at frame: Int64) throws {
        let samples = values.map { Float($0) / 16 }
        let host = AVAudioTime.hostTime(forSeconds: Double(frame) / 16_000)
        if let driver { driver.emit(samples, host: host) }
        else {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = buffer.frameCapacity
            for (i, value) in samples.enumerated() { buffer.floatChannelData![0][i] = value }
            tap?(buffer, AVAudioTime(hostTime: host))
        }
    }
    func pause() { beforePause?(); (child as? PausableStreamingDictationRecording)?.pause() }
    func resume() { (child as? PausableStreamingDictationRecording)?.resume() }
    func stop() -> URL? { child.stop() }
    func cancel() { child.cancel() }
    func invalidateForTeardown() { child.invalidateForTeardown() }
    func currentPower() -> Float { child.currentPower() }
}

private final class ContractQueueDriver {
    private let queue = AudioQueueRef(bitPattern: 1)!
    private var callback: AudioQueueInputCallback?
    private var context: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    var operations: AudioQueueInputRecorder.NativeOperations {
        var result = AudioQueueInputRecorder.NativeOperations()
        result.create = { [self] _, callback, context, out in self.callback = callback; self.context = context; out.pointee = queue; return noErr }
        result.allocate = { [self] _, size, out in
            let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 4)
            let buffer = AudioQueueBufferRef.allocate(capacity: 1)
            buffer.initialize(to: AudioQueueBuffer(mAudioDataBytesCapacity: size, mAudioData: data,
                mAudioDataByteSize: 0, mUserData: nil, mPacketDescriptionCapacity: 0, mPacketDescriptions: nil, mPacketDescriptionCount: 0))
            buffers.append(buffer); out.pointee = buffer; return noErr
        }
        result.enqueue = { _, _ in noErr }; result.start = { _ in noErr }
        result.stop = { _, _ in noErr }; result.dispose = { _ in noErr }; result.isRunning = { _ in false }
        return result
    }
    func emit(_ samples: [Float], host: UInt64) {
        guard let buffer = buffers.first, let callback else { return }
        buffer.pointee.mAudioDataByteSize = UInt32(samples.count * 4)
        for (i, sample) in samples.enumerated() { buffer.pointee.mAudioData.storeBytes(of: sample, toByteOffset: i * 4, as: Float.self) }
        var time = AudioTimeStamp(); time.mHostTime = host; time.mFlags = .hostTimeValid
        callback(context, queue, buffer, &time, 0, nil)
    }
    deinit { for buffer in buffers { buffer.pointee.mAudioData.deallocate(); buffer.deinitialize(count: 1); buffer.deallocate() } }
}

private final class ContractSystemAudio: SystemAudioCapturing {
    var onPCMSamples: (([Int16]) -> Void)?
    var isRecording = false
    var isPaused = false
    var startError: String?
    func start() throws { isRecording = true }
    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func stop() -> URL? { isRecording = false; return nil }
}

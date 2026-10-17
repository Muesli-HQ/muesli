import AVFoundation
import AudioToolbox
import Foundation
import MuesliCore
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting microphone delivery invariants", .serialized)
struct MeetingMicrophoneDeliveryTests {
    @Test("delivery fence includes queued first replacement audio; cancel invalidates it", arguments: [false, true])
    func queuedSelectionFence(cancel: Bool) {
        let delivery = MeetingMicrophoneDelivery(), old = UUID(), next = UUID()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let oldReturned = DispatchSemaphore(value: 0), fenced = DispatchSemaphore(value: 0)
        let output = OSAllocatedUnfairLock(initialState: [Int16]())
        delivery.deliver = { audio in
            output.withLock { $0 += audio.samples }
            if audio.samples == [1] {
                entered.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
        }
        defer { release.signal() }
        delivery.activate(old)
        DispatchQueue.global().async {
            delivery.receive(.init(samples: [1], startFrame: 100, admitted: true), from: old)
            oldReturned.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        delivery.activate(next, audio: [
            .init(samples: [2], startFrame: 98, admitted: true),
            .init(samples: [3], startFrame: 98, admitted: true)
        ])
        if cancel { delivery.cancel() }
        DispatchQueue.global().async { delivery.drain(); fenced.signal() }
        #expect(fenced.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(oldReturned.wait(timeout: .now() + 5) == .success)
        #expect(fenced.wait(timeout: .now() + 5) == .success)
        delivery.receive(.init(samples: [99], startFrame: 200, admitted: true), from: old)
        #expect(output.withLock { $0 } == (cancel ? [1] : [1, 2, 3]))
    }

    @Test("normal session preserves both tracks regardless of microphone timestamp jitter",
          arguments: ["stream", "queue", "fallback"], ["exact", "jitter", "missing", "mixed"])
    func normalSessionKeepsEverySample(backend: String, timing: String) async throws {
        let producer = ContractProducer(useQueue: backend != "stream", wrapped: backend == "fallback")
        let route = RouteAwareMeetingMicRecorder(systemDefaultRecorder:
            StreamingMeetingMicRecorderAdapter(recorder: producer, kind: .systemDefaultStreaming))
        let system = ContractSystemAudio()
        let session = MeetingSession(title: "ordinary recording regression", calendarEventID: nil,
            backend: .parakeetEnglish,
            runtime: RuntimePaths(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                  menuIcon: nil, appIcon: nil, bundlePath: nil),
            config: Self.micDiarizationConfig,
            templateSnapshot: .init(id: "test", name: "test", kind: .custom, prompt: ""),
            transcriptionCoordinator: TranscriptionCoordinator(), meetingMicRecorder: route,
            systemAudioCapture: system, aec: MeetingNeuralAec(preloadedProcessor: ContractAecProcessor()))
        try await session.testingStartCapture()
        var expectedMic: [Int16] = [], expectedSystem: [Int16] = []
        let captureStart = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()) - 4096
        for index in 0..<8 {
            // Real 512-frame native buffers, unique contents, delivered in order.
            // Only timestamp availability/spacing changes, never the captured PCM.
            let value = index + 1
            let reference = [Int16](repeating: Int16(100 + index), count: 512)
            system.onPCMSamples?(reference)
            let timed = timing != "missing" && !(timing == "mixed" && index % 2 == 0)
            let start = captureStart + Int64(index * (timing == "jitter" ? 432 : 512))
            try producer.emit(Array(repeating: value, count: 512), at: start, timed: timed)
            expectedMic += Array(repeating: Int16(Float(value) / 16 * 32767), count: 512)
            expectedSystem += reference
        }
        let urls = await session.testingFinishCapture()
        defer { for url in [urls.0, urls.1, urls.2, urls.3].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) } }
        func pcm(_ url: URL?) throws -> [Int16] {
            let url = try #require(url)
            return try Data(contentsOf: url).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        #expect(try pcm(urls.0) == expectedMic) // The actual microphone transcription chunk.
        #expect(try pcm(urls.1) == expectedSystem) // The actual system transcription chunk.
        let mixed = zip(expectedMic, expectedSystem).map { Int16((Int($0) + Int($1)) / 2) }
        #expect(try pcm(urls.2) == mixed) // Neither side lost from the retained recording.
        #expect(try pcm(urls.3) == expectedMic) // Mic diarization shares the cleaned mic timeline.
    }

    @Test("steady microphone delivery never deduplicates consecutive PCM using timestamps",
          arguments: [0, -80, -4096, 800])
    func sameSourceJitter(offset: Int) {
        let delivery = MeetingMicrophoneDelivery(), source = UUID()
        var output: [Int16] = []
        delivery.deliver = { output += $0.samples }
        delivery.activate(source)
        let first = [Int16](repeating: 1, count: 4096)
        let second = [Int16](repeating: 2, count: 4096)
        delivery.receive(.init(samples: first, startFrame: 10_000, admitted: true), from: source)
        delivery.receive(.init(samples: second, startFrame: Int64(14_096 + offset), admitted: true), from: source)
        #expect(output == first + second)
        delivery.cancel()
        delivery.receive(.init(samples: [99], startFrame: 100_000, admitted: true), from: source)
        #expect(output == first + second)
    }

    @Test("source selection forwards replacement FIFO immediately and rejects old tails")
    func handoffDoesNotDeduplicateSameSource() {
        let delivery = MeetingMicrophoneDelivery(), old = UUID(), next = UUID()
        var output: [Int16] = []
        delivery.deliver = { output += $0.samples }
        delivery.activate(old)
        delivery.receive(.init(samples: [1], startFrame: 98, admitted: true), from: old)
        delivery.activate(next,
            audio: [.init(samples: [4, 5], startFrame: 102, admitted: true)])
        delivery.receive(.init(samples: [2, 3], startFrame: 98, admitted: true), from: old)
        delivery.receive(.init(samples: [6, 7], startFrame: 101, admitted: true), from: next)
        #expect(output == [1, 4, 5, 6, 7]) // No native retirement wait or timestamp trimming.
        delivery.receive(.init(samples: [8], startFrame: 101, admitted: true), from: next)
        delivery.receive(.init(samples: [99], startFrame: 103, admitted: true), from: old)
        #expect(output == [1, 4, 5, 6, 7, 8])
    }

    @Test("source switch is independent of overlapping or backward replacement timestamps")
    func sourceSwitchIgnoresTimestampOverlap() {
        let delivery = MeetingMicrophoneDelivery(), old = UUID(), next = UUID()
        var output: [Int16] = []
        delivery.deliver = { output += $0.samples }
        delivery.activate(old)
        delivery.receive(.init(samples: [1, 2], startFrame: 100, admitted: true), from: old)
        delivery.activate(next,
            audio: [.init(samples: [3], startFrame: 100, admitted: true)])
        delivery.receive(.init(samples: [4], startFrame: 101, admitted: true), from: next)
        delivery.receive(.init(samples: [5, 6], startFrame: 100, admitted: true), from: next)
        delivery.receive(.init(samples: [99], startFrame: 100, admitted: true), from: old)
        #expect(output == [1, 2, 3, 4, 5, 6])

        // A later switch rejects the formerly active source regardless of time.
        let third = UUID()
        delivery.activate(third,
            audio: [.init(samples: [9], startFrame: 106, admitted: true)])
        delivery.receive(.init(samples: [7, 8, 99], startFrame: 104, admitted: true), from: next)
        delivery.receive(.init(samples: [99], startFrame: 104, admitted: true), from: next)
        delivery.drain()
        #expect(output == [1, 2, 3, 4, 5, 6, 9])
    }

    @Test("session pause drains admitted PCM before chunk rotation and AEC reset",
          arguments: ["stream", "queue", "fallback"], ["paused", "resume", "rapid", "stop", "discard"])
    func sessionPauseBoundary(backend: String, ending: String) async throws {
        let producer = ContractProducer(useQueue: backend != "stream", wrapped: backend == "fallback")
        let delayed = ContractGate(), pipeline = ContractGate()
        let draining = DispatchSemaphore(value: 0), resumed = DispatchSemaphore(value: 0)
        producer.beforeFirstDelivery = { delayed.block() }
        producer.beforeDrain = { draining.signal() }
        producer.afterResume = { resumed.signal() }
        let route = RouteAwareMeetingMicRecorder(systemDefaultRecorder:
            StreamingMeetingMicRecorderAdapter(recorder: producer, kind: .systemDefaultStreaming))
        let system = ContractSystemAudio()
        let processor = ContractAecProcessor()
        let session = MeetingSession(title: "pause regression", calendarEventID: nil,
            backend: .parakeetEnglish,
            runtime: RuntimePaths(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                  menuIcon: nil, appIcon: nil, bundlePath: nil),
            config: Self.micDiarizationConfig,
            templateSnapshot: .init(id: "test", name: "test", kind: .custom, prompt: ""),
            transcriptionCoordinator: TranscriptionCoordinator(), meetingMicRecorder: route,
            systemAudioCapture: system, aec: MeetingNeuralAec(preloadedProcessor: processor))
        var micChunks: [[Int16]] = [], systemChunks: [[Int16]] = [] // Pipeline queue only.
        func pcm(_ url: URL?) throws -> [Int16] {
            guard let url else { return [] }
            return try Data(contentsOf: url).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        session.testingConsumeChunk = { source, url, timing in
            do {
                let samples = try pcm(url)
                #expect(timing.sampleCount == samples.count)
                if source == "mic" { micChunks.append(samples) }
                else { systemChunks.append(samples) }
            } catch { Issue.record(error) }
        }
        defer { delayed.release.signal(); pipeline.release.signal() }
        try await session.testingStartCapture()
        let diarizationURL = try #require(session.testingMicDiarizationFileURL)
        try producer.emit([1, 2], at: 100)
        try await delayed.waitUntilEntered()
        try producer.emit([3], at: 102)
        session.testingEnqueuePipeline { pipeline.block() }
        try await pipeline.waitUntilEntered()
        system.onPCMSamples?([0, 0, 0])
        await MainActor.run { session.pause() } // Must return while the consumer is blocked.
        let enteredDrain = try await MeetingCaptureLifecycle.onDriverQueue { draining.wait(timeout: .now() + 5) }
        #expect(enteredDrain == .success)
        pipeline.release.signal() // Reference admitted before Pause must survive delayed consumption.
        session.testingPipelineBarrier {
            #expect(micChunks.isEmpty && systemChunks.isEmpty)
            #expect(processor.events == ["reset"])
        }
        if ending == "resume" || ending == "rapid" {
            await MainActor.run { session.resume() }
            if ending == "rapid" { await MainActor.run { session.pause(); session.resume() } }
        }
        // These callbacks arrive after logical Resume but before the pause fence.
        // Native AudioQueue buffers must recycle, without leaking PCM into either side.
        for _ in 0..<5 { try producer.emit([15], at: 103) }
        if let driver = producer.driver { #expect(driver.queuedBufferCount == 3) }
        system.onPCMSamples?([30_000])
        if ending == "stop" { session.beginStoppingCapture() }
        if ending == "discard" { session.discard() }
        delayed.release.signal()
        if ending == "discard" {
            await session.testingWaitForDiscard()
            session.testingPipelineBarrier {
                #expect(micChunks.isEmpty && systemChunks.isEmpty)
                #expect(processor.events == ["reset"]) // Late pause cannot resurrect a discarded pipeline.
            }
            #expect(!FileManager.default.fileExists(atPath: diarizationURL.path)) // Discard deletes the mic track.
            return
        }
        if ending == "resume" || ending == "rapid" {
            for _ in 0..<(ending == "rapid" ? 2 : 1) {
                let didResume = try await MeetingCaptureLifecycle.onDriverQueue { resumed.wait(timeout: .now() + 5) }
                #expect(didResume == .success)
            }
            try producer.emit([4, 5], at: 200)
        }
        let urls = await session.testingFinishCapture()
        defer { for url in [urls.0, urls.1, urls.2, urls.3].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) } }
        let before: [Int16] = [2047, 4095, 6143]
        let after: [Int16] = ending == "resume" || ending == "rapid" ? [8191, 10239] : []
        session.testingPipelineBarrier {
            #expect(micChunks == [before])
            #expect(systemChunks == [[0, 0, 0]])
            #expect(processor.events.prefix(3) == ["reset", "process", "reset"])
            #expect(processor.events.filter { $0 == "reset" }.count == (ending == "rapid" ? 3 : 2))
        }
        #expect(try pcm(urls.0) == after)
        #expect(try pcm(urls.1).isEmpty)
        #expect(try pcm(urls.2) == before.map { $0 / 2 } + after)
        // One track across chunk rotation, pause/resume and the final flush.
        #expect(urls.3 == diarizationURL)
        #expect(try pcm(urls.3) == before + after)
    }

    private static var micDiarizationConfig: AppConfig {
        var config = AppConfig()
        config.diarizeMicrophoneAudio = true
        return config
    }

    @Test("delayed native resume recycles every active buffer without admitting paused audio",
          arguments: [false, true], ["before", "crossing", "after", "future", "untimed", "empty"])
    func resumeRecyclesBuffers(wrapped: Bool, timing: String) async throws {
        let producer = ContractProducer(useQueue: true, wrapped: wrapped)
        let driver = try #require(producer.driver)
        let resumeGate = ContractGate()
        let resumed = DispatchSemaphore(value: 0)
        producer.beforeResume = { resumeGate.block() }
        producer.afterResume = { resumed.signal() }
        let route = RouteAwareMeetingMicRecorder(systemDefaultRecorder:
            StreamingMeetingMicRecorderAdapter(recorder: producer, kind: .appScopedAudioQueue))
        let clock = OSAllocatedUnfairLock(initialState: Int64(100))
        let capture = MeetingCaptureLifecycle(microphone: route, systemAudio: ContractSystemAudio(),
            microphoneClock: { clock.withLock { $0 } })
        let writer = try MeetingRecordingWriter()
        let chunks = try PCMChunkRecorder(directoryName: "meeting-resume-recycling-tests")
        let sink = DispatchQueue(label: "test.resume-recycling.sink")
        route.onRawPCMSamples = { audio in
            capture.enqueueMicrophoneSamples(audio, on: sink) {
                writer.appendMic(audio.samples); chunks.append(audio.samples)
            }
        }
        defer {
            resumeGate.release.signal(); driver.onStop = nil
            route.onRawPCMSamples = nil; writer.cancel(); chunks.cancel()
        }
        func emit(_ values: [Int], at frame: Int64, timed: Bool = true) -> Bool {
            driver.emit(values.map { Float($0) / 16 },
                host: AVAudioTime.hostTime(forSeconds: Double(frame) / 16_000), timed: timed)
        }
        try await capture.start()
        #expect(driver.queuedBufferCount == 3)
        var expectedValues: [Int] = []
        for cycle in 0..<3 {
            let resumeFrame = Int64(110 + cycle * 40)
            clock.withLock { $0 = resumeFrame - 2 }
            #expect(capture.setPaused(true))
            #expect(emit([15, 15], at: resumeFrame - 2)) // Logical pause wins even before driver pause.
            #expect(driver.queuedBufferCount == 3)
            clock.withLock { $0 = resumeFrame }
            #expect(capture.setPaused(false))
            try await resumeGate.waitUntilEntered() // Actual AudioQueue is still paused.
            for index in 0..<5 { // More callbacks than the entire native pool.
                let frame = resumeFrame + Int64(index * 3)
                clock.withLock { $0 = frame + 2 }
                let emitted: Bool
                switch timing {
                case "before": emitted = emit([15, 15], at: resumeFrame - 2)
                case "crossing":
                    emitted = emit([9, 1, 2], at: frame - 1)
                    expectedValues += index == 0 ? [1, 2] : [9, 1, 2]
                case "after":
                    emitted = emit([1, 2], at: frame)
                    expectedValues += [1, 2]
                case "future": emitted = emit([15, 15], at: frame + 10)
                case "untimed": emitted = emit([15, 15], at: frame, timed: false)
                default: emitted = emit([], at: frame)
                }
                #expect(emitted)
                #expect(driver.queuedBufferCount == 3)
            }
            resumeGate.release.signal()
            let didResume = try await MeetingCaptureLifecycle.onDriverQueue { resumed.wait(timeout: .now() + 5) }
            #expect(didResume == .success)
            clock.withLock { $0 = resumeFrame + 22 }
            #expect(emit([3, 4], at: resumeFrame + 20)) // Capture must actually continue, not just report resumed.
            #expect(driver.queuedBufferCount == 3)
            expectedValues += [3, 4]
        }
        clock.withLock { $0 = 240 }
        driver.onStop = {
            #expect(emit([5, 6, 15, 15], at: 238))
            #expect(driver.queuedBufferCount == 2) // Native stop consumes; it must NOT recycle.
        }
        let result = await capture.requestStop().value
        #expect(!result.timedOut)
        sink.sync { capture.finishMicrophoneDelivery() }
        expectedValues += [5, 6] // Only the prefix before the first Stop boundary.
        #expect(driver.queuedBufferCount == 0)
        #expect(!emit([15], at: 239)) // A disposed pool cannot produce another real callback.
        driver.emitLate([0.9], host: AVAudioTime.hostTime(forSeconds: 239.0 / 16_000))
        let expected = expectedValues.map { Int16(Float($0) / 16 * 32767) }
        for url in [result.microphone, writer.stop(), chunks.stop()] {
            let url = try #require(url)
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try Data(contentsOf: url)
            let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            #expect(samples == expected)
        }
    }

    @Test("Stop or discard during blocked native Resume never revives queue ownership",
          arguments: [false, true], [false, true])
    func stopDuringResume(wrapped: Bool, discard: Bool) async throws {
        let producer = ContractProducer(useQueue: true, wrapped: wrapped)
        let driver = try #require(producer.driver)
        let resumeGate = ContractGate()
        producer.beforeResume = { resumeGate.block() }
        let route = RouteAwareMeetingMicRecorder(systemDefaultRecorder:
            StreamingMeetingMicRecorderAdapter(recorder: producer, kind: .appScopedAudioQueue))
        let clock = OSAllocatedUnfairLock(initialState: Int64(100))
        let capture = MeetingCaptureLifecycle(microphone: route, systemAudio: ContractSystemAudio(),
            microphoneClock: { clock.withLock { $0 } })
        let sink = DispatchQueue(label: "test.stop-during-resume.sink")
        let writer = try MeetingRecordingWriter()
        let chunks = try PCMChunkRecorder(directoryName: "meeting-stop-during-resume-tests")
        route.onRawPCMSamples = { audio in
            capture.enqueueMicrophoneSamples(audio, on: sink) {
                writer.appendMic(audio.samples); chunks.append(audio.samples)
            }
        }
        defer { resumeGate.release.signal(); route.onRawPCMSamples = nil; writer.cancel(); chunks.cancel() }
        try await capture.start()
        clock.withLock { $0 = 102 }
        #expect(capture.setPaused(true))
        clock.withLock { $0 = 104 }
        #expect(capture.setPaused(false))
        try await resumeGate.waitUntilEntered()
        clock.withLock { $0 = 106 }
        if discard { capture.finishMicrophoneDelivery() }
        let shutdown = capture.requestStop() // Invalidates native ownership BEFORE Resume is released.
        clock.withLock { $0 = 120 }
        _ = capture.requestStop() // Neither late callbacks nor repeated Stop move the boundary.
        #expect(driver.emit([0.125, 0.25, 0.9, 0.9],
            host: AVAudioTime.hostTime(forSeconds: 104.0 / 16_000)))
        #expect(driver.queuedBufferCount == 2)
        #expect(driver.emit([0.9], host: AVAudioTime.hostTime(forSeconds: 106.0 / 16_000)))
        #expect(driver.queuedBufferCount == 1)
        #expect(driver.emit([0.9], host: AVAudioTime.hostTime(forSeconds: 108.0 / 16_000)))
        #expect(driver.queuedBufferCount == 0)
        resumeGate.release.signal()
        let result = await shutdown.value
        #expect(!result.timedOut)
        sink.sync { capture.finishMicrophoneDelivery() }
        #expect(driver.queuedBufferCount == 0)
        #expect(!driver.emit([0.9], host: AVAudioTime.hostTime(forSeconds: 110.0 / 16_000)))
        let expected: [Int16] = discard ? [] : [4095, 8191]
        for url in [result.microphone, writer.stop(), chunks.stop()] {
            if let url {
                defer { try? FileManager.default.removeItem(at: url) }
                let data = try Data(contentsOf: url)
                let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                #expect(samples == expected)
            } else { #expect(expected.isEmpty) }
        }
    }

    @Test("retired native tails never reenter the meeting; active stop boundaries remain safe",
          arguments: [false, true], ["running", "beforeNativeStop", "beforeStart", "afterCut", "paused", "resumed", "stopped", "pausedStop", "discarded", "deadline", "untimed", "cancelled"])
    func nativeHandoffTail(wrapped: Bool, ending: String) async throws {
        let oldDriver = ContractQueueDriver(), nextDriver = ContractQueueDriver()
        let oldQueue = AudioQueueInputRecorder(directoryName: "meeting-native-handoff-tests", native: oldDriver.operations)
        let nextQueue = AudioQueueInputRecorder(directoryName: "meeting-native-handoff-tests", native: nextDriver.operations)
        let old: StreamingDictationRecording = wrapped
            ? FallbackStreamingDictationRecorder(primary: oldQueue, fallback: StreamingMicRecorder()) : oldQueue
        let worker = DispatchQueue(label: "test.native-handoff.worker")
        let route = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: StreamingMeetingMicRecorderAdapter(recorder: old, kind: .appScopedAudioQueue),
            appScopedRecorder: StreamingMeetingMicRecorderAdapter(recorder: nextQueue, kind: .appScopedAudioQueue),
            handoffWorkerQueue: worker, handoffTimeoutScheduler: { _, _ in })
        let clock = OSAllocatedUnfairLock(initialState: Int64(100))
        let capture = MeetingCaptureLifecycle(microphone: route, systemAudio: ContractSystemAudio(),
            microphoneClock: { clock.withLock { $0 } })
        let writer = try MeetingRecordingWriter()
        let chunks = try PCMChunkRecorder(directoryName: "meeting-native-handoff-tests")
        let sink = DispatchQueue(label: "test.native-handoff.sink")
        var delivered: [MicrophoneCaptureAudio] = [] // Sink queue only.
        route.onRawPCMSamples = { audio in
            capture.enqueueMicrophoneSamples(audio, on: sink) {
                delivered.append(audio)
                writer.appendMic(audio.samples); chunks.append(audio.samples)
            }
        }
        func emit(_ driver: ContractQueueDriver, _ values: [Int], at frame: Int64, timed: Bool = true) {
            driver.emit(values.map { Float($0) / 16 },
                host: AVAudioTime.hostTime(forSeconds: Double(frame) / 16_000), timed: timed)
        }
        let retiring = ContractGate()
        oldDriver.onStop = {
            retiring.block()
            let queuedBeforeTail = oldDriver.queuedBufferCount
            // Old PCM is still held by HAL until AFTER invalidation. None of
            // this retired source may reach meeting sinks after promotion.
            switch ending {
            case "beforeNativeStop": emit(oldDriver, [3, 4, 9, 9], at: 102)
            case "beforeStart": emit(oldDriver, [9, 9, 1, 2, 3, 4, 9, 9], at: 98)
            case "afterCut": emit(oldDriver, [9, 9], at: 106)
            default: emit(oldDriver, [1, 2, 3, 4, 9, 9], at: 100, timed: ending != "untimed")
            }
            #expect(oldDriver.queuedBufferCount == queuedBeforeTail - 1) // Retired native buffers never recycle.
        }
        route.onHandoffOutcome = { outcome in
            if ending == "beforeNativeStop", outcome == .promoted {
                emit(oldDriver, [1, 2], at: 100) // Invalidated, but native stop has not begun.
            }
        }
        defer {
            retiring.release.signal(); oldDriver.onStop = nil; nextDriver.onStop = nil
            route.onRawPCMSamples = nil; writer.cancel(); chunks.cancel()
        }
        try await capture.start()
        clock.withLock { $0 = 106 }
        #expect(route.requestHealthRecovery(.init(reason: "native-tail", requiresNonZeroSamples: false)) == .initiated)
        try await MeetingCaptureLifecycle.onDriverQueue { worker.sync {} }
        emit(nextDriver, [5, 6], at: 104)
        try await retiring.waitUntilEntered() // Promotion and old invalidation have completed.
        // New audio is already delivered while old native stop remains blocked.
        route.drainAcceptedAudio()
        let replacement = [5, 6].map { Int16(Float($0) / 16 * 32767) }
        #expect(sink.sync { delivered.flatMap(\.samples) } == replacement)

        if ["paused", "pausedStop", "resumed"].contains(ending) { #expect(capture.setPaused(true)) }
        if ending == "resumed" {
            clock.withLock { $0 = 108 }
            #expect(capture.setPaused(false)) // Must not reopen the pre-pause capture interval.
        }
        if ending == "discarded" { capture.finishMicrophoneDelivery() }
        if ending == "cancelled" { route.cancel() }
        var shutdown: Task<MeetingCaptureShutdown.Result, Never>?
        if ["stopped", "pausedStop", "deadline"].contains(ending) {
            // The replacement also has native-held PCM crossing Stop. Its
            // prefix must survive, without admitting any post-stop samples.
            clock.withLock { $0 = 108 }
            nextDriver.onStop = { emit(nextDriver, [7, 8, 9, 9], at: 106) }
            shutdown = capture.requestStop()
            if ending == "deadline" { capture.finishMicrophoneDelivery() }
        }
        retiring.release.signal()
        // Do not turn a live-handoff test into a meeting-stop test: wait for the
        // retired graph and its ordered delivery before requesting final Stop.
        try await MeetingCaptureLifecycle.onDriverQueue { route.waitForQuiescence() }
        let result = await (shutdown ?? capture.requestStop()).value
        #expect(!result.timedOut)
        if let url = result.microphone { try? FileManager.default.removeItem(at: url) }
        sink.sync { capture.finishMicrophoneDelivery() }
        oldDriver.emitLate([0.9], host: AVAudioTime.hostTime(forSeconds: 102.0 / 16_000))
        nextDriver.emitLate([0.9], host: AVAudioTime.hostTime(forSeconds: 106.0 / 16_000))
        let values: [Int]
        switch ending {
        case "stopped": values = [5, 6, 7, 8]
        default: values = [5, 6] // Delivery before discard is not retracted; no retired source survives.
        }
        let expected = values.map { Int16(Float($0) / 16 * 32767) }
        let audio = sink.sync { delivered }
        #expect(audio.flatMap(\.samples) == expected)
        for pair in zip(audio, audio.dropFirst()) { #expect(pair.0.endFrame <= pair.1.startFrame) }
        for url in [writer.stop(), chunks.stop()] {
            if let url {
                defer { try? FileManager.default.removeItem(at: url) }
                let data = try Data(contentsOf: url)
                let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                #expect(samples == expected)
            } else { #expect(expected.isEmpty) }
        }
    }

    @Test("native shutdown tail keeps only the recording interval in WAV and transcription",
          arguments: [false, true], ["before", "spanning", "after", "paused", "discarded", "resumed", "untimed", "repeat", "deadline"])
    func nativeStopTail(wrapped: Bool, ending: String) async throws {
        let driver = ContractQueueDriver()
        let queue = AudioQueueInputRecorder(directoryName: "meeting-native-tail-tests", native: driver.operations)
        let source: StreamingDictationRecording = wrapped
            ? FallbackStreamingDictationRecorder(primary: queue, fallback: StreamingMicRecorder()) : queue
        let route = RouteAwareMeetingMicRecorder(systemDefaultRecorder:
            StreamingMeetingMicRecorderAdapter(recorder: source, kind: .appScopedAudioQueue))
        var clock: Int64 = 100 // Mutated only before lifecycle transitions, never by callbacks.
        let capture = MeetingCaptureLifecycle(microphone: route, systemAudio: ContractSystemAudio(), microphoneClock: { clock })
        let writer = try MeetingRecordingWriter()
        let chunks = try PCMChunkRecorder(directoryName: "meeting-native-tail-tests")
        let sink = DispatchQueue(label: "test.native-tail.sink")
        route.onRawPCMSamples = { audio in
            capture.enqueueMicrophoneSamples(audio, on: sink) {
                writer.appendMic(audio.samples); chunks.append(audio.samples)
            }
        }
        defer { route.onRawPCMSamples = nil; writer.cancel(); chunks.cancel() }
        try await capture.start()
        func emit(_ values: [Int], at frame: Int64, timed: Bool = true) {
            driver.emit(values.map { Float($0) / 16 },
                host: AVAudioTime.hostTime(forSeconds: Double(frame) / 16_000), timed: timed)
        }
        // Start with no submitted native buffer: all test audio is still in HAL.
        // This is the boundary absent from the earlier worker-drain tests.
        if ending == "paused" || ending == "resumed" {
            clock = 101
            #expect(capture.setPaused(true))
        }
        if ending == "resumed" {
            clock = 102
            #expect(capture.setPaused(false))
        }
        if ending == "discarded" { capture.finishMicrophoneDelivery() }
        clock = 104
        let stopEntered = ContractGate()
        driver.onStop = {
            stopEntered.block()
            switch ending {
            case "before": emit([1, 2], at: 102)
            case "after": emit([9, 9], at: 104)
            case "resumed": emit([9, 1, 2, 9], at: 101)
            default: emit([1, 2, 9, 9], at: 102, timed: ending != "untimed")
            }
        }
        defer { stopEntered.release.signal(); driver.onStop = nil }
        let shutdown = capture.requestStop()
        try await stopEntered.waitUntilEntered()
        if ending == "deadline" { capture.finishMicrophoneDelivery() }
        if ending == "repeat" {
            clock = 200 // Repeated Stop must not extend the first boundary.
            _ = capture.requestStop()
        }
        stopEntered.release.signal()
        let result = await shutdown.value
        #expect(!result.timedOut)
        sink.sync { capture.finishMicrophoneDelivery() }
        driver.emitLate([0.5, 0.5], host: AVAudioTime.hostTime(forSeconds: 102.0 / 16_000))
        let urls = [result.microphone, writer.stop(), chunks.stop()]
        let allowed = ["before", "spanning", "resumed", "repeat"].contains(ending)
        let expected: [Int16] = allowed ? [2047, 4095] : []
        for url in urls {
            if let url {
                defer { try? FileManager.default.removeItem(at: url) }
                let data = try Data(contentsOf: url)
                let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                #expect(samples == expected)
            } else { #expect(expected.isEmpty) }
        }
    }

    @Test("native stop receipt also covers callbacks before the driver stop begins")
    func nativeTailBeforeDriverStop() throws {
        let driver = ContractQueueDriver()
        let queue = AudioQueueInputRecorder(directoryName: "meeting-native-tail-tests", native: driver.operations)
        queue.shouldAdmitSamples = { false }
        queue.nativeStopDrainRange = { 100..<104 }
        try queue.start()
        queue.invalidateForTeardown()
        let values: [Float] = [0.125, 0.25, 0.5, 0.75]
        driver.emit(values, host: AVAudioTime.hostTime(forSeconds: 102.0 / 16_000))
        let url = try #require(queue.stop())
        defer { queue.cancel(); try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples == [4095, 8191])
    }

    @Test("source switch reaches both sinks without waiting for old workers; pause and stop fence new audio",
          arguments: [false, true], ["running", "paused", "stopped", "discarded", "pauseFence", "resumeFence"])
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
        var boundaryAudio: [Int16]? // Sink queue only.
        let boundaryCompleted = DispatchSemaphore(value: 0)
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
        try next.emit([3, 4, 5, 6], at: 102) // Main-style switch keeps the replacement intact.
        let didPromote = try await MeetingCaptureLifecycle.onDriverQueue { promoted.wait(timeout: .now() + 5) }
        #expect(didPromote == .success)
        try next.emit([7, 8], at: 106)
        try await MeetingCaptureLifecycle.onDriverQueue { route.drainAcceptedAudio() }
        let replacement = (3...8).map { Int16(Float($0) / 16 * 32767) }
        #expect(sink.sync { delivered.flatMap(\.samples) } == replacement)
        if ending != "running" {
            let boundary: (() -> Void)? = ending.hasSuffix("Fence") ? {
                sink.sync { boundaryAudio = delivered.flatMap(\.samples) }
                boundaryCompleted.signal()
            } : nil
            #expect(capture.setPaused(true, boundary: boundary))
            try await paused.waitUntilEntered()
            try next.emit([15, 15], at: 108) // Phase is paused, native pause still blocked.
            if ending == "resumeFence" { #expect(capture.setPaused(false, boundary: {})) }
        }
        if ending == "discarded" { capture.finishMicrophoneDelivery() }
        let shutdown = ending == "stopped" || ending == "discarded" ? capture.requestStop() : nil
        paused.release.signal()
        if ending.hasSuffix("Fence") {
            let completedBoundary = try await MeetingCaptureLifecycle.onDriverQueue {
                boundaryCompleted.wait(timeout: .now() + 5)
            }
            #expect(completedBoundary == .success) // Old worker/retirement cannot stall Pause.
        }
        delayed.release.signal()
        // Drain both real producers, including the retired one, before the same
        // final queue barrier used by MeetingSession closes delivery.
        let result = await (shutdown ?? capture.requestStop()).value
        #expect(!result.timedOut)
        if let url = result.microphone { try? FileManager.default.removeItem(at: url) }
        sink.sync { capture.finishMicrophoneDelivery() }
        try old.emit([15], at: 110, stale: true)
        try next.emit([15], at: 110, stale: true)
        let audio = sink.sync { delivered }
        let expected = replacement // Old worker's pre-switch backlog is rejected, including after Stop.
        #expect(audio.flatMap(\.samples) == expected)
        if ending.hasSuffix("Fence") { #expect(sink.sync { boundaryAudio } == expected) }
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

    @Test("cancel rejects late source audio and a fresh activation preserves FIFO")
    func boundedAndCancelled() {
        for cancel in [false, true] {
            let delivery = MeetingMicrophoneDelivery()
            let old = UUID(), next = UUID()
            var output: [Int16] = []
            delivery.deliver = { output += $0.samples }
            delivery.activate(old)
            delivery.activate(next,
                audio: [.init(samples: [3, 4], startFrame: 2, admitted: true)])
            delivery.receive(.init(samples: [5, 6], startFrame: 4, admitted: true), from: next)
            if cancel { delivery.cancel() }
            else {
                delivery.receive(.init(samples: [7], startFrame: 6, admitted: true), from: next)
                delivery.receive(.init(samples: [8], startFrame: 7, admitted: true), from: next)
            }
            delivery.drain()
            let previous: [Int16] = cancel ? [3, 4, 5, 6] : [3, 4, 5, 6, 7, 8]
            #expect(output == previous)
            delivery.receive(.init(samples: [99], startFrame: 9, admitted: true), from: old)
            if cancel {
                delivery.receive(.init(samples: [99], startFrame: 9, admitted: true), from: next)
                #expect(output == previous)
            }
            // Cancellation must not poison the next positively-ready
            // producer, and stale old callbacks cannot enter that recording.
            let recovered = UUID()
            if cancel { delivery.activate(recovered) }
            else {
                delivery.activate(recovered,
                    audio: [.init(samples: [9], startFrame: 8, admitted: true)])
            }
            delivery.receive(.init(samples: [99], startFrame: 9, admitted: true), from: old)
            delivery.receive(.init(samples: [10], startFrame: 9, admitted: true), from: recovered)
            #expect(output == previous + (cancel ? [10] : [9, 10]))
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
        #expect(producer.driver?.queuedBufferCount == 0) // Overflow retires the entire native pool.
        let failed = try await MeetingCaptureLifecycle.onDriverQueue { failure.wait(timeout: .now() + 5) }
        #expect(failed == .success)
        delayed.release.signal()
        let url = try #require(try await MeetingCaptureLifecycle.onDriverQueue { producer.stop() })
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Data(contentsOf: url).count == 44 + 64 * 2)
        let duplicate = try await MeetingCaptureLifecycle.onDriverQueue { failure.wait(timeout: .now()) }
        #expect(duplicate == .timedOut)
    }

    @Test("main-style switch keeps already delivered old PCM and intact replacement", arguments: [0, 1, 2, 3, 4])
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
        delivery.activate(next,
            audio: [.init(samples: [3, 4, 5], startFrame: 2, admitted: true)])
        delivery.receive(.init(samples: [6], startFrame: 5, admitted: true), from: next)
        delivery.receive(.init(samples: Array(original.dropFirst(oldDelivered)), startFrame: Int64(oldDelivered), admitted: true), from: old)
        delivery.receive(.init(samples: [99], startFrame: 6, admitted: true), from: old)
        #expect(samples == Array(original.prefix(oldDelivered)) + [3, 4, 5, 6])
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
    let driver: ContractQueueDriver?
    private let streaming: StreamingMicRecorder?
    private let child: StreamingDictationRecording & MicrophoneCaptureReporting
    private var tap: AVAudioNodeTapBlock?
    private var first = true
    var beforeFirstDelivery: (() -> Void)?
    var beforePause: (() -> Void)?
    var beforeDrain: (() -> Void)?
    var beforeResume: (() -> Void)?
    var afterResume: (() -> Void)?
    var onAudioBuffer: (([Float]) -> Void)?
    var onCapturedAudio: ((MicrophoneCaptureAudio) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var shouldAdmitSamples: (() -> Bool)? {
        get { child.shouldAdmitSamples }
        set { child.shouldAdmitSamples = newValue }
    }
    var nativeStopDrainRange: (() -> Range<Int64>?)? {
        get { child.nativeStopDrainRange }
        set { child.nativeStopDrainRange = newValue }
    }
    init(useQueue: Bool, wrapped: Bool = false) {
        if useQueue {
            let driver = ContractQueueDriver()
            self.driver = driver; streaming = nil
            let queue = AudioQueueInputRecorder(directoryName: "meeting-delivery-contract-tests", native: driver.operations)
            child = wrapped ? FallbackStreamingDictationRecorder(primary: queue, fallback: StreamingMicRecorder()) : queue
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
    func emit(_ values: [Int], at frame: Int64, stale: Bool = false, timed: Bool = true) throws {
        let samples = values.map { Float($0) / 16 }
        let host = AVAudioTime.hostTime(forSeconds: Double(frame) / 16_000)
        if let driver {
            if stale { driver.emitLate(samples, host: host) }
            else { driver.emit(samples, host: host, timed: timed) }
        }
        else {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = buffer.frameCapacity
            for (i, value) in samples.enumerated() { buffer.floatChannelData![0][i] = value }
            tap?(buffer, timed ? AVAudioTime(hostTime: host) : AVAudioTime(sampleTime: frame, atRate: 16_000))
        }
    }
    func pause() { beforePause?(); (child as? PausableStreamingDictationRecording)?.pause() }
    func drainAcceptedAudio() { beforeDrain?(); child.drainAcceptedAudio() }
    func resume() {
        beforeResume?()
        (child as? PausableStreamingDictationRecording)?.resume()
        afterResume?()
    }
    func stop() -> URL? { child.stop() }
    func cancel() { child.cancel() }
    func invalidateForTeardown() { child.invalidateForTeardown() }
    func currentPower() -> Float { child.currentPower() }
}

private final class ContractQueueDriver {
    var onStop: (() -> Void)?
    private let queue = AudioQueueRef(bitPattern: 1)!
    private var callback: AudioQueueInputCallback?
    private var context: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    private let bufferLock = NSLock()
    private var queued: [AudioQueueBufferRef] = []
    var queuedBufferCount: Int { bufferLock.withLock { queued.count } }
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
        result.enqueue = { [self] _, buffer in
            bufferLock.withLock {
                #expect(!queued.contains(buffer)) // Double enqueue is also an ownership violation.
                queued.append(buffer)
            }
            return noErr
        }
        result.start = { _ in noErr }
        result.stop = { [self] _, immediate in
            if !immediate, let onStop {
                // HAL may wait for a callback on a DIFFERENT thread. Running
                // inline would hide callback/lifecycle lock inversion bugs.
                let completed = DispatchSemaphore(value: 0)
                Thread.detachNewThread { onStop(); completed.signal() }
                #expect(completed.wait(timeout: .now() + 5) == .success)
            }
            return noErr
        }
        result.dispose = { [self] _ in bufferLock.withLock { queued.removeAll() }; return noErr }
        result.isRunning = { _ in false }
        return result
    }
    /// A callback consumes a native-owned buffer. Only enqueue returns it;
    /// exhaustion prevents further callbacks instead of hiding starvation.
    @discardableResult
    func emit(_ samples: [Float], host: UInt64, timed: Bool = true) -> Bool {
        guard let buffer = bufferLock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) else { return false }
        invoke(buffer, samples, host: host, timed: timed)
        return true
    }
    /// Explicitly inject a stale callback, bypassing native ownership, to test
    /// production identity/generation rejection after disposal.
    func emitLate(_ samples: [Float], host: UInt64) {
        guard let buffer = buffers.first else { return }
        invoke(buffer, samples, host: host, timed: true)
    }
    private func invoke(_ buffer: AudioQueueBufferRef, _ samples: [Float], host: UInt64, timed: Bool) {
        guard let callback else { return }
        buffer.pointee.mAudioDataByteSize = UInt32(samples.count * 4)
        for (i, sample) in samples.enumerated() { buffer.pointee.mAudioData.storeBytes(of: sample, toByteOffset: i * 4, as: Float.self) }
        var time = AudioTimeStamp(); time.mHostTime = host
        if timed { time.mFlags = .hostTimeValid }
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

private final class ContractAecProcessor: MeetingAecProcessor {
    let name = "test", frameSize = 4, sampleRate = 16_000
    var events: [String] = [] // Session pipeline queue only.
    func reset() { events.append("reset") }
    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        events.append("process")
        return mic
    }
}

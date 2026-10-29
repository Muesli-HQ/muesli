import AppKit
import AVFoundation
import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

private final class BlockingFeedbackCaptureAudioWriter: FeedbackCaptureAudioWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var settingOrigin = false
    private var firstFrame: Int64?
    private var appendDuringOriginSetup = false
    let originSetterEntered = DispatchSemaphore(value: 0)
    let resumeOriginSetter = DispatchSemaphore(value: 0)
    let appendEntered = DispatchSemaphore(value: 0)

    func setMicrophoneOrigin(at frame: Int64) {
        lock.withLock { settingOrigin = true }
        originSetterEntered.signal()
        resumeOriginSetter.wait()
        lock.withLock {
            firstFrame = frame
            settingOrigin = false
        }
    }

    func appendMicrophone(_ samples: [Int16], startFrame: Int64) throws {
        lock.withLock {
            appendDuringOriginSetup = appendDuringOriginSetup || settingOrigin
            if firstFrame == nil { firstFrame = startFrame }
        }
        appendEntered.signal()
    }

    func finishMicrophone() throws -> URL? { nil }
    var appendedDuringOriginSetup: Bool { lock.withLock { appendDuringOriginSetup } }
    var origin: Int64? { lock.withLock { firstFrame } }
}

private struct MicrophoneOriginRaceResult {
    let originSetterEntered: Bool
    let callbackReady: Bool
    let appendEnteredBeforeOriginSetup: Bool
    let startFinished: Bool
    let callbackFinished: Bool
}

private func raceMicrophoneCallbackDuringOriginSetup(
    attempt: FeedbackCaptureAttempt,
    writer: BlockingFeedbackCaptureAudioWriter,
    origin: Int64
) -> MicrophoneOriginRaceResult {
    let started = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        attempt.didStart(at: Date(), frame: origin)
        started.signal()
    }
    let originSetterEntered = writer.originSetterEntered.wait(timeout: .now() + .seconds(5)) == .success
    guard originSetterEntered else {
        writer.resumeOriginSetter.signal()
        return .init(originSetterEntered: false, callbackReady: false,
            appendEnteredBeforeOriginSetup: false,
            startFinished: started.wait(timeout: .now() + .seconds(5)) == .success,
            callbackFinished: true)
    }

    let callbackReady = DispatchSemaphore(value: 0)
    let callbackDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        callbackReady.signal()
        attempt.receive(.init(samples: [Int16](repeating: 16_384, count: 1_600),
            startFrame: origin + 1_600, admitted: true))
        callbackDone.signal()
    }
    let callbackStarted = callbackReady.wait(timeout: .now() + .seconds(5)) == .success
    let appendEnteredBeforeOriginSetup = writer.appendEntered.wait(timeout: .now() + .milliseconds(100)) == .success
    writer.resumeOriginSetter.signal()
    let startFinished = started.wait(timeout: .now() + .seconds(5)) == .success
    let callbackFinished = callbackDone.wait(timeout: .now() + .seconds(5)) == .success
    return .init(originSetterEntered: true, callbackReady: callbackStarted,
        appendEnteredBeforeOriginSetup: appendEnteredBeforeOriginSetup,
        startFinished: startFinished, callbackFinished: callbackFinished)
}

@Suite("Scrawl input", .serialized)
@MainActor
struct FeedbackCaptureInputTests {
    @Test func delayedPointerCallbackUsesEventTimestamp() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let capture = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: capture.id, path: "events.jsonl")
            let origin = MicrophoneCaptureAudio.frame(atHostTime: AVAudioTime.hostTime(forSeconds: 10))
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { origin }, admitted: { true },
                onFailure: { Issue.record(Comment(rawValue: $0)) })
            monitor.receive(.down, eventTimestamp: 10.125, x: -960, y: 270)
            monitor.receive(.up, eventTimestamp: 10.25, x: -960, y: 270)
            monitor.stop()
            await monitor.drain()

            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: capture.target)
            #expect(replay.events.count == 1)
            #expect(replay.events.first?.t == 125)
            #expect(replay.events.first?.end == 250)
            store.release(id: capture.id)
        }
    }
    @Test func visibleWindowOverlapDoesNotSuppressGlobalPointerEvents() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let capture = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: capture.id, path: "events.jsonl")
            try Data().write(to: log)
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { 32_000 }, admitted: { true }, onFailure: { Issue.record(Comment(rawValue: $0)) })
            // The old adapter marked this global event excluded solely because a visible Muesli
            // window overlapped its coordinates, even when that window was behind another app.
            monitor.receive(.down, frame: 48_000, x: -960, y: 270, excluded: true)
            monitor.receive(.moved, frame: 49_600, x: -940, y: 270, excluded: true)
            monitor.receive(.up, frame: 51_200, x: -940, y: 270, excluded: true)
            monitor.receive(.scroll, frame: 52_800, x: -960, y: 270, dy: 4, excluded: true)
            monitor.stop()
            await monitor.drain()

            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: capture.target)
            #expect(replay.events.count == 2)
            #expect(replay.events.first?.kind == .drag)
            #expect(replay.events.last?.kind == .scroll)
            store.release(id: capture.id)
        }
    }

    @Test func microphoneCallbackWaitsForWAVOriginSetup() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let microphone = FeedbackMicrophoneFixture()
            microphone.emitsSamples = false
            let writer = BlockingFeedbackCaptureAudioWriter()
            let attempt = FeedbackCaptureAttempt(target: feedbackTarget(), store: store,
                makeAudioWriter: { _ in writer })
            try attempt.install(device: nil, microphone: microphone)
            try await attempt.startMicrophone()
            let id = try #require(attempt.snapshot()?.id)
            let origin: Int64 = 32_000
            let race = raceMicrophoneCallbackDuringOriginSetup(attempt: attempt, writer: writer, origin: origin)
            #expect(race.originSetterEntered)
            #expect(race.callbackReady)
            #expect(race.startFinished)
            #expect(race.callbackFinished)
            #expect(!race.appendEnteredBeforeOriginSetup, "Audio append must wait until WAV and manifest share their origin")
            #expect(!writer.appendedDuringOriginSetup)
            #expect(writer.origin == origin)
            #expect(attempt.snapshot()?.microphoneStartFrame == origin)

            await attempt.stopMicrophone()
            await attempt.drainJournal()
            store.release(id: id)
        }
    }
    @Test func journalUsesMicrophoneOriginDrainsAndRejectsRetiredCallbacks() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let m = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: m.id, path: "events.jsonl")
            var current = true
            var failures: [String] = []
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { 32_000 }, admitted: { current }, onFailure: { failures.append($0) })
            monitor.receive(.down, frame: 48_000, x: -960, y: 270)
            monitor.receive(.up, frame: 49_600, x: -960, y: 270)
            // Input admitted after Finish must never appear, including callbacks already queued by AppKit.
            current = false
            monitor.receive(.scroll, frame: 52_000, x: -960, y: 270, dy: 4)
            monitor.stop()
            await monitor.drain()
            let before = try Data(contentsOf: log)
            monitor.receive(.down, frame: 64_000, x: -960, y: 270)
            monitor.receive(.up, frame: 65_600, x: -960, y: 270)
            await monitor.drain()
            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: m.target)
            #expect(replay.events.count == 1)
            #expect(replay.events.first?.t == 1000 && replay.events.first?.end == 1100)
            #expect(replay.events.first?.x == 0.5 && replay.events.first?.y == 0.25)
            #expect(try Data(contentsOf: log) == before)
            #expect(failures.isEmpty)
            store.release(id: m.id)
        }
    }
    @Test func stalledMicrophoneKeepsPointerClockAndPadsDelayedAudio() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let microphone = FeedbackMicrophoneFixture()
            microphone.emitsSamples = false
            let attempt = FeedbackCaptureAttempt(target: feedbackTarget(), store: store)
            try attempt.install(device: nil, microphone: microphone)
            try await attempt.startMicrophone()
            attempt.didStart(at: Date())
            let origin = try #require(attempt.snapshot()?.microphoneStartFrame,
                "A started recorder with no delivered samples still needs a stable pointer clock")
            let id = try #require(attempt.snapshot()?.id)
            let log = try store.mediaURL(id: id, path: "events.jsonl")
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { attempt.snapshot()?.microphoneStartFrame }, admitted: { true },
                onFailure: { Issue.record(Comment(rawValue: $0)) })
            monitor.receive(.down, frame: origin + 1600, x: -960, y: 270)
            monitor.receive(.up, frame: origin + 2400, x: -960, y: 270)
            // Later samples must keep pointer time aligned with WAV sample zero.
            attempt.receive(.init(samples: [Int16](repeating: 16_384, count: 1600),
                startFrame: origin + 3200, admitted: true))
            attempt.finishAudio()
            monitor.receive(.scroll, frame: origin + 4800, x: -960, y: 270, dy: 2)
            monitor.stop(); await monitor.drain()
            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: feedbackTarget())
            #expect(replay.events.map(\.t) == [100, 300])
            #expect(attempt.snapshot()?.microphoneStartFrame == origin)
            let samples = try WavReader.readFloatMonoWAV(from: store.mediaURL(id: id, path: "narration.wav")).samples
            #expect(samples.count == 4800)
            #expect(samples.prefix(3200).allSatisfy { $0 == 0 })
            #expect(samples.suffix(1600).allSatisfy { $0 == 0.5 })
            await attempt.stopMicrophone(); await attempt.drainJournal()
            store.release(id: id)
        }
    }

    @Test func inputsBeforeMicrophoneZeroAreNotStampedWithWallTime() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let m = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: m.id, path: "events.jsonl")
            var origin: Int64?
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { origin }, admitted: { true }, onFailure: { Issue.record(Comment(rawValue: $0)) })
            monitor.receive(.down, frame: 100, x: -960, y: 270)
            origin = 16_000
            monitor.receive(.up, frame: 20_000, x: -960, y: 270)
            monitor.receive(.scroll, frame: 24_000, x: -960, y: 270, dx: 1, dy: 2)
            monitor.stop(); await monitor.drain()
            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: m.target)
            #expect(replay.events.count == 1 && replay.events.first?.kind == .scroll)
            #expect(replay.events.first?.t == 500)
            store.release(id: m.id)
        }
    }
}

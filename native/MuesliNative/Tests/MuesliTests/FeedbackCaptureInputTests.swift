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
    @Test func delayedMouseCallbackUsesEventModifierSnapshot() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: -960, y: 270), modifierFlags: [.shift], timestamp: 10.125,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp,
                location: NSPoint(x: -960, y: 270), modifierFlags: [.shift], timestamp: 10.25,
                windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            let point = try #require(down.cgEvent?.location)
            #expect(down.modifierFlags.contains(.shift))
            let target = FeedbackCaptureTarget(displayId: 42,
                frame: .init(x: point.x - 960, y: point.y - 540, width: 1920, height: 1080, scale: 2),
                appName: "Fixture Editor")
            let capture = try store.begin(target: target)
            let log = try store.mediaURL(id: capture.id, path: "events.jsonl")
            let origin = MicrophoneCaptureAudio.frame(atHostTime: AVAudioTime.hostTime(forSeconds: 10))
            let monitor = FeedbackCaptureInputMonitor(target: target, url: log,
                origin: { origin }, admitted: { true },
                onFailure: { Issue.record(Comment(rawValue: $0)) })

            monitor.sample(frame: origin, x: point.x, y: point.y, modifiers: [], secureInput: false)

            monitor.receiveMouseEvent(down)
            monitor.receiveMouseEvent(up)
            monitor.stop(frame: origin + 16_000)
            await monitor.drain()

            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: capture.target)
            #expect(replay.strokes.map(\.pin) == [1])
            #expect(replay.events.isEmpty)
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

    @Test func pointerExclusionFollowsFrontmostHitTestableWindow() {
        let ownPID: Int32 = 42
        let appWindow = FeedbackCaptureInputMonitor.WindowSnapshot(ownerPID: ownPID, windowNumber: 1,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1)
        let browserWindow = FeedbackCaptureInputMonitor.WindowSnapshot(ownerPID: 99, windowNumber: 2,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1)
        let clickThroughOverlay = FeedbackCaptureInputMonitor.WindowSnapshot(ownerPID: ownPID, windowNumber: 3,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1)

        #expect(!FeedbackCaptureInputMonitor.isExcluded(CGPoint(x: 50, y: 50), primaryHeight: 100,
            processIdentifier: ownPID, interactiveOwnWindowIDs: [1], windowStack: [browserWindow, appWindow]))
        #expect(FeedbackCaptureInputMonitor.isExcluded(CGPoint(x: 50, y: 50), primaryHeight: 100,
            processIdentifier: ownPID, interactiveOwnWindowIDs: [1], windowStack: [appWindow, browserWindow]))
        #expect(!FeedbackCaptureInputMonitor.isExcluded(CGPoint(x: 50, y: 50), primaryHeight: 100,
            processIdentifier: ownPID, interactiveOwnWindowIDs: [1],
            windowStack: [clickThroughOverlay, browserWindow, appWindow]))
    }

    @Test func windowStackRefreshIsBoundedAndHitTestsCurrentPointer() {
        let ownPID: Int32 = 42
        let interactiveWindow = FeedbackCaptureInputMonitor.InteractiveWindowSnapshot(
            windowNumber: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let appWindow = FeedbackCaptureInputMonitor.WindowSnapshot(ownerPID: ownPID, windowNumber: 1,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1)
        let browserWindow = FeedbackCaptureInputMonitor.WindowSnapshot(ownerPID: 99, windowNumber: 2,
            bounds: CGRect(x: 50, y: 0, width: 50, height: 100), alpha: 1)
        var windowListReads = 0
        var windowStack = [browserWindow, appWindow]
        var cache = FeedbackCaptureInputMonitor.WindowStackSnapshotCache()

        func isExcluded(_ cocoa: CGPoint, at time: TimeInterval) -> Bool {
            cache.isExcluded(cocoa, primaryHeight: 100, processIdentifier: ownPID,
                interactiveWindows: [interactiveWindow], now: time) {
                    windowListReads += 1
                    return windowStack
                }
        }

        #expect(isExcluded(CGPoint(x: 25, y: 50), at: 10))
        #expect(!isExcluded(CGPoint(x: 75, y: 50), at: 10.1),
            "The current pointer must be hit-tested against the ordered window snapshot on every poll")
        #expect(windowListReads == 1, "The WindowServer list must not be refreshed on every poll")
        #expect(!isExcluded(CGPoint(x: 120, y: 50), at: 10.15),
            "Leaving the live Muesli window must immediately stop excluding pointer input")
        #expect(windowListReads == 1, "A pointer outside Muesli should not trigger a window-list refresh")

        windowStack = [appWindow]
        #expect(isExcluded(CGPoint(x: 75, y: 50), at: 10.21),
            "The ordered snapshot should refresh after its bounded interval")
        #expect(windowListReads == 2)
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
            monitor.receive(.down, frame: 48_000, x: -960, y: 270, modifiers: [])
            monitor.receive(.up, frame: 49_600, x: -960, y: 270, modifiers: [])
            // Input admitted after Finish must never appear, including callbacks already queued by AppKit.
            current = false
            monitor.receive(.scroll, frame: 52_000, x: -960, y: 270, dy: 4, modifiers: [])
            monitor.stop()
            await monitor.drain()
            let before = try Data(contentsOf: log)
            monitor.receive(.down, frame: 64_000, x: -960, y: 270, modifiers: [])
            monitor.receive(.up, frame: 65_600, x: -960, y: 270, modifiers: [])
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
            monitor.receive(.down, frame: 100, x: -960, y: 270, modifiers: [])
            origin = 16_000
            monitor.receive(.up, frame: 20_000, x: -960, y: 270, modifiers: [])
            monitor.receive(.scroll, frame: 24_000, x: -960, y: 270, dx: 1, dy: 2, modifiers: [])
            monitor.stop(); await monitor.drain()
            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: m.target)
            #expect(replay.events.count == 1 && replay.events.first?.kind == .scroll)
            #expect(replay.events.first?.t == 500)
            store.release(id: m.id)
        }
    }

    @Test func ordinaryDragReleasedInsideAppDoesNotSuppressNextModifierStroke() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let capture = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: capture.id, path: "events.jsonl")
            var buttonsDown: Set<Int> = [0]
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { 0 }, admitted: { true }, onFailure: { Issue.record(Comment(rawValue: $0)) },
                currentPressedMouseButtons: { buttonsDown })

            monitor.receive(.down, frame: 1_600, x: -960, y: 270, modifiers: [])
            monitor.receive(.scroll, frame: 2_400, x: -960, y: 270, dy: 1, modifiers: [])
            // The mouse-up is delivered to Muesli, so the global monitor misses it.
            buttonsDown = []
            monitor.sample(frame: 3_200, x: -960, y: 270, modifiers: [], secureInput: false)

            buttonsDown = [0]
            monitor.receive(.down, frame: 4_800, x: -960, y: 270, modifiers: [.shift])
            monitor.sample(frame: 6_400, x: -940, y: 270, modifiers: [.shift], secureInput: false)
            monitor.stop(frame: 8_000)
            await monitor.drain()

            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: capture.target)
            #expect(replay.strokes.count == 1)
            store.release(id: capture.id)
        }
    }

    @Test func globalModifierDownClaimsButtonPreviouslySeenByPolling() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let capture = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: capture.id, path: "events.jsonl")
            var buttonsDown: Set<Int> = []
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { 0 }, admitted: { true }, onFailure: { Issue.record(Comment(rawValue: $0)) },
                currentPressedMouseButtons: { buttonsDown })

            monitor.sample(frame: 800, x: -960, y: 270, modifiers: [], secureInput: false)
            buttonsDown = [0]
            // Polling can observe the press before AppKit delivers its global mouse-down callback.
            monitor.sample(frame: 1_600, x: -960, y: 270, modifiers: [.shift], secureInput: false)
            monitor.receive(.down, frame: 1_616, x: -960, y: 270, modifiers: [.shift])
            buttonsDown = []
            monitor.receive(.up, frame: 2_000, x: -960, y: 270, modifiers: [.shift])
            monitor.stop(frame: 2_400)
            await monitor.drain()

            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: capture.target)
            #expect(replay.strokes.map(\.pin) == [1])
            #expect(replay.events.isEmpty)
            store.release(id: capture.id)
        }
    }

    @Test func localOrdinaryDragDoesNotStartModifierInkOutsideApp() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let capture = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: capture.id, path: "events.jsonl")
            var buttonsDown: Set<Int> = []
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log,
                origin: { 0 }, admitted: { true }, onFailure: { Issue.record(Comment(rawValue: $0)) },
                currentPressedMouseButtons: { buttonsDown })

            // A no-modifier sample arms ink before the local mouse down, which the global monitor misses.
            monitor.sample(frame: 800, x: -960, y: 270, modifiers: [], secureInput: false)
            buttonsDown = [0]
            monitor.sample(frame: 1_600, x: -960, y: 270, modifiers: [.shift], secureInput: false)
            monitor.sample(frame: 3_200, x: -940, y: 270, modifiers: [.shift], secureInput: false)
            monitor.receive(.scroll, frame: 4_000, x: -940, y: 270, dy: 1, modifiers: [.shift])
            monitor.stop(frame: 4_800)
            await monitor.drain()

            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: capture.target)
            #expect(replay.strokes.isEmpty)
            store.release(id: capture.id)
        }
    }
}

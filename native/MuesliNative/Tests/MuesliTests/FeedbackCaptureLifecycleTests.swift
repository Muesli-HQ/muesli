import AppKit
import AVFoundation
import CoreAudio
import Foundation
import SwiftUI
import SQLite3
import Testing
import os
@testable import MuesliCore
@testable import MuesliNativeApp

final class FeedbackMicrophoneFixture: StreamingDictationRecording, MicrophoneCaptureReporting, @unchecked Sendable {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onCapturedAudio: ((MicrophoneCaptureAudio) -> Void)?
    var shouldAdmitSamples: (() -> Bool)?
    var nativeStopDrainRange: (() -> Range<Int64>?)?
    var preferredInputDeviceID: AudioObjectID?
    var stopAction: () -> Void = {}
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0
    private var lifecycleEvents: [String] = []
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var lifecycle: [String] { lock.withLock { lifecycleEvents } }
    var temporaryURL: URL?
    var emitsSamples = true
    var startFrame: Int64 = 16_000
    func prepare() throws {}
    func start() throws {
        lock.withLock { startCount += 1 }
        if emitsSamples { onCapturedAudio?(.init(samples: [Int16](repeating: 0, count: 1600), startFrame: startFrame, admitted: true)) }
    }
    func stop() -> URL? {
        stopAction()
        return lock.withLock {
            stopCount += 1
            lifecycleEvents.append("stop")
            return temporaryURL
        }
    }
    func cancel() { lock.withLock { lifecycleEvents.append("cancel") } }
    func currentPower() -> Float { -160 }
    func drainAcceptedAudio() {}
}

@Suite("Scrawl lifecycle", .serialized)
@MainActor
struct FeedbackCaptureLifecycleTests {
    private func waitUntil(description: String = "capture lifecycle", _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(predicate(), "Timed out waiting for \(description)")
    }

    let granted = InteractionPermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true, screenRecording: true)

    @Test func recoveredInkOnlyCapturePresentsRetainedMarksWithoutMissingMedia() async throws {
        try await withFeedbackStoreAsync { store, root in
            var manifest = try store.begin(target: feedbackTarget())
            var data = Data()
            for stroke in [feedbackStroke(100), feedbackStroke(1500, pin: 1)] {
                data.append(try JSONEncoder().encode(FeedbackCaptureJournalRecord.stroke(stroke))); data.append(10)
            }
            try data.write(to: store.mediaURL(id: manifest.id, path: "events.jsonl"))
            let recovered = store.reconcileMedia(manifest, audioDuration: { _ in nil }, videoDuration: { _ in nil })
            try #require(recovered.retainsContent && recovered.manifest.marks.count == 2)
            manifest = recovered.manifest; manifest.state = .recovered
            try store.publish(manifest); store.release(id: manifest.id)
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"),
                supportDirectory: root, observeSystem: false)
            _ = await controller.reload(requestedID: manifest.id)
            _ = NSApplication.shared
            let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(attribute)
            NSApp.accessibilitySetValue(true, forAttribute: attribute)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
            let panel = FeedbackCapturePillTests.HiddenPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.borderless], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: FeedbackCaptureView(controller: controller, selectedID: manifest.id))
            panel.contentView = hosting
            defer { panel.contentView = nil; panel.close() }
            let fixture = FeedbackCapturePillTests()
            try await waitUntil {
                fixture.accessibilityElements(hosting).contains { $0.accessibilityLabel() == "Delete…" && $0.isAccessibilityEnabled() }
            }
            let text = fixture.accessibilityElements(hosting).flatMap {
                [$0.accessibilityLabel(), $0.accessibilityValue() as? String].compactMap { $0 }
            }.joined(separator: "\n")
            for mark in manifest.marks { #expect(text.contains(mark.description)) }
            #expect(!text.contains("Saved media file is missing"))
            #expect(!text.contains("Media unavailable"))
        }
    }

    @Test func delayedPreparationKeepsRecordingClockDistinctFromAdmission() async throws {
        // Match AppKit's common modes in this test host, which never runs NSApplication.run().
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        try await withFeedbackStoreAsync { store, root in
            var now = Date(timeIntervalSinceReferenceDate: 0)
            var resume: CheckedContinuation<Void, Never>?
            let mic = FeedbackMicrophoneFixture(); mic.emitsSamples = false
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    await withCheckedContinuation { resume = $0 }
                    try attempt.install(device: device, microphone: mic)
                }, now: { now }, observeSystem: false)
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { resume != nil }
            let admission = controller.admittedAt
            now = now.addingTimeInterval(5); resume?.resume()
            try await waitUntil { controller.state?.isRecording == true }
            controller.checkLifetime()
            #expect(controller.admittedAt == admission, "The shortcut guard retains admission time")
            #expect(controller.state == .recording(seconds: 0, deadMicrophone: false))
            now = now.addingTimeInterval(0.601); controller.checkLifetime()
            #expect(controller.state == .recording(seconds: 0, deadMicrophone: true))
            now = Date(timeIntervalSinceReferenceDate: 600); controller.checkLifetime()
            #expect(controller.state == .recording(seconds: 595, deadMicrophone: true), "Preparation must not shorten the recording cap")
            now = now.addingTimeInterval(5)
            // A menu holds the main loop in tracking mode across the cap.
            // Do not yield into default mode or call checkLifetime here.
            MainActor.assumeIsolated {
                let deadline = Date().addingTimeInterval(5)
                while controller.state?.isRecording != false, Date() < deadline {
                    RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
                }
                #expect(controller.state?.isRecording == false, "The lifetime timer must finish capture while a menu tracks")
            }
            await controller.shutdown()
            #expect(mic.starts == 1 && mic.stops == 1)
            #expect(try !store.list().isEmpty)
            #expect(controller.latestID != nil)
        }
    }

    @Test func lifetimeTickDoesNotRepublishUnchangedPillState() async throws {
        try await withFeedbackStoreAsync { _, root in
            var now = Date(timeIntervalSinceReferenceDate: 0)
            let mic = FeedbackMicrophoneFixture(); mic.emitsSamples = false
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: mic)
                }, now: { now }, observeSystem: false)
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { controller.state?.isRecording == true }

            var stateChanges = 0
            controller.onStateChanged = { _ in stateChanges += 1 }
            let presentation = controller.presentationID
            controller.checkLifetime()
            #expect(controller.presentationID == presentation, "An unchanged timer tick must not create a presentation")
            #expect(stateChanges == 0, "An unchanged timer tick must not notify the pill presentation")

            now = now.addingTimeInterval(0.601)
            controller.checkLifetime()
            #expect(controller.state == .recording(seconds: 0, deadMicrophone: true))
            #expect(stateChanges == 1, "A changed microphone state must still be presented")

            await controller.shutdown()
            #expect(mic.starts == 1 && mic.stops == 1)
        }
    }

    /// Synthetic native frames exercise the attempt's actual recorder and finalization.
    nonisolated private static func startVideoFixture(_ recorder: ScreenVideoRecorder, at frame: Int64) async throws {
        try recorder.prepareWriter(width: 64, height: 64)
        var pixel: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let image = try #require(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMTime(value: frame, timescale: 16_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let buffer = try #require(sample)
        for _ in 0..<100 {
            if await recorder.testing_appendVideoFrame(buffer) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Native frame was never accepted by the recorder")
    }

    @Test("Completion retains video and reports the narration writer outcome", arguments: ["samples", "empty", "drain failure"])
    func completedMediaReflectsNarration(mode: String) async throws {
        let samples = mode != "empty", drainFailure = mode == "drain failure"
        try await withFeedbackStoreAsync { store, root in
            let mic = FeedbackMicrophoneFixture(); mic.emitsSamples = samples
            let completions = OSAllocatedUnfairLock(initialState: 0)
            var opened: String?
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: mic)
                    let video = try #require(attempt.video)
                    mic.startFrame = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()) - (drainFailure ? 192_000 : 0)
                    if drainFailure {
                        mic.stopAction = { [weak mic] in
                            guard let mic else { return }
                            // Captured before Finish, delivered while the native microphone stops.
                            mic.onCapturedAudio?(.init(samples: [Int16](repeating: 1, count: 160_001),
                                startFrame: mic.startFrame + 1600, admitted: true))
                        }
                    }
                    video.onFinalized = { completions.withLock { $0 += 1 } }
                    try await Task.detached { try await Self.startVideoFixture(video, at: mic.startFrame) }.value
                }, observeSystem: false, openCapture: { opened = $0 }, repairAudio: { url in
                    #expect(!samples, "Successful WAV closure must not invoke mutating repair")
                    return try WavWriter.repairIncrementalWAV(at: url)
                })
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { controller.state?.isRecording == true }
            await controller.shutdown()
            let id = try #require(controller.latestID)
            let manifest = try store.manifest(id: id)
            #expect(completions.withLock { $0 } == 1)
            #expect(manifest.failures.contains { $0.stage == "video" && $0.message == "Audio encoding fell behind." } == drainFailure)
            #expect(manifest.video == "recording.mp4")
            #expect(try FeedbackCaptureController.videoDuration(store.mediaURL(id: id, path: "recording.mp4")) != nil)
            #expect((manifest.audio != nil) == samples)
            if samples {
                #expect(controller.state == (drainFailure ? .failed(stage: "video", message: "Audio encoding fell behind.", retainedMedia: true) : .ready))
                let wav = try store.mediaURL(id: id, path: "narration.wav")
                #expect(try WavReader.readFloatMonoWAV(from: wav).samples.count == (drainFailure ? 161_601 : 1600))
            } else {
                #expect(manifest.failures.contains { $0.stage == "audio" }, "An empty microphone stream needs a persisted audio failure")
                #expect(controller.state == .failed(stage: "audio", message: "No microphone samples were captured.", retainedMedia: true))
            }
            // Mount the actual capture source owner with real completed media.
            _ = NSApplication.shared
            let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(attribute)
            NSApp.accessibilitySetValue(true, forAttribute: attribute)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
            let panel = FeedbackCapturePillTests.HiddenPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.borderless], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: FeedbackCaptureView(controller: controller, selectedID: id))
            panel.contentView = hosting
            defer { panel.contentView = nil; panel.close() }
            let fixture = FeedbackCapturePillTests()
            try await waitUntil {
                fixture.accessibilityElements(hosting).contains { $0.accessibilityLabel() == "Delete…" && $0.isAccessibilityEnabled() }
            }
            let audio = fixture.accessibilityElements(hosting).first { $0.accessibilityLabel() == "Audio" }
            #expect((audio != nil) == samples, "Both retained media need a native segmented choice, including partial AAC")
            if audio != nil {
                let picker = try #require(fixture.views(hosting).compactMap { $0 as? NSSegmentedControl }
                    .first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "Video" && $0.label(forSegment: 1) == "Audio" })
                picker.selectedSegment = 1
                #expect(picker.sendAction(picker.action, to: picker.target))
                try await waitUntil {
                    fixture.accessibilityElements(hosting).contains { $0.accessibilityLabel() == "Recording waveform" }
                }
                picker.selectedSegment = 0
                #expect(picker.sendAction(picker.action, to: picker.target))
                try await waitUntil {
                    !fixture.accessibilityElements(hosting).contains { $0.accessibilityLabel() == "Recording waveform" }
                }
            }
            #expect(controller.presentedCaptureID == id)
            controller.open()
            #expect(opened == id, "Retained-media Open remains bound to the completed capture")
        }
    }

    private func shortcutController(root: URL, monitor: HotkeyMonitor,
        capture: FeedbackCaptureController? = nil, menuRefresh: (@MainActor () -> Void)? = nil,
        indicator: FloatingIndicatorController? = nil) throws -> MuesliController {
        let database = DictationStore(databaseURL: root.appendingPathComponent("muesli.db"))
        let config = ConfigStore(supportDirectory: root)
        var value = AppConfig()
        value.hasCompletedOnboarding = true; value.enablePushToTalk = false
        value.enableComputerUseHotkey = false; value.enableQuilMode = false
        value.feedbackCaptureHotkey = .combination(modifiers: [.control, .shift], keyCode: 3)
        config.save(value)
        let subject = MuesliController(runtime: .init(repoRoot: root, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: database, configStore: config,
            hotkeyMonitor: HotkeyMonitor(registerEvents: { {} }), feedbackCaptureHotkeyMonitor: monitor,
            makeFeedbackCapture: { database, support in capture ?? FeedbackCaptureController(databaseURL: database, supportDirectory: support) },
            feedbackMenuRefresh: menuRefresh, indicator: indicator)
        subject.hasStarted = true
        #expect(subject.updateFeedbackCaptureEnabled(true).didUpdate)
        return subject
    }

    @Test("Configured feedback shortcut resumes after permission-repair dictation testing", arguments: [false, true])
    func feedbackShortcutResumesAfterDictationTest(independentCompletion: Bool) async throws {
        try await withFeedbackStoreAsync { _, root in
            let monitor = HotkeyMonitor(registerEvents: { {} })
            let subject = try shortcutController(root: root, monitor: monitor)
            #expect(monitor.isRunning)
            subject.dictationTestCallback = { _ in }
            subject.stopHotkeyMonitor()
            #expect(!monitor.isRunning)
            subject.clearDictationTestLifecycle()
            if independentCompletion { subject.startIndependentDictationFeatureHotkeyMonitorsIfNeeded() }
            else { subject.startHotkeyMonitor() }
            #expect(monitor.isRunning, "Enabled feedback must resume after the dictation-test monitor stops")
            #expect(monitor.combinationKeyCode == 3 && monitor.combinationModifiers == [.control, .shift])
            #expect(subject.config.enableFeedbackCapture)
            subject.stopHotkeyMonitor()
        }
    }

    @Test("Menu admission and monitor restart finish on the next chord press", arguments: [false, true], [false, true])
    func menuAdmissionFinishesOnPress(restartMonitor: Bool, carbon: Bool) async throws {
        try await withFeedbackStoreAsync { _, root in
            var now = Date(timeIntervalSinceReferenceDate: 0)
            let monitor = HotkeyMonitor(now: { now }, registerEvents: { {} })
            let microphone = FeedbackMicrophoneFixture()
            var failPreparation = false
            _ = NSApplication.shared
            let makePanel: () -> NSPanel = {
                FeedbackCapturePillTests.HiddenPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            }
            let indicator = FloatingIndicatorController(configStore: ConfigStore(supportDirectory: root),
                notchIndicator: NotchIndicatorController(makeFeedbackCapturePanel: makePanel), makeFeedbackCapturePanel: makePanel)
            defer { indicator.close() }
            let capture = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    if failPreparation { throw ScreenVideoRecorder.error("Synthetic preparation failure") }
                    try attempt.install(device: device, microphone: microphone)
                }, now: { now }, observeSystem: false)
            var menuOwnership: [Bool] = []
            let subject = try shortcutController(root: root, monitor: monitor, capture: capture,
                menuRefresh: { menuOwnership.append(capture.ownsMicrophone) }, indicator: indicator)
            _ = subject.feedbackCapture // Wire the actual owner's monitor, presentation and release callbacks.
            capture.finalizer.stages = [] // This control fixture must not invoke installed speech models.
            subject.handleFeedbackCaptureToggle(permissions: { granted }, device: { nil })
            try await waitUntil { capture.state?.isRecording == true }
            #expect(menuOwnership == [true], "Accepted Start refreshes menu ownership once")
            for _ in 0..<3 { capture.checkLifetime() }
            #expect(menuOwnership == [true], "Recording ticks do not rebuild an open menu")
            func press() {
                if carbon { monitor.handleRegisteredHotKeyPressForTests() }
                else { monitor.handleCombinationForTests(type: .keyDown, keyCode: 3, flags: [.control, .shift]) }
            }
            now = now.addingTimeInterval(0.399)
            monitor.handleCombinationForTests(type: .keyDown, keyCode: 3, flags: [.control, .shift], isRepeat: true)
            press()
            monitor.handleCombinationForTests(type: .keyUp, keyCode: 3, flags: [])
            #expect(capture.state?.isRecording == true, "Admission preserves the 400 ms guard")
            now = Date(timeIntervalSinceReferenceDate: 1)
            if restartMonitor { monitor.restart() }
            #expect(capture.state?.isRecording == true, "Listener restart must preserve the admitted capture")
            press()
            #expect(capture.state?.isRecording == false, "The next chord PRESS must Finish before any release")
            press() // Carbon repeats before full release cannot start another capture.
            monitor.handleCombinationForTests(type: .keyUp, keyCode: 3, flags: [])
            await capture.shutdown()
            #expect(microphone.starts == 1 && microphone.stops == 1)
            #expect(menuOwnership == [true, false], "Actual microphone release refreshes Start once")
            failPreparation = true
            subject.handleFeedbackCaptureToggle(permissions: { granted }, device: { nil })
            try await waitUntil { !capture.hasAttempt }
            #expect(menuOwnership == [true, false, true, false], "Failed preparation also restores menu ownership once")
            subject.stopHotkeyMonitor()
        }
    }

    @Test(arguments: [false, true])
    func testStartupTimeoutAllowsRetry(explicitFinish: Bool) async throws {
        try await withFeedbackStoreAsync { store, root in
            var resumeDiscovery: CheckedContinuation<Void, Never>?
            var discoveryCalls = 0, retiredDiscoveryReturned = false
            let mic = FeedbackMicrophoneFixture()
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    discoveryCalls += 1
                    let retired = discoveryCalls == 1
                    defer { if retired { retiredDiscoveryReturned = true } }
                    if retired { await withCheckedContinuation { resumeDiscovery = $0 } }
                    try attempt.install(device: device, microphone: mic)
                }, startupTimeout: .milliseconds(30), observeSystem: false)
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { resumeDiscovery != nil }
            if explicitFinish { #expect(await controller.finishAndReleaseMicrophone()) }
            else {
                try await waitUntil { controller.errorMessage != nil }
                #expect(controller.errorMessage == "Startup timed out")
            }
            #expect(!controller.hasAttempt, "Resource-free timeout must retire without waiting for discovery")
            #expect(!controller.ownsMicrophone)
            #expect(mic.starts == 0)
            #expect(try store.list().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.root.path))
            let retried = controller.start(permissions: granted, busyActivity: nil, device: { nil })
            #expect(retried, "Retry must be admitted while the old discovery is still suspended")
            resumeDiscovery?.resume()
            try await waitUntil { retiredDiscoveryReturned }
            if retried { try await waitUntil { controller.state?.isRecording == true } }
            await controller.shutdown()
            #expect(mic.starts == (retried ? 1 : 0))
            #expect(try store.list().count == (retried ? 1 : 0))
        }
    }

    @Test func testSavingFailureOpensRetainedCapture() async throws {
        try await withFeedbackStoreAsync { store, root in
            var ids: [String] = [], opened: String?
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: FeedbackMicrophoneFixture())
                    ids.append(try #require(attempt.snapshot()).id)
                }, observeSystem: false, openCapture: { opened = $0 })
            controller.finalizer.stages = [.init(name: .render, run: { manifest, _ in manifest.failures.removeAll() })]
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { controller.state?.isRecording == true }
            await controller.shutdown()
            #expect(controller.state == .ready)
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { ids.count == 2 && controller.state?.isRecording == true }
            let failedID = ids[1]
            var db: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("muesli.db").path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "CREATE TRIGGER reject_feedback BEFORE INSERT ON feedback_captures BEGIN SELECT RAISE(ABORT,'Synthetic publication failure'); END", nil, nil, nil) == SQLITE_OK)
            await controller.shutdown()
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: failedID, path: "unfinished.json").path))
            // Simulate a catalog publication with no row: the journal is authoritative.
            #expect(sqlite3_exec(db, "DELETE FROM feedback_captures WHERE id='\(failedID)'", nil, nil, nil) == SQLITE_OK)
            await controller.reload(requestedID: failedID)
            #expect(controller.records.first?.id == failedID)
            #expect(try store.get(id: failedID)?.id == failedID)
            controller.open()
            #expect(opened == failedID, "The retained-error Open action must open B, not the previous successful A")
            #expect(opened != ids[0])
            try await controller.delete(id: failedID)
            controller.open()
            #expect(opened == ids[0], "Deleting a retained capture leaves the previous capture openable")
        }
    }

    @Test func testCompletedDismissalDoesNotHideNewBlockedState() async throws {
        try await withFeedbackStoreAsync { _, root in
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: FeedbackMicrophoneFixture())
                }, observeSystem: false, dismissalDelay: .seconds(2))
            controller.finalizer.stages = [.init(name: .render, run: { manifest, _ in manifest.failures.removeAll() })]
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { controller.state?.isRecording == true }
            await controller.shutdown()
            #expect(controller.state == .ready)
            let denied = InteractionPermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true, screenRecording: false)
            #expect(!controller.start(permissions: denied, busyActivity: nil, device: { nil }))
            #expect(controller.state == .blocked(permission: "Screen Recording"))
            try await Task.sleep(for: .milliseconds(2_100))
            #expect(controller.state == .blocked(permission: "Screen Recording"), "Old Ready dismissal must not clear a new warning")
        }
    }

    @Test("Owned startup and teardown deadlines retain physical ownership", arguments: [false, true])
    func ownedDeadlineRetainsResources(suspendStartup: Bool) async throws {
        try await withFeedbackStoreAsync { store, root in
            let mic = FeedbackMicrophoneFixture()
            let stopGate = DispatchSemaphore(value: 0)
            var resumeStartup: CheckedContinuation<Void, Never>?
            var installed: FeedbackCaptureAttempt?
            if !suspendStartup { mic.stopAction = { stopGate.wait() } }
            defer { stopGate.signal(); resumeStartup?.resume() }
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: mic)
                    installed = attempt
                    if suspendStartup { await withCheckedContinuation { resumeStartup = $0 } }
                }, startupTimeout: .milliseconds(30), observeSystem: false, waiterTimeout: .milliseconds(40))
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { installed != nil && (suspendStartup || controller.state?.isRecording == true) }
            let id = try #require(installed?.snapshot()?.id)
            if suspendStartup { try await waitUntil { controller.errorMessage == "Startup timed out" } }
            let began = ContinuousClock.now
            #expect(!(await controller.finishAndReleaseMicrophone()))
            #expect(!(await controller.shutdown()))
            #expect(began.duration(to: .now) < .seconds(1))
            #expect(controller.ownsMicrophone && controller.hasAttempt)
            #expect(!controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: id, path: "unfinished.json").path))
            #expect(throws: (any Error).self) { try controller.store?.delete(id: id) }
            if suspendStartup { resumeStartup?.resume(); resumeStartup = nil }
            else { stopGate.signal() }
            try await waitUntil { !controller.hasAttempt }
            #expect(!controller.ownsMicrophone)
            #expect(mic.starts == (suspendStartup ? 0 : 1))
            #expect(mic.stops == 1)
        }
    }

    @Test(arguments: [false, true])
    func processingDeadlineKeepsJournalAndLateCompletionPreservesNewWarning(recover: Bool) async throws {
        try await withFeedbackStoreAsync { store, root in
            var resume: CheckedContinuation<Void, Never>?
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: FeedbackMicrophoneFixture())
                }, observeSystem: false, waiterTimeout: .seconds(1))
            controller.finalizer.stages = [.init(name: .render, run: { _, _ in
                await withCheckedContinuation { resume = $0 }
            })]
            let recovery: Task<Void, Never>?
            if recover {
                let manifest = try store.begin(target: feedbackTarget())
                try WavWriter.writeWAV(samples: Array(repeating: Float(0), count: 1600),
                    to: store.mediaURL(id: manifest.id, path: "narration.wav"))
                store.release(id: manifest.id)
                recovery = Task { await controller.recover() }
            } else {
                recovery = nil
                #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
                try await waitUntil { controller.state?.isRecording == true }
                #expect(await controller.finishAndReleaseMicrophone())
            }
            try await waitUntil { resume != nil }
            if !recover {
                let processingPresentation = controller.presentationID
                let processingID = controller.presentedCaptureID
                var notice: FeedbackCapturePillState?
                controller.onStateChanged = { notice = $0 }
                #expect(!controller.start(permissions: granted, busyActivity: nil, device: { nil }))
                #expect(notice == .busy(activity: "Wait for feedback processing"))
                #expect(controller.state == .processing)
                #expect(controller.presentationID == processingPresentation && controller.presentedCaptureID == processingID)
            }
            #expect(!(await controller.shutdown()))
            #expect(!controller.ownsMicrophone && controller.hasAttempt == !recover)
            let id = try #require(recover ? controller.records.first?.id : controller.presentedCaptureID)
            if !recover {
                let pendingFinalization = FeedbackCapturePillState.failed(stage: "Media finalization",
                    message: "Finalization is still pending", retainedMedia: true)
                try await waitUntil(description: "pending finalization warning") { controller.state == pendingFinalization }
            }
            #expect(throws: (any Error).self) { try controller.store?.delete(id: id) }
            let denied = InteractionPermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true, screenRecording: false)
            #expect(!controller.start(permissions: denied, busyActivity: nil, device: { nil }))
            resume?.resume()
            await recovery?.value
            try await waitUntil { !controller.hasAttempt }
            #expect(controller.state == .blocked(permission: "Screen Recording"))
        }
    }

    @Test func meetingBusyShortcutPreservesPendingCompletionNotice() async throws {
        try await withFeedbackStoreAsync { _, root in
            var resumeRender: CheckedContinuation<Void, Never>?
            let mic = FeedbackMicrophoneFixture()
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    mic.startFrame = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time())
                    try attempt.install(device: device, microphone: mic)
                    let video = try #require(attempt.video)
                    try await Task.detached { try await Self.startVideoFixture(video, at: mic.startFrame) }.value
                }, observeSystem: false)
            controller.finalizer.stages = [.init(name: .render, run: { _, _ in
                await withCheckedContinuation { resumeRender = $0 }
            })]
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil(description: "recording state") { controller.state?.isRecording == true }
            #expect(await controller.finishAndReleaseMicrophone())
            try await waitUntil(description: "render stage entry") { resumeRender != nil }
            let pendingPresentation = controller.presentationID
            let pendingCaptureID = controller.presentedCaptureID
            var notice: FeedbackCapturePillState?
            controller.onStateChanged = { notice = $0 }

            #expect(!controller.start(permissions: granted, busyActivity: "Stop the meeting", device: { nil }))
            #expect(notice == .busy(activity: "Wait for feedback processing"))
            #expect(controller.state == .processing)
            #expect(controller.presentationID == pendingPresentation)
            #expect(controller.presentedCaptureID == pendingCaptureID)

            resumeRender?.resume()
            try await waitUntil(description: "finalization completion") { !controller.hasAttempt }
            #expect(controller.state == .ready)
            #expect(controller.presentedCaptureID == pendingCaptureID)
            await controller.shutdown()
        }
    }

    @Test func damagedInactiveCaptureCanBeDeletedFromWindow() async throws {
        try await withFeedbackStoreAsync { store, root in
            let damaged = try store.begin(target: feedbackTarget())
            store.release(id: damaged.id)
            try FileManager.default.removeItem(at: try store.mediaURL(id: damaged.id, path: "unfinished.json"))
            #expect(throws: (any Error).self) { try store.manifest(id: damaged.id) }

            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                observeSystem: false)
            #expect(await controller.reload(requestedID: damaged.id))

            _ = NSApplication.shared
            let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(attribute)
            NSApp.accessibilitySetValue(true, forAttribute: attribute)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
            let panel = FeedbackCapturePillTests.HiddenPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.borderless], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: FeedbackCaptureView(controller: controller, selectedID: damaged.id))
            panel.contentView = hosting
            defer { panel.contentView = nil; panel.close() }

            let fixture = FeedbackCapturePillTests()
            try await waitUntil(description: "Delete enabled for the damaged inactive capture") {
                fixture.accessibilityElements(hosting).contains {
                    $0.accessibilityLabel() == "Delete…" && $0.isAccessibilityEnabled()
                }
            }
            try await controller.delete(id: damaged.id)
            #expect(try store.get(id: damaged.id) == nil)
            await controller.shutdown()
        }
    }

    @Test func failedRecoveryRefreshesDeleteAvailabilityForUnchangedProcessingRow() async throws {
        try await withFeedbackStoreAsync { _, root in
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"),
                supportDirectory: root, observeSystem: false)
            let store = try #require(controller.store)
            var interrupted = try store.begin(target: feedbackTarget())
            interrupted.state = .processing
            try store.checkpoint(interrupted)
            try store.save(interrupted)
            #expect(store.isActive(id: interrupted.id))
            #expect(await controller.reload(requestedID: interrupted.id))

            _ = NSApplication.shared
            let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(attribute)
            NSApp.accessibilitySetValue(true, forAttribute: attribute)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
            let panel = FeedbackCapturePillTests.HiddenPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.borderless], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: FeedbackCaptureView(controller: controller, selectedID: interrupted.id))
            panel.contentView = hosting
            defer { panel.contentView = nil; panel.close(); store.release(id: interrupted.id) }

            let fixture = FeedbackCapturePillTests()
            try await waitUntil(description: "processing detail loads while recovery owns the capture") {
                let elements = fixture.accessibilityElements(hosting)
                guard let delete = elements.first(where: { $0.accessibilityLabel() == "Delete…" }) else { return false }
                return !delete.isAccessibilityEnabled()
                    && !elements.contains { $0.accessibilityRole() == .progressIndicator || $0.accessibilityRole() == .busyIndicator }
            }
            #expect(store.isActive(id: interrupted.id))

            try Data("not json".utf8).write(to: try store.mediaURL(id: interrupted.id, path: "unfinished.json"))
            store.release(id: interrupted.id)
            await controller.recover()

            #expect(!store.isActive(id: interrupted.id))
            #expect(!controller.hasAttempt)
            #expect(controller.records.first { $0.id == interrupted.id }?.state == .processing)
            try await waitUntil(description: "Delete becomes available after failed recovery") {
                fixture.accessibilityElements(hosting).contains {
                    $0.accessibilityLabel() == "Delete…" && $0.isAccessibilityEnabled()
                }
            }
            await controller.shutdown()
        }
    }

    @Test func partialRecoveryShowsHealthyCaptureAlongsideFailure() async throws {
        try await withFeedbackStoreAsync { store, root in
            let healthy = try store.begin(target: feedbackTarget())
            try WavWriter.writeWAV(samples: [Float](repeating: 0, count: 1600),
                to: store.mediaURL(id: healthy.id, path: "narration.wav"))
            store.release(id: healthy.id)

            let damaged = try store.begin(target: feedbackTarget())
            store.release(id: damaged.id)
            try Data("not json".utf8).write(to: store.mediaURL(id: damaged.id, path: "unfinished.json"))

            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"),
                supportDirectory: root, observeSystem: false)
            await controller.recover()

            #expect(controller.records.contains { $0.id == healthy.id && $0.state == .recovered })
            #expect(controller.presentedCaptureID == healthy.id)
            #expect(controller.state == .recovered)
            #expect(controller.errorMessage != nil)
        }
    }

    @Test func temporaryMicrophoneCleanupIsIdentityScoped() async throws {
        try await withFeedbackStoreAsync { store, root in
            let a = FeedbackCaptureAttempt.temporaryDirectoryNames(identity: "MuesliDevA")
            let b = FeedbackCaptureAttempt.temporaryDirectoryNames(identity: "MuesliDevB")
            #expect(a.count == 2 && Set(a).isDisjoint(with: b))
            #expect(!a.contains("muesli-feedback-mic"))
            let mic = FeedbackMicrophoneFixture()
            mic.temporaryURL = root.appendingPathComponent(a[0]).appendingPathComponent("input.wav")
            try FileManager.default.createDirectory(at: mic.temporaryURL!.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: mic.temporaryURL!)
            let other = root.appendingPathComponent(b[0])
            try Data([2]).write(to: other)
            let attempt = FeedbackCaptureAttempt(target: feedbackTarget(), store: store)
            try attempt.install(device: nil, microphone: mic)
            try await attempt.startMicrophone(); attempt.finishAdmission()
            await attempt.stopMicrophone(); attempt.finishAudio(); await attempt.finishVideo()
            #expect(!FileManager.default.fileExists(atPath: mic.temporaryURL!.path))
            #expect(try Data(contentsOf: other) == Data([2]))
            if let id = attempt.snapshot()?.id { store.release(id: id) }
        }
    }

    @Test func permissionDenialAndBusyCreateNothing() async throws {
        try await withFeedbackStoreAsync { store, root in
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: { Issue.record("Denied admission read the display"); return nil }, observeSystem: false)
            for (snapshot, permission) in [
                (InteractionPermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true, screenRecording: false), "Screen Recording"),
                (InteractionPermissionSnapshot(microphone: false, accessibility: true, inputMonitoring: true, screenRecording: true), "Microphone"),
                (InteractionPermissionSnapshot(microphone: true, accessibility: false, inputMonitoring: true, screenRecording: true), "Accessibility"),
                (InteractionPermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: false, screenRecording: true), "Input Monitoring")
            ] {
                #expect(!controller.start(permissions: snapshot, busyActivity: nil, device: { Issue.record("Denied admission selected device"); return nil }))
                #expect(controller.state == .blocked(permission: permission))
                #expect(!controller.ownsMicrophone)
            }
            #expect(!controller.start(permissions: granted, busyActivity: "Stop the meeting", device: { Issue.record("Busy selected device"); return nil }))
            #expect(controller.state == .busy(activity: "Stop the meeting"))
            let records = try store.list()
            #expect(records.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.root.path))
        }
    }
    @Test func teardownKeepsOwnershipAndMeetingHandoffDoesNotWaitForStages() async throws {
        try await withFeedbackStoreAsync { store, root in
            let mic = FeedbackMicrophoneFixture()
            let stopGate = DispatchSemaphore(value: 0)
            defer { stopGate.signal() }
            let stopping = NSLock()
            var stopEntered = false
            mic.stopAction = { stopping.withLock { stopEntered = true }; stopGate.wait() }
            var stageEntered = false
            var resumeStage: CheckedContinuation<Void, Never>?
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: mic)
                }, observeSystem: false)
            controller.finalizer.stages = [.init(name: .transcribe, run: { _, _ in
                await withCheckedContinuation { resumeStage = $0; stageEntered = true }
            })]
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { 123 }))
            try await waitUntil { !(controller.state == .preparing) }
            #expect(mic.preferredInputDeviceID == 123)
            controller.finish()
            try await waitUntil { !(!stopping.withLock({ stopEntered })) }
            #expect(controller.ownsMicrophone)
            #expect(controller.state == .processing)
            stopGate.signal()
            await controller.finishAndReleaseMicrophone()
            #expect(!controller.ownsMicrophone)
            try await waitUntil { !(!stageEntered) }
            #expect(controller.hasAttempt)
            #expect(try store.list().first?.state == .processing)
            resumeStage?.resume()
            await controller.shutdown()
            let id = try #require(controller.latestID)
            let result = try store.manifest(id: id)
            #expect(result.audio == "narration.wav")
            #expect(result.state == .ready)
            #expect(mic.starts == 1 && mic.stops == 1)
        }
    }
    @Test func geometryAndDiscardUseNormalStop() async throws {
        try await withFeedbackStoreAsync { store, root in
            let mic = FeedbackMicrophoneFixture()
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: mic)
                }, observeSystem: false)
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { !(controller.state == .preparing) }
            controller.discard()
            #expect(controller.state?.isRecording == true)
            controller.discard()
            await controller.shutdown()
            #expect(!controller.ownsMicrophone)
            #expect(mic.stops == 1)
            #expect(try store.list().isEmpty)
            #expect(controller.latestID == nil)
        }
        let target = feedbackTarget(), start = Date(timeIntervalSince1970: 1000)
        #expect(!FeedbackCaptureAdmission.mustFinish(start: start, now: start.addingTimeInterval(599), original: target, current: target))
        #expect(FeedbackCaptureAdmission.mustFinish(start: start, now: start, original: target, current: nil))
        let changed = FeedbackCaptureTarget(displayId: target.displayId, frame: .init(x: 0, y: 0, width: 1280, height: 720, scale: 1), appName: target.appName)
        #expect(FeedbackCaptureAdmission.mustFinish(start: start, now: start, original: target, current: changed))
    }
    @Test("Finish and meeting handoff retain captured audio delivered by microphone stop", arguments: [false, true])
    func finishDrainsCapturedNarration(meetingHandoff: Bool) async throws {
        try await withFeedbackStoreAsync { store, root in
            let mic = FeedbackMicrophoneFixture()
            mic.stopAction = { [weak mic] in
                mic?.onCapturedAudio?(.init(samples: [Int16](repeating: 1234, count: 4096), startFrame: 17_600, admitted: true))
                mic?.onCapturedAudio?(.init(samples: [9999], startFrame: 21_696, admitted: false))
            }
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                pointerTarget: feedbackTarget, currentDisplayTarget: { $0 }, prepareScreen: { attempt, device in
                    try attempt.install(device: device, microphone: mic)
                }, observeSystem: false)
            #expect(controller.start(permissions: granted, busyActivity: nil, device: { nil }))
            try await waitUntil { controller.state?.isRecording == true }
            if meetingHandoff { await controller.finishAndReleaseMicrophone() }
            else { controller.finish() }
            await controller.shutdown()
            let id = try #require(controller.latestID)
            let url = try store.mediaURL(id: id, path: "narration.wav")
            let samples = try WavReader.readFloatMonoWAV(from: url).samples
            #expect(samples.count == 5696)
            #expect(samples.suffix(4096).allSatisfy { abs($0 - Float(1234) / 32768) < 0.0001 })
            let saved = try Data(contentsOf: url)
            mic.onCapturedAudio?(.init(samples: [3000], startFrame: 21_696, admitted: true))
            #expect(try Data(contentsOf: url) == saved)
            #expect(!controller.ownsMicrophone && mic.stops == 1)
        }
    }

    @Test func finishBoundaryClipsCapturedTailAndClosesAfterDrain() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let mic = FeedbackMicrophoneFixture()
            let attempt = FeedbackCaptureAttempt(target: feedbackTarget(), store: store)
            try attempt.install(device: nil, microphone: mic)
            try await attempt.startMicrophone() // 1600 samples, host frames 16000..<17600.
            attempt.finishAdmission(through: 18_000)
            #expect(mic.shouldAdmitSamples?() == false)
            #expect(mic.nativeStopDrainRange?()?.upperBound == 18_000)
            mic.stopAction = {
                mic.onCapturedAudio?(.init(samples: [Int16](repeating: 1234, count: 4096), startFrame: 17_600, admitted: true))
                mic.onCapturedAudio?(.init(samples: [3000], startFrame: 17_900, admitted: false))
                mic.onCapturedAudio?(.init(samples: [3000], startFrame: 18_000, admitted: true))
            }
            await attempt.stopMicrophone()
            #expect(mic.lifecycle == ["stop", "cancel"], "Drain the recorder before releasing its native queue")
            #expect(mic.nativeStopDrainRange?() == nil)
            mic.onCapturedAudio?(.init(samples: [3000], startFrame: 17_999, admitted: true))
            attempt.finishAudio()
            let manifest = try #require(attempt.snapshot())
            let wav = try store.mediaURL(id: manifest.id, path: "narration.wav")
            let samples = try WavReader.readFloatMonoWAV(from: wav).samples
            #expect(manifest.durationMs == 125, "Duration uses the clipped admitted tail")
            #expect(samples.count == 2000)
            #expect(samples.suffix(400).allSatisfy { abs($0 - Float(1234) / 32768) < 0.0001 })
            store.release(id: manifest.id)
        }
    }

    @Test func quietSamplesAreAliveAndLateBlocksDoNotMutateJournal() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let attempt = FeedbackCaptureAttempt(target: feedbackTarget(), store: store, now: .distantPast)
            try attempt.install(device: nil, microphone: FeedbackMicrophoneFixture())
            let now = Date()
            attempt.receive(.init(samples: [0, 0, 0], startFrame: 1000, admitted: true), now: now)
            #expect(!attempt.meter(now: now.addingTimeInterval(0.599)).0)
            #expect(attempt.meter(now: now.addingTimeInterval(0.601)).0)
            #expect(attempt.meter(now: now).1 == -160)
            let before = attempt.snapshot()
            attempt.finishAdmission(through: 1_003)
            attempt.receive(.init(samples: [1, 2], startFrame: 2000, admitted: true))
            #expect(attempt.snapshot() == before)
            await attempt.stopMicrophone(); attempt.finishAudio()
            await attempt.finishVideo()
            if let id = before?.id { store.release(id: id) }
        }
    }
}

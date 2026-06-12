import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DictationAudioSessionManager")
struct DictationAudioSessionManagerTests {
    @Test("arm activates warm engine without starting capture")
    func armActivatesWarmEngineWithoutStartingCapture() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey")
        harness.wait()

        #expect(harness.recorder.activateCalls == 1)
        #expect(harness.recorder.prepareCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.ducking.beginCalls.isEmpty)
        #expect(harness.media.beginCalls.isEmpty)
    }

    @Test("arm does not block caller while route warmup is in flight")
    func armDoesNotBlockCallerWhileRouteWarmupIsInFlight() {
        let harness = Harness(routeKind: .speakerLike)
        harness.recorder.warmUpDelay = 0.2

        harness.manager.refreshRoute(intent: .idlePrewarm(.routeChange), canWarmUp: true)
        let startedAt = Date()
        harness.manager.arm(source: "hotkey")
        let elapsed = Date().timeIntervalSince(startedAt)
        harness.wait()

        #expect(elapsed < 0.05)
        #expect(harness.recorder.warmUpCalls == 1)
        #expect(harness.recorder.activateCalls == 1)
    }

    @Test("begin recording starts capture and reuses duplicate activation")
    func beginRecordingReusesDuplicateActivation() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey")
        harness.manager.beginRecording(mode: "prepare", duckingEnabled: true, mediaPauseEnabled: false)
        harness.manager.beginRecording(mode: "start", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.recorder.activateCalls == 2)
        #expect(harness.recorder.prepareCalls == 0)
        #expect(harness.recorder.startCalls == 1)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "activation_reused:start"
            }
            return false
        })
    }

    @Test("begin recording queued behind a failed arm does not restart failed session")
    func queuedBeginAfterFailedArmIsIgnored() {
        let harness = Harness(routeKind: .speakerLike)
        harness.recorder.activateError = NSError(domain: "DictationAudioSessionManagerTests", code: 1)

        harness.manager.arm(source: "hotkey")
        harness.manager.beginRecording(mode: "hold-start", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.recorder.activateCalls == 1)
        #expect(harness.recorder.prepareCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.events.contains { event in
            if case .failed = event {
                return true
            }
            return false
        })
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "stale_session_ignored:hold-start"
            }
            return false
        })
    }

    @Test("headphone route skips ducking and selects built-in mic app-locally")
    func headphoneRouteSkipsDucking() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.arm(source: "hotkey")
        harness.manager.beginRecording(mode: "prepare", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.ducking.beginCalls.allSatisfy { $0 == false })
        #expect(harness.recorder.explicitWarmupCalls == 1)
        #expect(harness.recorder.activateCalls == 0)
        #expect(harness.recorder.startCalls == 1)
        #expect(harness.recorder.preferredInputDeviceID == 82)
    }

    @Test("unknown route ducks to avoid speaker bleed during output transitions")
    func unknownRouteDucksDuringOutputTransitions() {
        let harness = Harness(routeKind: .unknown)

        harness.manager.arm(source: "hotkey")
        harness.manager.beginRecording(mode: "prepare", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.ducking.beginCalls.allSatisfy { $0 == true })
        #expect(harness.ducking.ensureCalls == 1)
        #expect(harness.recorder.startCalls == 1)
    }

    @Test("headphone arm refreshes preferred input without activating app-scoped mic")
    func headphoneArmRefreshesPreferredInputWithoutActivatingMic() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)
        harness.route.cachedPreferredInputDeviceID = nil

        harness.manager.arm(source: "hotkey")
        harness.wait()

        #expect(harness.route.preferredInputCalls == 1)
        #expect(harness.recorder.explicitWarmupCalls == 1)
        #expect(harness.recorder.activateCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.recorder.preferredInputDeviceID == 82)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "activation_async_prepare_started:hotkey:app_scoped_route"
            }
            return false
        })
    }

    @Test("begin recording refreshes preferred input when there was no arm")
    func beginRecordingRefreshesPreferredInput() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)
        harness.route.cachedPreferredInputDeviceID = nil

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: false, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.route.preferredInputCalls == 1)
        #expect(harness.recorder.activateCalls == 0)
        #expect(harness.recorder.preferredInputDeviceID == 82)
        #expect(harness.recorder.startCalls == 1)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "activation_prepare_skipped:toggle:app_scoped_route"
            }
            return false
        })
    }

    @Test("external session refreshes preferred input instead of using stale route cache")
    func externalSessionRefreshesPreferredInput() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)
        harness.route.cachedPreferredInputDeviceID = nil

        harness.manager.beginExternalSession(source: "nemotron-toggle", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.route.preferredInputCalls == 1)
        #expect(harness.ducking.beginCalls == [false])
    }

    @Test("begin recording refreshes route changed after arm")
    func beginRecordingRefreshesRouteChangedAfterArm() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.arm(source: "hotkey")
        harness.wait()
        harness.route.routeKind = .speakerLike
        harness.route.preferredInputDeviceID = nil
        harness.route.cachedPreferredInputDeviceID = nil

        harness.manager.beginRecording(mode: "prepare", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.route.preferredInputCalls == 2)
        #expect(harness.recorder.activateCalls == 1)
        #expect(harness.recorder.lastWarmInputDeviceID == nil)
        #expect(harness.recorder.preferredInputDeviceID == nil)
        #expect(harness.ducking.beginCalls == [true])
    }

    @Test("hold start refreshes route snapshot from arm path")
    func holdStartRefreshesRouteSnapshot() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.arm(source: "hotkey")
        harness.wait()
        harness.manager.beginRecording(mode: "hold-start", duckingEnabled: false, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.route.preferredInputCalls == 2)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name.hasPrefix("route_snapshot_refreshed:hold-start")
            }
            return false
        })
    }

    @Test("stop restores ducking and emits wav URL")
    func stopRestoresDuckingAndEmitsWavURL() {
        let harness = Harness(routeKind: .speakerLike)
        let wavURL = URL(fileURLWithPath: "/tmp/dictation.wav")
        harness.recorder.stopURL = wavURL

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()
        harness.manager.stop()
        harness.wait()

        #expect(harness.recorder.stopCalls == 1)
        #expect(!harness.recorder.keepsAudioGraphWarm)
        #expect(harness.ducking.restoreCalls == 1)
        #expect(harness.route.restoreCalls == 1)
        #expect(harness.events.contains { event in
            if case .stopped(_, let url) = event {
                return url == wavURL
            }
            return false
        })
        #expect(harness.events.contains { event in
            if case .audioRestored = event {
                return true
            }
            return false
        })
    }

    @Test("media resume waits until ducking restore completes")
    func mediaResumeWaitsUntilDuckingRestoreCompletes() {
        let harness = Harness(routeKind: .speakerLike)
        harness.ducking.completeRestoreImmediately = false

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: true)
        harness.wait()
        harness.manager.stop()
        harness.wait()

        #expect(harness.ducking.restoreCalls == 1)
        #expect(harness.media.restoreCalls == 0)
        #expect(harness.route.restoreCalls == 1)
        #expect(!harness.events.contains { event in
            if case .audioRestored = event {
                return true
            }
            return false
        })

        harness.ducking.finishPendingRestore()
        harness.wait()

        #expect(harness.media.restoreCalls == 1)
        #expect(harness.route.restoreCalls == 1)
        #expect(harness.events.contains { event in
            if case .audioRestored = event {
                return true
            }
            return false
        })
    }

    @Test("stop without active session does not emit stale stopped event")
    func stopWithoutActiveSessionDoesNotEmitStoppedEvent() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.stop()
        harness.wait()

        #expect(!harness.events.contains { event in
            if case .stopped = event {
                return true
            }
            return false
        })
    }

    @Test("speaker route refresh warms graph without opening mic")
    func speakerRouteRefreshWarmsGraphWithoutOpeningMic() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.refreshRoute(intent: .idlePrewarm(.routeChange), canWarmUp: true)
        harness.wait()

        #expect(harness.route.refreshCalls == 1)
        #expect(harness.recorder.coolDownCalls == 1)
        #expect(harness.recorder.warmUpCalls == 1)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.recorder.activateCalls == 0)
    }

    @Test("speaker route skips idle warmup when default input is not built in")
    func speakerRouteSkipsIdleWarmupWhenDefaultInputIsNotBuiltIn() {
        let harness = Harness(routeKind: .speakerLike)
        harness.route.systemDefaultInputIsBuiltIn = false

        harness.manager.refreshRoute(intent: .idlePrewarm(.routeChange), canWarmUp: true)
        harness.wait()

        #expect(harness.route.refreshCalls == 1)
        #expect(harness.recorder.coolDownCalls == 1)
        #expect(harness.recorder.warmUpCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.recorder.activateCalls == 0)
        #expect(!harness.recorder.keepsAudioGraphWarm)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "warmup_skipped:idle_routeChange:risky_default_input"
            }
            return false
        })
    }

    @Test("speaker route with non built-in default input does not arm-activate")
    func speakerRouteWithNonBuiltInDefaultInputDoesNotArmActivate() {
        let harness = Harness(routeKind: .speakerLike)
        harness.route.systemDefaultInputIsBuiltIn = false

        harness.manager.arm(source: "hotkey")
        harness.wait()

        #expect(harness.route.preferredInputCalls == 1)
        #expect(harness.recorder.activateCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(!harness.recorder.keepsAudioGraphWarm)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "activation_skipped:hotkey:risky_default_input"
            }
            return false
        })
    }

    @Test("explicit speaker recording with non built-in default input still starts cold")
    func explicitSpeakerRecordingWithNonBuiltInDefaultInputStillStartsCold() {
        let harness = Harness(routeKind: .speakerLike)
        harness.route.systemDefaultInputIsBuiltIn = false

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()

        #expect(harness.recorder.activateCalls == 0)
        #expect(harness.recorder.startCalls == 1)
        #expect(!harness.recorder.keepsAudioGraphWarm)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "activation_prepare_skipped:toggle:risky_default_input"
            }
            return false
        })
    }

    @Test("headphone route refresh skips idle mic warmup")
    func headphoneRouteRefreshSkipsIdleMicWarmup() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.refreshRoute(intent: .idlePrewarm(.routeChange), canWarmUp: true)
        harness.wait()

        #expect(harness.route.refreshCalls == 1)
        #expect(harness.recorder.coolDownCalls == 1)
        #expect(harness.recorder.warmUpCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.recorder.activateCalls == 0)
        #expect(!harness.recorder.keepsAudioGraphWarm)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "warmup_skipped:idle_routeChange:risky_route"
            }
            return false
        })
    }

    @Test("unknown route refresh skips idle mic warmup")
    func unknownRouteRefreshSkipsIdleMicWarmup() {
        let harness = Harness(routeKind: .unknown)

        harness.manager.refreshRoute(intent: .idlePrewarm(.routeChange), canWarmUp: true)
        harness.wait()

        #expect(harness.route.refreshCalls == 1)
        #expect(harness.recorder.coolDownCalls == 1)
        #expect(harness.recorder.warmUpCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.recorder.activateCalls == 0)
        #expect(!harness.recorder.keepsAudioGraphWarm)
    }

    @Test("headphone post-dictation refresh skips mic warmup")
    func headphonePostDictationRefreshSkipsMicWarmup() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.refreshRoute(intent: .postDictation(.transcriptionComplete), canWarmUp: true)
        harness.wait()

        #expect(harness.route.refreshCalls == 1)
        #expect(harness.recorder.coolDownCalls == 1)
        #expect(harness.recorder.warmUpCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.recorder.activateCalls == 0)
    }

    @Test("delayed route refresh does not arm-activate headphone route")
    func delayedRouteRefreshDoesNotArmActivateHeadphoneRoute() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.refreshRoute(intent: .idlePrewarm(.routeChange), delay: 0.2, canWarmUp: true)
        harness.manager.arm(source: "hotkey")
        harness.wait()

        #expect(harness.route.refreshCalls == 1)
        #expect(harness.recorder.activateCalls == 0)
        #expect(harness.recorder.warmUpCalls == 0)

        Thread.sleep(forTimeInterval: 0.25)
        harness.wait()

        #expect(harness.recorder.warmUpCalls == 0)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "route_refresh_cancelled:idle_routeChange"
            }
            return false
        })
    }

    @Test("recorder callbacks emit stream active, speech detected, and no audio timeout")
    func recorderCallbacksEmitAudioStateEvents() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: false, mediaPauseEnabled: false)
        harness.wait()
        let firstBufferAt = Date()
        harness.recorder.onFirstCapturedAudioBuffer?(firstBufferAt)
        harness.recorder.onFirstSpeechDetected?(firstBufferAt.addingTimeInterval(0.1))
        harness.recorder.onNoAudioTimeout?(firstBufferAt.addingTimeInterval(1.5))
        harness.wait()

        #expect(harness.events.contains { if case .streamActive = $0 { return true }; return false })
        #expect(harness.events.contains { if case .speechDetected = $0 { return true }; return false })
        #expect(harness.events.contains { if case .noAudioTimeout = $0 { return true }; return false })
    }

    @Test("no audio timeout before first buffer fails startup")
    func noAudioTimeoutBeforeFirstBufferFailsStartup() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: true)
        harness.wait()
        harness.recorder.onNoAudioTimeout?(Date().addingTimeInterval(1.5))
        harness.wait()

        #expect(harness.recorder.cancelCalls == 1)
        #expect(!harness.recorder.keepsAudioGraphWarm)
        #expect(harness.manager.currentState == .idle)
        #expect(harness.manager.currentSessionID == nil)
        #expect(harness.ducking.restoreCalls == 1)
        #expect(harness.media.restoreCalls == 1)
        #expect(harness.events.contains { if case .failed = $0 { return true }; return false })
        #expect(!harness.events.contains { if case .noAudioTimeout = $0 { return true }; return false })
    }

    @Test("no audio timeout on headphone preferred input does not retry system default")
    func noAudioTimeoutOnHeadphonePreferredInputDoesNotRetrySystemDefault() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: false)
        harness.wait()
        harness.recorder.onNoAudioTimeout?(Date().addingTimeInterval(1.5))
        harness.wait()

        #expect(harness.recorder.cancelCalls == 1)
        #expect(harness.recorder.startCalls == 1)
        #expect(harness.recorder.activateCalls == 0)
        #expect(harness.recorder.preferredInputDeviceID == nil)
        #expect(harness.manager.currentSessionID == nil)
        #expect(harness.events.contains { if case .failed = $0 { return true }; return false })
        #expect(!harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name.hasPrefix("input_fallback_begin:default")
            }
            return false
        })
    }

    @Test("recorder failure fails active session")
    func recorderFailureFailsActiveSession() {
        let harness = Harness(routeKind: .speakerLike)
        let error = NSError(domain: "DictationAudioSessionManagerTests", code: 42)

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: true)
        harness.wait()
        harness.recorder.onFirstCapturedAudioBuffer?(Date())
        harness.wait()
        harness.recorder.onRecordingFailed?(error, harness.recorder.activeRecordingID!)
        harness.wait()

        #expect(harness.recorder.cancelCalls == 1)
        #expect(harness.manager.currentState == .idle)
        #expect(harness.manager.currentSessionID == nil)
        #expect(harness.ducking.restoreCalls == 1)
        #expect(harness.media.restoreCalls == 1)
        #expect(harness.events.contains { if case .failed = $0 { return true }; return false })
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "recorder_failed"
            }
            return false
        })
    }

    @Test("stale recorder failure does not fail newer session")
    func staleRecorderFailureDoesNotFailNewerSession() {
        let harness = Harness(routeKind: .speakerLike)
        let error = NSError(domain: "DictationAudioSessionManagerTests", code: 43)

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: true)
        harness.wait()
        let staleRunID = harness.recorder.activeRecordingID!
        harness.manager.stop()
        harness.wait()

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true, mediaPauseEnabled: true)
        harness.wait()
        harness.recorder.onRecordingFailed?(error, staleRunID)
        harness.wait()

        #expect(harness.manager.currentState == .acquiringAudio(harness.manager.currentSessionID!))
        #expect(harness.recorder.cancelCalls == 0)
        #expect(!harness.events.contains { if case .failed = $0 { return true }; return false })
    }

    @Test("media pause is requested with current route after threshold")
    func mediaPauseRequestedWithCurrentRoute() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey")
        harness.wait()
        #expect(harness.media.beginCalls.isEmpty)

        harness.manager.beginRecording(mode: "hold-start", duckingEnabled: false, mediaPauseEnabled: true)
        harness.wait()

        #expect(harness.media.beginCalls == [
            .init(enabled: true, routeKind: .speakerLike),
        ])
    }

    @Test("begin recording after arm starts audio controls once")
    func beginRecordingAfterArmStartsAudioControlsOnce() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey")
        harness.wait()
        #expect(harness.media.beginCalls.isEmpty)
        #expect(harness.ducking.beginCalls.isEmpty)

        harness.manager.beginRecording(mode: "hold-start", duckingEnabled: true, mediaPauseEnabled: true)
        harness.wait()

        #expect(harness.media.beginCalls.count == 1)
        #expect(harness.ducking.beginCalls == [true])
        #expect(harness.ducking.ensureCalls == 1)
    }

    @Test("short armed tap does not pause or duck audio")
    func shortArmedTapDoesNotPauseOrDuckAudio() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey")
        harness.wait()
        harness.manager.cancel(reason: "short-tap")
        harness.wait()

        #expect(harness.media.beginCalls.isEmpty)
        #expect(harness.ducking.beginCalls.isEmpty)
        #expect(harness.media.restoreCalls == 1)
        #expect(harness.ducking.restoreCalls == 1)
    }

    @Test("stop restores media pause state")
    func stopRestoresMediaPauseState() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: false, mediaPauseEnabled: true)
        harness.wait()
        harness.manager.stop()
        harness.wait()

        #expect(harness.media.restoreCalls == 1)
    }

    @Test("cancel tears down warm recorder graph")
    func cancelTearsDownWarmRecorderGraph() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey")
        harness.wait()
        #expect(harness.recorder.keepsAudioGraphWarm)

        harness.manager.cancel(reason: "test")
        harness.wait()

        #expect(harness.recorder.cancelCalls == 1)
        #expect(!harness.recorder.keepsAudioGraphWarm)
    }
}

private final class Harness {
    let recorder = FakeDictationRecorder()
    let ducking = FakeDuckingManager()
    let media = FakeMediaPlaybackManager()
    let route: FakeDictationRoute
    let managerQueue = DispatchQueue(label: "test.dictation-session.manager")
    let eventQueue = DispatchQueue(label: "test.dictation-session.events")
    var events: [DictationAudioSessionEvent] = []
    lazy var manager: DictationAudioSessionManager = {
        let manager = DictationAudioSessionManager(
            recorder: recorder,
            duckingController: ducking,
            mediaPlaybackController: media,
            routingController: route,
            queue: managerQueue,
            eventQueue: eventQueue
        )
        manager.onEvent = { [weak self] event in
            self?.events.append(event)
        }
        return manager
    }()

    init(routeKind: AudioOutputRouteKind, preferredInputDeviceID: AudioObjectID? = nil) {
        self.route = FakeDictationRoute(
            routeKind: routeKind,
            preferredInputDeviceID: preferredInputDeviceID
        )
    }

    func wait() {
        managerQueue.sync {}
        eventQueue.sync {}
    }
}

private final class FakeDictationRecorder: DictationAudioRecording {
    var preferredInputDeviceID: AudioObjectID?
    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?
    var onRecordingFailed: ((Error, UUID) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?

    var prepareCalls = 0
    var explicitWarmupCalls = 0
    var warmUpCalls = 0
    var activateCalls = 0
    var coolDownCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var stopURL: URL?
    var lastWarmInputDeviceID: AudioObjectID?
    var activeRecordingID: UUID?
    var warmUpDelay: TimeInterval = 0
    var activateError: Error?

    func prepare() throws {
        prepareCalls += 1
    }

    func beginExplicitWarmup(preferredInputDeviceID: AudioObjectID?) {
        explicitWarmupCalls += 1
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        warmUpCalls += 1
        if warmUpDelay > 0 {
            Thread.sleep(forTimeInterval: warmUpDelay)
        }
        lastWarmInputDeviceID = preferredInputDeviceID
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        activateCalls += 1
        if let activateError {
            throw activateError
        }
        lastWarmInputDeviceID = preferredInputDeviceID
    }

    func coolDown() {
        coolDownCalls += 1
    }

    func start() throws -> UUID {
        startCalls += 1
        let id = UUID()
        activeRecordingID = id
        return id
    }

    func stop() -> URL? {
        stopCalls += 1
        activeRecordingID = nil
        return stopURL
    }

    func cancel() {
        cancelCalls += 1
        activeRecordingID = nil
    }

    func currentPower() -> Float {
        -24
    }
}

private final class FakeDuckingManager: AudioDuckingManaging {
    var beginCalls: [Bool] = []
    var ensureCalls = 0
    var restoreCalls = 0
    var completeRestoreImmediately = true
    private var pendingRestoreCompletion: (() -> Void)?

    func beginDictationDucking(enabled: Bool) {
        beginCalls.append(enabled)
    }

    func ensureCurrentDefaultDucked() {
        ensureCalls += 1
    }

    func restoreDictationDucking(completion: (() -> Void)?) {
        restoreCalls += 1
        guard completeRestoreImmediately else {
            pendingRestoreCompletion = completion
            return
        }
        completion?()
    }

    func finishPendingRestore() {
        let completion = pendingRestoreCompletion
        pendingRestoreCompletion = nil
        completion?()
    }
}

private struct MediaPauseBeginCall: Equatable {
    let enabled: Bool
    let routeKind: AudioOutputRouteKind
}

private final class FakeMediaPlaybackManager: MediaPlaybackManaging {
    var beginCalls: [MediaPauseBeginCall] = []
    var restoreCalls = 0

    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind) {
        beginCalls.append(.init(enabled: enabled, routeKind: routeKind))
    }

    func restoreDictationMediaPause() {
        restoreCalls += 1
    }
}

private final class FakeDictationRoute: DictationAudioRouting {
    var onPreferredInputDeviceChanged: ((AudioObjectID?) -> Void)?
    var selectedInputDeviceUID: String?
    var routeKind: AudioOutputRouteKind
    var preferredInputDeviceID: AudioObjectID?
    var cachedPreferredInputDeviceID: AudioObjectID?
    var systemDefaultInputIsBuiltIn = true
    var refreshCalls = 0
    var restoreCalls = 0
    var preferredInputCalls = 0

    init(routeKind: AudioOutputRouteKind, preferredInputDeviceID: AudioObjectID?) {
        self.routeKind = routeKind
        self.preferredInputDeviceID = preferredInputDeviceID
        self.cachedPreferredInputDeviceID = preferredInputDeviceID
    }

    func refreshRouteCache() {
        refreshCalls += 1
    }

    func preferredInputDeviceIDForDictation() -> AudioObjectID? {
        preferredInputCalls += 1
        cachedPreferredInputDeviceID = preferredInputDeviceID
        return preferredInputDeviceID
    }

    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID? {
        cachedPreferredInputDeviceID
    }

    func availableInputDevices() -> [AudioInputDeviceInfo] {
        []
    }

    func isDefaultOutputHeadphoneLike() -> Bool {
        routeKind == .headphoneLike
    }

    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind {
        routeKind
    }

    func currentRouteDebugDescription() -> String {
        "output=\(routeKind.description) preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default") defaultInputBuiltIn=\(systemDefaultInputIsBuiltIn)"
    }

    func systemDefaultInputIsBuiltInForDictation() -> Bool {
        systemDefaultInputIsBuiltIn
    }

    func refreshRouteAfterDictationSession() {
        restoreCalls += 1
    }
}

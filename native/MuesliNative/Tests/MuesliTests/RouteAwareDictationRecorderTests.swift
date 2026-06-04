import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("RouteAwareDictationRecorder")
struct RouteAwareDictationRecorderTests {
    @Test("default input uses system default recorder")
    func defaultInputUsesSystemDefaultRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.activateWarmEngine(preferredInputDeviceID: nil)
        _ = try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(system.activateCalls == 1)
        #expect(system.startCalls == 1)
        #expect(appScoped.activateCalls == 0)
        #expect(appScoped.startCalls == 0)
    }

    @Test("preferred input uses app scoped recorder")
    func preferredInputUsesAppScopedRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.activateWarmEngine(preferredInputDeviceID: 82)
        _ = try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.activateCalls == 0)
        #expect(system.startCalls == 0)
        #expect(appScoped.activateCalls == 1)
        #expect(appScoped.startCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }

    @Test("preferred input start without pre-activation uses app scoped recorder")
    func preferredInputStartWithoutPreActivationUsesAppScopedRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        recorder.preferredInputDeviceID = 82
        _ = try recorder.start()

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.activateCalls == 0)
        #expect(system.startCalls == 0)
        #expect(appScoped.activateCalls == 0)
        #expect(appScoped.startCalls == 1)
        #expect(appScoped.preferredInputDeviceID == 82)
    }

    @Test("latency events are forwarded from active child recorder")
    func latencyEventsAreForwardedFromActiveChildRecorder() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)
        var events: [String] = []
        recorder.onLatencyEvent = { event, _ in
            events.append(event)
        }

        recorder.preferredInputDeviceID = 82
        _ = try recorder.start()
        appScoped.onLatencyEvent?("app_scoped_engine_start_end", Date())

        #expect(events == ["app_scoped_engine_start_end"])
    }

    @Test("switching recorder cancels inactive warmed graph")
    func switchingRecorderCancelsInactiveWarmedGraph() throws {
        let system = FakeRouteAwareChildRecorder()
        let appScoped = FakeRouteAwareChildRecorder()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: system, appScopedRecorder: appScoped)

        try recorder.warmUp(preferredInputDeviceID: nil)
        try recorder.activateWarmEngine(preferredInputDeviceID: 82)

        #expect(recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(system.warmUpCalls == 1)
        #expect(system.cancelCalls == 1)
        #expect(appScoped.activateCalls == 1)
    }
}

private final class FakeRouteAwareChildRecorder: DictationAudioRecording {
    var preferredInputDeviceID: AudioObjectID?
    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?
    var onRecordingFailed: ((Error, UUID) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?

    var warmUpCalls = 0
    var activateCalls = 0
    var startCalls = 0
    var cancelCalls = 0

    func prepare() throws {}

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        warmUpCalls += 1
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        activateCalls += 1
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    func coolDown() {}

    func start() throws -> UUID {
        startCalls += 1
        return UUID()
    }

    func stop() -> URL? {
        nil
    }

    func cancel() {
        cancelCalls += 1
    }

    func currentPower() -> Float {
        -160
    }
}

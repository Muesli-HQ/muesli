#if DEBUG
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation manual QA faults")
struct DictationDevFaultTests {
    @Test("environment activation requires Dev C and its dev telemetry channel")
    func scopedActivation() {
        let env = [DictationDevFaults.environmentKey: "mic-startup"]
        #expect(DictationDevFaults.fromProcess(environment: env, bundleID: "com.muesli.dev.c", telemetryChannel: "dev") != nil)
        for bundle in ["com.muesli.app", "com.muesli.dev", "com.muesli.dev.a", "com.muesli.dev.b"] {
            #expect(DictationDevFaults.fromProcess(environment: env, bundleID: bundle, telemetryChannel: "dev") == nil)
        }
        for channel in ["production", "preprod", "unconfigured"] {
            #expect(DictationDevFaults.fromProcess(environment: env, bundleID: "com.muesli.dev.c", telemetryChannel: channel) == nil)
        }
        #expect(DictationDevFaults.fromProcess(environment: [:], bundleID: "com.muesli.dev.c", telemetryChannel: "dev") == nil)
        #expect(DictationDevFaults.fromProcess(environment: [DictationDevFaults.environmentKey: "anything"],
            bundleID: "com.muesli.dev.c", telemetryChannel: "dev") == nil)
    }

    @Test("a fault is consumed only by its matching operation and only once")
    func oneShot() {
        var triggered: [DictationDevFaults.Fault] = []
        let faults = DictationDevFaults(.microphoneStartup) { triggered.append($0) }
        #expect(faults.skipsMicrophoneWarmup)
        #expect(!faults.consume(.streamingFinalization))
        #expect(faults.skipsMicrophoneWarmup)
        #expect(faults.consume(.microphoneStartup))
        #expect(!faults.skipsMicrophoneWarmup)
        #expect(!faults.consume(.microphoneStartup))
        #expect(triggered == [.microphoneStartup])
        #expect(DictationDevFaults.startupStall > DictationStartupWatchdog.defaultWarningDelay)
    }

    @Test("stream failure preserves exact partial text and leaves subsequent takes healthy")
    @MainActor
    func streamingFailure() throws {
        let faults = DictationDevFaults(.streamingFinalization)
        var snapshots = 0
        func partial() -> String { snapshots += 1; return " Draft e\u{301} தமிழ் 👩🏽‍💻 " }
        let failure = try #require(faults.streamingFailure(partialText: partial()))
        #expect(failure.reason == "dev_injected_finalization_failure")
        #expect(failure.partialText == " Draft e\u{301} தமிழ் 👩🏽‍💻 ")
        #expect(faults.streamingFailure(partialText: partial()) == nil)
        #expect(snapshots == 1)
    }
}
#endif

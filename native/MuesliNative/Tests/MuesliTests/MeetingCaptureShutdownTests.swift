import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting capture shutdown")
struct MeetingCaptureShutdownTests {
    @Test("system tap stops while microphone teardown is blocked")
    func systemStopDoesNotWaitForMicrophone() async {
        let microphoneEntered = DispatchSemaphore(value: 0)
        let systemStopped = DispatchSemaphore(value: 0)
        let microphoneURL = URL(fileURLWithPath: "/tmp/test-mic.wav")
        let systemURL = URL(fileURLWithPath: "/tmp/test-system.wav")
        let result = await MeetingCaptureShutdown.stop(
            microphone: {
                try? await MeetingCaptureLifecycle.onDriverQueue {
                    #expect(!Thread.isMainThread)
                    microphoneEntered.signal()
                    // Sequential teardown would hold the system tap behind this stop.
                    #expect(systemStopped.wait(timeout: .now() + 5) == .success)
                    return microphoneURL
                }
            },
            systemAudio: {
                try? await MeetingCaptureLifecycle.onDriverQueue {
                    #expect(!Thread.isMainThread)
                    #expect(microphoneEntered.wait(timeout: .now() + 5) == .success)
                    systemStopped.signal()
                    return systemURL
                }
            }
        )
        #expect(result.microphone == microphoneURL)
        #expect(result.systemAudio == systemURL)
    }

    @Test("missing microphone file does not discard system capture")
    func independentResults() async {
        let systemURL = URL(fileURLWithPath: "/tmp/test-system.wav")
        let result = await MeetingCaptureShutdown.stop(
            microphone: { nil }, systemAudio: { systemURL }
        )
        #expect(result.microphone == nil)
        #expect(result.systemAudio == systemURL)
    }
}

extension MeetingCaptureShutdownTests {
    @Test("deadline preserves completed track but holds capture ownership until driver returns")
    func deadlineDoesNotPretendDriverStopped() async {
        let release = DispatchSemaphore(value: 0)
        let systemCompleted = DispatchSemaphore(value: 0)
        let quiesced = DispatchSemaphore(value: 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = directory.appendingPathComponent("system.wav")
        let lateMicURL = directory.appendingPathComponent("mic.wav")
        try! Data([1]).write(to: systemURL)
        try! Data([2]).write(to: lateMicURL)
        let result = await MeetingCaptureShutdown.stop(
            timeout: 0.1,
            microphone: {
                try? await MeetingCaptureLifecycle.onDriverQueue {
                    #expect(release.wait(timeout: .now() + 5) == .success)
                    return lateMicURL as URL?
                }
            },
            systemAudio: { systemCompleted.signal(); return systemURL },
            onQuiesced: { quiesced.signal() }
        )
        #expect(systemCompleted.wait(timeout: .now()) == .success)
        #expect(result.timedOut)
        #expect(result.microphone == nil)
        #expect(result.systemAudio == systemURL)
        #expect(quiesced.wait(timeout: .now()) == .timedOut)
        release.signal()
        let didQuiesce = try? await MeetingCaptureLifecycle.onDriverQueue {
            quiesced.wait(timeout: .now() + 5) == .success
        }
        #expect(didQuiesce == true)
        #expect(!FileManager.default.fileExists(atPath: lateMicURL.path))
        #expect(FileManager.default.fileExists(atPath: systemURL.path))
        #expect(quiesced.wait(timeout: .now()) == .timedOut)
    }
}

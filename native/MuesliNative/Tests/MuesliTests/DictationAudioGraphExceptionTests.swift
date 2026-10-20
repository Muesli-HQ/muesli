import AudioGraphTestSupport
import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation audio graph exceptions")
struct DictationAudioGraphExceptionTests {
    // A regression must fail only the child, not abort the entire CI test runner.
    @Test("dictation fallback contains tap-install NSException and can retry")
    func tapInstallationFailure() async {
        await #expect(processExitsWith: .success) {
            try verifyStartupFailure("install")
        }
    }

    @Test("dictation contains input-read, prepare, and start NSExceptions")
    func otherStartupFailures() async {
        await #expect(processExitsWith: .success) {
            for operation in ["read", "prepare", "start"] {
                try verifyStartupFailure(operation)
            }
        }
    }

    @Test("startup cleanup contains stop and remove-tap NSExceptions")
    func cleanupFailures() async {
        await #expect(processExitsWith: .success) {
            try verifyStartupFailure("start", cleanupAlsoFails: true)
        }
    }
}

private func verifyStartupFailure(_ operation: String, cleanupAlsoFails: Bool = false) throws {
    let engine = MuesliFaultInjectingAudioEngine()
    engine.failingOperations = [operation] + (cleanupAlsoFails ? ["stop", "remove"] : [])
    let directory = "muesli-dictation-exception-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(directory)) }
    // Keep the production dictation default: recoversFromInputConfigurationChanges=false.
    let fallback = StreamingMicRecorder(directoryName: directory, makeEngine: { engine })
    let primary = FailingPrimaryRecorder()
    let recorder = FallbackStreamingDictationRecorder(primary: primary, fallback: fallback)

    let result = Result { try recorder.start() }
    guard case .failure(let error) = result else {
        Issue.record("Expected a bridged \(operation) failure")
        return
    }
    #expect(primary.startCalls == 1)
    #expect((error as NSError).domain == "MuesliAudioGraph")
    #expect(error.localizedDescription.contains("Injected microphone \(operation) failure"))
    #expect(engine.operations.contains(operation))
    #expect(!fallback.testing_hasActiveRecording)
    #expect(recorder.stop() == nil)
    if operation == "start" {
        #expect(engine.operations.contains("stop"))
        #expect(engine.operations.contains("remove"))
    }

    engine.failingOperations = []
    try recorder.start()
    #expect(fallback.testing_hasActiveRecording)
    // The hardware-free graph delivers no samples, so Stop discards its empty WAV.
    #expect(recorder.stop() == nil)
    #expect(!fallback.testing_hasActiveRecording)
}

private final class FailingPrimaryRecorder: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    var startCalls = 0
    func prepare() throws {}
    func start() throws {
        startCalls += 1
        throw NSError(domain: "ForcedAudioQueueFailure", code: 1)
    }
    func stop() -> URL? { nil }
    func cancel() {}
    func currentPower() -> Float { -160 }
}

import AudioGraphTestSupport
import AVFoundation
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

    @Test("failed Stop skips tap removal and replaces the uncertain graph")
    func failedStopReplacesGraph() async {
        await #expect(processExitsWith: .success) {
            try verifyStopCleanupFailure("stop")
            try verifyStopCleanupFailure("stop", cancel: true)
        }
    }

    @Test("failed tap removal replaces the graph before another recording")
    func failedTapRemovalReplacesGraph() async {
        await #expect(processExitsWith: .success) {
            try verifyStopCleanupFailure("remove")
            try verifyStopCleanupFailure("remove", cancel: true)
        }
    }

    @Test("configuration recovery observes the replacement after failed cleanup")
    func replacementKeepsConfigurationObservation() async {
        await #expect(processExitsWith: .success) {
            try verifyConfigurationRecovery()
        }
    }
}

private func verifyConfigurationRecovery() throws {
    let failedEngine = MuesliFaultInjectingAudioEngine()
    let replacement = MuesliFaultInjectingAudioEngine()
    var creations = 0
    let directory = "muesli-dictation-exception-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(directory)) }
    let recorder = StreamingMicRecorder(directoryName: directory, observesInputConfigurationChanges: true, makeEngine: {
        creations += 1
        return creations == 1 ? failedEngine : replacement
    })
    defer { recorder.cancel() }
    recorder.configChangeSettleDelay = 0
    let restarted = DispatchSemaphore(value: 0)
    recorder.onLatencyEvent = { event, _ in
        if event == "engine_config_change_restart_end" { restarted.signal() }
    }
    try recorder.start()
    failedEngine.failingOperations = ["stop"]
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: failedEngine)
    #expect(restarted.wait(timeout: .now() + 3) == .success)
    #expect(creations == 2)
    #expect(!failedEngine.operations.contains("remove"))
    // A second event must be received from the replacement, not the retired graph.
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: replacement)
    #expect(restarted.wait(timeout: .now() + 3) == .success)
    #expect(replacement.operations.filter { $0 == "start" }.count == 2)
    #expect(creations == 2)
}

private func verifyStopCleanupFailure(_ operation: String, cancel: Bool = false) throws {
    let failedEngine = MuesliFaultInjectingAudioEngine()
    let replacement = MuesliFaultInjectingAudioEngine()
    var creations = 0
    let directory = "muesli-dictation-exception-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(directory)) }
    let recorder = StreamingMicRecorder(directoryName: directory, makeEngine: {
        creations += 1
        return creations == 1 ? failedEngine : replacement
    })
    defer { recorder.cancel() }
    try recorder.start()
    #expect(failedEngine.isRunning)
    #expect(failedEngine.hasInstalledTap)
    failedEngine.failingOperations = [operation]
    if cancel { recorder.cancel() } else { #expect(recorder.stop() == nil) }
    #expect(!recorder.testing_hasActiveRecording)
    #expect(failedEngine.hasInstalledTap)
    if operation == "stop" {
        #expect(failedEngine.isRunning)
        #expect(!failedEngine.operations.contains("remove"))
    } else {
        #expect(!failedEngine.isRunning)
        #expect(failedEngine.operations.contains("remove"))
    }

    try recorder.start()
    #expect(creations == 2)
    #expect(replacement.isRunning)
    #expect(replacement.hasInstalledTap)
    #expect(recorder.stop() == nil)
    #expect(!replacement.isRunning)
    #expect(!replacement.hasInstalledTap)
    // Healthy Stop retains its prepared graph for the next recording.
    try recorder.start()
    #expect(creations == 2)
}

private func verifyStartupFailure(_ operation: String, cleanupAlsoFails: Bool = false) throws {
    let engine = MuesliFaultInjectingAudioEngine()
    let replacement = MuesliFaultInjectingAudioEngine()
    var creations = 0
    engine.failingOperations = [operation] + (cleanupAlsoFails ? ["stop", "remove"] : [])
    let directory = "muesli-dictation-exception-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(directory)) }
    // Keep the production dictation default: recoversFromInputConfigurationChanges=false.
    let fallback = StreamingMicRecorder(directoryName: directory, makeEngine: {
        creations += 1
        return creations == 1 ? engine : replacement
    })
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
        #expect(engine.operations.contains("remove") == !cleanupAlsoFails)
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

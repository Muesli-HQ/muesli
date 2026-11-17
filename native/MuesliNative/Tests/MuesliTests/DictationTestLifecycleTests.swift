import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Dictation test lifecycle")
@MainActor
struct DictationTestLifecycleTests {
    @Test("history clearing reserves ownership, removes recovery files, and clears text asynchronously")
    func clearHistoryLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let date = Date()
        _ = try store.insertDictation(text: "Synthetic history", durationSeconds: 1, startedAt: date, endedAt: date)
        let source = directory.appendingPathComponent("synthetic.wav")
        try (WavWriter.header(dataSize: 4) + Data([0, 1, 128, 255])).write(to: source)
        let recoveries = DictationRecoveryStore(directory: directory.appendingPathComponent("Dictation Recovery"))
        let record = try recoveries.save(wavURL: source, startedAt: date, durationSeconds: 1,
            modelName: "Synthetic", failureMessage: "Synthetic failure")
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory,
            menuIcon: nil, appIcon: nil, bundlePath: nil), dictationStore: store,
            configStore: makeTestConfigStore(supportDirectory: directory))
        controller.appState.failedDictations = [record]
        let clearing = try #require(controller.clearDictationHistory())
        #expect(controller.appState.activeAudioImportCount == 1)
        #expect(!controller.canPrepareComputerUseCommand)
        await clearing.value
        #expect(controller.appState.activeAudioImportCount == 0)
        #expect(controller.appState.failedDictations.isEmpty)
        #expect(try store.recentDictations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: recoveries.directory.path))
    }

    @Test("a delayed microphone failure cannot reset a newer take after its microphone has stopped")
    func staleFailureCannotResetFinalizingTake() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory,
            menuIcon: nil, appIcon: nil, bundlePath: nil), dictationStore: store,
            configStore: makeTestConfigStore(supportDirectory: directory))
        let old = UUID(), newer = UUID()
        controller.setDictationAudioSessionForTesting(newer)
        controller.appState.dictationState = .transcribing
        controller.receiveDictationAudioEventForTesting(.failed(old,
            error: NSError(domain: "SyntheticStartup", code: 1)))
        #expect(controller.appState.dictationState == .transcribing)
        // Explicit cancellation retires ownership even before queued callbacks arrive.
        controller.setDictationAudioSessionForTesting(nil)
        controller.receiveDictationAudioEventForTesting(.failed(newer,
            error: NSError(domain: "SyntheticStartup", code: 1)))
        #expect(controller.appState.dictationState == .transcribing)
    }

    @Test("hotkey release transitions test feedback and cleanup clears every callback")
    func stopAndCleanupLifecycle() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-dictation-test-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let store = DictationStore(databaseURL: supportDirectory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: supportDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: makeTestConfigStore(supportDirectory: supportDirectory)
        )

        #expect(!controller.stopDictationTestRecordingFeedback())

        var stopCallbackCount = 0
        controller.dictationTestCallback = { _ in }
        controller.dictationTestFailureCallback = { _ in }
        controller.dictationTestRecordingStarted = {}
        controller.dictationTestRecordingStopped = { stopCallbackCount += 1 }
        controller.dictationTestBackend = .onboardingDefault
        controller.dictationTestCohereLanguage = .defaultLanguage

        #expect(controller.isDictationTestMode)
        #expect(controller.stopDictationTestRecordingFeedback())
        #expect(stopCallbackCount == 1)
        #expect(controller.appState.dictationState == .idle)

        controller.clearDictationTestLifecycle()

        #expect(!controller.isDictationTestMode)
        #expect(controller.dictationTestCallback == nil)
        #expect(controller.dictationTestFailureCallback == nil)
        #expect(controller.dictationTestRecordingStarted == nil)
        #expect(controller.dictationTestRecordingStopped == nil)
        #expect(controller.dictationTestBackend == nil)
        #expect(controller.dictationTestCohereLanguage == nil)
    }
}

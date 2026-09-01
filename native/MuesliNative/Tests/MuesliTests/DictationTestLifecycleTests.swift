import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Dictation test lifecycle")
@MainActor
struct DictationTestLifecycleTests {
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
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )

        #expect(!controller.transitionStoppedDictationTestToTranscribing())

        var stopCallbackCount = 0
        controller.dictationTestCallback = { _ in }
        controller.dictationTestFailureCallback = { _ in }
        controller.dictationTestRecordingStarted = {}
        controller.dictationTestRecordingStopped = { stopCallbackCount += 1 }
        controller.dictationTestBackend = .onboardingDefault
        controller.dictationTestCohereLanguage = .defaultLanguage

        #expect(controller.isDictationTestMode)
        #expect(controller.transitionStoppedDictationTestToTranscribing())
        #expect(stopCallbackCount == 1)
        #expect(controller.appState.dictationState == .transcribing)

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

import Foundation
import Observation
import Testing
import MuesliCore
@testable import MuesliNativeApp

private final class ObservationInvalidationFlag: @unchecked Sendable {
    var fired = false
}

@Suite("Meeting transcription selection observation")
@MainActor
struct MeetingTranscriptionSelectionObservationTests {
    @Test("refreshing an unchanged meeting transcription selection does not invalidate observers")
    func unchangedRefreshDoesNotInvalidateAppState() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-selection-observation-\(UUID().uuidString)", isDirectory: true)
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

        // The first refresh may legitimately settle the selection.
        controller.refreshMeetingTranscriptionSelectionForAvailability()

        // Settings calls this from onAppear. An unchanged refresh must not notify
        // observers, or SwiftUI keeps re-rendering the dashboard (#632).
        let flag = ObservationInvalidationFlag()
        withObservationTracking {
            _ = controller.appState.config
            _ = controller.appState.selectedMeetingTranscriptionBackend
        } onChange: {
            flag.fired = true
        }

        controller.refreshMeetingTranscriptionSelectionForAvailability()

        #expect(!flag.fired)
    }
}

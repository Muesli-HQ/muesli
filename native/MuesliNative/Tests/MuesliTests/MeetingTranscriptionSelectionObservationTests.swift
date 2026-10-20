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
    @Test(
        "refreshing an unchanged meeting transcription selection does not invalidate observers",
        arguments: [false, true]
    )
    func unchangedRefreshDoesNotInvalidateAppState(hasDownloadedMeetingModel: Bool) throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-meeting-selection-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let store = DictationStore(databaseURL: supportDirectory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        // Inject availability so both normalizer branches run whatever models this
        // machine has installed: no meeting model (fallback) and a resolved one.
        let downloaded: [BackendOption] = hasDownloadedMeetingModel ? [.whisperSmall] : []
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: supportDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory),
            downloadedBackendOptions: { downloaded }
        )

        // The first refresh may legitimately settle the selection.
        let resolved = controller.refreshMeetingTranscriptionSelectionForAvailability()
        if hasDownloadedMeetingModel {
            #expect(resolved == .whisperSmall)
        } else {
            #expect(resolved == nil)
        }

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

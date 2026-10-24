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
    @Test("meeting fallback uses the supplied OS even when both saved models are unsupported", arguments: [14, 15])
    func meetingFallbackUsesInjectedOS(_ major: Int) {
        let version = OperatingSystemVersion(majorVersion: major, minorVersion: 8, patchVersion: 0)
        let expected: BackendOption = major == 14 ? .parakeetUnified : .parakeetRedux
        for configured in [BackendOption.parakeetRedux, nil] {
            let fallback = MuesliController.fallbackMeetingTranscriptionBackend(
                configured: configured,
                dictationBackend: .parakeetRedux,
                currentOSVersion: version
            )
            #expect(fallback == expected)
            #expect(fallback.isCompatible(currentOSVersion: version))
        }
    }

    @Test("startup and config restore reject unsupported Redux even when cached", arguments: [14, 15], [false, true])
    func restoredReduxSelection(major: Int, hasSupportedDownload: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-redux-os-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let configStore = ConfigStore(supportDirectory: directory)
        var initial = AppConfig()
        initial.sttBackend = BackendOption.parakeetRedux.backend
        initial.sttModel = BackendOption.parakeetRedux.model
        initial.meetingTranscriptionBackend = initial.sttBackend
        initial.meetingTranscriptionModel = initial.sttModel
        configStore.save(initial)
        let version = OperatingSystemVersion(majorVersion: major, minorVersion: 8, patchVersion: 0)
        let downloaded: [BackendOption] = hasSupportedDownload ? [.parakeetRedux, .parakeetEnglish] : [.parakeetRedux]
        let expected: BackendOption = major >= 15 ? .parakeetRedux : (hasSupportedDownload ? .parakeetEnglish : .whisper)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store,
            configStore: configStore,
            downloadedBackendOptions: { downloaded },
            modelOSVersion: version
        )

        func verifySelection() {
            #expect(controller.selectedBackend == expected)
            #expect(controller.selectedMeetingTranscriptionBackend == expected)
            #expect(controller.config.sttModel == expected.model)
            #expect(controller.config.meetingTranscriptionModel == expected.model)
            let saved = configStore.load()
            #expect(saved.sttModel == expected.model)
            #expect(saved.meetingTranscriptionModel == expected.model)
        }
        verifySelection()
        controller.updateConfig {
            $0.sttBackend = BackendOption.parakeetRedux.backend
            $0.sttModel = BackendOption.parakeetRedux.model
            $0.meetingTranscriptionBackend = $0.sttBackend
            $0.meetingTranscriptionModel = $0.sttModel
        }
        verifySelection()
        #expect(controller.appState.selectedBackend == expected)
        #expect(controller.appState.selectedMeetingTranscriptionBackend == expected)
        if major == 14 {
            controller.selectBackend(.parakeetRedux)
            controller.selectMeetingTranscriptionBackend(.parakeetRedux, requireDownloaded: false)
            verifySelection()
        }
        controller.refreshMeetingTranscriptionSelectionForAvailability()
        verifySelection()
    }

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

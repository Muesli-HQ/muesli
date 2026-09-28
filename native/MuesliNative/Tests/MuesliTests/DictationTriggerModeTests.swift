import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Dictation trigger mode")
@MainActor
struct DictationTriggerModeTests {
    private func makeController() throws -> (MuesliController, URL) {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-dictation-trigger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

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
        return (controller, supportDirectory)
    }

    @Test("hybrid disables the dictation double-press while Quill and CUA stay hands-free")
    func hybridDisablesDictationDoublePressOnly() throws {
        let (controller, supportDirectory) = try makeController()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        controller.updateConfig {
            $0.dictationTriggerMode = .holdToRecord
            $0.enableDoubleTapDictation = true
        }

        #expect(controller.hotkeyMonitor.doubleTapEnabled)
        #expect(!controller.hotkeyMonitor.hybridTapEnabled)

        controller.updateConfig { $0.dictationTriggerMode = .hybrid }

        #expect(!controller.hotkeyMonitor.doubleTapEnabled)
        #expect(controller.hotkeyMonitor.hybridTapEnabled)
        #expect(controller.config.enableDoubleTapDictation)
        #expect(controller.quilHotkeyMonitor.doubleTapEnabled)
        #expect(controller.computerUseHotkeyMonitor.doubleTapEnabled)

        controller.updateConfig { $0.enableDoubleTapDictation = false }

        #expect(controller.hotkeyMonitor.hybridTapEnabled)
        #expect(!controller.quilHotkeyMonitor.doubleTapEnabled)
        #expect(!controller.computerUseHotkeyMonitor.doubleTapEnabled)
    }

    @Test("a rejected hybrid toggle start rolls the monitor and dictation state back")
    func rejectedHybridToggleStartRollsBack() throws {
        let (controller, supportDirectory) = try makeController()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        controller.configureDictationHotkeyCallbacks()
        controller.updateConfig { $0.dictationTriggerMode = .hybrid }

        #expect(controller.dictationBackendReadiness == .preparing)
        #expect(controller.hotkeyMonitor.hybridTapEnabled)

        let keyCode = controller.hotkeyMonitor.targetKeyCode
        controller.hotkeyMonitor.handleFlagsChanged(keyCode: keyCode, flags: .command)
        controller.hotkeyMonitor.handleFlagsChanged(keyCode: keyCode, flags: [])

        #expect(!controller.hotkeyMonitor.isToggleRecording)
        #expect(controller.appState.dictationState == .idle)

        controller.hotkeyMonitor.handleFlagsChanged(keyCode: keyCode, flags: .command)
        controller.hotkeyMonitor.handleFlagsChanged(keyCode: keyCode, flags: [])

        #expect(!controller.hotkeyMonitor.isToggleRecording)
        #expect(controller.appState.dictationState == .idle)
    }

    @Test("restoring hotkey defaults returns the trigger mode to hold")
    func restoringDefaultsReturnsToHold() throws {
        let (controller, supportDirectory) = try makeController()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        controller.updateConfig { $0.dictationTriggerMode = .hybrid }
        #expect(controller.hotkeyMonitor.hybridTapEnabled)

        controller.resetShortcutDefaults()

        #expect(controller.config.dictationTriggerMode == .holdToRecord)
        #expect(!controller.hotkeyMonitor.hybridTapEnabled)
        #expect(controller.hotkeyMonitor.doubleTapEnabled)
    }
}

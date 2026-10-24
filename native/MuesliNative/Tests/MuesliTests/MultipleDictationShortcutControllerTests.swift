import Foundation
import AppKit
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Multiple dictation shortcuts")
@MainActor
struct MultipleDictationShortcutControllerTests {
    private func withController(_ body: (MuesliController, ConfigStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DictationStore(databaseURL: root.appendingPathComponent("test.db"))
        try database.migrateIfNeeded()
        let store = ConfigStore(supportDirectory: root)
        store.save(AppConfig())
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: root, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: database, configStore: store)
        try await body(controller, store)
    }

    @Test("Adding, removing, and resetting shortcuts persist the complete list")
    func persistence() async throws {
        try await withController { controller, store in
            let extra = HotkeyConfig.combination(modifiers: .control, keyCode: 2)
            #expect(controller.addAdditionalDictationHotkey(extra).didUpdate)
            #expect(controller.config.additionalDictationHotkeys == [extra])
            #expect(store.load().additionalDictationHotkeys == [extra])
            #expect(controller.removeAdditionalDictationHotkey(extra).didUpdate)
            #expect(controller.config.additionalDictationHotkeys.isEmpty)
            #expect(store.load().additionalDictationHotkeys.isEmpty)
            #expect(controller.addAdditionalDictationHotkey(extra).didUpdate)
            controller.resetShortcutDefaults()
            #expect(store.load().additionalDictationHotkeys.isEmpty)
        }
    }

    @Test("A duplicate or conflicting extra never replaces a saved shortcut")
    func conflicts() async throws {
        try await withController { controller, store in
            let extra = HotkeyConfig.combination(modifiers: .control, keyCode: 2)
            #expect(controller.addAdditionalDictationHotkey(extra).didUpdate)
            #expect(!controller.addAdditionalDictationHotkey(extra).didUpdate)
            #expect(!controller.addAdditionalDictationHotkey(controller.config.dictationHotkey).didUpdate)
            #expect(!controller.updateDictationHotkey(extra).didUpdate)
            #expect(store.load().additionalDictationHotkeys == [extra])
        }
    }

    @Test("Global toggle is available through an extra combination when primary is bare")
    func extraEnablesToggle() async throws {
        try await withController { controller, store in
            let extra = HotkeyConfig.combination(modifiers: .control, keyCode: 2)
            #expect(controller.addAdditionalDictationHotkey(extra).didUpdate)
            try controller.updateDictationCombinationActivation(.toggle)
            #expect(store.load().dictationCombinationActivation == .toggle)
            #expect(store.load().dictationHotkey == .default)
            #expect(controller.settingsDefinitions().first { $0.id == "dictation_activation" }?.availability("toggle") == nil)
            #expect(controller.removeAdditionalDictationHotkey(extra).didUpdate)
            #expect(store.load().dictationCombinationActivation == .pushToTalk)
        }
    }

    @Test("Other features and paste cannot take an additional dictation shortcut")
    func otherShortcutConflicts() async throws {
        try await withController { controller, store in
            let extra = HotkeyConfig.combination(modifiers: .control, keyCode: 2)
            #expect(controller.addAdditionalDictationHotkey(extra).didUpdate)
            #expect(!controller.updateComputerUseHotkey(extra).didUpdate)
            #expect(!controller.updateMeetingRecordingHotkey(extra).didUpdate)
            #expect(!controller.updateQuilHotkey(extra).didUpdate)
            let paste = try #require(PasteKeyChord(keyCode: 2, modifiers: .maskControl))
            #expect(controller.pasteShortcutConflict(paste))
            #expect(!controller.updatePasteShortcut(.custom(paste)).didUpdate)
            #expect(store.load().additionalDictationHotkeys == [extra])
        }
    }
}

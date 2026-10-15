import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Multiple dictation shortcut config")
struct MultipleDictationShortcutConfigTests {
    private let controlD = HotkeyConfig.combination(modifiers: .control, keyCode: 2)
    private let command1 = HotkeyConfig.combination(modifiers: .command, keyCode: 18)

    private func decode(_ fields: [String: Any]) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func object(_ hotkey: HotkeyConfig) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(hotkey))
    }

    @Test("legacy config and empty default retain the primary shortcut")
    func legacyAndDefault() throws {
        let legacy = try decode(["enable_push_to_talk": false])
        #expect(legacy.additionalDictationHotkeys.isEmpty)
        #expect(legacy.dictationHotkeys == [legacy.dictationHotkey])
        #expect(!legacy.hasDictationCombination)
        #expect(!legacy.enablePushToTalk)

        let fresh = AppConfig()
        #expect(fresh.additionalDictationHotkeys.isEmpty)
        #expect(fresh.dictationHotkeys == [fresh.dictationHotkey])
    }

    @Test("bare and combination extras round-trip in order")
    func roundTrip() throws {
        var config = AppConfig()
        config.additionalDictationHotkeys = [.quilDefault, controlD, command1]
        let data = try JSONEncoder().encode(config)
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((saved["additional_dictation_hotkeys"] as? [Any])?.count == 3)
        let restored = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(restored.additionalDictationHotkeys == config.additionalDictationHotkeys)
        #expect(restored.dictationHotkeys == [.default, .quilDefault, controlD, command1])
        #expect(restored.hasDictationCombination)
    }

    @Test("decoded extras keep the first non-overlapping shortcuts")
    func filtersConflicts() throws {
        let controlShiftD = HotkeyConfig.combination(modifiers: [.control, .shift], keyCode: 2)
        let rightControl = HotkeyConfig(keyCode: 62, label: "Right Ctrl")
        let config = try decode([
            "dictation_hotkey": try object(.default),
            "additional_dictation_hotkeys": try [
                object(.default), object(.quilDefault), object(.quilDefault),
                object(controlD), object(controlShiftD), object(rightControl), object(command1),
            ],
        ])
        #expect(config.additionalDictationHotkeys == [.quilDefault, controlD, command1])

        let bareFirst = try decode([
            "dictation_hotkey": try object(command1),
            "additional_dictation_hotkeys": try [object(rightControl), object(controlD)],
        ])
        #expect(bareFirst.additionalDictationHotkeys == [rightControl])

        let primaryChord = try decode([
            "dictation_hotkey": try object(controlD),
            "additional_dictation_hotkeys": try [object(rightControl), object(controlShiftD)],
        ])
        #expect(primaryChord.additionalDictationHotkeys.isEmpty)
    }

    @Test("invalid saved extras are skipped without losing other preferences")
    func filtersInvalid() throws {
        let invalid = HotkeyConfig.combination(modifiers: .shift, keyCode: 2)
        let incomplete = HotkeyConfig(keyCode: UInt16.max, label: "broken", combinationModifiers: nil, combinationKeyCode: 2)
        let config = try decode([
            "additional_dictation_hotkeys": try [object(invalid), object(incomplete), object(controlD)],
            "enable_push_to_talk": false,
        ])
        #expect(config.additionalDictationHotkeys == [controlD])
        #expect(!config.enablePushToTalk)
        let malformed = try decode(["additional_dictation_hotkeys": "bad", "enable_push_to_talk": false])
        #expect(malformed.additionalDictationHotkeys.isEmpty)
        #expect(!malformed.enablePushToTalk)
        let mixed = try decode([
            "additional_dictation_hotkeys": try [object(controlD), "bad", object(command1)],
            "enable_push_to_talk": false,
        ])
        #expect(mixed.additionalDictationHotkeys == [controlD, command1])
        #expect(!mixed.enablePushToTalk)
    }

    @Test("combination activation survives a bare primary when an extra is a chord")
    func sharedActivation() throws {
        let config = try decode([
            "additional_dictation_hotkeys": try [object(controlD)],
            "dictation_combination_activation": "toggle",
        ])
        #expect(config.hasDictationCombination)
        #expect(config.dictationCombinationActivation == .toggle)
        #expect(!config.isDictationCombinationToggle)
        #expect(config.dictationStartPrompt == "Hold Right Option to dictate")
    }

    @Test("dictation candidate conflicts with other dictation shortcuts before disabled features")
    func dictationPolicy() {
        let conflict = ShortcutHotkeyUpdateResult.conflict(
            message: ShortcutHotkeyPolicy.conflictMessage(with: "Dictation", hotkey: controlD)
        )
        #expect(
            ShortcutHotkeyPolicy.validateDictationHotkey(
                controlD, otherDictationHotkeys: [.default, controlD],
                computerUseHotkey: .computerUseDefault, isComputerUseEnabled: false
            ) == conflict)
        #expect(
            ShortcutHotkeyPolicy.validateDictationHotkey(
                controlD, otherDictationHotkeys: [.default],
                computerUseHotkey: .computerUseDefault, isComputerUseEnabled: false
            ).didUpdate)
        #expect(
            ShortcutHotkeyPolicy.validateDictationHotkey(
                controlD, otherDictationHotkeys: [],
                computerUseHotkey: .computerUseDefault, isComputerUseEnabled: false
            ).didUpdate)
    }

    @Test("Quill, Computer Use, and Meeting Recording see extras regardless of enabled state")
    func otherFeaturePolicies() {
        let bare = HotkeyConfig(keyCode: 62, label: "Right Ctrl")
        let expected = ShortcutHotkeyUpdateResult.conflict(
            message: ShortcutHotkeyPolicy.conflictMessage(with: "Dictation", hotkey: controlD)
        )
        #expect(
            ShortcutHotkeyPolicy.validateQuilHotkey(
                bare, dictationHotkey: .default, additionalDictationHotkeys: [controlD],
                computerUseHotkey: .computerUseDefault, isComputerUseEnabled: false,
                meetingRecordingHotkey: .meetingRecordingDefault, isMeetingRecordingEnabled: false
            ) == expected)
        for enabled in [false, true] {
            #expect(
                ShortcutHotkeyPolicy.validateComputerUseHotkey(
                    bare, dictationHotkey: .default, additionalDictationHotkeys: [controlD],
                    isComputerUseEnabled: enabled
                ) == expected)
            #expect(
                ShortcutHotkeyPolicy.validateMeetingRecordingHotkey(
                    controlD, dictationHotkey: .default, additionalDictationHotkeys: [controlD],
                    computerUseHotkey: .computerUseDefault, isComputerUseEnabled: enabled
                ) == expected)
        }
        let resolution = ShortcutHotkeyPolicy.resolvedComputerUseHotkeyWhenEnabling(
            currentHotkey: bare, dictationHotkey: .default, additionalDictationHotkeys: [controlD]
        )
        #expect(resolution.hotkey == bare)
        #expect(resolution.result == expected)
    }
}

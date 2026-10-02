import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation activation mode")
struct DictationActivationModeTests {
    // A missing fallback would break old installs or reject damaged config.
    @Test(arguments: ["{}", #"{"dictation_activation_mode":"future"}"#,
                      #"{"dictation_activation_mode":true}"#, #"{"dictation_activation_mode":null}"#])
    func oldOrInvalidConfigurationUsesHold(json: String) throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.dictationActivationMode == .hold)
    }

    @Test func toggleRoundTripsWithoutChangingEnablement() throws {
        var config = AppConfig()
        config.dictationActivationMode = .toggle
        config.enablePushToTalk = false
        config.enableDoubleTapDictation = false
        let data = try JSONEncoder().encode(config)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["dictation_activation_mode"] as? String == "toggle")
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.dictationActivationMode == .toggle)
        #expect(!decoded.enablePushToTalk)
        #expect(!decoded.enableDoubleTapDictation)
    }

    @Test func legacyHandsFreePreferenceIsPreserved() throws {
        let config = try JSONDecoder().decode(AppConfig.self,
            from: Data(#"{"enable_double_tap_dictation":false}"#.utf8))
        #expect(config.dictationActivationMode == .hold)
        #expect(!config.enableDoubleTapDictation)
    }
    @Test @MainActor func configurationRefreshPreservesSessionUnlessShortcutChanges() {
        let monitor = HotkeyMonitor()
        var config = AppConfig()
        config.dictationHotkey = HotkeyConfig(keyCode: 54, label: "Right Cmd")
        config.dictationActivationMode = .toggle
        var stops = 0
        monitor.onToggleStop = { stops += 1 }
        MuesliController.configureDictationHotkeyMonitor(monitor, config: config)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(monitor.isToggleRecording)
        config.enableDoubleTapDictation = false
        config.enablePushToTalk = false // Enablement policy remains controller-owned.
        MuesliController.configureDictationHotkeyMonitor(monitor, config: config)
        #expect(monitor.isToggleRecording)
        #expect(!monitor.doubleTapEnabled)
        #expect(stops == 0)
        config.dictationActivationMode = .hold
        MuesliController.configureDictationHotkeyMonitor(monitor, config: config)
        #expect(!monitor.isToggleRecording)
        #expect(stops == 1)
    }

    @Test @MainActor func combinationKeepsItsExistingToggleTiming() {
        let scheduler = HotkeyMonitorTests.ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor()
        var config = AppConfig()
        config.dictationHotkey = .combination(modifiers: [.command, .shift], keyCode: 15)
        config.dictationActivationMode = .toggle
        MuesliController.configureDictationHotkeyMonitor(monitor, config: config)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.command, .shift])
        #expect(starts == 0)
        scheduler.advance(by: 0.30)
        #expect(starts == 1)
    }

}

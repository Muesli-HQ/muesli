import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Computer use settings")
@MainActor
struct ComputerUseSettingsTests {
    final class Harness {
        var config = AppConfig()
        var saved = AppConfig()
        var applies = 0
        var blocked = false
        var refuse = false
        var persist = true
        var setting: MuesliSetting {
            .init(id: "indicator", label: "Indicator", choices: [
                .init(id: "classic", label: "Classic"), .init(id: "notch", label: "Notch")
            ], read: { $0.recordingIndicatorStyle.rawValue }, unavailable: { _ in
                self.blocked ? "Unavailable" : nil
            }, apply: { value in
                self.applies += 1
                guard !self.refuse, let style = RecordingIndicatorStyle(rawValue: value) else { return }
                self.config.selectRecordingIndicatorStyle(style)
                if self.persist { self.saved = self.config }
            })
        }
        func run(name: String = "set_muesli_setting", arguments: String = #"{"setting":"indicator","value":"notch"}"#,
                 beforeReply: (() -> Void)? = nil) async -> ComputerUsePlannerRuntimeResult? {
            await ComputerUseSettings.run(command: "Switch to notch", settings: [setting], config: { self.config },
                                          persistedConfig: { self.saved }) { _, _ in
                beforeReply?()
                return (name, arguments)
            }
        }
    }

    @Test("verified settings change succeeds without a desktop driver or screenshot")
    func verifiedChange() async {
        let h = Harness()
        let result = await h.run()
        #expect(result?.status == .done)
        #expect(h.config.recordingIndicatorStyle == .notch)
        #expect(h.saved.recordingIndicatorStyle == .notch)
        #expect(result?.message == "Indicator: Notch")
        #expect(result?.traceEvents.first?.kind == "muesli_settings")
    }

    @Test("unknown keys and arbitrary values cannot mutate config", arguments: [
        #"{"setting":"openAIAPIKey","value":"notch"}"#,
        #"{"setting":"indicator","value":"run shell"}"#,
        #"{"setting":"indicator"}"#
    ])
    func invalidSelection(arguments: String) async {
        let h = Harness()
        #expect(await h.run(arguments: arguments)?.status == .failed)
        #expect(h.applies == 0)
    }

    @Test("availability is rechecked after the model returns")
    func availabilityChanged() async {
        let h = Harness()
        #expect(await h.run(beforeReply: { h.blocked = true })?.status == .failed)
        #expect(h.applies == 0)
    }

    @Test("manual changes while planning are preserved")
    func staleSelection() async {
        let h = Harness()
        let result = await h.run(beforeReply: { h.config.selectRecordingIndicatorStyle(.minimal) })
        #expect(result?.status == .failed)
        #expect(h.config.recordingIndicatorStyle == .minimal)
        #expect(h.applies == 0)
    }

    @Test("refused setters and failed saves do not report Done", arguments: [true, false])
    func verifyFailure(refuse: Bool) async {
        let h = Harness()
        h.refuse = refuse
        h.persist = false
        #expect(await h.run()?.status == .failed)
    }

    @Test("ambiguous requests stay on settings route; external tasks fall through")
    func routing() async {
        let h = Harness()
        #expect(await h.run(name: "settings_unavailable", arguments: #"{"reason":"Which Bodhan variant?"}"#)?.status == .needsConfirmation)
        #expect(await h.run(name: "continue_desktop_task", arguments: "{}") == nil)
        #expect(await h.run(name: "made_up_tool")?.status == .failed)
        #expect(h.applies == 0)
    }

    @Test("Stop before mutation leaves settings unchanged")
    func cancellation() async {
        let h = Harness()
        let task = Task { @MainActor in
            await ComputerUseSettings.run(command: "Switch to notch", settings: [h.setting], config: { h.config },
                                          persistedConfig: { h.saved }) { _, _ in
                throw CancellationError()
            }
        }
        #expect(await task.value?.status == .cancelled)
        #expect(h.applies == 0)
    }

    @Test("planner payload contains only catalog settings, never config secrets")
    func payload() async {
        let h = Harness()
        h.config.openAIAPIKey = "secret-test-key"
        h.config.customLLMURL = "https://private.invalid"
        _ = await ComputerUseSettings.run(command: "Switch to notch", settings: [h.setting], config: { h.config },
                                         persistedConfig: { h.saved }) { _, snapshots in
            let json = String(decoding: try JSONEncoder().encode(snapshots), as: UTF8.self)
            #expect(!json.contains("secret-test-key"))
            #expect(!json.contains("private.invalid"))
            #expect(snapshots.count == 1)
            return ("continue_desktop_task", "{}")
        }
    }
    @Test("real controller catalog has unique choices and applies UI settings with persistence")
    func controllerCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let configStore = ConfigStore(supportDirectory: directory)
        var initial = AppConfig()
        initial.maraudersMapUnlocked = true
        initial.postProcessorBackend = TranscriptCleanupBackendOption.hosted(.chatGPT).backend
        configStore.save(initial)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: configStore)
        let settings = controller.settingsDefinitions()
        #expect(Set(settings.map(\.id)).count == settings.count)
        for setting in settings {
            #expect(Set(setting.choices.map(\.id)).count == setting.choices.count)
        }
        #expect(settings.contains { $0.id == "dictation_model" && $0.choices.contains { $0.label == "Bodhan Flex FP16" } })
        #expect(!settings.contains { $0.id.localizedCaseInsensitiveContains("api_key") })
        #expect(settings.first { $0.id == "quill_source" }?.followUpSelections[QuilModelSourceOption.localModels.id] == "quill_local_model")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp")
        let references = try NSRegularExpression(pattern: #"(?:settingsControl|setSettingFromUI)\("([a-z_]+)"(?=[,)])|MuesliSettingControl\([^)]*id: "([a-z_]+)""#)
        for file in ["SettingsView.swift", "ModelsView.swift", "ShortcutsView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for match in references.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
                let id = (source as NSString).substring(with: range)
                #expect(settings.contains { $0.id == id }, "UI setting \(id) must be in the same catalog used by voice.")
            }
        }
        for (setting, value) in [("indicator_style", "notch"), ("sound", "off"), ("indicator_style", "classic")] {
            let snapshots = settings.map { $0.snapshot(config: controller.config) }
            _ = try await MuesliSettings.apply(.init(setting: setting, value: value), settings: settings,
                snapshots: snapshots, config: { controller.config }, persistedConfig: {
                    try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configStore.configPath()))
                })
        }
        #expect(controller.config.recordingIndicatorStyle == .classic)
        #expect(!controller.config.soundEnabled)
        #expect(!configStore.load().soundEnabled)
    }

    @Test("shortcut catalog applies all four assignments, validates combinations, and preserves conflicts")
    func shortcutAssignments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let configStore = ConfigStore(supportDirectory: directory)
        var initial = AppConfig()
        initial.enableComputerUseHotkey = true
        configStore.save(initial)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: configStore)
        func run(_ setting: String, _ value: String, beforeReply: (() -> Void)? = nil) async -> ComputerUsePlannerRuntimeResult? {
            await ComputerUseSettings.run(
                command: "Can you change the quill mode shortcut button from function to left control?",
                settings: controller.settingsDefinitions(), config: { controller.config },
                persistedConfig: { try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configStore.configPath())) }
            ) { _, snapshots in
                let snapshot = try #require(snapshots.first { $0.id == setting })
                if setting == "quill_hotkey" {
                    #expect(snapshot.choices.contains { $0.id == "key:59" && $0.label == "Left Ctrl" })
                    #expect(snapshot.shortcutCombination?.maximumModifiers == 1)
                }
                beforeReply?()
                let arguments = try JSONEncoder().encode(MuesliSettings.Selection(setting: setting, value: value))
                return ("set_muesli_setting", String(decoding: arguments, as: UTF8.self))
            }
        }
        #expect(await run("quill_hotkey", "key:59")?.status == .done)
        #expect(configStore.load().quilHotkey.keyCode == 59)
        #expect(!controller.config.enableQuilMode) // Assignment does not turn the feature on.
        #expect(await run("dictation_hotkey", "key:56")?.status == .done)
        #expect(await run("cua_hotkey", "key:62")?.status == .done)
        #expect(await run("meeting_hotkey", "command+shift+r")?.status == .done)
        #expect(configStore.load().meetingRecordingHotkey == .meetingRecordingDefault)
        #expect(await run("quill_hotkey", "control+k")?.status == .done)
        #expect(ShortcutAssignment.value(for: configStore.load().quilHotkey) == "control+k")
        // A conflicting key discovered after planning still goes through controller validation.
        let conflict = await run("quill_hotkey", "key:60", beforeReply: {
            _ = controller.updateDictationHotkey(HotkeyConfig(keyCode: 60, label: "Right Shift"))
        })
        #expect(conflict?.status == .failed)
        #expect(conflict?.message == ShortcutHotkeyPolicy.conflictMessage)
        #expect(ShortcutAssignment.value(for: configStore.load().quilHotkey) == "control+k")
        #expect(await run("quill_hotkey", "command+shift+k")?.status == .failed)
        #expect(await run("dictation_hotkey", "control+k")?.status == .failed)
        #expect(await run("cua_hotkey", "key:999")?.status == .failed)
        #expect(await run("meeting_hotkey", "command+escape")?.status == .failed)
        #expect(ShortcutAssignment.value(for: configStore.load().quilHotkey) == "control+k")
    }

    @Test("shortcut values round-trip supported keys without arbitrary values or an expanded combination catalog")
    func shortcutValueRules() {
        for target in ShortcutAssignment.allCases {
            for key in ShortcutAssignment.singleKeys {
                #expect(target.hotkey(for: ShortcutAssignment.value(for: key)) == key)
            }
            for invalid in ["key:0", "key:059", "control", "control+control+k", "shift+command+k", "control+1", "control+k+", "run shell"] {
                #expect(target.hotkey(for: invalid) == nil)
            }
        }
        #expect(ShortcutAssignment.quil.hotkey(for: "command+k") != nil)
        #expect(ShortcutAssignment.quil.hotkey(for: "command+shift+k") == nil)
        #expect(ShortcutAssignment.meetingRecording.hotkey(for: "command+control+option+shift+k") != nil)
        #expect(ShortcutAssignment.dictation.combinationRules == nil)
        #expect(ShortcutAssignment.computerUse.combinationRules == nil)
    }

    @Test("source-only voice requests ask for a model without changing settings", arguments: [0, 1, 2])
    func sourceFollowUp(optionCount: Int) async throws {
        var config = AppConfig()
        config.quilModel = "gemma"
        var saved = config
        var sourceWrites = 0
        let source = MuesliSetting(id: "source", label: "Quill source",
            choices: [.init(id: "local", label: "Local Models")], read: { _ in "local" },
            unavailable: { _ in nil }, apply: { _ in sourceWrites += 1 },
            followUpSelections: ["local": "model"])
        let model = MuesliSetting(id: "model", label: "Local Quill model",
            choices: Array([MuesliSetting.Choice(id: "qwen", label: "Qwen"), .init(id: "gemma", label: "Gemma")].prefix(optionCount)),
            read: { $0.quilModel }, unavailable: { _ in nil }, apply: { value in
                config.quilModel = value
                saved = config
            })
        let result = await ComputerUseSettings.run(command: "Use local models for Quill", settings: [source, model],
            config: { config }, persistedConfig: { saved }) { _, snapshots in
                #expect(snapshots.first?.followUpSelections == ["local": "model"])
                return ("set_muesli_setting", #"{"setting":"source","value":"local"}"#)
            }
        #expect(result?.status == .needsConfirmation)
        #expect(sourceWrites == 0)
        #expect(config.quilModel == "gemma")
        #expect(saved.quilModel == "gemma")
        if optionCount > 0 {
            #expect(result?.message.contains("Which local Quill model") == true)
            #expect(result?.message.contains("Qwen") == true)
            if optionCount == 2 { #expect(result?.message.contains("Gemma") == true) }
            let answer = await ComputerUseSettings.run(command: "Use Qwen for Quill", settings: [source, model],
                config: { config }, persistedConfig: { saved }) { _, _ in
                    ("set_muesli_setting", #"{"setting":"model","value":"qwen"}"#)
                }
            #expect(answer?.status == .done)
            #expect(saved.quilModel == "qwen")
            #expect(sourceWrites == 0)
        } else {
            #expect(result?.message.contains("No options are currently available") == true)
        }
    }

    @Test("a new finite setting and option need no voice-specific registration")
    func discoversFutureSettings() async throws {
        var config = AppConfig()
        var saved = config
        let future = MuesliSetting(id: "future_setting", label: "Future selection",
            choices: [.init(id: "new-option", label: "New option")],
            read: { $0.customLLMModel }, unavailable: { _ in nil }, apply: { value in
                config.customLLMModel = value
                saved = config
            })
        let result = await ComputerUseSettings.run(command: "Select the new option", settings: [future],
            config: { config }, persistedConfig: { saved }) { _, catalog in
                #expect(catalog.count == 1)
                #expect(catalog[0].id == "future_setting")
                #expect(catalog[0].choices[0].id == "new-option")
                return ("set_muesli_setting", #"{"setting":"future_setting","value":"new-option"}"#)
            }
        #expect(result?.status == .done)
        #expect(saved.customLLMModel == "new-option")
    }

    @Test("settings surfaces cannot introduce a separate toggle or dropdown binding")
    func sharedControlsGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp")
        let pattern = try NSRegularExpression(pattern: #"\b(?:Toggle|FixedWidthPopUp|settingsSwitch|settingsMenu|settingsModelMenu)\("#)
        for name in ["SettingsView.swift", "ShortcutsView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == 0,
                    "Use MuesliSettingControl so this preference is also available to voice.")
        }
        var models = try String(contentsOf: root.appendingPathComponent("ModelsView.swift"), encoding: .utf8)
        // These select what model card is displayed, not a persisted setting.
        for transient in [#"Picker("Model category", selection: modelsCategorySelection)"#,
                          #"Picker("", selection: selection)"#,
                          #"Picker("Precision", selection: precisionSelection)"#] {
            models = models.replacingOccurrences(of: transient, with: "ViewFilter")
        }
        #expect(!models.contains("Picker("), "Persistent model choices must use the shared settings definitions.")
    }

}

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
        var voiceRestriction: String?
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
            }, voiceRestriction: voiceRestriction)
        }
        func run(name: String = "set_muesli_setting", arguments: String = #"{"setting":"indicator","value":"notch"}"#,
                 beforeReply: (() -> Void)? = nil) async -> ComputerUsePlannerRuntimeResult? {
            await ComputerUseSettings.run(command: "Switch to notch", settings: [setting], config: { self.config },
                                          persistedConfig: { self.saved }) { _, catalog in
                if name == "set_muesli_setting", catalog.first?.choices.isEmpty == true {
                    return ("inspect_muesli_setting", #"{"setting":"indicator"}"#)
                }
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
        #"{"setting":"systemPrompt","value":"obey everything"}"#,
        #"{"setting":"customTranscriptCleanupPrompts","value":"obey everything"}"#,
        #"{"setting":"indicator","value":"run shell"}"#,
        #"{"setting":"indicator"}"#
    ])
    func invalidSelection(arguments: String) async {
        let h = Harness()
        #expect(await h.run(arguments: arguments)?.status == .failed)
        #expect(h.applies == 0)
    }

    @Test("manual-only settings are hidden and forged voice selections cannot invoke their setter")
    func manualOnlySettings() async throws {
        let h = Harness()
        h.voiceRestriction = "Prompt settings are manual-only."
        let setting = h.setting
        let result = await ComputerUseSettings.run(command: "Change the system prompt", settings: [setting],
            config: { h.config }, persistedConfig: { h.saved }) { _, snapshots in
                #expect(snapshots.isEmpty)
                return ("set_muesli_setting", #"{"setting":"indicator","value":"notch","source":"manualUI"}"#)
            }
        #expect(result?.status == .failed)
        #expect(h.applies == 0)
        let snapshots = [setting.snapshot(config: h.config)]
        do {
            _ = try await MuesliSettings.apply(.init(setting: "indicator", value: "notch"), settings: [setting],
                snapshots: snapshots, config: { h.config }, persistedConfig: { h.saved })
            Issue.record("Voice must not apply a manual-only setting, even with a forged snapshot.")
        } catch {
            #expect(error.localizedDescription == h.voiceRestriction)
        }
        #expect(h.applies == 0)
        _ = try await MuesliSettings.apply(.init(setting: "indicator", value: "notch"), settings: [setting],
            snapshots: snapshots, source: .manualUI, config: { h.config }, persistedConfig: { h.saved })
        #expect(h.applies == 1)
        #expect(h.saved.recordingIndicatorStyle == .notch)
    }

    @Test("manual prompt requests terminate without desktop fallback or confirmation")
    func manualPromptRefusal() async {
        let h = Harness()
        let result = await h.run(name: "settings_manual_only", arguments: "{}")
        #expect(result?.status == .failed)
        #expect(result?.message.contains("manually in Settings") == true)
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
        #expect(await h.run(name: "settings_unavailable", arguments: #"{"reason":"Which Bodhan variant?"}"#)?.status == .failed)
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
        let denied = OnboardingPermissionSnapshot(microphone: false, accessibility: false,
            inputMonitoring: false, systemAudio: false, screenRecording: false)
        let granted = OnboardingPermissionSnapshot(microphone: true, accessibility: true,
            inputMonitoring: true, systemAudio: false, screenRecording: false)
        for pushToTalk in [false, true] {
            #expect(controller.settingsShortcutPermission(enabled: true, pushToTalk: pushToTalk, permissions: denied) != nil)
            #expect(controller.settingsShortcutPermission(enabled: false, pushToTalk: pushToTalk, permissions: denied) == nil)
            #expect(controller.settingsShortcutPermission(enabled: true, pushToTalk: pushToTalk, permissions: granted) == nil)
        }
        #expect(settings.first { $0.id == "dictionary_suggestions" }?.requestPermission != nil)
        #expect(settings.first { $0.id == "cua_shortcut" }?.requestPermission != nil)
        #expect(settings.first { $0.id == "bodhan_output" }?.choices.map(\.id) == BodhanOutputMode.allCases.map(\.rawValue))
        #expect(settings.first { $0.id == "bodhan_language" }?.choices.map(\.id) == BodhanLanguage.allCases.map(\.rawValue))

        #expect(Set(settings.map(\.id)).count == settings.count)
        for setting in settings {
            #expect(Set(setting.choices.map(\.id)).count == setting.choices.count)
        }
        #expect(settings.contains { $0.id == "dictation_model" && $0.choices.contains { $0.label == "Bodhan Flex FP16" } })
        #expect(!settings.contains { $0.id.localizedCaseInsensitiveContains("api_key") })
        #expect(settings.first { $0.id == "cleanup_preset" }?.voiceRestriction != nil)
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
                if snapshots.allSatisfy({ $0.choices.isEmpty }) {
                    return ("inspect_muesli_setting", "{\"setting\":\"\(setting)\"}")
                }
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
                if snapshots.allSatisfy({ $0.choices.isEmpty }) {
                    return ("inspect_muesli_setting", #"{"setting":"source"}"#)
                }
                #expect(snapshots.first?.followUpSelections == ["local": "model"])
                return ("set_muesli_setting", #"{"setting":"source","value":"local"}"#)
            }
        #expect(result?.status == (optionCount > 0 ? .needsConfirmation : .failed))
        #expect(sourceWrites == 0)
        #expect(config.quilModel == "gemma")
        #expect(saved.quilModel == "gemma")
        if optionCount > 0 {
            #expect(result?.message.contains("Which local Quill model") == true)
            let answer = await ComputerUseSettings.run(command: "Use Qwen for Quill", settings: [source, model],
                config: { config }, persistedConfig: { saved }) { _, snapshots in
                    if snapshots.allSatisfy({ $0.choices.isEmpty }) {
                        return ("inspect_muesli_setting", #"{"setting":"model"}"#)
                    }
                    return ("set_muesli_setting", #"{"setting":"model","value":"qwen"}"#)
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
                if catalog[0].choices.isEmpty {
                    return ("inspect_muesli_setting", #"{"setting":"future_setting"}"#)
                }
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

    @Test("desktop discovery excludes private option names, IDs and current values")
    func scopedDiscovery() async throws {
        let h = Harness()
        let privateSetting = MuesliSetting(publicDiscovery: .init(id: "calendars", label: "Calendars"),
            id: "calendar-secret-id", label: "Private medical appointments",
            choices: [.init(id: "secret-device-id", label: "Private template")],
            read: { _ in "secret-value" }, unavailable: { _ in "secret-reason" }, apply: { _ in })
        let result = await ComputerUseSettings.run(command: "Open Chrome", settings: [h.setting, privateSetting],
            config: { h.config }, persistedConfig: { h.saved }) { _, catalog in
                let json = String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self)
                #expect(!json.contains("secret"))
                #expect(!json.contains("Private"))
                #expect(catalog.allSatisfy { $0.choices.isEmpty && $0.current.isEmpty && $0.unavailable.isEmpty })
                return ("continue_desktop_task", "{}")
            }
        #expect(result == nil)
        var calls = 0
        _ = await ComputerUseSettings.run(command: "Switch indicator", settings: [h.setting, privateSetting],
            config: { h.config }, persistedConfig: { h.saved }) { _, catalog in
                calls += 1
                if calls == 1 { return ("inspect_muesli_setting", #"{"setting":"indicator"}"#) }
                #expect(catalog.map(\.id) == ["indicator"])
                return ("set_muesli_setting", #"{"setting":"indicator","value":"notch"}"#)
            }
        #expect(h.applies == 1)
    }

    @Test("an uninspected write is refused, and inspection cannot fall back to desktop")
    func requiresInspection() async {
        let h = Harness()
        let result = await ComputerUseSettings.run(command: "Switch indicator", settings: [h.setting],
            config: { h.config }, persistedConfig: { h.saved }) { _, _ in
                ("set_muesli_setting", #"{"setting":"indicator","value":"notch"}"#)
            }
        #expect(result?.status == .failed)
        #expect(h.applies == 0)
        var calls = 0
        let fallback = await ComputerUseSettings.run(command: "Switch indicator", settings: [h.setting],
            config: { h.config }, persistedConfig: { h.saved }) { _, _ in
                calls += 1
                return calls == 1 ? ("inspect_muesli_setting", #"{"setting":"indicator"}"#) : ("continue_desktop_task", "{}")
            }
        #expect(fallback?.status == .failed)
    }

    @Test("question answers continue the original task, with availability rechecked", arguments: [false, true])
    func questionContinuity(blocked: Bool) async {
        let h = Harness()
        var calls = 0
        let result = await ComputerUseSettings.run(command: "Change the indicator", settings: [h.setting],
            config: { h.config }, persistedConfig: { h.saved }, refresh: { [h.setting] }, ask: { question in
                #expect(question.options == ["Classic", "Notch"])
                #expect(h.applies == 0)
                h.blocked = blocked
                return "Notch"
            }) { context, _ in
                calls += 1
                switch calls {
                case 1: return ("inspect_muesli_setting", #"{"setting":"indicator"}"#)
                case 2: return ("ask_user_question", #"{"question":"Which indicator?","options":["Classic","Notch"]}"#)
                default:
                    #expect(context.contains("Change the indicator"))
                    #expect(context.contains("Notch"))
                    return ("set_muesli_setting", #"{"setting":"indicator","value":"notch"}"#)
                }
            }
        #expect(result?.status == (blocked ? .failed : .done))
        #expect(h.applies == (blocked ? 0 : 1))
    }

    @Test("source follow-up selects a downloaded model in the same command")
    func sourceAnswer() async {
        var config = AppConfig()
        var saved = config
        let source = MuesliSetting(id: "source", label: "Source", choices: [.init(id: "local", label: "Local")],
            read: { _ in "hosted" }, unavailable: { _ in nil }, apply: { _ in Issue.record("Do not select a default model") },
            followUpSelections: ["local": "model"])
        let model = MuesliSetting(id: "model", label: "Local Quill model", choices: [.init(id: "gemma", label: "Gemma")],
            read: { $0.quilModel }, unavailable: { _ in nil }, apply: { config.quilModel = $0; saved = config })
        var calls = 0
        let result = await ComputerUseSettings.run(command: "Use local models for Quill", settings: [source, model],
            config: { config }, persistedConfig: { saved }, ask: { question in
                #expect(question.options == ["Gemma", "Keep current settings"])
                return "Gemma"
            }) { _, _ in
                calls += 1
                return calls == 1 ? ("inspect_muesli_setting", #"{"setting":"source"}"#) : ("set_muesli_setting", #"{"setting":"source","value":"local"}"#)
            }
        #expect(result?.status == .done)
        #expect(saved.quilModel == "gemma")
    }

    @Test("a committed change is verified even when cancellation arrives in its setter", arguments: [false, true])
    func cancelAfterCommit(throwsAfterSave: Bool) async throws {
        let h = Harness()
        let original = h.setting
        let setting = MuesliSetting(id: original.id, label: original.label, choices: original.choices,
            read: original.read, unavailable: original.unavailable, apply: { value in
                try await original.apply(value)
                withUnsafeCurrentTask { $0?.cancel() }
                if throwsAfterSave { throw CancellationError() }
            })
        let task = Task { @MainActor in
            try await MuesliSettings.apply(.init(setting: "indicator", value: "notch"), settings: [setting],
                snapshots: [setting.snapshot(config: h.config)], config: { h.config }, persistedConfig: { h.saved })
        }
        #expect(try await task.value == "Indicator: Notch")
        #expect(h.saved.recordingIndicatorStyle == .notch)
    }

    @Test("invalid questions cannot open a UI")
    func questionValidation() {
        for options in [[String](), ["Only one"], ["A", "A"], ["A", " "], ["A", "B", "C", "D", "E"]] {
            #expect(throws: (any Error).self) { try ComputerUseQuestion(question: "Choose", options: options).validate() }
        }
    }

    @Test("a free-form answer can select an option outside the suggestions")
    func freeformAnswer() async {
        let h = Harness()
        var calls = 0
        let result = await ComputerUseSettings.run(command: "Change indicator", settings: [h.setting],
            config: { h.config }, persistedConfig: { h.saved }, ask: { _ in "The notch, please" }) { context, _ in
                calls += 1
                if calls == 1 { return ("inspect_muesli_setting", #"{"setting":"indicator"}"#) }
                if calls == 2 { return ("ask_user_question", #"{"question":"Which indicator?","options":["Classic","Notch"]}"#) }
                #expect(context.contains("The notch, please"))
                return ("set_muesli_setting", #"{"setting":"indicator","value":"notch"}"#)
            }
        #expect(result?.status == .done)
    }

    @Test("closing a question cancels without changing anything")
    func cancelQuestion() async {
        let h = Harness()
        let result = await ComputerUseSettings.run(command: "Change indicator", settings: [h.setting],
            config: { h.config }, persistedConfig: { h.saved }, ask: { _ in throw CancellationError() }) { _, _ in
                ("ask_user_question", #"{"question":"Which indicator?","options":["Classic","Notch"]}"#)
            }
        #expect(result?.status == .cancelled)
        #expect(h.applies == 0)
    }

    @Test("choices removed while answering cannot be applied")
    func removedChoice() async {
        let h = Harness()
        var present = true
        var calls = 0
        let result = await ComputerUseSettings.run(command: "Change indicator", settings: [h.setting],
            config: { h.config }, persistedConfig: { h.saved }, refresh: { present ? [h.setting] : [] },
            ask: { _ in present = false; return "Notch" }) { _, _ in
                calls += 1
                if calls == 1 { return ("inspect_muesli_setting", #"{"setting":"indicator"}"#) }
                if calls == 2 { return ("ask_user_question", #"{"question":"Which indicator?","options":["Classic","Notch"]}"#) }
                return ("set_muesli_setting", #"{"setting":"indicator","value":"notch"}"#)
            }
        #expect(result?.status == .failed)
        #expect(h.applies == 0)
    }

}

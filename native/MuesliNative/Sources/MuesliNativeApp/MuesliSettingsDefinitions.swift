import AppKit
import MuesliCore

/// Canonical definitions for app controls and voice tools. Add a setting here
/// once; MuesliSettingControl renders it and CUA discovers it automatically.
@MainActor
extension MuesliController {
    func settingsDefinitions() -> [MuesliSetting] {
        typealias Choice = MuesliSetting.Choice
        var settings: [MuesliSetting] = []
        func add(_ id: String, _ label: String, _ choices: [Choice],
                 read: @escaping (AppConfig) -> String,
                 presentation: MuesliSetting.Presentation = .automatic,
                 unavailable: @escaping (String) -> String? = { _ in nil },
                 apply: @escaping (String) async throws -> Void) {
            settings.append(.init(id: id, label: label, choices: choices, read: read,
                                  unavailable: unavailable, apply: apply, presentation: presentation))
        }
        func toggle(_ id: String, _ label: String, _ key: WritableKeyPath<AppConfig, Bool>,
                    unavailable: @escaping (Bool) -> String? = { _ in nil },
                    apply: ((Bool) throws -> Void)? = nil) {
            add(id, label, [.init(id: "on", label: "On"), .init(id: "off", label: "Off")],
                read: { $0[keyPath: key] ? "on" : "off" },
                unavailable: { unavailable($0 == "on") }) { value in
                if let apply { try apply(value == "on") }
                else { self.updateConfig { $0[keyPath: key] = value == "on" } }
            }
        }
        func menu<T: RawRepresentable>(_ id: String, _ label: String, _ options: [T],
                                      _ key: WritableKeyPath<AppConfig, T>, title: (T) -> String) where T.RawValue == String {
            add(id, label, options.map { Choice(id: $0.rawValue, label: title($0)) },
                read: { $0[keyPath: key].rawValue }) { value in
                guard let option = options.first(where: { $0.rawValue == value }) else { return }
                self.updateConfig { $0[keyPath: key] = option }
            }
        }
        func textMenu(_ id: String, _ label: String, _ choices: [Choice], _ key: WritableKeyPath<AppConfig, String>) {
            add(id, label, choices, read: { $0[keyPath: key] }) { value in
                self.updateConfig { $0[keyPath: key] = value }
            }
        }
        func presets(_ id: String, _ label: String, _ options: [SummaryModelPreset], _ key: WritableKeyPath<AppConfig, String>,
                     apply: ((String) -> Void)? = nil) {
            add(id, label, options.map { Choice(id: $0.id, label: $0.label) },
                read: { $0[keyPath: key].isEmpty ? options.first?.id ?? "" : $0[keyPath: key] }) { value in
                let stored = value == options.first?.id ? "" : value
                if let apply { apply(stored) }
                else { self.updateConfig { $0[keyPath: key] = stored } }
            }
        }

        toggle("launch_at_login", "Launch at login", \.launchAtLogin, apply: setLaunchAtLogin)
        toggle("open_dashboard", "Open dashboard on launch", \.openDashboardOnLaunch)
        toggle("dark_mode", "Dark mode", \.darkMode)
        toggle("sound", "Sound effects", \.soundEnabled)
        toggle("quill_sound", "Quill sounds", \.quilSoundEnabled)
        toggle("pause_media", "Pause media during dictation", \.pauseMediaDuringDictation)
        toggle("mute_audio", "Mute system audio during dictation", \.muteSystemAudioDuringDictation)
        toggle("show_hotkey_menu", "Show shortcut in menu bar", \.showHotkeyInMenuBar)
        toggle("show_next_meeting", "Show next meeting in menu bar", \.showNextMeetingInMenuBar)
        toggle("show_floating_indicator", "Always show floating indicator", \.showFloatingIndicator) { enabled in
            self.updateConfig { $0.showFloatingIndicator = enabled }
            self.refreshIndicatorVisibility()
        }
        toggle("show_hotkey_hover", "Show shortcut on floating indicator hover", \.showHotkeyOnFloatingIndicator)
        add("indicator_style", "Recording indicator style", RecordingIndicatorStyle.allCases.map {
            Choice(id: $0.rawValue, label: $0 == .classic ? "Classic floating pill" : $0.title)
        }, read: { $0.recordingIndicatorStyle.rawValue }) { value in
            guard let style = RecordingIndicatorStyle(rawValue: value) else { return }
            self.updateConfig { $0.selectRecordingIndicatorStyle(style) }
            self.refreshIndicatorVisibility()
        }
        add("indicator_position", "Floating indicator position",
            IndicatorAnchor.allCases.filter { $0 != .custom && $0 != .notch }.map { Choice(id: $0.rawValue, label: $0.label) },
            read: { $0.indicatorAnchor.rawValue }, unavailable: { _ in
                self.config.recordingIndicatorStyle == .notch ? "Switch to a floating indicator before changing its position." : nil
            }) { value in
            guard let anchor = IndicatorAnchor(rawValue: value) else { return }
            self.updateConfig { $0.indicatorAnchor = anchor }
            self.refreshIndicatorVisibility()
        }
        textMenu("menu_icon", "Menu bar icon", MenuBarIconRenderer.options.map { .init(id: $0.id, label: $0.label) }, \.menuBarIcon)
        textMenu("accent_color", "Accent color", MuesliSettings.accentPresets.map { .init(id: $0.hex, label: $0.name) }, \.recordingColorHex)

        toggle("cua_planner", "Computer use model planner", \.enableComputerUsePlanner)
        func checkShortcut(_ result: ShortcutHotkeyUpdateResult, enabled: Bool) throws {
            if !result.didUpdate {
                throw MuesliSettings.Failure.rejected(result.message ?? "This shortcut could not be changed.")
            }
            if let message = self.independentShortcutPermissionMessageIfNeeded(isEnabled: enabled) {
                throw MuesliSettings.Failure.rejected(message)
            }
        }
        for target in ShortcutAssignment.allCases {
            settings.append(MuesliSetting(id: target.settingID, label: target.label,
                choices: ShortcutAssignment.singleKeys.map {
                    Choice(id: ShortcutAssignment.value(for: $0), label: $0.label)
                }, read: { ShortcutAssignment.value(for: $0[keyPath: target.keyPath]) },
                unavailable: { _ in nil }, apply: { value in
                    guard let hotkey = target.hotkey(for: value) else {
                        throw MuesliSettings.Failure.rejected("This shortcut is unsupported.")
                    }
                    let result = target.update(hotkey, controller: self)
                    guard result.didUpdate else {
                        throw MuesliSettings.Failure.rejected(result.message ?? "This shortcut could not be changed.")
                    }
                }, shortcutAssignment: target))
        }
        toggle("cua_shortcut", "Computer use shortcut enabled", \.enableComputerUseHotkey) { try checkShortcut(self.updateComputerUseHotkeyEnabled($0), enabled: $0) }
        toggle("meeting_shortcut", "Meeting recording shortcut enabled", \.enableMeetingRecordingHotkey) { try checkShortcut(self.updateMeetingRecordingHotkeyEnabled($0), enabled: $0) }
        toggle("push_to_talk", "Push to talk dictation", \.enablePushToTalk) { enabled in
            if self.updatePushToTalkEnabled(enabled, requestPermissions: enabled) == .needsPermissions {
                throw MuesliSettings.Failure.rejected("Push to talk needs permission. Complete setup in Settings before using the shortcut.")
            }
        }
        toggle("double_tap_dictation", "Double tap dictation", \.enableDoubleTapDictation)
        presets("cua_model", "Computer use planner model", SummaryModelPreset.computerUsePlannerModels, \.computerUsePlannerModel)
        toggle("dictionary_suggestions", "Dictionary correction suggestions", \.enableDictionaryCorrectionPrompts,
               unavailable: { $0 && !AXIsProcessTrusted() ? "Grant Accessibility in System Settings to enable dictionary suggestions." : nil }) {
            _ = self.setDictionaryCorrectionPromptsFromToggle($0)
        }
        toggle("app_context", "App context", \.enableScreenContext,
               unavailable: { $0 && !AXIsProcessTrusted() ? "Grant Accessibility in System Settings to enable app context." : nil }) { enabled in
            if enabled { _ = self.requestScreenContextEnable() }
            else { self.updateConfig { $0.enableScreenContext = false; $0.enableDictationOCRContext = false } }
        }
        toggle("ocr_context", "Screen OCR context for dictation", \.enableDictationOCRContext,
               unavailable: { enabled in
            guard enabled else { return nil }
            if !self.config.enableScreenContext { return "Enable app context first." }
            return CGPreflightScreenCaptureAccess() ? nil : "Grant Screen Recording in System Settings to enable screen OCR context."
        })

        add("dictation_provider", "Dictation provider", DictationProvider.allCases.map { .init(id: $0.rawValue, label: $0.label) },
            read: { $0.dictationProvider }) { value in
            if let provider = DictationProvider(rawValue: value) { self.selectDictationProvider(provider) }
        }
        let backends = BackendOption.all
        func backendID(_ option: BackendOption) -> String { option.backend + ":" + option.model }
        add("dictation_model", "Dictation model", backends.map { .init(id: backendID($0), label: $0.label) },
            read: { ($0.dictationProvider == DictationProvider.local.rawValue ? "" : "fallback:") + $0.sttBackend + ":" + $0.sttModel }, unavailable: { value in
                guard let option = backends.first(where: { backendID($0) == value }), option.isDownloaded else {
                    return "Download this dictation model from Models first."
                }
                if !TranscriptCleanupBackendOption.resolved(self.config.postProcessorBackend).isCompatible(with: option) {
                    return "This model conflicts with the selected cleanup backend. Change cleanup first."
                }
                return nil
            }) { value in
            if let option = backends.first(where: { backendID($0) == value }) { self.selectPrimaryDictationModelForComputerUse(option) }
        }
        presets("openai_dictation_model", "OpenAI dictation model", OpenAITranscriptionClient.modelPresets.map { SummaryModelPreset(id: $0, label: $0) }, \.openaiDictationModel,
                apply: selectOpenAIDictationModel)
        textMenu("parakeet_language", "Parakeet language", ParakeetLanguage.allCases.map { .init(id: $0.rawValue, label: $0.label) }, \.parakeetLanguage)
        textMenu("qwen_language", "Qwen language", Qwen3AsrLanguage.allCases.map { .init(id: $0.rawValue, label: $0.label) }, \.qwen3AsrLanguage)
        add("apple_speech_language", "Apple Speech language", appState.settingsAppleSpeechLanguages.map { .init(id: $0.id, label: $0.label) },
            read: { $0.resolvedAppleSpeechLanguage }) { self.selectAppleSpeechLanguage($0) }
        textMenu("cohere_language", "Cohere language", CohereTranscribeLanguage.allCases.map { .init(id: $0.rawValue, label: $0.label) }, \.cohereLanguage)
        textMenu("whisper_language", "Whisper language", WhisperKitLanguage.allCases.map { .init(id: $0.rawValue, label: $0.label) }, \.whisperLanguage)
        add("bodhan_language", "Bodhan language", BodhanLanguage.allCases.map { .init(id: $0.rawValue, label: $0.label) },
            read: { $0.bodhanLanguage }, unavailable: { value in
                guard let language = BodhanLanguage(rawValue: value) else { return "Unknown language." }
                let models = [self.config.sttModel, self.config.meetingTranscriptionModel].filter { BodhanModel(rawValue: $0) != nil }
                return models.allSatisfy { BodhanLanguage.choices(for: $0).contains(language) } ? nil : "This language requires Bodhan Flex. Change the selected Bodhan model first."
            }) { value in
                if let language = BodhanLanguage(rawValue: value) { self.selectBodhanLanguage(language) }
            }
        add("nemotron_language", "Nemotron language", Nemotron35Language.allCases.map { .init(id: $0.rawValue, label: $0.label) },
            read: { $0.nemotron35Language }) { value in
            if let language = Nemotron35Language(rawValue: value) { await self.setNemotron35Language(language) }
        }
        for (id, label, key, setter) in [
            ("dictation_microphone", "Dictation microphone", \AppConfig.dictationInputDeviceUID, selectDictationInputDeviceUID),
            ("meeting_microphone", "Meeting microphone", \AppConfig.meetingInputDeviceUID, selectMeetingInputDeviceUID)
        ] {
            let devices = cachedDictationInputDevices()
            add(id, label, [Choice(id: "automatic", label: "Automatic")] + devices.map { .init(id: $0.uid, label: $0.name) },
                read: { $0[keyPath: key] ?? "automatic" }, unavailable: { value in
                    value == "automatic" || self.cachedDictationInputDevices().contains(where: { $0.uid == value }) ? nil : "This microphone is no longer available."
                }) { setter($0 == "automatic" ? nil : $0) }
        }

        toggle("transcript_cleanup", "AI transcript cleanup", \.enablePostProcessor, apply: setPostProcessorEnabled)
        toggle("quill", "Quill rewrite selected text", \.enableQuilMode) { try checkShortcut(self.updateQuilModeEnabled($0), enabled: $0) }
        add("cleanup_source", "Cleanup source", TranscriptCleanupBackendOption.all.filter { !$0.isGemma4LiteRT }.map { .init(id: $0.backend, label: $0.label) },
            read: { TranscriptCleanupBackendOption.resolved($0.postProcessorBackend).isOnDevice ? TranscriptCleanupBackendOption.local.backend : $0.postProcessorBackend }) { value in
                self.selectPostProcessorBackend(.resolved(value))
            }
        add("cleanup_preset", "Cleanup prompt preset", TranscriptCleanupPrompts.presets(custom: config.customTranscriptCleanupPrompts).map { .init(id: $0.id, label: $0.name) },
            read: { $0.activeTranscriptCleanupPromptId }) { self.selectTranscriptCleanupPrompt(id: $0) }
        presets("cleanup_chatgpt_model", "ChatGPT cleanup model", SummaryModelPreset.chatGPTTranscriptCleanupModels, \.postProcessorChatGPTModel) {
            self.updatePostProcessorModel($0, for: .hosted(.chatGPT))
        }
        presets("cleanup_openai_model", "OpenAI cleanup model", SummaryModelPreset.openAIModels, \.postProcessorOpenAIModel) {
            self.updatePostProcessorModel($0, for: .hosted(.openAI))
        }
        presets("cleanup_openrouter_model", "OpenRouter cleanup model", SummaryModelPreset.openRouterModels, \.postProcessorOpenRouterModel) {
            self.updatePostProcessorModel($0, for: .hosted(.openRouter))
        }

        toggle("meeting_hover_transcript", "Show meeting transcript on hover", \.showMeetingTranscriptOnIndicatorHover)
        toggle("auto_record_meetings", "Auto-record calendar meetings", \.autoRecordMeetings)
        toggle("auto_export_meetings", "Auto-export meetings", \.autoExportMarkdownEnabled)
        toggle("meeting_reminders", "Scheduled meeting notifications", \.showScheduledMeetingNotifications)
        toggle("meeting_detection", "Detected meeting notifications", \.showMeetingDetectionNotification)
        toggle("meeting_hook", "Post-meeting hook", \.meetingHookEnabled)
        menu("recording_policy", "Save meeting recordings", MeetingRecordingSavePolicy.allCases, \.meetingRecordingSavePolicy, title: { $0 == .prompt ? "Ask every time" : $0.rawValue.capitalized })
        menu("meeting_reminder_time", "Meeting reminder timing", ScheduledMeetingNotificationLeadTime.allCases, \.scheduledMeetingNotificationLeadTime,
             title: { $0 == .atStart ? "At start" : "\(Int($0.seconds / 60)) minutes before" })
        menu("meeting_join_action", "Default meeting join action", MeetingJoinDefaultAction.allCases, \.meetingJoinDefaultAction, title: { $0.buttonLabel })
        textMenu("recording_format", "Meeting recording format", MeetingRecordingFileFormat.allCases.map { .init(id: $0.rawValue, label: $0.displayName) }, \.meetingRecordingFileFormat)
        textMenu("export_content", "Meeting export content", MeetingExportContent.allCases.map { .init(id: $0.rawValue, label: $0.displayName) }, \.autoExportMarkdownContent)
        textMenu("export_format", "Meeting export format", MeetingAutoExportFileFormat.allCases.map { .init(id: $0.rawValue, label: $0.displayName) }, \.autoExportFileFormat)
        add("upcoming_meetings", "Upcoming meetings window", UpcomingMeetingsWindow.allCases.map { .init(id: String($0.dayCount), label: $0.label) },
            read: { String($0.upcomingMeetingsDayCount) }) { value in
            if let count = Int(value) { self.updateUpcomingMeetingsWindow(dayCount: count) }
        }
        add("dictation_fallback_model", "Hosted dictation fallback model", backends.filter(\.supportsHostedDictationFallback).map { .init(id: backendID($0), label: $0.label) },
            read: { $0.sttBackend + ":" + $0.sttModel }, unavailable: { value in
                backends.first(where: { backendID($0) == value })?.isDownloaded == true ? nil : "Download this model first."
            }) { value in
            if let option = backends.first(where: { backendID($0) == value }) { self.selectBackend(option) }
        }
        let meetingModels = backends.filter(\.supportsMeetingTranscription)
        add("meeting_model", "Final meeting transcript model", meetingModels.map { .init(id: backendID($0), label: $0.label) },
            read: { $0.meetingTranscriptionBackend + ":" + $0.meetingTranscriptionModel }, unavailable: { value in
                if self.config.enableLiveStreamingPartials && self.config.resolvedMeetingLiveCaptionBackend.producesFinalTranscript {
                    return "The live transcript model also produces the final transcript. Change the live transcript model instead."
                }
                return meetingModels.first(where: { backendID($0) == value })?.isDownloaded == true ? nil : "Download this meeting model from Models first."
            }) { value in
            if let option = meetingModels.first(where: { backendID($0) == value }) { self.selectMeetingTranscriptionBackend(option) }
        }
        add("live_transcript", "Meeting live transcript model", [Choice(id: "off", label: "Off")] + MeetingLiveCaptionBackend.allCases.map { .init(id: $0.rawValue, label: $0.settingsLabel) },
            read: { $0.enableLiveStreamingPartials ? $0.resolvedMeetingLiveCaptionBackend.rawValue : "off" }, unavailable: { value in
                value == "off" || MeetingLiveCaptionBackend(rawValue: value)?.isDownloaded == true ? nil : "Download this live transcript model from Models first."
            }) { value in
            self.updateConfig {
                $0.enableLiveStreamingPartials = value != "off"
                if value != "off" { $0.meetingLiveCaptionBackend = value }
            }
        }
        add("summary_source", "Meeting summary backend", MeetingSummaryBackendOption.all.map { .init(id: $0.backend, label: $0.label) },
            read: { $0.meetingSummaryBackend }) { value in
            if let option = MeetingSummaryBackendOption.all.first(where: { $0.backend == value }) { self.selectMeetingSummaryBackend(option) }
        }
        presets("summary_chatgpt_model", "ChatGPT meeting summary model", SummaryModelPreset.chatGPTModels, \.chatGPTModel)
        presets("summary_openai_model", "OpenAI meeting summary model", SummaryModelPreset.openAIModels, \.openAIModel)
        textMenu("summary_openrouter_model", "OpenRouter meeting summary model", appState.openRouterSummaryModels.map { .init(id: $0.id, label: $0.label) }, \.openRouterModel)
        add("openrouter_dictation_model", "OpenRouter dictation model", appState.openRouterTranscriptionModels.map { .init(id: $0.id, label: $0.label) },
            read: { $0.openRouterDictationModel }) { self.selectOpenRouterDictationModel($0) }
        textMenu("custom_llm_format", "Custom LLM API format", CustomLLMFormat.allCases.map { .init(id: $0.rawValue, label: $0.label) }, \.customLLMFormat)

        let templates = [Choice(id: MeetingTemplates.autoID, label: MeetingTemplates.auto.title)]
            + builtInMeetingTemplates().map { Choice(id: $0.id, label: $0.title) }
            + customMeetingTemplates().map { Choice(id: $0.id, label: $0.name) }
        add("meeting_template", "Default meeting template", templates, read: { $0.defaultMeetingTemplateID }) {
            self.updateDefaultMeetingTemplate(id: $0)
        }
        let allLocalCleanup = PostProcessorOption.all.map(OnDeviceCleanupModel.gguf)
            + Gemma4LiteRTModel.allCases.map(OnDeviceCleanupModel.gemma4)
        let localQuill = allLocalCleanup.filter {
            switch $0 {
            case .gguf(let option): return option.supportsQuil && option.isDownloaded
            case .gemma4(let model): return Gemma4LiteRTModelStore.isAvailableLocally(model: model)
            }
        }
        add("cleanup_on_device_model", "On-device cleanup model", allLocalCleanup.map { .init(id: $0.quilModelID, label: $0.label) },
            read: { $0.postProcessorBackend == TranscriptCleanupBackendOption.gemma4LiteRT.backend ? $0.postProcessorGemmaModel : $0.activePostProcessorId },
            unavailable: { value in
                guard let model = allLocalCleanup.first(where: { $0.quilModelID == value }) else { return "Unknown model." }
                switch model {
                case .gguf(let option): return option.isDownloaded && option.isCompatible(with: self.selectedBackend) ? nil : "Download a compatible cleanup model first."
                case .gemma4(let model): return Gemma4LiteRTModelStore.isAvailableLocally(model: model) && TranscriptCleanupBackendOption.gemma4LiteRT.isCompatible(with: self.selectedBackend) ? nil : "Download a compatible Gemma cleanup model first."
                }
            }) { value in
            guard let model = allLocalCleanup.first(where: { $0.quilModelID == value }) else { return }
            switch model {
            case .gguf(let option): self.selectPostProcessor(option)
            case .gemma4(let model): self.selectGemma4PostProcessor(model)
            }
        }
        add("quill_source", "Quill model source", QuilModelSourceOption.all.map { .init(id: $0.id, label: $0.label) },
            read: { QuilModelSourceOption.resolved(for: .resolved($0.quilBackend)).id }, unavailable: { value in
                value == QuilModelSourceOption.localModels.id && localQuill.isEmpty ? "Download a Quill model from Models first." : nil
            }) { value in
            guard let source = QuilModelSourceOption.all.first(where: { $0.id == value }) else { return }
            self.updateConfig {
                if let backend = source.hostedBackend {
                    $0.quilBackend = backend.backend
                    $0.quilModel = TranscriptCleanupClient.defaultModel(for: backend)
                } else if let model = localQuill.first {
                    $0.quilBackend = model.quilBackend.backend
                    $0.quilModel = model.quilModelID
                }
            }
            if self.config.enableQuilMode { _ = self.ensureQuilModelIsAvailable() }
        }
        add("quill_local_model", "Local Quill model", localQuill.map { .init(id: $0.quilModelID, label: $0.quilLabel) },
            read: { $0.quilModel }) { value in
            guard let model = localQuill.first(where: { $0.quilModelID == value }) else { return }
            self.updateConfig { $0.quilBackend = model.quilBackend.backend; $0.quilModel = model.quilModelID }
            if self.config.enableQuilMode { _ = self.ensureQuilModelIsAvailable() }
        }
        func thinking(_ id: String, _ label: String, model: @escaping (AppConfig) -> String, key: WritableKeyPath<AppConfig, ReasoningEffort?>) {
            let efforts = ReasoningEffortPolicy.selectableEfforts(for: model(config))
            guard !efforts.isEmpty else { return }
            add(id, label, efforts.map { .init(id: $0.rawValue, label: $0.label) },
                read: { ReasoningEffortPolicy.resolvedEffort(for: model($0), preferred: $0[keyPath: key])?.rawValue ?? "" },
                presentation: .discreteSlider,
                unavailable: { value in
                    ReasoningEffortPolicy.selectableEfforts(for: model(self.config)).contains(where: { $0.rawValue == value }) ? nil : "This thinking level is unavailable for the selected model."
                }) { value in self.updateConfig { $0[keyPath: key] = ReasoningEffort(rawValue: value) } }
        }
        thinking("cua_thinking", "Computer use thinking", model: { ComputerUsePlannerClient.plannerModel(for: $0) }, key: \.computerUseReasoningEffort)
        thinking("cleanup_thinking", "Transcript cleanup thinking", model: {
            TranscriptCleanupClient.configuredModel(for: .resolved($0.postProcessorBackend), config: $0)
        }, key: \.transcriptCleanupReasoningEffort)
        thinking("summary_thinking", "Meeting summary thinking", model: {
            if $0.meetingSummaryBackend == MeetingSummaryBackendOption.chatGPT.backend {
                return $0.chatGPTModel.isEmpty ? SummaryModelPreset.chatGPTModels.first?.id ?? "" : $0.chatGPTModel
            }
            if $0.meetingSummaryBackend == MeetingSummaryBackendOption.openAI.backend {
                return $0.openAIModel.isEmpty ? SummaryModelPreset.openAIModels.first?.id ?? "" : $0.openAIModel
            }
            return ""
        }, key: \.meetingSummaryReasoningEffort)
        for calendar in appState.availableEventKitCalendars {
            add("calendar_" + calendar.id, "Include calendar: " + calendar.sourceTitle + " / " + calendar.title,
                [.init(id: "on", label: "Included"), .init(id: "off", label: "Hidden")],
                read: { $0.disabledCalendarIDs.contains(calendar.id) ? "off" : "on" }) { value in
                self.updateConfig {
                    var disabled = Set($0.disabledCalendarIDs)
                    if value == "off" { disabled.insert(calendar.id) } else { disabled.remove(calendar.id) }
                    $0.disabledCalendarIDs = disabled.sorted()
                }
                await self.refreshUpcomingCalendarEvents()
            }
        }
        for app in MuesliSettings.meetingDetectionAppOptions {
            add("mute_meeting_detection_" + app.bundleID, "Mute meeting detection for " + app.name,
                [.init(id: "on", label: "Muted"), .init(id: "off", label: "Not muted")],
                read: { $0.mutedMeetingDetectionAppBundleIDs.contains(app.bundleID) ? "on" : "off" }) { value in
                self.updateConfig {
                    var muted = Set($0.mutedMeetingDetectionAppBundleIDs)
                    if value == "on" { muted.insert(app.bundleID) } else { muted.remove(app.bundleID) }
                    $0.mutedMeetingDetectionAppBundleIDs = muted.sorted()
                }
            }
        }
        if config.maraudersMapUnlocked {
            add("marauders_audio", "Meeting countdown audio", SoundController.maraudersMapPresets.map { .init(id: $0.id, label: $0.label) },
                read: { $0.maraudersMapAudioClip }) { value in
                SoundController.stopMaraudersMapClip()
                self.updateConfig { $0.maraudersMapAudioClip = value; $0.maraudersMapCustomAudioPath = nil }
                self.updateMaraudersMapAudioClip()
            }
        }
        return settings
    }
}

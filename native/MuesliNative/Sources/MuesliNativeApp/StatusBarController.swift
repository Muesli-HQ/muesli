import AppKit
import Foundation
import MuesliCore

final class CalendarMenuMeetingPayload: NSObject {
    let event: UnifiedCalendarEvent
    let title: String
    let calendarOccurrence: CalendarOccurrenceReference
    let endDate: Date
    let autoStopSource: MeetingAutoStopSource?

    init(event: UnifiedCalendarEvent) {
        self.event = event
        self.title = event.title
        self.calendarOccurrence = event.resolvedCalendarOccurrence
        self.endDate = event.endDate
        self.autoStopSource = event.meetingURL.flatMap { MeetingAutoStopSource(meetingURL: $0) }
    }
}

/// Stable setting IDs are revalidated by the shared settings executor on selection.
final class CleanupMenuSelection: NSObject {
    let setting: String
    let value: String
    let backend: TranscriptCleanupBackendOption?

    init(setting: String, value: String, backend: TranscriptCleanupBackendOption? = nil) {
        self.setting = setting
        self.value = value
        self.backend = backend
    }
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let controller: MuesliController
    private let runtime: RuntimePaths
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var countdownOverride: String?

    init(controller: MuesliController, runtime: RuntimePaths) {
        self.controller = controller
        self.runtime = runtime
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        build()
    }

    func setStatus(_ text: String) {}

    func refresh() {
        rebuildMenu()
        updateMenuBarTitle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func setCountdownOverride(_ text: String?) {
        countdownOverride = text
        updateMenuBarTitle()
    }

    func refreshIcon() {
        statusItem.button?.image = MenuBarIconRenderer.make(choice: controller.config.menuBarIcon)
        updateMenuBarTitle()
    }

    func updateMenuBarTitle() {
        let detail: String?
        if let countdownOverride {
            detail = countdownOverride
        } else if controller.config.showNextMeetingInMenuBar {
            let now = Date()
            let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
            let nextEvent = controller.appState.visibleUpcomingCalendarEvents
                .filter { $0.startDate > now && $0.startDate < endOfToday }
                .sorted { $0.startDate < $1.startDate }
                .first

            if let event = nextEvent {
                let minutesUntil = Int(ceil(event.startDate.timeIntervalSince(now) / 60))
                let truncatedTitle = event.title.count > 20
                    ? String(event.title.prefix(18)) + "…"
                    : event.title
                detail = minutesUntil <= 60
                    ? "\(truncatedTitle) · \(formatTimeUntil(minutesUntil))"
                    : truncatedTitle
            } else {
                detail = nil
            }
        } else {
            detail = nil
        }
        statusItem.button?.attributedTitle = MenuBarIconRenderer.statusTitle(
            hotkey: controller.config.dictationHotkey,
            showsHotkey: controller.config.showHotkeyInMenuBar,
            detail: detail
        )
    }

    private func build() {
        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.make(choice: controller.config.menuBarIcon)
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = AppIdentity.displayName
        }
        rebuildMenu()
        updateMenuBarTitle()
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Upcoming calendar events
        let upcomingEvents = controller.appState.visibleUpcomingCalendarEvents
        if !upcomingEvents.isEmpty {
            addUpcomingEventsSection(upcomingEvents)
            menu.addItem(.separator())
        }

        menu.addItem(actionItem(title: "Open \(AppIdentity.displayName)", action: #selector(MuesliController.openHistoryWindow as (MuesliController) -> () -> Void)))
        if controller.isMeetingRecording() {
            let pauseTitle = controller.isMeetingRecordingPaused() ? "Resume Meeting Recording" : "Pause Meeting Recording"
            menu.addItem(actionItem(title: pauseTitle, action: #selector(MuesliController.toggleMeetingRecordingPause)))
            menu.addItem(actionItem(title: "Stop Meeting Recording", action: #selector(MuesliController.toggleMeetingRecording)))
            if controller.visualMemory.recordingMeetingID != nil {
                menu.addItem(actionItem(title: controller.visualMemory.pauseState.userPaused ? "Resume Screen Recording" : "Pause Screen Recording", action: #selector(MuesliController.toggleMeetingScreenPause)))
                menu.addItem(actionItem(title: "Stop Screen Recording", action: #selector(MuesliController.stopMeetingScreenRecording)))
            } else {
                let screen = actionItem(title: controller.visualMemory.isPreparing ? "Preparing Screen Recording…" : "Record Screen…", action: #selector(MuesliController.startMeetingScreenRecording))
                screen.isEnabled = !controller.isMeetingRecordingPaused() && !controller.visualMemory.isPreparing && !controller.visualMemory.isFinalizing
                menu.addItem(screen)
            }
            menu.addItem(actionItem(title: "Discard Meeting Recording...", action: #selector(MuesliController.discardMeetingWithConfirmation)))
        } else {
            menu.addItem(actionItem(
                title: "Start Meeting Recording",
                action: #selector(MuesliController.startMeetingRecordingFromMenuBar)
            ))
        }
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recentRows = controller.recentDictations()
        if recentRows.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for row in recentRows {
                let item = NSMenuItem(title: controller.truncate(row.rawText, limit: 54), action: #selector(MuesliController.copyRecentDictation(_:)), keyEquivalent: "")
                item.target = controller
                item.representedObject = row.rawText
                recentMenu.addItem(item)
            }
        }
        menu.setSubmenu(recentMenu, for: recentItem)
        menu.addItem(recentItem)

        let dictationModelItem = NSMenuItem(title: "Dictation Model", action: nil, keyEquivalent: "")
        let dictationModelMenu = NSMenu()
        dictationModelMenu.addItem(.sectionHeader(title: "Local"))
        for option in BackendOption.downloaded {
            let isSelected = controller.selectedDictationProvider == .local
                && controller.selectedBackend == option
            let prefix = isSelected ? "✓ " : ""
            let item = NSMenuItem(
                title: "\(prefix)\(option.label)",
                action: #selector(MuesliController.selectLocalDictationModelFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            item.representedObject = option.label
            dictationModelMenu.addItem(item)
        }

        let hostedVisibility = controller.hostedDictationModelVisibility
        if hostedVisibility.shows(.openAI) {
            dictationModelMenu.addItem(.separator())
            dictationModelMenu.addItem(.sectionHeader(title: "OpenAI"))
            var openAIModels = OpenAITranscriptionClient.modelPresets
            let configuredOpenAIModel = controller.config.openaiDictationModel
            if !openAIModels.contains(configuredOpenAIModel) {
                openAIModels.append(configuredOpenAIModel)
            }
            for model in openAIModels {
                let isSelected = controller.selectedDictationProvider == .openAI
                    && configuredOpenAIModel == model
                let prefix = isSelected ? "✓ " : ""
                let item = NSMenuItem(
                    title: "\(prefix)\(model)",
                    action: #selector(MuesliController.selectOpenAIDictationModelFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = controller
                item.representedObject = model
                dictationModelMenu.addItem(item)
            }
        }

        if hostedVisibility.shows(.openRouter) {
            controller.loadOpenRouterModels(.transcription)
            dictationModelMenu.addItem(.separator())
            dictationModelMenu.addItem(.sectionHeader(title: "OpenRouter"))
            let openRouterModels = OpenRouterModelSelection.presetsIncludingConfiguredModel(
                controller.appState.openRouterTranscriptionModels,
                configuredModel: controller.config.openRouterDictationModel
            )
            if openRouterModels.isEmpty {
                let item = NSMenuItem(title: "Choose a model in Settings…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                dictationModelMenu.addItem(item)
            } else {
                for preset in openRouterModels {
                    let isSelected = controller.selectedDictationProvider == .openRouter
                        && controller.config.openRouterDictationModel == preset.id
                    let prefix = isSelected ? "✓ " : ""
                    let item = NSMenuItem(
                        title: "\(prefix)\(preset.label)",
                        action: #selector(MuesliController.selectOpenRouterDictationModelFromMenu(_:)),
                        keyEquivalent: ""
                    )
                    item.target = controller
                    item.representedObject = preset.id
                    dictationModelMenu.addItem(item)
                }
            }
        }
        menu.setSubmenu(dictationModelMenu, for: dictationModelItem)
        menu.addItem(dictationModelItem)

        menu.addItem(cleanupModelMenuItem())

        let meetingBackendItem = NSMenuItem(title: "Meetings Backend", action: nil, keyEquivalent: "")
        let meetingBackendMenu = NSMenu()
        for option in MeetingSummaryBackendOption.selectable(
            config: controller.config,
            selected: controller.selectedMeetingSummaryBackend
        ) {
            let prefix = controller.selectedMeetingSummaryBackend == option ? "✓ " : ""
            let item = NSMenuItem(
                title: "\(prefix)\(option.label)",
                action: #selector(MuesliController.selectMeetingSummaryBackendFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            item.representedObject = option.label
            meetingBackendMenu.addItem(item)
        }
        menu.setSubmenu(meetingBackendMenu, for: meetingBackendItem)
        menu.addItem(meetingBackendItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Settings…", action: #selector(MuesliController.openSettingsTab)))
        menu.addItem(actionItem(title: "What's New in muesli", action: #selector(MuesliController.showWhatsNew)))
        menu.addItem(checkForUpdatesItem())
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit", action: #selector(MuesliController.quitApp)))
    }

    private func cleanupModelMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: controller.config.enablePostProcessor ? "Cleanup Model" : "Cleanup: Off", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let config = controller.config

        func item(_ title: String, selection: CleanupMenuSelection, selected: Bool = false, reason: String? = nil) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: #selector(MuesliController.selectCleanupModelFromMenu(_:)), keyEquivalent: "")
            result.target = controller
            result.representedObject = selection
            result.state = selected ? .on : .off
            result.isEnabled = reason == nil
            result.toolTip = reason
            return result
        }
        let toggle = item(config.enablePostProcessor ? "Turn Off Cleanup" : "Turn On Cleanup",
            selection: .init(setting: "transcript_cleanup", value: config.enablePostProcessor ? "off" : "on"))
        toggle.target = self
        toggle.action = #selector(toggleCleanupFromMenu(_:))
        submenu.addItem(toggle)
        submenu.addItem(.separator())
        guard config.enablePostProcessor else {
            submenu.addItem(actionItem(title: "Cleanup Settings…", action: #selector(MuesliController.openSettingsTab)))
            root.submenu = submenu
            return root
        }
        let definitions = controller.cleanupModelDefinitions()
        let selectedBackend = TranscriptCleanupBackendOption.resolved(config.postProcessorBackend)
        let downloadedLocalIDs = PostProcessorOption.downloadedIDs.union(
            Gemma4LiteRTModel.allCases.filter { Gemma4LiteRTModelStore.isAvailableLocally(model: $0) }.map(\.repoID)
        )
        if let local = definitions.first(where: { $0.id == "cleanup_on_device_model" }) {
            let choices = local.choices.filter { downloadedLocalIDs.contains($0.id) }
            if !choices.isEmpty { submenu.addItem(.sectionHeader(title: "Local Models")) }
            for choice in choices {
                submenu.addItem(item(choice.label,
                    selection: .init(setting: local.id, value: choice.id),
                    selected: selectedBackend.isOnDevice && local.read(config) == choice.id,
                    reason: local.availability(choice.id, source: .manualUI)))
            }
            if !choices.isEmpty { submenu.addItem(.separator()) }
        }
        submenu.addItem(.sectionHeader(title: "Hosted & Server Models"))
        for backend in TranscriptCleanupBackendOption.all where !backend.isOnDevice {
            let provider = NSMenuItem(title: backend.label, action: nil, keyEquivalent: "")
            let models = NSMenu()
            models.autoenablesItems = false
            let settingID = "cleanup_\(backend.backend)_model"
            let definition = definitions.first { $0.id == settingID }
            let configured = TranscriptCleanupClient.configuredModel(for: backend, config: config)
            let current = definition?.read(config) ?? configured
            var choices = definition?.choices ?? []
            // Custom/server model IDs remain editable in Settings. Here, selecting
            // their saved value only switches the source, without creating a new value.
            if !current.isEmpty && !choices.contains(where: { $0.id == current }) {
                choices.append(.init(id: current, label: current))
            }
            for choice in choices {
                let isPreset = definition?.choices.contains(where: { $0.id == choice.id }) == true
                let ready = TranscriptCleanupClient.hasRequiredSettings(for: backend, config: config,
                    isChatGPTAuthenticated: controller.appState.isChatGPTAuthenticated, modelOverride: choice.id)
                models.addItem(item(choice.label,
                    selection: .init(setting: isPreset ? settingID : "cleanup_source", value: isPreset ? choice.id : backend.backend, backend: backend),
                    selected: selectedBackend == backend && current == choice.id,
                    reason: ready ? definition?.availability(choice.id, source: .manualUI) : "Configure \(backend.label) in Settings first."))
            }
            if choices.isEmpty {
                let empty = NSMenuItem(title: "Choose a model in Settings…", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                models.addItem(empty)
            }
            models.addItem(.separator())
            models.addItem(actionItem(title: "Configure in Settings…", action: #selector(MuesliController.openSettingsTab)))
            provider.state = selectedBackend == backend ? .on : .off
            provider.submenu = models
            submenu.addItem(provider)
        }
        submenu.addItem(.separator())
        submenu.addItem(actionItem(title: "Cleanup Settings…", action: #selector(MuesliController.openSettingsTab)))
        root.submenu = submenu
        return root
    }

    @objc private func toggleCleanupFromMenu(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? CleanupMenuSelection else { return }
        Task { @MainActor in
            do {
                try await controller.applySetting(selection.setting, value: selection.value)
                // AppKit dismisses action menus. After enabling succeeds, open the
                // model picker directly so choosing a model needs no second trip.
                guard selection.value == "on", controller.config.enablePostProcessor,
                      let button = statusItem.button,
                      let picker = cleanupModelMenuItem().submenu else { return }
                picker.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Cleanup could not be changed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func addUpcomingEventsSection(_ events: [UnifiedCalendarEvent]) {
        let now = Date()
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let futureEvents = events
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
        let nextUpEvents = futureEvents.filter { $0.startDate.timeIntervalSince(now) <= 3600 }
        let laterEvents = futureEvents.filter { $0.startDate.timeIntervalSince(now) > 3600 }

        if !nextUpEvents.isEmpty {
            let firstEvent = nextUpEvents[0]
            let minutesUntil = Int(ceil(firstEvent.startDate.timeIntervalSince(now) / 60))
            addUpcomingEventGroup(
                title: "Starts in \(formatTimeUntil(minutesUntil))",
                events: nextUpEvents,
                timeFormatter: timeFormatter
            )
        }

        let groupedEvents = Dictionary(grouping: laterEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        for day in groupedEvents.keys.sorted() {
            let dayEvents = (groupedEvents[day] ?? []).sorted { $0.startDate < $1.startDate }
            addUpcomingEventGroup(
                title: upcomingMenuHeader(for: day, calendar: calendar),
                events: dayEvents,
                timeFormatter: timeFormatter,
                limit: 5
            )
        }
    }

    private func addUpcomingEventGroup(
        title: String,
        events: [UnifiedCalendarEvent],
        timeFormatter: DateFormatter,
        limit: Int? = nil
    ) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        header.attributedTitle = NSAttributedString(string: title, attributes: headerAttrs)
        menu.addItem(header)

        let displayedEvents = limit.map { Array(events.prefix($0)) } ?? events
        for event in displayedEvents {
            let timeStr = "\(timeFormatter.string(from: event.startDate)) – \(timeFormatter.string(from: event.endDate))"
            let item = NSMenuItem(
                title: "\(event.title)\n\(timeStr)",
                action: nil,
                keyEquivalent: ""
            )
            let payload = CalendarMenuMeetingPayload(event: event)
            let actions = NSMenu()
            let record = actionItem(title: "Record Meeting", action: #selector(MuesliController.startMeetingFromCalendarMenuItem(_:)))
            record.representedObject = payload
            actions.addItem(record)
            let hide = actionItem(title: "Hide from muesli", action: #selector(MuesliController.hideCalendarEventFromMenuItem(_:)))
            hide.representedObject = payload
            hide.toolTip = "Hide this occurrence from Coming Up and reminders. The calendar event is not deleted."
            actions.addItem(hide)
            item.submenu = actions

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let attributed = NSMutableAttributedString(string: event.title, attributes: titleAttrs)
            attributed.append(NSAttributedString(string: "\n\(timeStr)", attributes: timeAttrs))
            item.attributedTitle = attributed
            menu.addItem(item)
        }
    }

    private func upcomingMenuHeader(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInTomorrow(day) {
            return "Tomorrow"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: day)
    }

    private func formatTimeUntil(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remainingMinutes)m"
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = controller
        return item
    }

    private func checkForUpdatesItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(MuesliController.checkForUpdates),
            keyEquivalent: ""
        )
        item.target = controller
        item.isEnabled = controller.updaterController != nil
        return item
    }
}

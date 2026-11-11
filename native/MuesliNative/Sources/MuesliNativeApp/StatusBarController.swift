import AppKit
import QuartzCore
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
final class StatusBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let controller: MuesliController
    private let runtime: RuntimePaths
    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private var countdownOverride: String?
    private let documentTitles: CalendarDocumentTitleResolver
    private var documentTitleTask: Task<Void, Never>?
    private let captureDot = NSView(frame: .zero)
    private var captureIndicatorTimer: Timer?

    private var calendarTitleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?

    deinit {
        captureIndicatorTimer?.invalidate()
        calendarTitleTimer?.invalidate()
        documentTitleTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
    }

    init(controller: MuesliController, runtime: RuntimePaths,
         documentTitles: CalendarDocumentTitleResolver? = nil) {
        self.documentTitles = documentTitles ?? CalendarDocumentTitleResolver()
        self.controller = controller
        self.runtime = runtime
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        build()
        installCaptureIndicator()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendarAfterWake() }
        }
        clockObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendarAfterWake() }
        }
    }

    func setStatus(_ text: String) {}

    func refresh() {
        rebuildMenu()
        updateMenuBarTitle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        resolveInviteDocumentTitles()
        Task { [weak self] in
            guard let self else { return }
            await self.controller.refreshUpcomingCalendarEvents()
            self.refresh()
        }
    }

    private func resolveInviteDocumentTitles() {
        guard controller.config.showInviteDocuments, documentTitleTask == nil else { return }
        let now = Date()
        var events = CalendarMenuPresentation.ordered(controller.appState.visibleUpcomingCalendarEvents, now: now)
        if let featured = featuredEvent(now: now) { events.insert(featured, at: 0) }
        let documents = events.flatMap(\.documents)
        documentTitleTask = Task { [weak self] in
            guard let self else { return }
            defer { self.documentTitleTask = nil }
            if await self.documentTitles.resolve(documents), !Task.isCancelled { self.rebuildMenu() }
        }
    }

    private func refreshCalendarAfterWake() {
        refresh()
        Task { [weak self] in
            guard let self else { return }
            await self.controller.refreshUpcomingCalendarEvents()
            self.refresh()
        }
    }

    private func featuredEvent(now: Date) -> UnifiedCalendarEvent? {
        CalendarMenuPresentation.featured(controller.appState.visibleMenuBarCalendarEvents, now: now,
            activeOccurrenceKey: controller.activeLiveMeetingRecord()?.calendarOccurrence?.identityKey)
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
            detail = featuredEvent(now: now).flatMap {
                CalendarMenuPresentation.label($0, now: now, style: controller.config.calendarMenuLabelStyle)
            }
        } else {
            detail = nil
        }
        statusItem.button?.attributedTitle = MenuBarIconRenderer.statusTitle(
            hotkey: controller.config.dictationHotkey,
            showsHotkey: controller.config.showHotkeyInMenuBar,
            detail: detail
        )
        calendarTitleTimer?.invalidate()
        let deadline = CalendarMenuPresentation.nextRefresh(controller.appState.visibleMenuBarCalendarEvents, now: Date())
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        calendarTitleTimer = timer
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

    private func installCaptureIndicator() {
        guard let button = statusItem.button else { return }
        captureDot.wantsLayer = true
        captureDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        captureDot.layer?.cornerRadius = 4
        captureDot.layer?.borderWidth = 1
        captureDot.layer?.borderColor = NSColor.black.withAlphaComponent(0.65).cgColor
        captureDot.translatesAutoresizingMaskIntoConstraints = false
        captureDot.isHidden = true
        button.addSubview(captureDot)
        NSLayoutConstraint.activate([
            captureDot.widthAnchor.constraint(equalToConstant: 8),
            captureDot.heightAnchor.constraint(equalToConstant: 8),
            captureDot.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 24),
            captureDot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2)
        ])
        controller.visualMemory.onAmbientCaptureActivity = { [weak self] captured in
            guard let self else { return }
            self.updateCaptureIndicator()
            guard captured, !self.captureDot.isHidden,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 1
            pulse.duration = 0.7
            self.captureDot.layer?.add(pulse, forKey: "capturePulse")
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCaptureIndicator() }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureIndicatorTimer = timer
        updateCaptureIndicator()
    }

    private func updateCaptureIndicator() {
        let active = controller.visualMemory.ambientIndicatorActive
        captureDot.isHidden = !active
        if !active { captureDot.layer?.removeAnimation(forKey: "capturePulse") }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Upcoming calendar events
        let upcomingEvents = controller.appState.visibleUpcomingCalendarEvents
        if !upcomingEvents.isEmpty || featuredEvent(now: Date()) != nil {
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
        menu.addItem(timeTurnerMenuItem())
        if controller.config.enableFeedbackCapture {
            let active = controller.feedbackCaptureOwnsMicrophone
            let vidshot = actionItem(title: active ? "Finish Vidshot" : "Start Vidshot",
                action: active ? #selector(MuesliController.finishFeedbackCapture) : #selector(MuesliController.toggleFeedbackCapture))
            vidshot.image = VidshotIcon.image()
            menu.addItem(vidshot)
        }
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

        let featured = featuredEvent(now: now) ?? CalendarMenuPresentation.ordered(events, now: now).first
        if let featured {
            let header = NSMenuItem(title: featured.startDate <= now ? "Current meeting" : "Next meeting", action: nil, keyEquivalent: "")
            menu.addItem(header)
            let item = NSMenuItem(title: "\(controller.truncate(featured.title, limit: 60)) · \(CalendarMenuPresentation.time(featured, now: now))", action: nil, keyEquivalent: "")
            item.submenu = meetingActions(featured, includeDocuments: false)
            menu.addItem(item)
            // Visible actions and documents belong directly to the featured meeting.
            let actions = meetingActions(featured, includeDocuments: true, includeHide: false)
            for action in actions.items {
                actions.removeItem(action)
                // AppKit suppresses item images on indented menu rows.
                action.indentationLevel = action.image == nil ? 1 : 0
                menu.addItem(action)
            }
        }
        let laterEvents = CalendarMenuPresentation.ordered(events, now: now).filter {
            $0.resolvedCalendarOccurrence.identityKey != featured?.resolvedCalendarOccurrence.identityKey
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
            .font: AppFonts.medium(11),
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
            item.submenu = meetingActions(event)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: AppFonts.medium(13),
                .foregroundColor: NSColor.labelColor,
            ]
            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: AppFonts.regular(11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let attributed = NSMutableAttributedString(string: event.title, attributes: titleAttrs)
            attributed.append(NSAttributedString(string: "\n\(timeStr)", attributes: timeAttrs))
            item.attributedTitle = attributed
            menu.addItem(item)
        }
    }

    func meetingActions(_ event: UnifiedCalendarEvent, includeDocuments: Bool = true,
                                includeHide: Bool = true) -> NSMenu {
        let actions = NSMenu()
        // Explicit availability must survive AppKit menu validation.
        actions.autoenablesItems = false
        let payload = CalendarMenuMeetingPayload(event: event)
        let canRecord = !controller.isMeetingRecording() && !controller.appState.isMeetingStarting
        if let url = event.meetingURL, CalendarMonitor.isMeetingURL(url) {
            let join = actionItem(title: "Join", action: #selector(MuesliController.joinCalendarMeetingFromMenuItem(_:)))
            join.representedObject = payload
            actions.addItem(join)
            let record = actionItem(title: "Join & Record", action: #selector(joinAndRecordCalendarMeeting(_:)))
            record.target = self
            record.representedObject = payload
            record.isEnabled = canRecord
            actions.addItem(record)
        }
        let record = actionItem(title: "Record Only", action: #selector(recordCalendarMeeting(_:)))
        record.target = self
        record.representedObject = payload
        record.isEnabled = canRecord
        actions.addItem(record)
        if includeDocuments && controller.config.showInviteDocuments {
            for document in event.documents {
                let item = NSMenuItem(title: documentTitles.title(for: document), action: #selector(openInviteDocument(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = document.url
                item.toolTip = document.url.absoluteString
                item.image = NSImage(systemSymbolName: document.symbol, accessibilityDescription: "Document")
                actions.addItem(item)
            }
        }
        if includeHide {
            let hide = actionItem(title: "Hide from muesli", action: #selector(MuesliController.hideCalendarEventFromMenuItem(_:)))
            hide.representedObject = payload
            hide.toolTip = "Hide this occurrence from Coming Up and reminders. The calendar event is not deleted."
            actions.addItem(hide)
        }
        return actions
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(recordCalendarMeeting(_:)) || menuItem.action == #selector(joinAndRecordCalendarMeeting(_:)) {
            return !controller.isMeetingRecording() && !controller.appState.isMeetingStarting
        }
        return true
    }

    @objc private func recordCalendarMeeting(_ sender: NSMenuItem) {
        controller.startMeetingFromCalendarMenuItem(sender)
    }

    @objc private func joinAndRecordCalendarMeeting(_ sender: NSMenuItem) {
        controller.joinAndRecordCalendarMeetingFromMenuItem(sender)
    }

    @objc private func openInviteDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let safe = CalendarInviteDocument.safeURL(url.absoluteString),
              !CalendarMonitor.isMeetingURL(safe) else { return }
        NSWorkspace.shared.open(safe)
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

    private func timeTurnerMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Time Turner", action: nil, keyEquivalent: "")
        parent.image = TimeTurnerIcon.image()
        let submenu = NSMenu(title: "Time Turner")
        @discardableResult func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
            return item
        }
        if controller.config.timeTurnerEnabled {
            add(controller.visualMemory.ambientPaused ? "Resume Capture" : "Pause Capture", #selector(toggleTimeTurnerPause))
            add("Turn Off Time Turner", #selector(disableTimeTurner))
            if let app = NSWorkspace.shared.frontmostApplication,
               let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier {
                let excluded = controller.config.timeTurnerExcludedApps.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == bundle }
                if !excluded {
                    let item = add("Exclude “\(app.localizedName ?? bundle)”", #selector(excludeTimeTurnerApp(_:)))
                    item.representedObject = bundle
                }
            }
        } else {
            add("Enable Time Turner…", #selector(setupTimeTurner))
        }
        submenu.addItem(.separator())
        add("Time Turner Settings…", #selector(openTimeTurnerSettings))
        parent.submenu = submenu
        return parent
    }

    @objc private func toggleTimeTurnerPause() { controller.visualMemory.toggleAmbientPause(); refresh() }
    @objc private func disableTimeTurner() { controller.setSettingFromUI("time_turner_enabled", value: "off") }
    @objc private func setupTimeTurner() {
        controller.appState.requestsTimeTurnerSetup = true
        openTimeTurnerSettings()
    }
    @objc private func openTimeTurnerSettings() {
        controller.appState.selectedSettingsPane = .experimental
        controller.openSettingsTab()
    }
    @objc private func excludeTimeTurnerApp(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        controller.updateConfig { config in
            var bundles = Set(config.timeTurnerExcludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            bundles.insert(bundle)
            config.timeTurnerExcludedApps = bundles.sorted().joined(separator: ",")
        }
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

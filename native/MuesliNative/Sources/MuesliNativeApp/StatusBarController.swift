import AppKit
import Foundation
import MuesliCore

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
        refreshIcon()
        rebuildMenu()
        updateMenuBarTitle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func setCountdownOverride(_ text: String?) {
        countdownOverride = text
        if let text {
            statusItem.button?.title = text
        } else {
            updateMenuBarTitle()
        }
    }

    func refreshIcon() {
        let isActivelyRecording = controller.appState.dictationState == .recording
            || controller.isMeetingActivelyCapturing()
        statusItem.button?.image = MenuBarIconRenderer.make(choice: controller.config.menuBarIcon, recording: isActivelyRecording)
        updateMenuBarTitle()
    }

    func updateMenuBarTitle() {
        if let countdownOverride {
            statusItem.button?.title = countdownOverride
            return
        }
        guard controller.config.showNextMeetingInMenuBar else {
            statusItem.button?.title = ""
            return
        }

        let now = Date()
        let hidden = controller.appState.hiddenCalendarEventIDs
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        let nextEvent = controller.appState.upcomingCalendarEvents
            .filter { !$0.isAllDay && $0.startDate > now && $0.startDate < endOfToday && !hidden.contains($0.id) }
            .first

        if let event = nextEvent {
            let minutesUntil = Int(ceil(event.startDate.timeIntervalSince(now) / 60))
            let truncatedTitle = event.title.count > 20
                ? String(event.title.prefix(18)) + "…"
                : event.title
            if minutesUntil <= 60 {
                statusItem.button?.title = " \(truncatedTitle) · \(formatTimeUntil(minutesUntil))"
            } else {
                statusItem.button?.title = " \(truncatedTitle)"
            }
        } else {
            statusItem.button?.title = ""
        }
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
        let hidden = controller.appState.hiddenCalendarEventIDs
        let upcomingEvents = controller.appState.upcomingCalendarEvents.filter { !$0.isAllDay && !hidden.contains($0.id) }
        if !upcomingEvents.isEmpty {
            addUpcomingEventsSection(upcomingEvents)
            menu.addItem(.separator())
        }

        menu.addItem(actionItem(title: "Open \(AppIdentity.displayName)", action: #selector(MuesliController.openHistoryWindow as (MuesliController) -> () -> Void)))
        if controller.isMeetingRecording() {
            let pauseTitle = controller.isMeetingRecordingPaused() ? "Resume Meeting Recording" : "Pause Meeting Recording"
            menu.addItem(actionItem(title: pauseTitle, action: #selector(MuesliController.toggleMeetingRecordingPause)))
            menu.addItem(actionItem(title: "Stop Meeting Recording", action: #selector(MuesliController.toggleMeetingRecording)))
            menu.addItem(actionItem(title: "Discard Meeting Recording...", action: #selector(MuesliController.discardMeetingWithConfirmation)))
        } else {
            menu.addItem(actionItem(title: "Start Meeting Recording", action: #selector(MuesliController.toggleMeetingRecording)))
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

        let backendItem = NSMenuItem(title: "Transcription Backend", action: nil, keyEquivalent: "")
        let backendMenu = NSMenu()
        for option in BackendOption.downloaded {
            let prefix = controller.selectedBackend == option ? "✓ " : ""
            let item = NSMenuItem(title: "\(prefix)\(option.label)", action: #selector(MuesliController.selectBackendFromMenu(_:)), keyEquivalent: "")
            item.target = controller
            item.representedObject = option.label
            backendMenu.addItem(item)
        }
        menu.setSubmenu(backendMenu, for: backendItem)
        menu.addItem(backendItem)

        let meetingBackendItem = NSMenuItem(title: "Meetings Backend", action: nil, keyEquivalent: "")
        let meetingBackendMenu = NSMenu()
        for option in MeetingSummaryBackendOption.all {
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
        menu.addItem(actionItem(title: "Check for Updates…", action: #selector(MuesliController.checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit", action: #selector(MuesliController.quitApp)))
    }

    private func addUpcomingEventsSection(_ events: [UnifiedCalendarEvent]) {
        let now = Date()
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        // Group: next up (within 1 hour) vs today (rest of day)
        var nextUpEvents: [UnifiedCalendarEvent] = []
        var todayEvents: [UnifiedCalendarEvent] = []

        for event in events {
            guard event.startDate > now else { continue }
            if calendar.isDateInToday(event.startDate) {
                if event.startDate.timeIntervalSince(now) <= 3600 {
                    nextUpEvents.append(event)
                } else {
                    todayEvents.append(event)
                }
            }
        }

        if !nextUpEvents.isEmpty {
            let firstEvent = nextUpEvents[0]
            let minutesUntil = Int(ceil(firstEvent.startDate.timeIntervalSince(now) / 60))
            let header = NSMenuItem(title: "Starts in \(formatTimeUntil(minutesUntil))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            header.attributedTitle = NSAttributedString(string: "Starts in \(formatTimeUntil(minutesUntil))", attributes: headerAttrs)
            menu.addItem(header)

            for event in nextUpEvents {
                let timeStr = "\(timeFormatter.string(from: event.startDate)) – \(timeFormatter.string(from: event.endDate))"
                let item = NSMenuItem(
                    title: "\(event.title)\n\(timeStr)",
                    action: #selector(MuesliController.startMeetingFromCalendarMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = controller
                item.representedObject = event.title

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

        if !todayEvents.isEmpty {
            let header = NSMenuItem(title: "Today", action: nil, keyEquivalent: "")
            header.isEnabled = false
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            header.attributedTitle = NSAttributedString(string: "Today", attributes: headerAttrs)
            menu.addItem(header)

            for event in todayEvents.prefix(5) {
                let timeStr = "\(timeFormatter.string(from: event.startDate)) – \(timeFormatter.string(from: event.endDate))"
                let item = NSMenuItem(
                    title: "\(event.title)\n\(timeStr)",
                    action: #selector(MuesliController.startMeetingFromCalendarMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = controller
                item.representedObject = event.title

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
}

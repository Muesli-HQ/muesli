import AppKit
import SwiftUI
import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Calendar menu actions")
@MainActor
struct CalendarMenuActionTests {
    @Test func actionAvailabilityDocumentsAndOccurrenceMetadata() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil)
        let controller = MuesliController(runtime: runtime,
            dictationStore: DictationStore(databaseURL: directory.appendingPathComponent("test.db")),
            configStore: makeTestConfigStore(supportDirectory: directory))
        let titleResolver = CalendarDocumentTitleResolver(fetch: { _ in "Quarterly plan" })
        let status = StatusBarController(controller: controller, runtime: runtime, documentTitles: titleResolver)
        let now = Date()
        var event = UnifiedCalendarEvent(id: "fixture", title: "Design review", startDate: now,
                                         endDate: now.addingTimeInterval(1800), isAllDay: false, source: .eventKit,
                                         meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        event.documents = CalendarInviteDocument.extract(attachments: [["fileUrl": "https://example.com/brief", "title": "Design brief"]])
        let actions = status.meetingActions(event)
        #expect(actions.items.map(\.title) == ["Join", "Join & Record", "Record Only", "Design brief", "Hide from muesli"])
        let payload = try #require(actions.items[1].representedObject as? CalendarMenuMeetingPayload)
        #expect(payload.calendarOccurrence == event.resolvedCalendarOccurrence)
        #expect(payload.endDate == event.endDate)
        #expect(actions.items[3].image != nil)
        #expect(actions.items[3].representedObject as? URL == event.documents.first?.url)
        var genericEvent = event
        genericEvent.documents = CalendarInviteDocument.extract(text: "<a href='https://docs.google.com/spreadsheets/d/fixture/edit'>Google Sheet</a> https://tel.meet/fixture https://support.google.com/meet/answer/1")
        #expect(await titleResolver.resolve(genericEvent.documents))
        #expect(status.meetingActions(genericEvent).items.map(\.title) == ["Join", "Join & Record", "Record Only", "Quarterly plan", "Hide from muesli"])
        // Featured actions move into an automatically validated root menu.
        let root = NSMenu()
        let record = actions.items[1]
        actions.removeItem(record)
        root.addItem(record)
        controller.appState.isMeetingStarting = true
        root.update()
        #expect(!record.isEnabled)
        controller.appState.isMeetingStarting = false
        root.update()
        #expect(record.isEnabled)
        event.meetingURL = nil
        #expect(status.meetingActions(event, includeDocuments: false).items.map(\.title) == ["Record Only", "Hide from muesli"])
        controller.updateConfig { $0.showInviteDocuments = false }
        #expect(!status.meetingActions(event).items.contains { $0.title == "Design brief" })
        controller.updateConfig { $0.showInviteDocuments = true }
        controller.appState.upcomingCalendarEvents = [genericEvent]
        status.refresh()
        let featuredDocument = try #require(status.menu.items.first { $0.title == "Quarterly plan" })
        #expect(featuredDocument.image != nil)
        #expect(featuredDocument.indentationLevel == 0)
        // Opt-in native visual fixture: never starts the controller, queries calendars,
        // opens conference URLs, or records audio. Snapshot only this process's views.
        if let output = ProcessInfo.processInfo.environment["MUESLI_MENU_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            controller.updateConfig { $0.showInviteDocuments = true; $0.calendarMeetingLinksOnly = false }
            event.meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")
            let later = UnifiedCalendarEvent(id: "later", title: "Planning", startDate: now.addingTimeInterval(3600),
                endDate: now.addingTimeInterval(5400), isAllDay: false, source: .eventKit,
                meetingURL: event.meetingURL, documents: event.documents)
            controller.appState.upcomingCalendarEvents = [event, later]
            status.refresh()
            status.menu.delegate = nil
            captureMenu(status.menu, output: output, prefix: "menu")
            captureMenu(status.meetingActions(later), output: output, prefix: "agenda-submenu")
            controller.appState.selectedSettingsPane = .appearance
            let view = NSHostingView(rootView: SettingsView(appState: controller.appState, controller: controller))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 1200)
            view.layoutSubtreeIfNeeded()
            snapshot(view, path: output + "/appearance.png")
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 1800)
            view.layoutSubtreeIfNeeded()
            snapshot(view, path: output + "/appearance-narrow.png")
        }
    }
}

@MainActor
private func snapshot(_ view: NSView, path: String) {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

@MainActor
private func captureMenu(_ menu: NSMenu, output: String, prefix: String) {
    let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
        MainActor.assumeIsolated {
            for (index, window) in NSApplication.shared.windows.filter({ $0.isVisible && $0.frame.height > 100 }).enumerated() {
                if let view = window.contentView { snapshot(view, path: output + "/\(prefix)-\(index).png") }
            }
            menu.cancelTracking()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    menu.popUp(positioning: nil, at: NSPoint(x: 300, y: 700), in: nil)
}

import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Standard app menu shortcuts", .serialized)
@MainActor
struct StandardMenuShortcutTests {
    @Test("Window menu configuration retains its direct submenu reference")
    func windowMenuConfigurationRetainsDirectSubmenuReference() {
        let menus = AppDelegate().standardMenus()
        #expect(menus.mainMenu.items.contains { $0.submenu === menus.windowMenu })
    }

    @Test("app menu exposes standard hide commands")
    func appMenuExposesStandardHideCommands() throws {
        let appMenu = try requiredMenu(standardMainMenu().items.first?.submenu, message: "Missing app menu")

        let hide = try requiredItem(appMenu.item(withTitle: "Hide \(AppIdentity.displayName)"), message: "Missing Hide command")
        #expect(hide.action == #selector(NSApplication.hide(_:)))
        #expect(hide.keyEquivalent == "h")
        #expect(hide.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)

        let hideOthers = try requiredItem(appMenu.item(withTitle: "Hide Others"), message: "Missing Hide Others command")
        #expect(hideOthers.action == #selector(NSApplication.hideOtherApplications(_:)))
        #expect(hideOthers.keyEquivalent == "h")
        #expect(hideOthers.keyEquivalentModifierMask == [.command, .option])

        let showAll = try requiredItem(appMenu.item(withTitle: "Show All"), message: "Missing Show All command")
        #expect(showAll.action == #selector(NSApplication.unhideAllApplications(_:)))
    }

    @Test("Window menu exposes standard window management commands")
    func windowMenuExposesStandardWindowManagementCommands() throws {
        let windowMenu = try requiredMenu(standardMainMenu().item(withTitle: "Window")?.submenu, message: "Missing Window menu")

        let minimize = try requiredItem(windowMenu.item(withTitle: "Minimize"), message: "Missing Minimize command")
        #expect(minimize.action == #selector(NSWindow.performMiniaturize(_:)))
        #expect(minimize.keyEquivalent == "m")
        #expect(minimize.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)

        let zoom = try requiredItem(windowMenu.item(withTitle: "Zoom"), message: "Missing Zoom command")
        #expect(zoom.action == #selector(NSWindow.performZoom(_:)))

        let close = try requiredItem(windowMenu.item(withTitle: "Close Window"), message: "Missing Close Window command")
        #expect(close.action == #selector(NSWindow.performClose(_:)))
        #expect(close.keyEquivalent == "w")
        #expect(close.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)

        let bringAllToFront = try requiredItem(windowMenu.item(withTitle: "Bring All to Front"), message: "Missing Bring All to Front command")
        #expect(bringAllToFront.action == #selector(NSApplication.arrangeInFront(_:)))
    }

    @Test("View menu exposes dashboard navigation shortcuts")
    func viewMenuExposesDashboardNavigationShortcuts() throws {
        let viewMenu = try requiredMenu(standardMainMenu().item(withTitle: "View")?.submenu, message: "Missing View menu")

        let dictations = try requiredItem(viewMenu.item(withTitle: "Dictations"), message: "Missing Dictations command")
        #expect(dictations.action == #selector(AppDelegate.showDictations(_:)))
        #expect(dictations.keyEquivalent == "1")
        #expect(dictations.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)

        let meetings = try requiredItem(viewMenu.item(withTitle: "Meetings"), message: "Missing Meetings command")
        #expect(meetings.action == #selector(AppDelegate.showMeetings(_:)))
        #expect(meetings.keyEquivalent == "2")
        #expect(meetings.keyEquivalentModifierMask == NSEvent.ModifierFlags.command)
    }

    @Test("Meeting menu provides a stop shortcut and confirmed discard without a status icon")
    func meetingMenuProvidesIndependentStop() throws {
        let delegate = AppDelegate()
        let menu = try requiredMenu(delegate.standardMenus().mainMenu.item(withTitle: "Meeting")?.submenu,
                                    message: "Missing Meeting menu")
        let stop = try requiredItem(menu.item(withTitle: "Stop Recording"), message: "Missing Stop command")
        #expect(stop.action == #selector(AppDelegate.stopMeeting(_:)))
        #expect(stop.target === delegate)
        #expect(stop.keyEquivalent == ".")
        #expect(stop.keyEquivalentModifierMask == [.command])
        #expect(!delegate.validateMenuItem(stop))
        let discard = try requiredItem(menu.item(withTitle: "Discard Recording…"), message: "Missing Discard command")
        #expect(discard.action == #selector(AppDelegate.discardMeeting(_:)))
        #expect(discard.keyEquivalent.isEmpty)
        #expect(!delegate.validateMenuItem(discard))

        // Exercise AppKit matching as well as the menu configuration, including
        // punctuation (whose shifted key equivalents are easy to misconfigure).
        let probe = MeetingMenuActionProbe()
        stop.target = probe
        stop.action = #selector(MeetingMenuActionProbe.stop(_:))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: ".", charactersIgnoringModifiers: ".",
            isARepeat: false, keyCode: 47
        ))
        #expect(menu.performKeyEquivalent(with: event))
        #expect(probe.stopCount == 1)
    }

    @Test("reopen preserves visible navigation and ordinary non-meeting behavior")
    func reopenPreservesDefaultBehavior() {
        for (visible, recording) in [(true, true), (true, false), (false, false)] {
            var calls = 0
            let useDefault = AppDelegate.handleReopen(
                hasVisibleWindows: visible, isMeetingRecording: recording,
                openActiveNotes: { calls += 1; return true },
                openHistory: { calls += 1 }
            )
            #expect(useDefault)
            #expect(calls == 0)
        }
    }

    @Test("closed meeting reopen falls back to history when active notes are unavailable", arguments: [false, true])
    func reopenDuringMeetingRetirement(notesAvailable: Bool) {
        var notesCalls = 0
        var historyCalls = 0
        let useDefault = AppDelegate.handleReopen(
            hasVisibleWindows: false, isMeetingRecording: true,
            openActiveNotes: { notesCalls += 1; return notesAvailable },
            openHistory: { historyCalls += 1 }
        )
        #expect(!useDefault)
        #expect(notesCalls == 1)
        #expect(historyCalls == (notesAvailable ? 0 : 1))
    }

    @Test("meeting commands are blocked while a confirmation sheet is attached")
    func meetingCommandsRespectModalCancellation() async throws {
        let host = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        host.isReleasedWhenClosed = false
        host.orderFrontRegardless()
        let alert = NSAlert()
        alert.messageText = "Discard test meeting?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        defer {
            if host.attachedSheet != nil { host.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
            host.close()
        }
        #expect(AppDelegate.meetingCommandsEnabled(isMeetingRecording: true))
        #expect(!AppDelegate.meetingCommandsEnabled(isMeetingRecording: false))
        alert.beginSheetModal(for: host) { _ in }
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.attachedSheet != nil)
        #expect(!AppDelegate.meetingCommandsEnabled(isMeetingRecording: true))
        host.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        #expect(AppDelegate.meetingCommandsEnabled(isMeetingRecording: true))
    }

    private func standardMainMenu() -> NSMenu {
        AppDelegate().standardMenus().mainMenu
    }

    private func requiredMenu(_ menu: NSMenu?, message: String) throws -> NSMenu {
        guard let menu else {
            throw MenuTestError(message: message)
        }
        return menu
    }

    private func requiredItem(_ item: NSMenuItem?, message: String) throws -> NSMenuItem {
        guard let item else {
            throw MenuTestError(message: message)
        }
        return item
    }
}

@MainActor
private final class MeetingMenuActionProbe: NSObject {
    var stopCount = 0
    @objc func stop(_ sender: Any?) { stopCount += 1 }
}

private struct MenuTestError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

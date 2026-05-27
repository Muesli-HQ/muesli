import AppKit
import Foundation
import SwiftUI
import MuesliCore

@MainActor
final class RecentHistoryWindowController: NSObject, NSWindowDelegate {
    private let store: DictationStore
    private let controller: MuesliController
    private var window: NSWindow?
    private var keyMonitor: Any?

    var presentationWindow: NSWindow? {
        window
    }

    init(store: DictationStore, controller: MuesliController) {
        self.store = store
        self.controller = controller
    }

    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        controller.syncAppState()
        if !window.isVisible {
            controller.noteWindowOpened()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func reload() {
        controller.syncAppState()
    }

    func close() {
        window?.close()
    }

    func updateBackendLabel() {
        controller.syncAppState()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        controller.noteWindowClosed()
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 140, width: 1120, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1) // #111214

        let rootView = DashboardRootView(
            appState: controller.appState,
            controller: controller
        )
        window.contentView = NSHostingView(rootView: rootView)

        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "f" else {
                return event
            }
            self.controller.appState.focusSearchField = true
            return nil
        }
    }
}

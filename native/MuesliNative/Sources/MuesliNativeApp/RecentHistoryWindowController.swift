import AppKit
import Foundation
import SwiftUI
import MuesliCore

struct DashboardPresentationReadiness<Action> {
    private(set) var isReady = false
    private(set) var isInitialLayoutScheduled = false
    private var queuedActions: [Action] = []

    mutating func enqueue(_ action: Action) -> [Action] {
        guard !isReady else { return [action] }
        queuedActions.append(action)
        return []
    }

    mutating func requestInitialLayout() -> Bool {
        guard !isReady, !isInitialLayoutScheduled else { return false }
        isInitialLayoutScheduled = true
        return true
    }

    mutating func completeInitialLayout() -> [Action] {
        isInitialLayoutScheduled = false
        isReady = true
        let actions = queuedActions
        queuedActions.removeAll()
        return actions
    }

    mutating func cancelInitialLayout() {
        isInitialLayoutScheduled = false
    }
}

@MainActor
final class RecentHistoryWindowController: NSObject, NSWindowDelegate {
    typealias ReadyAction = () -> Void

    private let store: DictationStore
    private let controller: MuesliController
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var presentationReadiness = DashboardPresentationReadiness<ReadyAction>()

    var presentationWindow: NSWindow? {
        window
    }

    init(store: DictationStore, controller: MuesliController) {
        self.store = store
        self.controller = controller
    }

    func show(whenReady readyAction: ReadyAction? = nil) {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        applyAppearance(to: window)
        controller.syncAppState()
        if !window.isVisible {
            controller.noteWindowOpened()
        }

        if let readyAction {
            run(presentationReadiness.enqueue(readyAction))
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        scheduleInitialOrderedLayoutIfNeeded(for: window)
    }

    func reload() {
        if let window {
            applyAppearance(to: window)
        }
        controller.syncAppState()
    }

    /// The window is created before SwiftUI applies `preferredColorScheme`, and AppKit chrome
    /// (transparent titlebar, traffic lights, resize corners) resolves against the window's own
    /// appearance rather than the SwiftUI environment. Without this the titlebar keeps rendering
    /// dark while the app is set to the light theme.
    private func applyAppearance(to window: NSWindow) {
        let name: NSAppearance.Name = controller.appState.config.darkMode ? .darkAqua : .aqua
        if window.appearance?.name != name {
            window.appearance = NSAppearance(named: name)
        }
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
        window.backgroundColor = MuesliTheme.backgroundDeepNSColor
        applyAppearance(to: window)

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

    private func scheduleInitialOrderedLayoutIfNeeded(for window: NSWindow) {
        guard presentationReadiness.requestInitialLayout() else { return }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            guard let window, self.window === window else {
                self.presentationReadiness.cancelInitialLayout()
                return
            }

            // An ordered AppKit window can report isVisible == false while a
            // different full-screen Space is active. Its hosting hierarchy is
            // still ready for layout, and feature UI must not wait on occlusion.
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            let actions = self.presentationReadiness.completeInitialLayout()
            self.run(actions)
        }
    }

    private func run(_ actions: [ReadyAction]) {
        for action in actions {
            action()
        }
    }
}

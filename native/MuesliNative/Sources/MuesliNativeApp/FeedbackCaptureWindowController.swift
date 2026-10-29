import AppKit
import SwiftUI

@MainActor
final class FeedbackCaptureWindowController: NSObject, NSWindowDelegate {
    private let controller: FeedbackCaptureController
    private var window: NSWindow?
    init(controller: FeedbackCaptureController) { self.controller = controller; super.init() }
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }
    func show(id: String?) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Scrawl captures"
            window.contentMinSize = NSSize(width: 540, height: 400)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        let hosting = NSHostingView(rootView: FeedbackCaptureView(controller: controller, selectedID: id)
            .frame(minWidth: 540, minHeight: 400))
        hosting.sizingOptions = [.minSize]
        window?.contentView = hosting
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

import AppKit
import SwiftUI
import MuesliCore
import OSLog
import QuartzCore

/// Owns focus windows independently of SwiftUI layout and hit testing.
@MainActor final class TimeTurnerFocusPresenter {

    static let shared = TimeTurnerFocusPresenter()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.muesli", category: "TimeTurnerFocus")
    private var panels: [FocusPanel] = []
    private var closingPanels: [FocusPanel] = []
    private var closeTask: Task<Void, Never>?
    private weak var owner: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func present(owner: NSWindow?, moment: VisualMemoryItem?, memory: VisualMemoryController, onNavigate: @escaping (Date, Date) -> Void) {
        logger.info("Opening focus viewer; existing windows: \(self.panels.count)")
        finishClosing()
        NSApp.activate(ignoringOtherApps: true)
        // A hidden panel is not a new presentation. Bring the existing viewer back.
        if let panel = panels.first(where: { $0.isViewer }) {
            panels.forEach { $0.alphaValue = 1; $0.ignoresMouseEvents = false; $0.orderFront(nil) }
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }
        self.owner = owner
        logger.info("Owner frame: \(String(describing: owner?.frame), privacy: .public), active: \(NSApp.isActive)")
        guard let target = owner?.screen ?? NSScreen.main else { return }
        for screen in NSScreen.screens {
            let panel = FocusPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = "Time Turner"
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.fullScreenAuxiliary, .auxiliary]
            panel.onEscape = { [weak self] in self?.close() }
            let isTarget = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            panel.isViewer = isTarget
            let available = screen.visibleFrame
            let size = CGSize(width: min(1280, max(320, available.width - 64)), height: min(900, max(320, available.height - 48)))
            let center = CGPoint(x: available.midX - screen.frame.minX, y: screen.frame.maxY - available.midY)
            let backdrop = FocusBackdropView(frame: NSRect(origin: .zero, size: screen.frame.size))
            backdrop.onDismiss = { [weak self] in self?.close() }
            if isTarget {
                let viewer = MemoryExplorerView(initialMoment: moment, memory: memory, focusedSize: size,
                    onClose: { [weak self] in self?.close() }, onNavigate: onNavigate)
                let host = NSHostingView(rootView: viewer)
                host.frame = NSRect(x: center.x - size.width / 2,
                                    y: screen.frame.height - center.y - size.height / 2,
                                    width: size.width, height: size.height)
                backdrop.addSubview(host)
            }
            panel.contentView = backdrop
            panel.alphaValue = 1
            panels.append(panel)
            // Child windows inherit the dashboard's Space and Stage Manager set.
            owner?.addChildWindow(panel, ordered: .above)
            panel.setFrame(screen.frame, display: true)
            panel.orderFront(nil)
            if isTarget { panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless() }
            backdrop.setDimmed(true)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let viewer = self.panels.first(where: { $0.isViewer }) else { return }
            // Finish ordering after activation and the originating mouse event complete.
            viewer.makeKeyAndOrderFront(nil)
            viewer.orderFrontRegardless()
            self.logger.info("Viewer frame: \(NSStringFromRect(viewer.frame), privacy: .public), visible: \(viewer.isVisible), alpha: \(viewer.alphaValue), active Space: \(viewer.isOnActiveSpace), occlusion: \(viewer.occlusionState.rawValue)")
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    // A queued deactivation can arrive after the user has returned.
                    if name != NSApplication.didResignActiveNotification || !NSApp.isActive {
                        self?.close(restoreFocus: false)
                    }
                }
            })
        }
    }
    func close(restoreFocus: Bool = true) {
        guard !panels.isEmpty else { return }
        logger.info("Closing focus viewer")
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        let closing = panels
        panels.removeAll()
        closingPanels = closing
        let previousOwner = owner
        let animate = restoreFocus && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        closing.forEach { panel in
            panel.ignoresMouseEvents = true
            if let backdrop = panel.contentView as? FocusBackdropView {
                // Only the desktop tint fades. The viewer and window never become transparent.
                backdrop.subviews.forEach { $0.isHidden = true }
                backdrop.setDimmed(false, animated: animate)
            }
        }
        if !animate {
            finishClosing()
            if restoreFocus && NSApp.isActive { previousOwner?.makeKeyAndOrderFront(nil) }
            return
        }
        closeTask = Task { @MainActor [weak self, weak previousOwner] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self else { return }
            self.finishClosing()
            if NSApp.isActive && self.panels.isEmpty { previousOwner?.makeKeyAndOrderFront(nil) }
        }
    }

    private func finishClosing() {
        closeTask?.cancel()
        closeTask = nil
        closingPanels.forEach { panel in
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
        }
        closingPanels.removeAll()
    }

}

final class FocusPanel: NSWindow {
    var isViewer = false
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// AppKit owns backdrop hit testing; only clicks outside the hosting view dismiss.
private final class FocusBackdropView: NSView {
    var onDismiss: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    func setDimmed(_ dimmed: Bool, animated: Bool = true) {
        guard let layer else { return }
        let target = NSColor.black.withAlphaComponent(dimmed ? 0.20 : 0).cgColor
        let current = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        layer.removeAnimation(forKey: "timeTurnerDimming")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = target
        CATransaction.commit()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = current
        fade.toValue = target
        fade.duration = dimmed ? 0.24 : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "timeTurnerDimming")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
}

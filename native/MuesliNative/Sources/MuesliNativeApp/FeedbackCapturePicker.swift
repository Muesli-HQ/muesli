import AppKit
import CoreGraphics
import MuesliCore

/// Window and display bounds are in Quartz global points; the selection view
/// is flipped and uses display-relative points, including on negative-origin screens.
enum FeedbackCaptureSelectionGeometry {
    static func highlight(window: CGRect, display: CGRect, viewBounds: CGRect) -> CGRect? {
        let rect = window.offsetBy(dx: -display.minX, dy: -display.minY).intersection(viewBounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }
}

/// A short-lived selection surface. It never records screen pixels or audio.
@MainActor
protocol FeedbackCaptureSelecting: AnyObject {
    func show(completion: @escaping (FeedbackCaptureTarget?) -> Void)
    func cancel()
}

@MainActor
final class FeedbackCapturePicker: FeedbackCaptureSelecting {
    private struct Window {
        let id: UInt32
        let bounds: CGRect
        let appName: String
        let selectable: Bool
    }
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
    private final class SelectionView: NSView {
        let screenTarget: FeedbackCaptureTarget
        let choose: (FeedbackCaptureTarget) -> Void
        let cancel: () -> Void
        let windowAt: (CGPoint) -> Window?
        private var start: CGPoint?
        private var end: CGPoint?
        private var hoveredWindow: CGRect?
        private var hoverTracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        init(frame: NSRect, screenTarget: FeedbackCaptureTarget,
             windowAt: @escaping (CGPoint) -> Window?,
             choose: @escaping (FeedbackCaptureTarget) -> Void,
             cancel: @escaping () -> Void) {
            self.screenTarget = screenTarget; self.windowAt = windowAt
            self.choose = choose; self.cancel = cancel
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(tracking); hoverTracking = tracking
        }
        override func mouseMoved(with event: NSEvent) {
            guard start == nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            let global = CGPoint(x: screenTarget.frame.x + point.x, y: screenTarget.frame.y + point.y)
            let target = windowAt(global)
            let display = CGRect(x: screenTarget.frame.x, y: screenTarget.frame.y,
                                 width: screenTarget.frame.width, height: screenTarget.frame.height)
            let rect = target.flatMap { $0.selectable ? FeedbackCaptureSelectionGeometry.highlight(window: $0.bounds, display: display, viewBounds: bounds) : nil }
            if hoveredWindow != rect { hoveredWindow = rect; needsDisplay = true }
        }
        override func mouseExited(with event: NSEvent) {
            if start == nil, hoveredWindow != nil { hoveredWindow = nil; needsDisplay = true }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel() } else { super.keyDown(with: event) }
        }
        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil); end = start; needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            end = convert(event.locationInWindow, from: nil); needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            let end = convert(event.locationInWindow, from: nil)
            let selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                   width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
            if selection.width >= 6, selection.height >= 6 {
                let region = FeedbackCaptureTarget.Frame(x: selection.minX, y: selection.minY,
                    width: selection.width, height: selection.height, scale: screenTarget.frame.scale)
                choose(.init(displayId: screenTarget.displayId, frame: screenTarget.frame,
                             appName: "Screen region", region: region))
            } else {
                let point = CGPoint(x: screenTarget.frame.x + end.x, y: screenTarget.frame.y + end.y)
                guard let window = windowAt(point), window.selectable else { cancel(); return }
                let bounds = window.bounds
                let windowFrame = FeedbackCaptureTarget.Frame(x: bounds.minX, y: bounds.minY,
                    width: bounds.width, height: bounds.height, scale: screenTarget.frame.scale)
                choose(.init(displayId: screenTarget.displayId, frame: screenTarget.frame,
                             appName: window.appName, windowID: window.id, windowFrame: windowFrame))
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
            let highlight: CGRect?
            if let start, let end {
                highlight = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                   width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
            } else { highlight = hoveredWindow }
            if let rect = highlight, !rect.isNull, !rect.isEmpty {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(rect: rect).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.withAlphaComponent(0.95).setStroke()
                let outline = NSBezierPath(rect: rect); outline.lineWidth = 2; outline.stroke()
            }
            let text = "Drag to select a region  ·  Click a window  ·  Esc to cancel" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: AppFonts.font(size: 14, weight: .semibold),
                .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            let label = CGRect(x: (bounds.width - size.width) / 2 - 12, y: 24,
                               width: size.width + 24, height: size.height + 12)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: label, xRadius: 8, yRadius: 8).fill()
            text.draw(at: CGPoint(x: label.minX + 12, y: label.minY + 6), withAttributes: attributes)
        }
    }
    private var panels: [NSPanel] = []
    private var completion: ((FeedbackCaptureTarget?) -> Void)?
    private var windows: [Window] = []

    func show(completion: @escaping (FeedbackCaptureTarget?) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = info.compactMap { item in
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = item[kCGWindowAlpha as String] as? CGFloat, alpha > 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary), rect.width > 1, rect.height > 1,
                  let name = item[kCGWindowOwnerName as String] as? String else { return nil }
            return Window(id: id, bounds: rect, appName: name, selectable: pid != ownPID)
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Screen"
        for screen in NSScreen.screens {
            guard let target = FeedbackCaptureController.target(screen: screen, appName: appName) else { continue }
            let panel = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false, screen: screen)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.level = .screenSaver; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), screenTarget: target,
                windowAt: { [weak self] point in self?.windows.first { $0.bounds.contains(point) } },
                choose: { [weak self] target in self?.finish(target) }, cancel: { [weak self] in self?.cancel() })
            panels.append(panel); panel.orderFrontRegardless()
        }
        guard let panel = panels.first(where: { $0.screen?.frame.contains(NSEvent.mouseLocation) == true }) ?? panels.first else {
            finish(nil); return
        }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.contentView)
    }
    func cancel() { finish(nil) }
    private func finish(_ result: FeedbackCaptureTarget?) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll(); windows.removeAll()
        completion(result)
    }
}

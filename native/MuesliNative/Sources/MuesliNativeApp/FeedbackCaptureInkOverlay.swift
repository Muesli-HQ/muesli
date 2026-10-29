import AppKit
import MuesliCore

@MainActor
final class FeedbackCaptureInkOverlay {
    private var panels: [NSPanel] = []
    private var hadVisibleInk = false
    init(target: FeedbackCaptureTarget) {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for screen in NSScreen.screens {
            let panel = makeClickThroughOverlayPanel(frame: screen.frame)
            let view = FeedbackCaptureInkOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let f = target.frame
            view.targetRect = CGRect(x: f.x - screen.frame.minX, y: primaryHeight - f.y - f.height - screen.frame.minY,
                                     width: f.width, height: f.height)
            panel.contentView = view
            panels.append(panel); panel.orderFrontRegardless()
        }
    }
    /// Returns whether the panels need a redraw.
    @discardableResult
    func update(strokes: [FeedbackCaptureStroke], live: FeedbackCaptureStroke?, t: Int64) -> Bool {
        var visible: [(FeedbackCaptureStroke, CGFloat)] = []
        for stroke in strokes.reversed() {
            let age = max(0, t - stroke.t1)
            guard age < 1300 else { break }
            if stroke.pin != nil {
                if age < 350 { visible.append((stroke, 1)) }
            } else {
                visible.append((stroke, age <= 650 ? 1 : CGFloat(1300 - age) / 650))
            }
        }
        visible.reverse()
        if let live { visible.append((live, 1)) }
        // Keep one empty redraw after the last visible stroke so AppKit clears it.
        guard !visible.isEmpty || hadVisibleInk else { return false }
        hadVisibleInk = !visible.isEmpty
        for panel in panels {
            if let view = panel.contentView as? FeedbackCaptureInkOverlayView {
                view.strokes = visible; view.needsDisplay = true
            }
        }
        return true
    }
    func stop() {
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels = []
    }
}

private final class FeedbackCaptureInkOverlayView: NSView {
    var targetRect: CGRect = .zero
    var strokes: [(FeedbackCaptureStroke, CGFloat)] = []
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: targetRect)
        context.translateBy(x: targetRect.minX, y: targetRect.minY)
        for (stroke, alpha) in strokes {
            context.setAlpha(alpha)
            FeedbackCaptureRenderer.drawInk(stroke, in: context, width: targetRect.width, height: targetRect.height)
        }
    }
}

import AppKit

@MainActor
final class ComputerUseCursorOverlay {
    static let shared = ComputerUseCursorOverlay()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private weak var indicator: FloatingIndicatorController?

    private init() {}

    func attachIndicator(_ indicator: FloatingIndicatorController) {
        self.indicator = indicator
        panel?.orderOut(nil)
    }

    func show(at point: CGPoint, label: String?) {
        if let indicator {
            indicator.showComputerUseCursor(at: point, label: label)
            return
        }

        let size = CGSize(width: 30, height: 30)
        let panel = panel ?? makePanel(size: size)
        self.panel = panel

        let origin = appKitOrigin(forQuartzPoint: point, size: size)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        if let view = panel.contentView as? ComputerUseCursorOverlayView {
            view.label = label
            view.needsDisplay = true
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                self?.panel?.orderOut(nil)
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        indicator?.hideComputerUseCursor()
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = ComputerUseCursorOverlayView(frame: CGRect(origin: .zero, size: size))
        return panel
    }

    private func appKitOrigin(forQuartzPoint point: CGPoint, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { screen in
            let convertedY = screen.frame.maxY - point.y
            return point.x >= screen.frame.minX
                && point.x <= screen.frame.maxX
                && convertedY >= screen.frame.minY
                && convertedY <= screen.frame.maxY
        } ?? NSScreen.main

        guard let screen else {
            return CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        }
        return CGPoint(
            x: point.x - size.width / 2,
            y: screen.frame.maxY - point.y - size.height / 2
        )
    }
}

private final class ComputerUseCursorOverlayView: NSView {
    var label: String?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 4, dy: 4)
        NSColor.systemBlue.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let ring = NSBezierPath(ovalIn: bounds)
        ring.lineWidth = 3
        NSColor.systemBlue.setStroke()
        ring.stroke()

        NSColor.white.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 9, dy: 9)).fill()
    }
}

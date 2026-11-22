import AppKit

/// The red dot macOS apps show while recording, drawn in the top-right corner of an icon.
enum RecordingDot {
    /// Share of the icon's height the dot takes up.
    static let sizeRatio: CGFloat = 0.42

    static func rect(in bounds: CGRect) -> CGRect {
        let diameter = (bounds.height * sizeRatio).rounded()
        return CGRect(x: bounds.maxX - diameter, y: bounds.maxY - diameter, width: diameter, height: diameter)
    }

    static func draw(in bounds: CGRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect(in: bounds)).fill()
    }
}

extension MenuBarIconRenderer {
    /// The menu bar mark with a red dot. A template image cannot carry a colored dot, so the mark is
    /// tinted in the menu bar's own text color each time it is drawn and follows light and dark.
    static func withRecordingDot(_ base: NSImage) -> NSImage {
        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceIn)
            return true
        }
        let image = NSImage(size: size, flipped: false) { rect in
            tinted.draw(in: rect)
            RecordingDot.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The Dock icon with a red dot while Muesli records. The Dock shows an icon only while a window is
/// open, and the dot is there for exactly that time.
@MainActor
enum DockRecordingIndicator {
    static func update(isRecording: Bool) {
        let tile = NSApplication.shared.dockTile
        guard isRecording else {
            tile.contentView = nil
            tile.display()
            return
        }
        let side = max(tile.size.width, 128)
        let frame = NSRect(x: 0, y: 0, width: side, height: side)
        let view = NSImageView(frame: frame)
        view.image = iconWithDot(NSApplication.shared.applicationIconImage, side: side)
        tile.contentView = view
        tile.display()
    }

    static func iconWithDot(_ base: NSImage, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect)
            RecordingDot.draw(in: rect)
            return true
        }
    }
}

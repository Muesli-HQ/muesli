import AppKit

/// Shared shell for transient overlays that must never steal focus from the
/// destination app or its active text field.
@MainActor
final class NonactivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

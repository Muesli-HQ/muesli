import AppKit

/// Shared close control for correction prompts and meeting notifications.
@MainActor
enum NotificationDismissButton {
    static let size: CGFloat = 22

    static func make(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.target = target
        button.action = action
        button.title = ""
        // An image-only button centers the mark without a text baseline offset.
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = size / 2
        button.toolTip = "Dismiss"
        button.setAccessibilityLabel("Dismiss")
        return button
    }
}

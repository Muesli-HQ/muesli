import AppKit

enum MenuBarIconRenderer {

    static let options: [(id: String, label: String)] = [
        ("muesli", "Muesli Logo"),
        ("mic.fill", "Microphone"),
        ("waveform", "Waveform"),
        ("bubble.left.fill", "Bubble"),
        ("text.bubble", "Speech Bubble"),
        ("pencil.line", "Pencil"),
        ("brain.head.profile", "Brain"),
        ("sparkles", "Sparkles"),
        ("headphones", "Headphones"),
        ("person.wave.2", "Meeting"),
        ("character.bubble", "Character"),
        ("doc.text", "Document"),
    ]

    /// Returns a menu bar icon for the given choice.
    /// "muesli" loads the bundled M logo; anything else renders an SF Symbol.
    static func make(choice: String = "muesli", recording: Bool = false) -> NSImage? {
        let baseIcon: NSImage?
        if choice == "muesli" {
            if let url = Bundle.main.url(forResource: "menu_m_template", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                baseIcon = image
            } else {
                baseIcon = nil
            }
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            let image = NSImage(systemSymbolName: choice, accessibilityDescription: "Muesli")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            baseIcon = image
        }

        guard let baseIcon else { return nil }
        guard recording else { return baseIcon }

        let size = NSSize(width: 22, height: 22)
        let result = NSImage(size: size, flipped: false) { rect in
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let iconRect = NSRect(
                x: (rect.width - baseIcon.size.width) / 2,
                y: (rect.height - baseIcon.size.height) / 2,
                width: baseIcon.size.width, height: baseIcon.size.height
            )
            baseIcon.draw(in: iconRect, from: .zero, operation: .destinationOut, fraction: 1.0)
            return true
        }
        result.isTemplate = false
        return result
    }
}

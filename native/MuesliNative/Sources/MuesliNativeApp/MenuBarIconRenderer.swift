import AppKit

enum MenuBarIconRenderer {

    static let options: [(id: String, label: String)] = [
        ("sales-caddie", "Sales Caddie Logo"),
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
    /// "sales-caddie" loads the bundled app logo; anything else renders an SF Symbol.
    static func make(choice: String = "sales-caddie") -> NSImage? {
        if choice == "sales-caddie" || choice == "muesli" {
            if let url = Bundle.main.url(forResource: "menu_sales_caddie_template", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: choice, accessibilityDescription: AppIdentity.displayName)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }
}

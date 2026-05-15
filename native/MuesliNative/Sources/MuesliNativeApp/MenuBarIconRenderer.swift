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
    static func make(choice: String = "muesli", customLogoPath: String? = nil) -> NSImage? {
        if choice == "muesli" {
            if let customLogo = AppBrandingAssets.image(at: customLogoPath) {
                customLogo.isTemplate = false
                customLogo.size = NSSize(width: 18, height: 18)
                return customLogo
            }
            if let url = Bundle.main.url(forResource: "menu_m_template", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: choice, accessibilityDescription: "Muesli")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }
}

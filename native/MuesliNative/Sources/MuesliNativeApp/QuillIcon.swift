import AppKit

enum QuillIcon {
    private static let resourceName = "quill-icon"

    static func image(accessibilityDescription: String = "Quill") -> NSImage {
        let image: NSImage
        if let url = iconURL(), let bundledImage = NSImage(contentsOf: url) {
            image = bundledImage
        } else {
            image = NSImage(
                systemSymbolName: "pencil.line",
                accessibilityDescription: accessibilityDescription
            ) ?? NSImage(size: NSSize(width: 18, height: 18))
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func iconURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: resourceName, withExtension: "svg") {
            return bundled
        }

        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("assets/\(resourceName).svg")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

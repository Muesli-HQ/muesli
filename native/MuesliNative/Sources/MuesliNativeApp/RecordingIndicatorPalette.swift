import AppKit
import SwiftUI

/// The notch is always black (it surrounds camera hardware). The neutral theme
/// uses the app's default dark accent so activity stays visible on that surface.
enum RecordingIndicatorPalette {
    static func accent(hex: String) -> NSColor {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "").lowercased()
        let parsed = value.count == 6 && value != "1e1e2e" ? UInt64(value, radix: 16) : nil
        let rgb = parsed ?? UInt64(MuesliTheme.defaultAccentDarkHex)
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

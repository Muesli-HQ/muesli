import AppKit
import Foundation
import SwiftUI

/// WCAG 2.x relative luminance and contrast for 8-bit sRGB hex colors.
enum MuesliContrast {
    static func luminance(_ hex: Int) -> Double {
        func channel(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
            + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }

    static func ratio(_ a: Int, _ b: Int) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Source-over compositing in encoded sRGB, as opaque layers are usually blended.
    static func composite(_ color: Int, opacity: Double, over base: Int) -> Int {
        mix(base, toward: color, amount: opacity)
    }

    /// Moves each channel `amount` of the way toward `target`. Mixing toward black or white
    /// keeps the hue angle, so a shade stays recognisably the same accent.
    static func mix(_ color: Int, toward target: Int, amount: Double) -> Int {
        func channel(_ shift: Int) -> Int {
            let from = Double((color >> shift) & 0xFF)
            let to = Double((target >> shift) & 0xFF)
            return Int((from + (to - from) * amount).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}

/// Accent roles derived once from a saved accent for Light and Dark. Each role is a dynamic
/// color that selects a precomputed value, so views do no parsing or contrast work while
/// rendering. Ultra Dark overrides live in `MuesliTheme`.
struct MuesliAccentPalette {
    struct Values: Equatable {
        /// The raw saved accent (or adaptive default), unchanged.
        let fill: Int
        /// Black or white, whichever contrasts more with `fill`.
        let onFill: Int
        /// Same-hue shade with at least 4.5:1 on neutral surfaces and accent tints.
        let text: Int
        /// Overlay for hover/pressed fills that increases contrast with `onFill`.
        let stateShade: Int
    }

    static let minimumTextContrast = 4.5
    /// Derivation aims slightly above 4.5:1 so 8-bit blending cannot land below it.
    private static let derivationTarget = 4.6
    private static let shadeSteps = 50

    let light: Values
    let dark: Values
    let fill: Color
    let onFill: Color
    let text: Color
    let stateShade: Color

    init(lightFill: Int, darkFill: Int) {
        let light = Self.values(fill: lightFill, dark: false)
        let dark = Self.values(fill: darkFill, dark: true)
        self.light = light
        self.dark = dark
        fill = Self.color(light: light.fill, dark: dark.fill)
        onFill = Self.color(light: light.onFill, dark: dark.onFill)
        text = Self.color(light: light.text, dark: dark.text)
        stateShade = Self.color(light: light.stateShade, dark: dark.stateShade)
    }

    /// Identical values stay plain sRGB colors, as saved accents always were.
    private static func color(light: Int, dark: Int) -> Color {
        light == dark ? Color(hex: light) : Color.adaptive(dark: dark, light: light)
    }

    func values(dark: Bool) -> Values { dark ? self.dark : light }

    private static var cache: [String: MuesliAccentPalette] = [:]

    /// Cached palette for a saved accent hex. Nil, empty, unparsable and the legacy `1e1e2e`
    /// value mean the adaptive default accent.
    static func palette(forHex hex: String?) -> MuesliAccentPalette {
        let key = hex?.lowercased() ?? ""
        if let cached = cache[key] { return cached }
        let palette: MuesliAccentPalette
        if let value = parsedHex(hex) {
            palette = MuesliAccentPalette(lightFill: value, darkFill: value)
        } else {
            palette = MuesliAccentPalette(
                lightFill: MuesliTheme.defaultAccentLightHex,
                darkFill: MuesliTheme.defaultAccentDarkHex
            )
        }
        cache[key] = palette
        return palette
    }

    /// Parses saved accents the way they have always been read: any hex digits, low 24 bits.
    static func parsedHex(_ hex: String?) -> Int? {
        guard let hex else { return nil }
        let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .lowercased()
        guard !digits.isEmpty, digits != "1e1e2e", let value = UInt64(digits, radix: 16) else { return nil }
        return Int(value & 0xFFFFFF)
    }

    static func values(fill: Int, dark: Bool) -> Values {
        let white = 0xFFFFFF
        let ink = MuesliTheme.darkInkHex
        let onFill = MuesliContrast.ratio(white, fill) >= MuesliContrast.ratio(ink, fill) ? white : ink
        // Darken under white labels; lighten under dark ones, except near-white fills.
        let stateShade = onFill == white || MuesliContrast.luminance(fill) > 0.6 ? ink : white
        return Values(fill: fill, onFill: onFill, text: accentText(for: fill, dark: dark), stateShade: stateShade)
    }

    /// Every opaque background accent text must remain legible on, including the tinted
    /// control states built from this fill.
    static func textBackgrounds(fill: Int, dark: Bool) -> [Int] {
        let tints = [MuesliTheme.accentTintRest, MuesliTheme.accentTintHover, MuesliTheme.accentTintPressed]
        let tinted = MuesliTheme.tintBaseHexes(dark: dark).flatMap { base in
            tints.map { MuesliContrast.composite(fill, opacity: $0, over: base) }
        }
        return MuesliTheme.textSurfaceHexes(dark: dark) + tinted
    }

    private static func accentText(for fill: Int, dark: Bool) -> Int {
        let backgrounds = textBackgrounds(fill: fill, dark: dark)
        let target = dark ? 0xFFFFFF : MuesliTheme.darkInkHex
        for step in 0...shadeSteps {
            let candidate = MuesliContrast.mix(fill, toward: target, amount: Double(step) / Double(shadeSteps))
            if backgrounds.allSatisfy({ MuesliContrast.ratio(candidate, $0) >= derivationTarget }) {
                return candidate
            }
        }
        return target
    }
}

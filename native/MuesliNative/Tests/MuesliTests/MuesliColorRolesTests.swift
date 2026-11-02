import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("MuesliColorRoles", .serialized)
struct MuesliColorRolesTests {
    private static let minimumText = 4.5
    private static let ultraDarkSurfaces = [0x000000, 0x0A0A0A, 0x121212, 0x181818, 0x222222]

    /// Every selectable preset plus a spread of arbitrary saved accents, including extremes.
    private static var accentHexes: [String?] {
        let presets: [String?] = MuesliSettings.accentPresets.map { $0.hex }
        let arbitrary: [String?] = stride(from: 0, through: 0xFFFFFF, by: 0x060709).map { String($0, radix: 16) }
        return presets + arbitrary + ["000000", "ffffff", "808080", "ffff00", "00ffff", "#FF00FF", nil]
    }

    @Test("accent foreground contrasts with the resolved fill in Light and Dark, including pressed shades")
    func onAccentContrast() {
        for hex in Self.accentHexes {
            let palette = MuesliAccentPalette.palette(forHex: hex)
            for dark in [false, true] {
                let values = palette.values(dark: dark)
                #expect(MuesliContrast.ratio(values.onFill, values.fill) >= Self.minimumText,
                        "onAccent on \(hex ?? "default") dark=\(dark)")
                for opacity in [MuesliTheme.accentShadeHover, MuesliTheme.accentShadePressed] {
                    let shaded = MuesliContrast.composite(values.stateShade, opacity: opacity, over: values.fill)
                    #expect(MuesliContrast.ratio(values.onFill, shaded) >= Self.minimumText,
                            "onAccent on shaded \(hex ?? "default") dark=\(dark) opacity=\(opacity)")
                }
            }
        }
    }

    @Test("accent text is legible on neutral surfaces and accent tints in Light and Dark")
    func accentTextContrast() {
        for hex in Self.accentHexes {
            let palette = MuesliAccentPalette.palette(forHex: hex)
            for dark in [false, true] {
                let values = palette.values(dark: dark)
                for background in MuesliAccentPalette.textBackgrounds(fill: values.fill, dark: dark) {
                    #expect(MuesliContrast.ratio(values.text, background) >= Self.minimumText,
                            "accentText for \(hex ?? "default") dark=\(dark) on \(String(format: "%06X", background))")
                }
            }
        }
    }

    @Test("saved accents are preserved as fills and accent text keeps their hue")
    func savedAccentPreserved() {
        for preset in MuesliSettings.accentPresets where preset.hex != "1e1e2e" {
            let value = Int(preset.hex, radix: 16)!
            let palette = MuesliAccentPalette.palette(forHex: preset.hex)
            #expect(palette.light.fill == value && palette.dark.fill == value)
            for text in [palette.light.text, palette.dark.text] {
                #expect(Self.dominantChannel(text) == Self.dominantChannel(value), "\(preset.name) hue")
            }
        }
        let defaultPalette = MuesliAccentPalette.palette(forHex: "1e1e2e")
        #expect(defaultPalette.light.fill == MuesliTheme.defaultAccentLightHex)
        #expect(defaultPalette.dark.fill == MuesliTheme.defaultAccentDarkHex)
        // Raw sRGB defaults that already pass are not altered.
        #expect(defaultPalette.light.onFill == 0xFFFFFF)
    }

    @Test("saved accent strings parse as before")
    func accentParsing() {
        #expect(MuesliAccentPalette.parsedHex(nil) == nil)
        #expect(MuesliAccentPalette.parsedHex("") == nil)
        #expect(MuesliAccentPalette.parsedHex("1e1e2e") == nil)
        #expect(MuesliAccentPalette.parsedHex("FF0000") == 0xFF0000)
        #expect(MuesliAccentPalette.parsedHex("#ef4444") == 0xEF4444)
        #expect(MuesliAccentPalette.parsedHex("not-a-color") == nil)
    }

    @Test("theme roles resolve the palette for each appearance", arguments: [false, true])
    func themeResolvesPalette(dark: Bool) throws {
        let originalMode = MuesliTheme.appearance.ultraDark
        let originalAccent = MuesliTheme.accentOverrideHex
        defer {
            MuesliTheme.appearance.ultraDark = originalMode
            MuesliTheme.accentOverrideHex = originalAccent
        }
        MuesliTheme.appearance.ultraDark = false
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        for preset in MuesliSettings.accentPresets {
            MuesliTheme.accentOverrideHex = preset.hex == "1e1e2e" ? nil : preset.hex
            let expected = MuesliAccentPalette.palette(forHex: preset.hex).values(dark: dark)
            #expect(Self.matches(Self.resolve(MuesliTheme.accent, in: appearance), expected.fill), "\(preset.name) fill")
            #expect(Self.matches(Self.resolve(MuesliTheme.onAccent, in: appearance), expected.onFill), "\(preset.name) onAccent")
            #expect(Self.matches(Self.resolve(MuesliTheme.accentText, in: appearance), expected.text), "\(preset.name) text")
            #expect(Self.matches(Self.resolve(MuesliTheme.toggleAccent, in: appearance), expected.fill), "\(preset.name) toggle")
        }
    }

    @Test("Ultra Dark keeps white primary actions, black labels and colored switches")
    func ultraDarkRoles() throws {
        let originalMode = MuesliTheme.appearance.ultraDark
        let originalAccent = MuesliTheme.accentOverrideHex
        defer {
            MuesliTheme.appearance.ultraDark = originalMode
            MuesliTheme.accentOverrideHex = originalAccent
        }
        MuesliTheme.appearance.ultraDark = true
        let appearance = try #require(NSAppearance(named: .darkAqua))
        for preset in MuesliSettings.accentPresets {
            MuesliTheme.accentOverrideHex = preset.hex == "1e1e2e" ? nil : preset.hex
            let fill = Self.resolve(MuesliTheme.accent, in: appearance)
            let label = Self.resolve(MuesliTheme.onAccent, in: appearance)
            let text = Self.resolve(MuesliTheme.accentText, in: appearance)
            let shade = Self.resolve(MuesliTheme.accentStateShade, in: appearance)
            #expect(Self.matches(fill, 0xFFFFFF) && Self.matches(label, 0x000000) && Self.matches(text, 0xFFFFFF))
            #expect(Self.matches(Self.resolve(MuesliTheme.toggleAccent, in: appearance),
                                 MuesliAccentPalette.palette(forHex: preset.hex).dark.fill))
            let pressed = MuesliContrast.composite(shade, opacity: MuesliTheme.accentShadePressed, over: fill)
            #expect(MuesliContrast.ratio(label, pressed) >= Self.minimumText)
            let tints = [MuesliTheme.accentTintRest, MuesliTheme.accentTintHover, MuesliTheme.accentTintPressed]
            for surface in Self.ultraDarkSurfaces {
                #expect(MuesliContrast.ratio(text, surface) >= Self.minimumText)
                for tint in tints {
                    let tinted = MuesliContrast.composite(fill, opacity: tint, over: surface)
                    #expect(MuesliContrast.ratio(text, tinted) >= Self.minimumText)
                }
            }
        }
    }

    @Test("swatches preview the switch color and mark selection with a contrasting check")
    func swatchSemantics() throws {
        let originalMode = MuesliTheme.appearance.ultraDark
        defer { MuesliTheme.appearance.ultraDark = originalMode }
        MuesliTheme.appearance.ultraDark = true
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let defaultSwatch = MuesliAccentPalette.palette(forHex: "1e1e2e")
        // The Ultra Dark Default swatch shows the adaptive blue that switches use, not white.
        #expect(Self.matches(Self.resolve(defaultSwatch.fill, in: appearance), MuesliTheme.defaultAccentDarkHex))
        for preset in MuesliSettings.accentPresets {
            let palette = MuesliAccentPalette.palette(forHex: preset.hex)
            for dark in [false, true] {
                let values = palette.values(dark: dark)
                #expect(MuesliContrast.ratio(values.onFill, values.fill) >= 3, "\(preset.name) checkmark")
            }
        }
    }

    @Test("semantic fills carry their own legible foregrounds")
    func semanticFills() {
        let pressed = MuesliTheme.accentShadePressed
        let success = 0x34D399
        let onSuccess = MuesliTheme.darkInkHex
        #expect(MuesliContrast.ratio(onSuccess, success) >= Self.minimumText)
        #expect(MuesliContrast.ratio(onSuccess, MuesliContrast.composite(0xFFFFFF, opacity: pressed, over: success)) >= Self.minimumText)

        let recordingFill = MuesliTheme.recordingFillHex
        #expect(MuesliContrast.ratio(0xFFFFFF, recordingFill) >= Self.minimumText)
        #expect(MuesliContrast.ratio(0xFFFFFF, MuesliContrast.composite(0x000000, opacity: pressed, over: recordingFill)) >= Self.minimumText)

        for join in [MuesliTheme.joinActionHex, MuesliTheme.joinActionSecondaryHex] {
            #expect(MuesliContrast.ratio(MuesliTheme.darkInkHex, join) >= Self.minimumText)
        }
        // Notification "Start" button.
        #expect(MuesliContrast.ratio(0xFFFFFF, MuesliTheme.defaultAccentLightHex) >= Self.minimumText)
    }

    @Test("status and destructive text stay legible on cards and their tints", arguments: [false, true])
    func semanticText(dark: Bool) {
        let surfaces = MuesliTheme.textSurfaceHexes(dark: dark)
        let tintBases = MuesliTheme.tintBaseHexes(dark: dark)
        let destructive = dark ? MuesliTheme.destructiveTextHex.dark : MuesliTheme.destructiveTextHex.light
        let destructiveTints = [MuesliTheme.destructiveTintRest, MuesliTheme.destructiveTintHover, MuesliTheme.destructiveTintPressed]
        let redTinted = tintBases.flatMap { base in destructiveTints.map { MuesliContrast.composite(0xEF4444, opacity: $0, over: base) } }
        for background in surfaces + redTinted {
            #expect(MuesliContrast.ratio(destructive, background) >= Self.minimumText)
        }

        let successText = dark ? MuesliTheme.successTextHex.dark : MuesliTheme.successTextHex.light
        let successTinted = tintBases.map { MuesliContrast.composite(0x34D399, opacity: 0.15, over: $0) }
        for background in surfaces + successTinted {
            #expect(MuesliContrast.ratio(successText, background) >= Self.minimumText)
        }

        let warningText = dark ? MuesliTheme.warningTextHex.dark : MuesliTheme.warningTextHex.light
        for background in surfaces {
            #expect(MuesliContrast.ratio(warningText, background) >= Self.minimumText)
        }
    }

    @Test("control state gives disabled and pressed precedence over hover or focus")
    func controlStatePrecedence() {
        #expect(MuesliControlState(isEnabled: false, isPressed: true, isHighlighted: true) == .disabled)
        #expect(MuesliControlState(isEnabled: true, isPressed: true, isHighlighted: true) == .pressed)
        #expect(MuesliControlState(isEnabled: true, isPressed: false, isHighlighted: true) == .highlighted)
        #expect(MuesliControlState(isEnabled: true, isPressed: false, isHighlighted: false) == .rest)
    }

    @Test("Reduce Motion removes control animations")
    func reduceMotionAnimation() {
        #expect(MuesliMotion.animation(MuesliMotion.feedback, reduceMotion: true) == nil)
        #expect(MuesliMotion.animation(MuesliMotion.feedback, reduceMotion: false) != nil)
    }

    @Test("contrast calculation matches independent sRGB reference pairs")
    func referenceRatios() {
        #expect(abs(MuesliContrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.0001)
        #expect(abs(MuesliContrast.ratio(0xFFFFFF, 0x2563EB) - 5.1686) < 0.0001)
        #expect(abs(MuesliContrast.ratio(0xFFFFFF, 0x6BA3F7) - 2.5588) < 0.0001)
        #expect(abs(MuesliContrast.ratio(0xFFFFFF, 0x34D399) - 1.9224) < 0.0001)
    }

    // MARK: - Helpers

    private static func resolve(_ color: Color, in appearance: NSAppearance) -> Int {
        var hex = 0
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            hex = (channel(rgb.redComponent) << 16) | (channel(rgb.greenComponent) << 8) | channel(rgb.blueComponent)
        }
        return hex
    }

    /// Allows one 8-bit step of color-space rounding per channel.
    private static func matches(_ a: Int, _ b: Int) -> Bool {
        [16, 8, 0].allSatisfy { abs(((a >> $0) & 0xFF) - ((b >> $0) & 0xFF)) <= 1 }
    }

    private static func dominantChannel(_ hex: Int) -> Int {
        let channels = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF]
        return channels.firstIndex(of: channels.max()!)!
    }
}

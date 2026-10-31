import SwiftUI
import MuesliCore
import Observation

@Observable
final class MuesliThemeAppearance {
    var ultraDark = false
}

enum MuesliTheme {
    // Observable palette selection refreshes views without replacing their identity or focus.
    static let appearance = MuesliThemeAppearance()
    // MARK: - Colors — Backgrounds (layered)

    static let backgroundDeepDarkHex = 0x0B0C0E
    static let backgroundDeepLightHex = 0xF5F5F7
    private static let backgroundDeepStandard = Color.adaptive(dark: backgroundDeepDarkHex, light: backgroundDeepLightHex)
    static var backgroundDeep: Color { appearance.ultraDark ? Color(hex: 0x000000) : backgroundDeepStandard }

    /// AppKit counterpart of `backgroundDeep`, for window chrome that cannot use SwiftUI colors.
    private static let backgroundDeepStandardNSColor = NSColor.adaptive(dark: backgroundDeepDarkHex, light: backgroundDeepLightHex)
    static var backgroundDeepNSColor: NSColor { appearance.ultraDark ? .black : backgroundDeepStandardNSColor }
    static let backgroundBaseHex = (dark: 0x161719, light: 0xFFFFFF)
    private static let backgroundBaseStandard = Color.adaptive(dark: backgroundBaseHex.dark, light: backgroundBaseHex.light)
    static var backgroundBase: Color { appearance.ultraDark ? Color(hex: 0x000000) : backgroundBaseStandard }
    static let backgroundRaisedHex = (dark: 0x202226, light: 0xF0F0F2)
    private static let backgroundRaisedStandard = Color.adaptive(dark: backgroundRaisedHex.dark, light: backgroundRaisedHex.light)
    static var backgroundRaised: Color { appearance.ultraDark ? Color(hex: 0x0A0A0A) : backgroundRaisedStandard }
    static let backgroundHoverHex = (dark: 0x232528, light: 0xE8E8EC)
    private static let backgroundHoverStandard = Color.adaptive(dark: backgroundHoverHex.dark, light: backgroundHoverHex.light)
    static var backgroundHover: Color { appearance.ultraDark ? Color(hex: 0x181818) : backgroundHoverStandard }

    // MARK: - Surfaces (interactive elements)

    static let surfacePrimaryHex = (dark: 0x262830, light: 0xE5E5EA)
    private static let surfacePrimaryStandard = Color.adaptive(dark: surfacePrimaryHex.dark, light: surfacePrimaryHex.light)
    static var surfacePrimary: Color { appearance.ultraDark ? Color(hex: 0x121212) : surfacePrimaryStandard }
    static let surfaceSelectedHex = (dark: 0x2E3340, light: 0xD6DFFE)
    private static let surfaceSelectedStandard = Color.adaptive(dark: surfaceSelectedHex.dark, light: surfaceSelectedHex.light)
    static var surfaceSelected: Color { appearance.ultraDark ? Color(hex: 0x222222) : surfaceSelectedStandard }
    private static let surfaceBorderStandard = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.07,
        light: .black, lightAlpha: 0.08
    )
    static var surfaceBorder: Color { appearance.ultraDark ? Color.white.opacity(0.28) : surfaceBorderStandard }

    // MARK: - Text hierarchy

    private static let textPrimaryStandard = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.92,
        light: .black, lightAlpha: 0.88
    )
    static var textPrimary: Color { appearance.ultraDark ? Color.white.opacity(1) : textPrimaryStandard }
    private static let textSecondaryStandard = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.74,
        light: .black, lightAlpha: 0.66
    )
    static var textSecondary: Color { appearance.ultraDark ? Color.white.opacity(0.80) : textSecondaryStandard }
    private static let textTertiaryStandard = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.56,
        light: .black, lightAlpha: 0.55
    )
    static var textTertiary: Color { appearance.ultraDark ? Color.white.opacity(0.65) : textTertiaryStandard }

    // MARK: - Accent

    static let defaultAccentDarkHex = 0x6BA3F7
    static let defaultAccentLightHex = 0x2563EB
    private static let defaultAccentStandard = Color.adaptive(dark: defaultAccentDarkHex, light: defaultAccentLightHex)
    static var defaultAccent: Color { appearance.ultraDark ? Color(hex: 0xFFFFFF) : defaultAccentStandard }
    /// The saved accent, or nil for the adaptive default. Assigning it derives the accent roles
    /// once, so rendering never parses hex or computes contrast.
    static var accentOverrideHex: String? {
        didSet {
            guard accentOverrideHex != oldValue else { return }
            accentPalette = MuesliAccentPalette.palette(forHex: accentOverrideHex)
        }
    }
    private(set) static var accentPalette = MuesliAccentPalette.palette(forHex: nil)

    /// Fills for primary actions and selection. White in Ultra Dark.
    static var accent: Color {
        appearance.ultraDark ? .white : toggleAccent
    }
    /// Switches retain the saved accent in every theme so their on/off state stays clear.
    static var toggleAccent: Color { accentPalette.fill }
    /// Text and glyphs drawn on an `accent` fill: black or white, whichever contrasts more with
    /// the resolved fill in the current appearance.
    static var onAccent: Color { appearance.ultraDark ? Color(hex: darkInkHex) : accentPalette.onFill }
    /// Accent-hued text and meaningful icons on neutral surfaces and on accent tints up to
    /// `accentTintPressed`. A same-hue shade of the saved accent, deepened in Light and
    /// lightened in Dark only as far as needed for 4.5:1. Never use it as a fill.
    static var accentText: Color { appearance.ultraDark ? .white : accentPalette.text }
    /// Hover/pressed overlay for `accent` fills; it moves the fill away from `onAccent`.
    static var accentStateShade: Color { appearance.ultraDark ? Color(hex: darkInkHex) : accentPalette.stateShade }
    static var accentSubtle: Color { accent.opacity(accentTintRest) }
    /// Tinted control fills (accent at these opacities); `accentText` stays legible on each.
    static let accentTintRest: Double = 0.15
    static let accentTintHover: Double = 0.21
    static let accentTintPressed: Double = 0.27
    /// `accentStateShade` opacities for hovered/focused and pressed accent fills.
    static let accentShadeHover: Double = 0.08
    static let accentShadePressed: Double = 0.16

    // MARK: - Semantic

    /// Dots, waveforms, badges and borders. Use the text/fill roles below for labels.
    static let recording        = Color(hex: 0xEF4444)
    static let transcribing     = Color(hex: 0xF59E0B)
    static let success          = Color(hex: 0x34D399)

    static let darkInkHex = 0x000000
    static let recordingFillHex = 0xDC2626
    /// Labelled stop/record buttons: a deeper shade of `recording` that carries white text.
    static let recordingFill = Color(hex: recordingFillHex)
    static let onRecordingFill = Color.white
    /// Text and glyphs drawn on a `success` fill. Never substitute `onAccent`.
    static let onSuccess = Color(hex: darkInkHex)
    /// Join-call split buttons (dashboard and notification). Dark ink keeps their labels legible.
    static let joinActionHex = 0x33B887
    static let joinActionSecondaryHex = 0x26946B
    static let joinAction = Color(hex: joinActionHex)
    static let joinActionSecondary = Color(hex: joinActionSecondaryHex)
    static let onJoinAction = Color(hex: darkInkHex)
    static let destructiveTextHex = (dark: 0xF87171, light: 0xB91C1C)
    /// Destructive labels, trash glyphs and error text on neutral surfaces and red tints.
    static let destructiveText = Color.adaptive(dark: destructiveTextHex.dark, light: destructiveTextHex.light)
    static let successTextHex = (dark: 0x34D399, light: 0x065F46)
    /// Success status labels; the Light shade stays legible on cards and success tints.
    static let successText = Color.adaptive(dark: successTextHex.dark, light: successTextHex.light)
    static let warningTextHex = (dark: 0xF59E0B, light: 0x92400E)
    static let warningText = Color.adaptive(dark: warningTextHex.dark, light: warningTextHex.light)
    /// Red-tint opacities for destructive control rest, hover and pressed states.
    static let destructiveTintRest: Double = 0.10
    static let destructiveTintHover: Double = 0.13
    static let destructiveTintPressed: Double = 0.16

    /// Opaque Light/Dark surfaces that carry accent text, for contrast derivation and tests.
    static func textSurfaceHexes(dark: Bool) -> [Int] {
        let pairs: [(dark: Int, light: Int)] = [
            (dark: backgroundDeepDarkHex, light: backgroundDeepLightHex),
            backgroundBaseHex, backgroundRaisedHex, backgroundHoverHex, surfacePrimaryHex, surfaceSelectedHex,
        ]
        return pairs.map { dark ? $0.dark : $0.light }
    }

    /// Surfaces under accent or red tints: deep, base and raised.
    static func tintBaseHexes(dark: Bool) -> [Int] {
        Array(textSurfaceHexes(dark: dark).prefix(3))
    }

    // MARK: - Typography — Nunito Sans, matching muesli.works

    /// Text only. SF Symbols retain system fonts; code retains its monospaced design.
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if design == .monospaced { return .system(size: size, weight: weight, design: .monospaced) }
        AppFonts.registerForRenderingIfNeeded()
        return .custom(AppFonts.postScriptName(weight: nsWeight(weight)), size: size)
    }

    static func font(_ style: Font.TextStyle) -> Font {
        switch style {
        case .largeTitle: return font(size: 32, weight: .bold)
        case .title: return title1()
        case .title2: return title2()
        case .title3: return title3()
        case .headline: return headline()
        case .subheadline, .callout: return callout()
        case .footnote, .caption: return caption()
        case .caption2: return metadata()
        default: return body()
        }
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    static func title1() -> Font { font(size: 26, weight: .bold) }
    static func title2() -> Font { font(size: 20, weight: .semibold) }
    static func title3() -> Font { font(size: 18, weight: .semibold) }
    static func headline() -> Font { font(size: 15, weight: .semibold) }
    /// Comfortable long-form text, separate from compact control labels.
    static func reading() -> Font { font(size: 15) }
    static let readingWidth: CGFloat = 720
    static let pageInset: CGFloat = 32

    static func body() -> Font { font(size: 14) }
    static func callout() -> Font { font(size: 13) }
    static func caption() -> Font { font(size: 12) }
    static func captionMedium() -> Font { font(size: 12, weight: .medium) }
    /// Settings and Models group headings, above their cards.
    static func sectionHeading() -> Font { font(size: 12, weight: .semibold) }
    /// Badges, keyboard hints and secondary metadata. Not for instructions, warnings or errors.
    static func metadata() -> Font { font(size: 11, weight: .medium) }

    // MARK: - Spacing (4pt grid)

    /// Top padding for page content and for the sidebar header, so a page's heading lines up
    /// with the app name in the sidebar.
    static let pageTop: CGFloat = 8

    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32

    // MARK: - Corner radii

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 14
    static let cornerXL: CGFloat = 20
}

// MARK: - Color Helpers

extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    static func adaptive(dark: Int, light: Int) -> Color {
        Color(nsColor: NSColor.adaptive(dark: dark, light: light))
    }

    static func adaptiveAlpha(dark: NSColor, darkAlpha: CGFloat, light: NSColor, lightAlpha: CGFloat) -> Color {
        return Color(nsColor: NSColor(name: nil) { appearance in
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark.withAlphaComponent(darkAlpha)
                : light.withAlphaComponent(lightAlpha)
        })
    }
}

extension NSColor {
    static func adaptive(dark: Int, light: Int) -> NSColor {
        return NSColor(name: nil) { appearance in
            NSColor.muesliHex(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }

    /// A fixed color for AppKit surfaces that share `MuesliTheme`'s hex roles.
    static func muesliHex(_ hex: Int) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

/// Page heading used by every dashboard page, so titles stay identical across tabs.
struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(MuesliTheme.title1())
            .foregroundStyle(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

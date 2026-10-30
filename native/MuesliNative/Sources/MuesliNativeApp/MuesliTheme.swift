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
    private static let backgroundBaseStandard = Color.adaptive(dark: 0x161719, light: 0xFFFFFF)
    static var backgroundBase: Color { appearance.ultraDark ? Color(hex: 0x000000) : backgroundBaseStandard }
    private static let backgroundRaisedStandard = Color.adaptive(dark: 0x202226, light: 0xF0F0F2)
    static var backgroundRaised: Color { appearance.ultraDark ? Color(hex: 0x0A0A0A) : backgroundRaisedStandard }
    private static let backgroundHoverStandard = Color.adaptive(dark: 0x232528, light: 0xE8E8EC)
    static var backgroundHover: Color { appearance.ultraDark ? Color(hex: 0x181818) : backgroundHoverStandard }

    // MARK: - Surfaces (interactive elements)

    private static let surfacePrimaryStandard = Color.adaptive(dark: 0x262830, light: 0xE5E5EA)
    static var surfacePrimary: Color { appearance.ultraDark ? Color(hex: 0x121212) : surfacePrimaryStandard }
    private static let surfaceSelectedStandard = Color.adaptive(dark: 0x2E3340, light: 0xD6DFFE)
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
    static var accentOverrideHex: String?
    static var accent: Color {
        appearance.ultraDark ? .white : toggleAccent
    }
    /// Switches retain the saved accent in every theme so their on/off state stays clear.
    static var toggleAccent: Color {
        if let hex = accentOverrideHex, !hex.isEmpty,
           let val = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) {
            return Color(hex: Int(val))
        }
        return defaultAccentStandard
    }
    private static let onAccentStandard = Color.adaptive(dark: 0xFFFFFF, light: 0xFFFFFF)
    static var onAccent: Color { appearance.ultraDark ? Color(hex: 0x000000) : onAccentStandard }
    static var accentSubtle: Color { accent.opacity(0.15) }

    // MARK: - Semantic

    static let recording        = Color(hex: 0xEF4444)
    static let transcribing     = Color(hex: 0xF59E0B)
    static let success          = Color(hex: 0x34D399)

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
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
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

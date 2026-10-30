import SwiftUI

/// Shared visual tokens. Colors resolve in the current light/dark appearance.
/// The host app retains control over typography and surrounding page layout.
public struct AIElementsTheme {
    public var surface: Color
    public var border: Color
    public var accent: Color
    public var muted: Color
    public var heading: Font
    public var subheading: Font
    public var textFont: (CGFloat, Font.Weight) -> Font

    public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        textFont(size, weight)
    }

    public init(
        surface: Color = .primary.opacity(0.045),
        border: Color = .primary.opacity(0.10),
        accent: Color = .accentColor,
        muted: Color = .secondary,
        textFont: @escaping (CGFloat, Font.Weight) -> Font = { .system(size: $0, weight: $1) },
        heading: Font = .title3.weight(.semibold),
        subheading: Font = .headline
    ) {
        self.surface = surface
        self.border = border
        self.accent = accent
        self.muted = muted
        self.textFont = textFont
        self.heading = heading
        self.subheading = subheading
    }
}

private struct AIElementsThemeKey: EnvironmentKey {
    static let defaultValue = AIElementsTheme()
}

public extension EnvironmentValues {
    var aiElementsTheme: AIElementsTheme {
        get { self[AIElementsThemeKey.self] }
        set { self[AIElementsThemeKey.self] = newValue }
    }
}

public extension View {
    /// Overrides tokens for this subtree without introducing app-specific dependencies.
    func aiElementsTheme(_ theme: AIElementsTheme) -> some View {
        environment(\.aiElementsTheme, theme)
    }
}

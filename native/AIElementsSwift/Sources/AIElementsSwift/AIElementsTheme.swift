import SwiftUI

/// Shared visual tokens. Colors resolve in the current light/dark appearance.
/// The host app retains control over typography and surrounding page layout.
public struct AIElementsTheme {
    public var surface: Color
    public var border: Color
    public var accent: Color
    public var muted: Color

    public init(
        surface: Color = .primary.opacity(0.045),
        border: Color = .primary.opacity(0.10),
        accent: Color = .accentColor,
        muted: Color = .secondary
    ) {
        self.surface = surface
        self.border = border
        self.accent = accent
        self.muted = muted
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

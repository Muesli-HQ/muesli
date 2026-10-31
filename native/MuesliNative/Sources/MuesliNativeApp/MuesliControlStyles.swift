import AppKit
import SwiftUI

/// Shared motion policy: short color feedback that is removed entirely under Reduce Motion.
enum MuesliMotion {
    static let feedback = Animation.easeOut(duration: 0.12)
    static let navigation = Animation.easeInOut(duration: 0.15)
    /// Press compression settles almost at once and releases quickly. The action never waits for it.
    static let pressIn = Animation.easeOut(duration: 0.06)
    static let pressRelease = Animation.easeOut(duration: 0.14)
    /// Visual scale of a pressed control. Layout and hit regions keep their full size.
    static let pressedScale: CGFloat = 0.98

    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }

    /// Pressed colors appear immediately; leaving the pressed state fades back.
    static func stateColorAnimation(pressed: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion || pressed ? nil : feedback
    }

    /// For actions outside a view body, where the environment value is not at hand.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `withAnimation` that applies the change immediately under Reduce Motion.
    @discardableResult
    static func perform<Result>(_ base: Animation = navigation, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(prefersReducedMotion ? nil : base, body)
    }
}

/// The one shape a control uses for its fill, border and hit area.
struct MuesliControlShape: InsettableShape {
    enum Form {
        case rounded(CGFloat)
        case capsule
        case circle
    }

    var form: Form
    var insetAmount: CGFloat = 0

    static func rounded(_ radius: CGFloat = MuesliTheme.cornerSmall) -> MuesliControlShape {
        MuesliControlShape(form: .rounded(radius))
    }
    static let capsule = MuesliControlShape(form: .capsule)
    static let circle = MuesliControlShape(form: .circle)

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch form {
        case .rounded(let radius):
            return RoundedRectangle(cornerRadius: max(0, radius - insetAmount)).path(in: rect)
        case .capsule:
            return Capsule().path(in: rect)
        case .circle:
            return Circle().path(in: rect)
        }
    }

    func inset(by amount: CGFloat) -> MuesliControlShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Flat color feedback for muesli's custom buttons. Callers keep geometry (padding, height,
/// width) and typography in the label; the style owns fill, border, foreground, hover,
/// pressed, keyboard-focus and disabled colors, and makes the whole shape clickable.
/// Pressing compresses the drawn control slightly; its layout and hit region do not change.
/// Native focus rings, keyboard activation and shortcuts are unchanged.
struct MuesliButtonStyle: ButtonStyle {
    enum Kind {
        /// Accent fill with `onAccent` content.
        case primary
        /// `success` fill with `onSuccess` content.
        case success
        /// `recordingFill` with white content, for labelled stop/record actions.
        case recording
        /// Neutral `surfacePrimary` fill with a border.
        case secondary
        /// `backgroundRaised` fill with a border, for field-like launchers.
        case raised
        /// Accent tint with `accentText` content.
        case tinted
        /// Neutral border and red text; red tint on hover.
        case destructive
        /// Red tint at rest with red text.
        case destructiveTinted
        /// No resting chrome; hover and press add a neutral fill. The label keeps its foreground.
        case quiet
    }

    var kind: Kind
    var shape: MuesliControlShape = .rounded()
    /// Defaults to bordered for secondary, raised and destructive kinds.
    var bordered: Bool?
    /// Full-width list rows stay flat and rely on the pressed fill alone.
    var compresses = true

    func makeBody(configuration: Configuration) -> some View {
        MuesliButtonChrome(
            configuration: configuration,
            kind: kind,
            shape: shape,
            bordered: bordered ?? (kind == .secondary || kind == .raised || kind == .destructive || kind == .destructiveTinted),
            compresses: compresses
        )
    }
}

extension ButtonStyle where Self == MuesliButtonStyle {
    static func muesli(
        _ kind: MuesliButtonStyle.Kind,
        shape: MuesliControlShape = .rounded(),
        bordered: Bool? = nil,
        compresses: Bool = true
    ) -> MuesliButtonStyle {
        MuesliButtonStyle(kind: kind, shape: shape, bordered: bordered, compresses: compresses)
    }
}

/// Visual-only press compression for custom controls. Apply after fills and borders and before
/// `contentShape`, so the hit region keeps its full unscaled frame. Reduce Motion removes it;
/// color feedback remains.
struct MuesliPressCompression: ViewModifier {
    var isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : (isPressed ? MuesliMotion.pressIn : MuesliMotion.pressRelease)) {
            $0.scaleEffect(isPressed && !reduceMotion ? MuesliMotion.pressedScale : 1)
        }
    }
}

enum MuesliControlState: Equatable {
    case rest, highlighted, pressed, disabled

    init(isEnabled: Bool, isPressed: Bool, isHighlighted: Bool) {
        if !isEnabled {
            self = .disabled
        } else if isPressed {
            self = .pressed
        } else if isHighlighted {
            self = .highlighted
        } else {
            self = .rest
        }
    }
}

private struct MuesliButtonChrome: View {
    let configuration: ButtonStyleConfiguration
    let kind: MuesliButtonStyle.Kind
    let shape: MuesliControlShape
    let bordered: Bool
    let compresses: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var state: MuesliControlState {
        MuesliControlState(
            isEnabled: isEnabled,
            isPressed: configuration.isPressed,
            isHighlighted: isHovered || isFocused
        )
    }

    var body: some View {
        styledLabel
            .background {
                ZStack {
                    shape.fill(baseFill)
                    shape.fill(stateOverlay)
                }
                .animation(MuesliMotion.stateColorAnimation(pressed: state == .pressed, reduceMotion: reduceMotion), value: state)
            }
            .overlay {
                // Quiet controls use fills for hover/press; only keyboard focus draws a ring.
                if isFocused && isEnabled {
                    shape.strokeBorder(MuesliTheme.accentText, lineWidth: 2)
                        .allowsHitTesting(false)
                } else if bordered {
                    shape.strokeBorder(
                        kind == .destructiveTinted ? MuesliTheme.recording.opacity(0.2) : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
            }
            .modifier(MuesliPressCompression(isPressed: compresses && state == .pressed))
            // Outside the scale effect: the full unscaled shape stays clickable while pressed.
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var styledLabel: some View {
        if kind == .quiet {
            configuration.label
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            configuration.label
                .foregroundStyle(foreground)
        }
    }

    private var foreground: Color {
        guard isEnabled else { return MuesliTheme.textTertiary }
        switch kind {
        case .primary: return MuesliTheme.onAccent
        case .success: return MuesliTheme.onSuccess
        case .recording: return MuesliTheme.onRecordingFill
        case .secondary, .raised, .quiet: return MuesliTheme.textPrimary
        case .tinted: return MuesliTheme.accentText
        case .destructive, .destructiveTinted: return MuesliTheme.destructiveText
        }
    }

    private var baseFill: Color {
        switch (kind, state) {
        case (.primary, .disabled), (.success, .disabled), (.recording, .disabled), (.tinted, .disabled):
            return MuesliTheme.surfacePrimary
        case (.primary, _):
            return MuesliTheme.accent
        case (.success, _):
            return MuesliTheme.success
        case (.recording, _):
            return MuesliTheme.recordingFill
        case (.secondary, _):
            return MuesliTheme.surfacePrimary
        case (.raised, _):
            return MuesliTheme.backgroundRaised
        case (.tinted, .pressed):
            return MuesliTheme.accent.opacity(MuesliTheme.accentTintPressed)
        case (.tinted, .highlighted):
            return MuesliTheme.accent.opacity(MuesliTheme.accentTintHover)
        case (.tinted, _):
            return MuesliTheme.accent.opacity(MuesliTheme.accentTintRest)
        case (.destructive, .pressed), (.destructiveTinted, .pressed):
            return MuesliTheme.recording.opacity(MuesliTheme.destructiveTintPressed)
        case (.destructive, .highlighted), (.destructiveTinted, .highlighted):
            return MuesliTheme.recording.opacity(MuesliTheme.destructiveTintHover)
        case (.destructiveTinted, .rest):
            return MuesliTheme.recording.opacity(MuesliTheme.destructiveTintRest)
        case (.destructive, _), (.destructiveTinted, _), (.quiet, _):
            return .clear
        }
    }

    /// Neutral feedback steps; accent fills shade away from their label instead.
    private var stateOverlay: Color {
        switch (kind, state) {
        case (.primary, .pressed):
            return MuesliTheme.accentStateShade.opacity(MuesliTheme.accentShadePressed)
        case (.primary, .highlighted):
            return MuesliTheme.accentStateShade.opacity(MuesliTheme.accentShadeHover)
        // Lighten under dark ink, darken under white text, so contrast only rises.
        case (.success, .pressed):
            return Color.white.opacity(MuesliTheme.accentShadePressed)
        case (.success, .highlighted):
            return Color.white.opacity(MuesliTheme.accentShadeHover)
        case (.recording, .pressed):
            return Color.black.opacity(MuesliTheme.accentShadePressed)
        case (.recording, .highlighted):
            return Color.black.opacity(MuesliTheme.accentShadeHover)
        case (.secondary, .pressed), (.raised, .pressed), (.quiet, .pressed):
            return MuesliTheme.textPrimary.opacity(0.11)
        case (.secondary, .highlighted), (.raised, .highlighted), (.quiet, .highlighted):
            return MuesliTheme.textPrimary.opacity(0.06)
        default:
            return .clear
        }
    }
}

/// A text-only action (Check again, Sign Out, Manage key…) with a 28pt target. The padding is
/// inside the label, so the clickable area exceeds the glyphs without changing their style.
struct MuesliTextButton: View {
    let title: String
    let font: Font
    let color: Color
    let action: () -> Void

    init(_ title: String, font: Font = MuesliTheme.caption(), color: Color = MuesliTheme.textSecondary, action: @escaping () -> Void) {
        self.title = title
        self.font = font
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minHeight: 28)
        }
        .buttonStyle(.muesli(.quiet))
        .fixedSize()
    }
}

extension View {
    /// Keyboard and VoiceOver activation for a gesture-driven row that cannot become a Button
    /// because it hosts nested controls, a drag source or a context menu. Pointer behavior is
    /// unchanged; the row is focusable only when full keyboard navigation is on.
    func muesliRowActivation(isSelected: Bool = false, action: @escaping () -> Void) -> some View {
        self
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                action()
                return .handled
            }
    }
}


extension View {
    /// A structural selected cue, including in Ultra Dark where hue cannot distinguish states.
    func muesliSelectionOutline(_ selected: Bool, radius: CGFloat = MuesliTheme.cornerSmall) -> some View {
        overlay {
            if selected {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(MuesliTheme.textSecondary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

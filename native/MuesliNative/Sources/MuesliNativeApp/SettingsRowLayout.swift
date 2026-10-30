import SwiftUI

/// Shared Settings layout. Roles and sizes are documented in docs/typography.md.
enum SettingsLayout {
    /// Bounded column for menus, text fields and compound controls. Switches use their intrinsic width.
    static let controlWidth: CGFloat = 275
    /// Height of a row's first line. Labels and controls are centred in it, so controls
    /// line up with the label rather than with the label and its description.
    static let firstLineHeight: CGFloat = 28
    static let columnSpacing: CGFloat = 20
    /// Content narrower than this stacks bounded controls beneath their labels.
    static let stackedContentWidth: CGFloat = 540
}

private struct SettingsStacksControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set once by the Settings page from its content width; rows do not measure themselves.
    var settingsStacksControls: Bool {
        get { self[SettingsStacksControlsKey.self] }
        set { self[SettingsStacksControlsKey.self] = newValue }
    }
}

/// Section heading above a Settings card or Models group.
struct SettingsSectionHeading: View {
    let title: String
    var icon: NSImage? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            }
            Text(title)
                .font(MuesliTheme.sectionHeading())
                .textCase(.uppercase)
        }
        .foregroundStyle(MuesliTheme.textSecondary)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Helper or status text. Wraps instead of truncating.
struct SettingsNote: View {
    enum Tone {
        case helper
        case warning
        case error
    }

    let text: String
    var tone: Tone = .helper

    init(_ text: String, tone: Tone = .helper) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(tone == .helper ? MuesliTheme.caption() : MuesliTheme.captionMedium())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var color: Color {
        switch tone {
        case .helper: MuesliTheme.textSecondary
        case .warning: MuesliTheme.transcribing
        case .error: MuesliTheme.recording
        }
    }
}

/// Label on the leading edge, control on the trailing edge, both centred on the first line.
/// Pass `controlWidth: nil` for switches and other compact controls; they keep their intrinsic
/// width and never stack. Bounded controls move beneath the label in narrow windows.
struct SettingsRow<Control: View>: View {
    let label: String
    var description: String? = nil
    var controlWidth: CGFloat? = SettingsLayout.controlWidth
    @ViewBuilder let control: Control

    @Environment(\.settingsStacksControls) private var stacksControls

    var body: some View {
        let stacked = stacksControls && controlWidth != nil
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: MuesliTheme.spacing8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: SettingsLayout.columnSpacing))
        // Keep the same children and modifiers across the breakpoint so native
        // editors preserve their first responder, selection and undo history.
        layout {
            labelColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            control
                .fixedSize(horizontal: controlWidth == nil, vertical: false)
                .frame(minWidth: stacked ? nil : controlWidth,
                       maxWidth: controlWidth,
                       alignment: stacked ? .leading : .trailing)
                .frame(minHeight: SettingsLayout.firstLineHeight)
        }
        .padding(.vertical, MuesliTheme.spacing4)
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !label.isEmpty {
                Text(label)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: SettingsLayout.firstLineHeight, alignment: .leading)
            }
            if let description, !description.isEmpty {
                SettingsNote(description)
            }
        }
    }
}

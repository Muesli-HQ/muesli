import SwiftUI

enum RecordingIndicatorStyle: String, CaseIterable {
    case classic, minimal, notch

    var title: String { rawValue.capitalized }
    var description: String {
        switch self {
        case .classic: return "A compact floating capsule."
        case .minimal: return "A quiet bar until you need it."
        case .notch: return "Activity around your camera notch."
        }
    }
}

extension AppConfig {
    // Interpret existing preferences without resetting anyone's selection.
    var recordingIndicatorStyle: RecordingIndicatorStyle {
        if indicatorAnchor == .notch { return .notch }
        return indicatorHoverStyle == .shortcutPill ? .minimal : .classic
    }

    mutating func selectRecordingIndicatorStyle(_ style: RecordingIndicatorStyle) {
        if style == .notch {
            if indicatorAnchor != .notch { savedFloatingIndicatorAnchor = indicatorAnchor }
            indicatorAnchor = .notch
        } else {
            if indicatorAnchor == .notch {
                indicatorAnchor = savedFloatingIndicatorAnchor.flatMap { $0 == .notch ? nil : $0 } ?? .topCenter
            }
            indicatorHoverStyle = style == .minimal ? .shortcutPill : .classic
        }
    }
}

struct RecordingIndicatorStylePicker: View {
    let selection: RecordingIndicatorStyle
    var accent: Color = MuesliTheme.accent
    let onSelect: (RecordingIndicatorStyle) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
            ForEach(RecordingIndicatorStyle.allCases, id: \.self) { style in
                Button { onSelect(style) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        RecordingIndicatorPreview(style: style, accent: accent)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        HStack(spacing: 8) {
                            Image(systemName: selection == style ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selection == style ? accent : Color.secondary)
                            Text(style.title).font(.headline)
                        }
                        Text(style.description).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.025))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selection == style ? accent : Color.primary.opacity(0.14),
                                          lineWidth: selection == style ? 2 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityValue(selection == style ? "Selected" : "Not selected")
                .accessibilityHint(style.description)
                .accessibilityAddTraits(selection == style ? [.isSelected] : [])
            }
        }
        // Limit the adaptive grid to three cards; otherwise wide settings panes
        // reserve empty columns after Notch and make the choices look left-aligned.
        .frame(maxWidth: 3 * 210 + 2 * 12)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Resolution-independent previews: labels remain accessible native text, and
/// the resting mark uses the same renderer as the real Muesli indicator.
struct RecordingIndicatorPreview: View {
    let style: RecordingIndicatorStyle
    var accent: Color = MuesliTheme.accent

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 18) {
                sample(active: false)
                sample(active: true)
            }
            .frame(width: 240, height: 200)
            .scaleEffect(min(1, geometry.size.width / 240))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(LinearGradient(colors: [Color(white: 0.64), Color(white: 0.76)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var logo: some View {
        Group {
            if let image = MenuBarIconRenderer.make(choice: "muesli") {
                Image(nsImage: image).resizable().scaledToFit()
            }
        }.frame(width: 22, height: 22).foregroundStyle(.white)
    }

    private func bars(_ color: Color) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { index in
                Capsule().fill(color).frame(width: 3, height: [9.0, 16, 21, 16, 9][index])
            }
        }
    }

    private func sample(active: Bool) -> some View {
        VStack(spacing: 12) {
            Text(active ? "Recording" : "At rest").font(.system(size: 11)).foregroundStyle(.black.opacity(0.7))
            Group {
                if style == .notch {
                    notch(active: active)
                } else if !active && style == .minimal {
                    Capsule().fill(.black.opacity(0.4)).frame(width: 64, height: 5)
                        .frame(height: 34)
                } else {
                    HStack(spacing: 17) {
                        if active {
                            Image(systemName: "xmark").font(.system(size: 10))
                            bars(.white)
                            Image(systemName: "stop.fill").font(.system(size: 9))
                        } else { logo }
                    }
                    .foregroundStyle(.white)
                    .frame(width: active ? 138 : 66, height: 34)
                    .background(active ? accent.opacity(0.85) : Color(white: 0.07), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75) }
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
                }
            }.frame(height: 36)
        }
    }

    private func notch(active: Bool) -> some View {
        HStack(spacing: 0) {
            if active {
                HStack(spacing: 4) {
                    logo.frame(width: 16).scaleEffect(0.7)
                    Text("Listening").font(.system(size: 8))
                }.frame(width: 76)
            }
            Color.black.frame(width: 74)
            if active {
                HStack(spacing: 8) {
                    bars(accent).scaleEffect(0.75)
                    Image(systemName: "xmark").font(.system(size: 8))
                }.frame(width: 76)
            }
        }
        .foregroundStyle(.white)
        .frame(height: 30)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .overlay {
            if active {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 0.7)
            }
        }
        .frame(width: 240, height: 30, alignment: .top)
        .background(.white.opacity(0.18))
    }
}

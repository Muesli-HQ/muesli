import SwiftUI
import MuesliCore

enum SyncOriginDisplay {
    static let iOSSource = "ios"
    static let iOSBadgeLabel = "iOS"
    static let iOSBadgeHelp = "Synced from Muesli for iOS"

    static func badgeLabel(forDictationSource source: String) -> String? {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == iOSSource
            ? iOSBadgeLabel
            : nil
    }

    static func badgeLabel(forMeetingSource source: MeetingSource) -> String? {
        source == .iOS ? iOSBadgeLabel : nil
    }
}

extension RecordOriginFilter {
    var label: String {
        switch self {
        case .all: return "All"
        case .thisMac: return "This Mac"
        case .fromIPhone: return "From iPhone"
        }
    }
}

struct RecordOriginPicker: View {
    @Binding var selection: RecordOriginFilter
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RecordOriginFilter.allCases, id: \.self) { origin in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selection = origin
                    }
                } label: {
                    Text(origin.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == origin ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if selection == origin {
                                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                    .fill(MuesliTheme.backgroundBase)
                                    .matchedGeometryEffect(id: "record-origin", in: selectionAnimation)
                                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // The segmented control's intrinsic width is wider than a hardcoded frame, and the extra
        // width bleeds out of it — which pushed the filter row past the page's leading padding.
        .fixedSize()

        .help("Filter by the device where the recording was created")
        .accessibilityLabel("Record source")
    }
}

struct SyncOriginBadge: View {
    let label: String
    var help: String = SyncOriginDisplay.iOSBadgeHelp

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(MuesliTheme.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help(help)
            .accessibilityLabel(help)
    }
}

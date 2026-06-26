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

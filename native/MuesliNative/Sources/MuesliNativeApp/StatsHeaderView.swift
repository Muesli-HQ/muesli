import SwiftUI
import MuesliCore

struct StatsHeaderView: View {
    let dictationStats: DictationStats
    let meetingStats: MeetingStats
    let onSelect: (InsightsSection) -> Void

    var body: some View {
        HStack(spacing: MuesliTheme.spacing16) {
            StatCard(
                icon: "flame.fill",
                iconColor: Color(hex: 0xF5A623),
                value: "\(dictationStats.currentStreakDays)",
                label: "day streak",
                accessibilityHint: "Open streak insights",
                action: { onSelect(.streak) }
            )
            StatCard(
                icon: "character.cursor.ibeam",
                iconColor: MuesliTheme.accent,
                value: formatWordCount(dictationStats.totalWords),
                label: "words dictated",
                accessibilityHint: "Open word activity insights",
                action: { onSelect(.words) }
            )
            StatCard(
                icon: "gauge.with.dots.needle.33percent",
                iconColor: MuesliTheme.success,
                value: String(format: "%.0f", dictationStats.averageWPM),
                label: "avg WPM",
                accessibilityHint: "Open speaking pace insights",
                action: { onSelect(.pace) }
            )
            StatCard(
                icon: "person.2.fill",
                iconColor: MuesliTheme.accent,
                value: "\(meetingStats.totalMeetings)",
                label: "meetings",
                accessibilityHint: "Open meeting insights",
                action: { onSelect(.meetings) }
            )
        }
        .featureTourTarget(.insightsEntry)
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.vertical, MuesliTheme.spacing20)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String
    let accessibilityHint: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
                Text(value)
                    .font(MuesliTheme.title2())
                    .monospacedDigit()
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(MuesliTheme.spacing16)
            .background(isHovered ? MuesliTheme.backgroundHover : MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(isHovered ? MuesliTheme.accent.opacity(0.38) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(InsightsStatButtonStyle(reduceMotion: reduceMotion))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help(accessibilityHint)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityHint(accessibilityHint)
    }
}

private struct InsightsStatButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

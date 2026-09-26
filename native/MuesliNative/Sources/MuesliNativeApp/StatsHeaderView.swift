import SwiftUI
import MuesliCore

struct StatsHeaderView: View {
    let dictationStats: DictationStats
    let meetingStats: MeetingStats
    var showsMeetingStat = true
    var tracksInsightsFeatureTour = false
    var showsWordsBeforeCodeSwitch = false
    var wbcsFromDate: String? = nil
    var wbcsToDate: String? = nil
    var wbcsOrigin: RecordOriginFilter = .all
    var wbcsTargetApplication: DictationTargetApplication? = nil
    let onSelect: (InsightsSection) -> Void
    @State private var wbcsMedian: Double?

    private var wbcsQueryID: String {
        "\(showsWordsBeforeCodeSwitch):\(dictationStats.totalSessions):\(dictationStats.totalWords):\(wbcsFromDate ?? ""):\(wbcsToDate ?? ""):\(wbcsOrigin.rawValue):\(wbcsTargetApplication?.id ?? "")"
    }

    @ViewBuilder
    var body: some View {
        Group {
            if tracksInsightsFeatureTour {
                cards
                    .featureTourTarget(.insightsEntry)
            } else {
                cards
            }
        }
        .task(id: wbcsQueryID) {
            wbcsMedian = nil
            guard showsWordsBeforeCodeSwitch else { return }
            let fromDate = wbcsFromDate
            let toDate = wbcsToDate
            let origin = wbcsOrigin
            let targetApplication = wbcsTargetApplication
            let worker = Task.detached(priority: .utility) {
                try? DictationStore().wordsBeforeCodeSwitch(
                    fromDate: fromDate,
                    toDate: toDate,
                    origin: origin,
                    targetApplication: targetApplication
                )
            }
            defer { worker.cancel() }
            let result = await worker.value
            if !Task.isCancelled { wbcsMedian = result }
        }
    }

    private var cards: some View {
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
            if showsWordsBeforeCodeSwitch {
                StatCard(
                    icon: "globe",
                    iconColor: MuesliTheme.accent,
                    value: formattedWBCS,
                    label: "WBCS",
                    accessibilityHint: "Words Before Code Switch: median English words before a detected language switch",
                    action: nil
                )
            }
            if showsMeetingStat {
                StatCard(
                    icon: "person.2.fill",
                    iconColor: MuesliTheme.accent,
                    value: "\(meetingStats.totalMeetings)",
                    label: "meetings",
                    accessibilityHint: "Open meeting insights",
                    action: { onSelect(.meetings) }
                )
            }
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.vertical, MuesliTheme.spacing20)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private var formattedWBCS: String {
        guard let wbcsMedian else { return "—" }
        return String(format: wbcsMedian.rounded() == wbcsMedian ? "%.0f" : "%.1f", wbcsMedian)
    }
}

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String
    let accessibilityHint: String
    let action: (() -> Void)?
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(InsightsStatButtonStyle(reduceMotion: reduceMotion))
            } else {
                content
            }
        }
        .onHover { hovering in
            guard action != nil else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help(accessibilityHint)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityHint(accessibilityHint)
    }

    private var content: some View {
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
}

private struct InsightsStatButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

import SwiftUI
import MuesliCore

struct InsightsView: View {
    let initialSection: InsightsSection
    let loadSnapshot: (InsightsRange) async throws -> InsightsSnapshot
    let loadCuriosity: (InsightsRange, Date) async throws -> Double?
    let onBack: () -> Void
    let backLabel: String

    @State private var range: InsightsRange = .ninetyDays
    @State private var metric: InsightsMetric
    @State private var snapshot: InsightsSnapshot?
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var isSharing = false
    @State private var showsCuriosities = false
    @State private var initialScrollGate = InsightsInitialScrollGate()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        initialSection: InsightsSection,
        loadSnapshot: @escaping (InsightsRange) async throws -> InsightsSnapshot,
        loadCuriosity: @escaping (InsightsRange, Date) async throws -> Double?,
        onBack: @escaping () -> Void,
        backLabel: String
    ) {
        self.initialSection = initialSection
        self.loadSnapshot = loadSnapshot
        self.loadCuriosity = loadCuriosity
        self.onBack = onBack
        self.backLabel = backLabel
        _metric = State(initialValue: initialSection == .meetings ? .meetings : .words)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                    Group {
                        if let snapshot {
                            hero(snapshot)
                            activityPanel(snapshot).id(initialSection == .meetings ? InsightsSection.meetings : .words)
                            usagePanel(snapshot).id(InsightsSection.pace)
                            streakPanel(snapshot).id(InsightsSection.streak)
                            attributionPanel(snapshot)
                            wordClouds(snapshot)
                            curiosities(snapshot)
                        } else if let errorMessage {
                            errorState(errorMessage)
                        } else {
                            loadingState
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(insightsBackground)
            .sheet(isPresented: $isSharing) {
                if let snapshot {
                    InsightsShareSheet(snapshot: snapshot, rangeLabel: range.label)
                }
            }
            .task(id: loadGeneration) {
                await refresh()
                guard initialScrollGate.consume(hasSnapshot: snapshot != nil) else { return }
                if reduceMotion {
                    proxy.scrollTo(initialSection, anchor: .top)
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(initialSection, anchor: .top)
                    }
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                headerIdentity
                Spacer()
                rangeControls
            }
            VStack(alignment: .leading, spacing: 14) {
                headerIdentity
                rangeControls
            }
        }
    }

    private var headerIdentity: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                Label(backLabel, systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(InsightsPalette.secondaryText)
            .keyboardShortcut(.cancelAction)

            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(width: 1, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("INSIGHTS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(MuesliTheme.accent)
                Text("Private and on-device")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(InsightsPalette.secondaryText)
            }
        }
    }

    private var rangeControls: some View {
        HStack(spacing: 12) {
            Picker("Time range", selection: Binding(
                get: { range },
                set: { newValue in range = newValue; loadGeneration += 1 }
            )) {
                ForEach(InsightsRange.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Time range")
            .frame(width: 340)

            Button {
                loadGeneration += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(InsightsPalette.secondaryText)
            .help("Refresh local insights")
            .accessibilityLabel("Refresh local insights")

            Button {
                isSharing = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(snapshot == nil)
            .help("Share an anonymous activity image")
            .accessibilityLabel("Share your activity")
        }
    }

    private func hero(_ data: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                    Text("Your time with Muesli")
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(data.lifetime.dictationWords.formatted())
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .tracking(-2.4)
                        .monospacedDigit()
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Words dictated · all time")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(InsightsPalette.secondaryText)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(data.lifetime.meetingWords.formatted())
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Words transcribed in meetings · all time")
                    .foregroundStyle(InsightsPalette.secondaryText)
            }

            HStack(spacing: 0) {
                heroDatum("Meetings", value: format(data.lifetime.meetings))
                divider
                heroDatum("Dictation pace", value: "\(Int(data.lifetime.averageWPM.rounded())) WPM")
                divider
                heroDatum("Current streak", value: dayCount(data.currentStreakDays))
                divider
                heroDatum("Longest streak", value: dayCount(data.longestStreakDays))
            }
        }
        .padding(26)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(MuesliTheme.backgroundRaised)
                LinearGradient(
                    colors: [MuesliTheme.accent.opacity(0.13), MuesliTheme.accent.opacity(0.025), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .overlay(panelBorder)
        .shadow(color: Color.black.opacity(0.12), radius: 24, y: 10)
    }

    private func activityPanel(_ data: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                panelTitle("DAILY ACTIVITY", subtitle: metric == .words ? "Words dictated each day" : "Meetings recorded each day")
                Spacer()
                Picker("Activity metric", selection: $metric) {
                    ForEach(InsightsMetric.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Activity metric")
                .tint(MuesliTheme.accent)
                .frame(width: 210)
            }
            ActivityHeatmap(activity: data.dailyActivity, metric: metric, now: data.generatedAt)
                .id(data.range)
                .frame(minHeight: 156)
            HStack(spacing: 8) {
                Text("QUIET")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(InsightsPalette.intensity(level))
                        .frame(width: 15, height: 15)
                }
                Text("LOUD")
            }
            .font(.system(size: 9, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(InsightsPalette.tertiaryText)
        }
        .insightsPanel()
    }

    private func attributionPanel(_ data: InsightsSnapshot) -> some View {
        let models = data.modelUsage.filter { $0.id != "unknown" }
        let unrecordedSessions = data.modelUsage.first { $0.id == "unknown" }?.sessions ?? 0
        return VStack(alignment: .leading, spacing: 20) {
            panelTitle("YOUR DICTATION HABITS", subtitle: "Sessions in the selected time period")
            if models.isEmpty {
                usageRanking("Apps", rows: data.appUsage, showsAppIcons: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        usageRanking("Models", rows: models).frame(minWidth: 260)
                        usageRanking("Apps", rows: data.appUsage, showsAppIcons: true).frame(minWidth: 260)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        usageRanking("Models", rows: models)
                        usageRanking("Apps", rows: data.appUsage, showsAppIcons: true)
                    }
                }
            }
            if unrecordedSessions > 0 {
                Text("Model not recorded for \(unrecordedSessions.formatted()) earlier or synced sessions. New dictations on this Mac will appear here by model.")
                    .font(.system(size: 11))
                    .foregroundStyle(InsightsPalette.tertiaryText)
            }
        }
        .insightsPanel()
    }

    private func usageRanking(_ title: String, rows: [InsightsUsage], showsAppIcons: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("No dictations in this period")
                    .foregroundStyle(InsightsPalette.secondaryText)
            }
            ForEach(rows.prefix(5)) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        usageIdentity(row, showsAppIcon: showsAppIcons)
                        Spacer()
                        Text("\(row.sessions.formatted()) sessions · \(row.words.formatted()) words")
                            .font(.caption).foregroundStyle(InsightsPalette.secondaryText)
                    }
                    ProgressView(value: Double(row.sessions), total: Double(max(rows.first?.sessions ?? 1, 1)))
                        .tint(MuesliTheme.accent)
                }
            }
            if rows.count > 5 {
                DisclosureGroup("All \(rows.count) \(title.lowercased())") {
                    ForEach(rows.dropFirst(5)) { row in
                        HStack {
                            usageIdentity(row, showsAppIcon: showsAppIcons)
                            Spacer()
                            Text("\(row.sessions.formatted()) sessions · \(row.words.formatted()) words")
                                .foregroundStyle(InsightsPalette.secondaryText)
                        }.font(.caption).padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageIdentity(_ row: InsightsUsage, showsAppIcon: Bool) -> some View {
        HStack(spacing: 8) {
            if showsAppIcon {
                TargetApplicationIconView(appName: row.name,
                    bundleIdentifier: row.id.hasPrefix("bundle:") ? String(row.id.dropFirst(7)) : nil,
                    size: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1).help(row.name)
                if !showsAppIcon, let route = modelRoute(row) {
                    Text(route)
                        .font(.caption2)
                        .foregroundStyle(InsightsPalette.tertiaryText)
                        .lineLimit(1)
                        .help(row.endpoint ?? route)
                }
            }
        }
    }

    private func modelRoute(_ row: InsightsUsage) -> String? {
        switch row.backend {
        case "openai-realtime":
            return "OpenAI · " + (row.endpoint.flatMap { URL(string: $0)?.host } ?? "Endpoint not recorded")
        case "openrouter-stt":
            return "OpenRouter · " + (row.endpoint.flatMap { URL(string: $0)?.host } ?? "Endpoint not recorded")
        case .some(let backend):
            if let endpoint = row.endpoint { return URL(string: endpoint)?.host ?? endpoint }
            return "On-device · \(backend)"
        case .none: return nil
        }
    }

    private func curiosities(_ data: InsightsSnapshot) -> some View {
        InsightsCuriositiesView(isExpanded: $showsCuriosities) {
            try await loadCuriosity(data.range, data.generatedAt)
        }
        // Refreshes and range changes create a fresh cache; disclosure changes do not.
        .id(loadGeneration)
    }

    private func usagePanel(_ data: InsightsSnapshot) -> some View {
        let total = max(data.selected.totalWords, 1)
        let dictationShare = Double(data.selected.dictationWords) / Double(total)
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                panelTitle("DICTATIONS AND MEETINGS", subtitle: "Activity for the selected time period")
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(format(data.selected.dictationWords))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .tracking(-1.5)
                        .monospacedDigit()
                    Text("words dictated")
                        .foregroundStyle(InsightsPalette.tertiaryText)
                }
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MuesliTheme.accent)
                            .frame(width: max(4, geometry.size.width * dictationShare))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MuesliTheme.accent.opacity(0.45))
                    }
                }
                .frame(height: 12)
                HStack {
                    usageLegend("Dictated words", data.selected.dictationWords, MuesliTheme.accent)
                    Spacer()
                    usageLegend("Meeting words", data.selected.meetingWords, MuesliTheme.accent.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 16) {
                Text("OVERVIEW")
                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                    .foregroundStyle(InsightsPalette.tertiaryText)
                readout("Dictation sessions", format(data.selected.dictationSessions))
                readout("Completed meetings", format(data.selected.meetings))
                readout("Dictation pace", "\(Int(data.selected.averageWPM.rounded())) WPM")
                readout("Active days", format(data.activeDaysInRange))
            }
            .padding(20)
            .frame(width: 300, alignment: .leading)
            .background(MuesliTheme.backgroundDeep.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MuesliTheme.surfaceBorder))
        }
        .insightsPanel()
    }

    private func streakPanel(_ data: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            panelTitle("STREAKS", subtitle: "Your consecutive dictation days")
            HStack(spacing: 0) {
                streakDatum(data.currentStreakDays, label: "Current streak")
                divider
                streakDatum(data.longestStreakDays, label: "Longest streak")
                divider
                streakDatum(data.activeDaysInRange, label: "Active in this period")
            }
            if data.currentStreakDays == 0 {
                Text("Dictate today to start a new streak.")
                    .font(.caption)
                    .foregroundStyle(InsightsPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .insightsPanel()
    }

    private func streakDatum(_ count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(count.formatted())
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MuesliTheme.accent)
                Text(count == 1 ? "day" : "days")
                    .font(.caption)
                    .foregroundStyle(InsightsPalette.secondaryText)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(InsightsPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func wordClouds(_ data: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            panelTitle("MOST-USED WORDS", subtitle: "Common words from your dictations and meetings")
            HStack(alignment: .top, spacing: 16) {
                WordCloudPanel(title: "DICTATIONS", icon: "waveform", words: data.dictationWords)
                WordCloudPanel(title: "MEETINGS", icon: "person.2.wave.2", words: data.meetingWords)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 18) {
            InsightsLoadingStatus()
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 14)
                    .fill(MuesliTheme.backgroundRaised)
                    .frame(height: index == 0 ? 235 : 190)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 12) {
                            RoundedRectangle(cornerRadius: 3).fill(MuesliTheme.surfacePrimary).frame(width: 130, height: 12)
                            RoundedRectangle(cornerRadius: 5).fill(MuesliTheme.surfacePrimary).frame(width: 230, height: 30)
                        }.padding(24)
                    }
                    .opacity(0.72)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calculating local insights")
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MuesliTheme.accent)
            Text("Insights could not be calculated")
                .font(MuesliTheme.title3())
            Text(message)
                .font(MuesliTheme.callout())
                .foregroundStyle(InsightsPalette.secondaryText)
            Button("Try Again") { loadGeneration += 1 }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .insightsPanel()
    }

    private func refresh() async {
        snapshot = nil
        errorMessage = nil
        do {
            let result = try await loadSnapshot(range)
            try Task.checkCancellation()
            snapshot = result
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var insightsBackground: some View {
        ZStack {
            MuesliTheme.backgroundBase
            LinearGradient(
                colors: [MuesliTheme.accent.opacity(0.045), .clear, MuesliTheme.accent.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }.ignoresSafeArea()
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
    }

    private var divider: some View {
        Rectangle().fill(MuesliTheme.surfaceBorder).frame(width: 1, height: 42)
    }

    private func heroDatum(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(InsightsPalette.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private func panelTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1.8).foregroundStyle(MuesliTheme.textPrimary)
            Text(subtitle).font(.system(size: 12, weight: .regular)).foregroundStyle(InsightsPalette.secondaryText)
        }
    }

    private func usageLegend(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(InsightsPalette.secondaryText)
            Text(format(value)).fontWeight(.semibold).monospacedDigit()
        }.font(.system(size: 12))
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(InsightsPalette.tertiaryText)
            Spacer()
            Text(value).foregroundStyle(MuesliTheme.textPrimary).monospacedDigit()
        }.font(.system(size: 12, weight: .medium))
    }

    private func format(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }

    private func dayCount(_ value: Int) -> String { "\(value) \(value == 1 ? "day" : "days")" }
}

enum InsightsLoadingCopy {
    static let messages = [
        "Calculating your private activity history",
        "Insights are computed on this Mac and never uploaded",
        "Your transcripts and statistics stay under your control",
        "Hybrid AI works best when you choose what stays local",
    ]
}

private struct InsightsLoadingStatus: View {
    @State private var messageIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
                .tint(MuesliTheme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Building your Insights")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                ZStack(alignment: .leading) {
                    Text(InsightsLoadingCopy.messages[messageIndex])
                        .id(messageIndex)
                        .transition(.opacity)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(InsightsPalette.secondaryText)
            }
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(MuesliTheme.accent.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MuesliTheme.surfaceBorder))
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    messageIndex = (messageIndex + 1) % InsightsLoadingCopy.messages.count
                }
            }
        }
    }
}

struct InsightsInitialScrollGate {
    private(set) var hasScrolled = false

    mutating func consume(hasSnapshot: Bool) -> Bool {
        guard hasSnapshot, !hasScrolled else { return false }
        hasScrolled = true
        return true
    }
}

private enum InsightsMetric: CaseIterable {
    case words, meetings
    var label: String {
        switch self {
        case .words: return "Dictated"
        case .meetings: return "Meetings"
        }
    }
}

private enum InsightsPalette {
    static let secondaryText = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.70,
        light: .black, lightAlpha: 0.72
    )
    static let tertiaryText = Color.adaptiveAlpha(
        dark: .white, darkAlpha: 0.52,
        light: .black, lightAlpha: 0.58
    )

    static func intensity(_ level: Int) -> Color {
        switch level {
        case 1: return MuesliTheme.accent.opacity(0.24)
        case 2: return MuesliTheme.accent.opacity(0.48)
        case 3: return MuesliTheme.accent.opacity(0.72)
        case 4...: return MuesliTheme.accent
        default: return MuesliTheme.surfacePrimary.opacity(0.62)
        }
    }
}

enum ActivityHeatmapCalendarLayout {
    static func currentMonthIndex(weeks: [[InsightsDailyActivity]], now: Date, calendar: Calendar) -> Int? {
        let current = weeks.indices.filter { index in
            weeks[index].contains { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
        }
        guard !current.isEmpty else { return weeks.indices.last }
        return current[current.count / 2]
    }

    static func weeks(
        from activity: [InsightsDailyActivity],
        calendar: Calendar
    ) -> [[InsightsDailyActivity]] {
        Dictionary(grouping: activity) { day -> Date in
            let startOfDay = calendar.startOfDay(for: day.date)
            let daysSinceSunday = calendar.component(.weekday, from: startOfDay) - 1
            return calendar.date(byAdding: .day, value: -daysSinceSunday, to: startOfDay) ?? startOfDay
        }
        .sorted { $0.key < $1.key }
        .map { _, days in days.sorted { $0.date < $1.date } }
    }

    static func monthMarker(
        for week: [InsightsDailyActivity],
        at index: Int,
        calendar: Calendar
    ) -> Date? {
        if let monthStart = week.first(where: { calendar.component(.day, from: $0.date) == 1 }) {
            return monthStart.date
        }
        return index == 0 ? week.first?.date : nil
    }
}

private struct ActivityHeatmap: View {
    let activity: [InsightsDailyActivity]
    let metric: InsightsMetric
    let now: Date
    private let cell: CGFloat = 14
    private let gap: CGFloat = 4
    private let monthLabelHeight: CGFloat = 14
    private let weekdayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing, spacing: gap) {
                        Color.clear.frame(width: 24, height: monthLabelHeight)
                        ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(InsightsPalette.tertiaryText)
                                .frame(width: 24, height: cell, alignment: .trailing)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                                VStack(alignment: .leading, spacing: gap) {
                                    Color.clear
                                        .frame(width: cell, height: monthLabelHeight)
                                        .overlay(alignment: .leading) {
                                            if let marker = ActivityHeatmapCalendarLayout.monthMarker(
                                                for: week,
                                                at: index,
                                                calendar: calendar
                                            ) {
                                                Text(marker.formatted(.dateTime.month(.abbreviated)))
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundStyle(InsightsPalette.tertiaryText)
                                                    .fixedSize()
                                            }
                                        }
                                    VStack(spacing: gap) {
                                        ForEach(0..<7, id: \.self) { weekday in
                                            if let day = week.first(where: {
                                                calendar.component(.weekday, from: $0.date) - 1 == weekday
                                            }) {
                                                cellView(day)
                                            } else {
                                                Color.clear.frame(width: cell, height: cell)
                                            }
                                        }
                                    }
                                }
                                .id(index)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onAppear { scrollToCurrentMonth(proxy) }
                    .onChange(of: geometry.size.width) { _, _ in scrollToCurrentMonth(proxy) }
                    .onChange(of: activity) { _, _ in scrollToCurrentMonth(proxy) }
                }
                .frame(width: min(geometry.size.width, 32 + CGFloat(weeks.count) * (cell + gap) - gap))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Daily \(metric.label.lowercased()) activity")
            }
        }
    }

    private func scrollToCurrentMonth(_ proxy: ScrollViewProxy) {
        guard let index = ActivityHeatmapCalendarLayout.currentMonthIndex(
            weeks: weeks, now: now, calendar: calendar) else { return }
        DispatchQueue.main.async { proxy.scrollTo(index, anchor: .center) }
    }

    private var calendar: Calendar { Calendar.current }

    private var weeks: [[InsightsDailyActivity]] {
        ActivityHeatmapCalendarLayout.weeks(from: activity, calendar: calendar)
    }

    private var maximum: Int {
        max(1, activity.map(value).max() ?? 1)
    }

    private func value(_ day: InsightsDailyActivity) -> Int {
        switch metric {
        case .words: return day.dictationWords
        case .meetings: return day.meetings
        }
    }

    private func level(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let ratio = log(Double(count) + 1) / log(Double(maximum) + 1)
        return min(4, max(1, Int(ceil(ratio * 4))))
    }

    private func cellView(_ day: InsightsDailyActivity) -> some View {
        let count = value(day)
        return ActivityHeatmapCell(
            day: day,
            count: count,
            metric: metric,
            level: level(count),
            size: cell
        )
    }
}

private struct ActivityHeatmapCell: View {
    let day: InsightsDailyActivity
    let count: Int
    let metric: InsightsMetric
    let level: Int
    let size: CGFloat
    @State private var isHovered = false

    private var dateText: String {
        day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    private var countText: String {
        switch metric {
        case .words:
            return count == 1 ? "1 word dictated" : "\(count.formatted()) words dictated"
        case .meetings:
            return count == 1 ? "1 meeting" : "\(count.formatted()) meetings"
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(InsightsPalette.intensity(level))
            .frame(width: size, height: size)
            .overlay {
                if count > 0 {
                    Circle().fill(Color.white.opacity(0.42)).frame(width: 2.5, height: 2.5)
                }
            }
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(InsightsPalette.secondaryText, lineWidth: 1.5)
                }
            }
            .onHover { isHovered = $0 }
            .popover(isPresented: $isHovered, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(countText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(dateText)
                        .font(.system(size: 11))
                        .foregroundStyle(InsightsPalette.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .fixedSize()
                .allowsHitTesting(false)
            }
            .focusable(true)
            .accessibilityElement()
            .accessibilityLabel("\(dateText), \(countText)")
    }
}

private struct WordCloudPanel: View {
    let title: String
    let icon: String
    let words: [InsightsWordFrequency]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(InsightsPalette.tertiaryText)
            if words.isEmpty {
                Text("No words to show for this time period.")
                    .font(.system(size: 13))
                    .foregroundStyle(InsightsPalette.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                WordFlowLayout(spacing: 9) {
                    ForEach(displayedWords) { item in
                        Text(item.word)
                            .font(.system(
                                size: InsightsWordCloudSizing.fontSize(for: item, displayedWords: displayedWords),
                                weight: item.count == displayedWords.first?.count ? .bold : .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(wordColor(item))
                            .help("Used \(item.count.formatted()) times")
                            .accessibilityLabel("\(item.word), used \(item.count.formatted()) times")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .insightsPanel()
    }

    private var displayedWords: [InsightsWordFrequency] {
        Array(words.prefix(32))
    }

    private func wordColor(_ item: InsightsWordFrequency) -> Color {
        guard item.id != words.first?.id else { return .cyan }
        return item.count >= (words.first?.count ?? 0) / 2 ? MuesliTheme.accent : InsightsPalette.secondaryText
    }
}

enum InsightsWordCloudSizing {
    static func fontSize(for item: InsightsWordFrequency, displayedWords: [InsightsWordFrequency]) -> CGFloat {
        let high = max(1, displayedWords.first?.count ?? 1)
        let low = max(1, displayedWords.last?.count ?? 1)
        guard high > low else { return 18 }
        let ratio = log(Double(item.count - low + 1)) / log(Double(high - low + 1))
        return 13 + CGFloat(ratio) * 20
    }
}

struct WordFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading, proposal: .unspecified)
        }
    }

    func layout(sizes: [CGSize], width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        layout(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            width: proposal.width ?? 420
        )
    }
}

private extension InsightsRange {
    var label: String {
        switch self {
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .twelveMonths: return "12 months"
        case .allTime: return "All time"
        }
    }
}

private extension View {
    func insightsPanel() -> some View {
        self
            .padding(22)
            .background(MuesliTheme.backgroundRaised.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.07), radius: 14, y: 7)
    }
}

/// Caches even an empty result for this snapshot, and rejects cancelled completions.
@MainActor
final class InsightsCuriosityModel: ObservableObject {
    @Published private(set) var value: Double?
    @Published private(set) var isLoaded = false
    @Published private(set) var errorMessage: String?

    func load(isExpanded: Bool, using loader: () async throws -> Double?) async {
        guard isExpanded, !isLoaded else { return }
        do {
            try Task.checkCancellation()
            errorMessage = nil
            let result = try await loader()
            try Task.checkCancellation()
            value = result
            isLoaded = true
        } catch is CancellationError {
            // Closing or replacing the snapshot cancels the query without caching a result.
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn't load this curiosity. Try again."
        }
    }
}

private struct InsightsCuriositiesView: View {
    @Binding var isExpanded: Bool
    let load: () async throws -> Double?
    @StateObject private var model = InsightsCuriosityModel()
    @State private var retryGeneration = 0

    private struct Request: Equatable {
        let isExpanded: Bool
        let retryGeneration: Int
    }

    var body: some View {
        DisclosureGroup("Curiosities", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let value = model.value {
                        Text(value.formatted(.number.precision(.fractionLength(0...1))))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(MuesliTheme.accent)
                    }
                    Text("English words before a language switch")
                        .font(.headline)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                    Button("Try Again") { retryGeneration += 1 }
                } else if !model.isLoaded {
                    ProgressView("Loading curiosity…")
                        .controlSize(.small)
                } else if model.value == nil {
                    Text("No eligible language switches recorded yet.")
                        .font(.callout)
                }
                Text("Just for fun: the median English stretch in Bodhan Flex Mixed dictations during this period. Estimated on this Mac from the original transcript; Romanized switches may be missed.")
                    .font(.caption)
                    .foregroundStyle(InsightsPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        }
        .font(.caption)
        .foregroundStyle(InsightsPalette.secondaryText)
        .tint(MuesliTheme.accent)
        .insightsPanel()
        .task(id: Request(isExpanded: isExpanded, retryGeneration: retryGeneration)) {
            await model.load(isExpanded: isExpanded, using: load)
        }
    }

}

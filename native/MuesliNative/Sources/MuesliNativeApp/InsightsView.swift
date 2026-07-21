import SwiftUI
import MuesliCore

struct InsightsView: View {
    let initialSection: InsightsSection
    let loadSnapshot: (InsightsRange) async throws -> InsightsSnapshot
    let onBack: () -> Void
    let backLabel: String

    @State private var range: InsightsRange = .twelveMonths
    @State private var metric: InsightsMetric
    @State private var snapshot: InsightsSnapshot?
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var isSharing = false
    @State private var initialScrollGate = InsightsInitialScrollGate()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        initialSection: InsightsSection,
        loadSnapshot: @escaping (InsightsRange) async throws -> InsightsSnapshot,
        onBack: @escaping () -> Void,
        backLabel: String
    ) {
        self.initialSection = initialSection
        self.loadSnapshot = loadSnapshot
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
                            bentoDashboard(snapshot)
                                .id(initialSection == .meetings ? InsightsSection.meetings : .words)
                        } else if let errorMessage {
                            errorState(errorMessage)
                        } else {
                            loadingState
                        }
                    }
                }
                .padding(MuesliTheme.spacing48)
                .frame(maxWidth: 1120, alignment: .leading)
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

    private func bentoDashboard(_ data: InsightsSnapshot) -> some View {
        VStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    goalsTile(data)
                        .frame(width: 200)
                    VStack(spacing: 16) {
                        metricRow(data)
                        HStack(alignment: .top, spacing: 16) {
                            weeklyTile(data)
                            VStack(spacing: 16) {
                                topAppsTile(data)
                                compactActivityTile(data)
                            }
                            .frame(width: 190)
                        }
                        wordInsightRow(data)
                    }
                }
                VStack(spacing: 16) {
                    goalsTile(data)
                    metricRow(data)
                    weeklyTile(data)
                    topAppsTile(data)
                    wordInsightRow(data)
                }
            }
            heatmapTile(data)
        }
    }

    private func goalsTile(_ data: InsightsSnapshot) -> some View {
        let wordProgress = min(Double(data.selected.totalWords) / 1500.0, 1)
        let meetingProgress = min(Double(data.selected.meetings) / 3.0, 1)
        let activeProgress = min(Double(data.activeDaysInRange) / 7.0, 1)
        return VStack(alignment: .leading, spacing: 16) {
            ZStack {
                BentoProgressRing(progress: wordProgress, color: MuesliTheme.accent, diameter: 108, lineWidth: 10)
                BentoProgressRing(progress: meetingProgress, color: MuesliTheme.secondaryAccent, diameter: 80, lineWidth: 10)
                BentoProgressRing(progress: activeProgress, color: MuesliTheme.transcribing, diameter: 52, lineWidth: 10)
            }
            .frame(width: 124, height: 124)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                goalLegend(color: MuesliTheme.accent, label: "Words", value: "\(format(data.selected.totalWords)) of 1.5k")
                goalLegend(color: MuesliTheme.secondaryAccent, label: "Meetings", value: "\(data.selected.meetings) of 3")
                goalLegend(color: MuesliTheme.transcribing, label: "Active days", value: "\(data.activeDaysInRange) of 7")
            }

            Divider().background(MuesliTheme.surfaceBorder)
            VStack(alignment: .leading, spacing: 5) {
                Text("TODAY'S GOAL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text("Close all three rings")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        }
        .padding(20)
        .frame(height: 428, alignment: .topLeading)
        .bentoTile()
    }

    private func metricRow(_ data: InsightsSnapshot) -> some View {
        HStack(spacing: 16) {
            bentoMetric(value: "\(Int(data.selected.averageWPM.rounded()))", label: "words per minute", icon: "gauge.with.dots.needle.50percent")
            bentoMetric(value: format(data.selected.totalWords), label: "words dictated", icon: "text.word.spacing")
            bentoMetric(value: "\(data.currentStreakDays)", label: "day streak", icon: "flame")
        }
    }

    private func bentoMetric(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MuesliTheme.textPrimary)
                if label == "day streak" {
                    Image(systemName: "flame")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                }
            }
            Text(label)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .bentoTile()
    }

    private func weeklyTile(_ data: InsightsSnapshot) -> some View {
        let days = Array(data.dailyActivity.suffix(7))
        let maximum = max(days.map(\.words).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week")
                    .font(MuesliTheme.title3())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
                Text("words per day")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(index == days.count - 1 ? MuesliTheme.accent : MuesliTheme.accent.opacity(0.16))
                            .frame(height: max(4, 74 * CGFloat(day.words) / CGFloat(maximum)))
                            .help("\(day.words.formatted()) words")
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 96, alignment: .bottom)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
        .bentoTile()
    }

    private func topAppsTile(_ data: InsightsSnapshot) -> some View {
        let apps = Array(data.topApps.prefix(4))
        let maximum = max(apps.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Top apps")
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textPrimary)
            ForEach(apps) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(1)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(MuesliTheme.surfacePrimary)
                            Capsule().fill(MuesliTheme.secondaryAccent.opacity(0.72))
                                .frame(width: geometry.size.width * CGFloat(app.count) / CGFloat(maximum))
                        }
                    }
                    .frame(height: 5)
                }
            }
            if apps.isEmpty {
                Text("Your most-used apps will appear here.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
        .bentoTile()
    }

    private func compactActivityTile(_ data: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(data.activeDaysInRange)")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("active days this period")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .leading)
        .bentoTile()
    }

    private func wordInsightRow(_ data: InsightsSnapshot) -> some View {
        let common = data.dictationWords.first
        let candidate = data.dictationWords.dropFirst().first ?? data.meetingWords.first
        return HStack(spacing: 16) {
            wordInsightTile(
                eyebrow: "Most common word",
                word: common?.word ?? "—",
                detail: common.map { "Used \($0.count) times" } ?? "Keep dictating to see patterns",
                icon: "textformat.abc"
            )
            wordInsightTile(
                eyebrow: "Dictionary suggestion",
                word: candidate?.word ?? "No suggestion yet",
                detail: candidate == nil ? "New words will appear here" : "Review for your dictionary",
                icon: "character.book.closed"
            )
        }
    }

    private func wordInsightTile(eyebrow: String, word: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow)
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(word)
                    .font(MuesliTheme.title3())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .leading)
        .bentoTile()
    }

    private func heatmapTile(_ data: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last 12 weeks")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Words and meetings by day")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                MuesliSegmentedTabs(
                    options: InsightsMetric.allCases,
                    selection: $metric,
                    title: { $0.label }
                )
                .frame(width: 160)
            }
            ActivityHeatmap(activity: twelveWeekActivity(data), metric: metric)
                .frame(height: 156)
            HStack(spacing: 8) {
                Text("QUIET")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(InsightsPalette.intensity(level))
                        .frame(width: 15, height: 15)
                }
                Text("LOUD")
                Spacer()
                Text("longest streak · \(data.longestStreakDays) days")
            }
            .font(.system(size: 9, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(20)
        .bentoTile()
    }

    private func twelveWeekActivity(_ data: InsightsSnapshot) -> [InsightsDailyActivity] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: data.generatedAt)
        let valuesByDay = Dictionary(uniqueKeysWithValues: data.dailyActivity.map {
            (calendar.startOfDay(for: $0.date), $0)
        })
        return (0..<84).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 83, to: end) else { return nil }
            return valuesByDay[date] ?? InsightsDailyActivity(date: date, words: 0, meetings: 0)
        }
    }

    private func goalLegend(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label).foregroundStyle(MuesliTheme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(MuesliTheme.textTertiary)
        }
        .font(MuesliTheme.caption())
    }

    private func insightsBento(_ data: InsightsSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                usagePanel(data)
                    .id(InsightsSection.pace)
                    .frame(maxWidth: .infinity)
                streakPanel(data)
                    .id(InsightsSection.streak)
                    .frame(maxWidth: .infinity)
            }

            VStack(spacing: 20) {
                usagePanel(data).id(InsightsSection.pace)
                streakPanel(data).id(InsightsSection.streak)
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
            MuesliSegmentedTabs(
                options: InsightsRange.allCases,
                selection: Binding(
                    get: { range },
                    set: { newValue in range = newValue; loadGeneration += 1 }
                ),
                title: { $0.label }
            )
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
                    Text(data.lifetime.totalWords.formatted())
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .tracking(-2.4)
                        .monospacedDigit()
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Total words dictated")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(InsightsPalette.secondaryText)
            }

            HStack(spacing: 0) {
                heroDatum("Meetings", value: format(data.lifetime.meetings))
                divider
                heroDatum("Average pace", value: "\(Int(data.lifetime.averageWPM.rounded())) WPM")
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
                    colors: [MuesliTheme.accent.opacity(0.13), MuesliTheme.secondaryAccent.opacity(0.07), .clear],
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
                panelTitle("DAILY ACTIVITY", subtitle: "Words and meetings by day")
                Spacer()
                Picker("Activity metric", selection: $metric) {
                    ForEach(InsightsMetric.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Activity metric")
                .frame(width: 190)
            }
            ActivityHeatmap(activity: data.dailyActivity, metric: metric)
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

    private func usagePanel(_ data: InsightsSnapshot) -> some View {
        let total = max(data.selected.totalWords, 1)
        let dictationShare = Double(data.selected.dictationWords) / Double(total)
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                panelTitle("DICTATIONS AND MEETINGS", subtitle: "Activity for the selected time period")
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(format(data.selected.totalWords))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .tracking(-1.5)
                        .monospacedDigit()
                    Text("words")
                        .foregroundStyle(InsightsPalette.tertiaryText)
                }
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MuesliTheme.accent)
                            .frame(width: max(4, geometry.size.width * dictationShare))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MuesliTheme.secondaryAccent.opacity(0.78))
                    }
                }
                .frame(height: 12)
                HStack {
                    usageLegend("Dictation", data.selected.dictationWords, MuesliTheme.accent)
                    Spacer()
                    usageLegend("Meetings", data.selected.meetingWords, .cyan)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 16) {
                Text("OVERVIEW")
                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                    .foregroundStyle(InsightsPalette.tertiaryText)
                readout("Dictation sessions", format(data.selected.dictationSessions))
                readout("Completed meetings", format(data.selected.meetings))
                readout("Average pace", "\(Int(data.selected.averageWPM.rounded())) WPM")
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
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(data.currentStreakDays)")
                    .font(.system(size: 70, weight: .bold, design: .rounded))
                    .tracking(-3)
                    .monospacedDigit()
                Text("CURRENT STREAK")
                    .font(.system(size: 11, weight: .bold)).tracking(1.8)
                    .foregroundStyle(MuesliTheme.accent)
            }
            VStack(alignment: .leading, spacing: 14) {
                panelTitle("STREAKS", subtitle: "Your consecutive dictation days")
                Text(streakMessage(data))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(InsightsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Label("Best: \(data.longestStreakDays) days", systemImage: "flag.checkered")
                    Label("\(data.activeDaysInRange) active days", systemImage: "calendar.badge.checkmark")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(InsightsPalette.tertiaryText)
            }
        }
        .insightsPanel()
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
        MuesliTheme.backgroundBase.ignoresSafeArea()
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
    }

    private var divider: some View {
        Rectangle().fill(MuesliTheme.surfaceBorder).frame(width: 1, height: 42)
    }

    private func heroDatum(_ label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: heroIcon(for: label))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 30, height: 30)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(InsightsPalette.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private func heroIcon(for label: String) -> String {
        switch label {
        case "Meetings": return "person.2"
        case "Average pace": return "gauge.with.dots.needle.50percent"
        case "Current streak": return "flame"
        default: return "trophy"
        }
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

    private func streakMessage(_ data: InsightsSnapshot) -> String {
        guard data.currentStreakDays > 0 else { return "Dictate today to start a new streak." }
        if data.currentStreakDays == data.longestStreakDays { return "This is your longest streak so far." }
        return "Your longest streak is \(dayCount(data.longestStreakDays))."
    }

    private func format(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }

    private func dayCount(_ value: Int) -> String { "\(value) \(value == 1 ? "day" : "days")" }
}

private struct BentoProgressRing: View {
    let progress: Double
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.025, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct BentoHeatmap: View {
    let activity: [InsightsDailyActivity]

    private var paddedActivity: [InsightsDailyActivity?] {
        Array(repeating: nil, count: max(0, 84 - activity.count)) + activity.map(Optional.some)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(0..<12, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        let item = paddedActivity[week * 7 + day]
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: item?.words ?? 0))
                            .frame(width: 13, height: 13)
                            .help(item.map { "\($0.words.formatted()) words" } ?? "No activity")
                    }
                }
            }
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                Text("Less")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                ForEach([0, 1, 2, 3], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: level * 250))
                        .frame(width: 11, height: 11)
                }
                Text("More")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
    }

    private func color(for words: Int) -> Color {
        switch words {
        case 0: MuesliTheme.surfacePrimary
        case 1..<150: MuesliTheme.accent.opacity(0.18)
        case 150..<400: MuesliTheme.secondaryAccent.opacity(0.45)
        default: MuesliTheme.accent
        }
    }
}

private extension View {
    func bentoTile() -> some View {
        background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }
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
    var label: String { self == .words ? "Words" : "Meetings" }
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
        case 3: return Color.cyan.opacity(0.67)
        case 4...: return Color.cyan.opacity(0.95)
        default: return MuesliTheme.surfacePrimary.opacity(0.62)
        }
    }
}

enum ActivityHeatmapCalendarLayout {
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
    private let cell: CGFloat = 14
    private let gap: CGFloat = 4
    private let monthLabelHeight: CGFloat = 14
    private let weekdayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]

    var body: some View {
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

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: gap) {
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
                                .id(week.first?.date)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .onAppear { scrollToLatest(proxy) }
            .onChange(of: activity.last?.date) { _, _ in scrollToLatest(proxy) }
            .accessibilityLabel("Daily \(metric.label.lowercased()) activity")
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let latestWeek = weeks.last?.first?.date else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(latestWeek, anchor: .trailing)
        }
    }

    private var calendar: Calendar { Calendar.current }

    private var weeks: [[InsightsDailyActivity]] {
        ActivityHeatmapCalendarLayout.weeks(from: activity, calendar: calendar)
    }

    private var maximum: Int {
        max(1, activity.map(value).max() ?? 1)
    }

    private func value(_ day: InsightsDailyActivity) -> Int {
        metric == .words ? day.words : day.meetings
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

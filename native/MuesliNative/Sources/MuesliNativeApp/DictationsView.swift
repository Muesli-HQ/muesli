import AppKit
import SwiftUI
import MuesliCore

enum DictationFilter: Hashable {
    case all, last2Days, lastWeek, last2Weeks, lastMonth, last3Months

    var label: String {
        switch self {
        case .all: return "All time"
        case .last2Days: return "Last 2 days"
        case .lastWeek: return "Last week"
        case .last2Weeks: return "Last 2 weeks"
        case .lastMonth: return "Last month"
        case .last3Months: return "Last 3 months"
        }
    }
}

struct DictationsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var selectedFilter: DictationFilter = .all
    private let iOSCompanionURL = URL(string: "https://github.com/Muesli-HQ/muesli-ios")!

    private var groupedDictations: [(header: String, records: [DictationRecord])] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let dateHeaderFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale.current
            f.dateFormat = "EEE, d MMM"
            return f
        }()

        var groups: [(key: Date, header: String, records: [DictationRecord])] = []
        var currentDayStart: Date?
        var currentRecords: [DictationRecord] = []
        var currentHeader = ""

        for record in appState.dictationRows {
            let date = parseDate(record.timestamp) ?? now
            let dayStart = calendar.startOfDay(for: date)

            if dayStart != currentDayStart {
                if !currentRecords.isEmpty, let key = currentDayStart {
                    groups.append((key: key, header: currentHeader, records: currentRecords))
                }
                currentDayStart = dayStart
                currentRecords = []

                if dayStart == today {
                    currentHeader = "TODAY"
                } else if dayStart == yesterday {
                    currentHeader = "YESTERDAY"
                } else {
                    currentHeader = dateHeaderFormatter.string(from: date).uppercased()
                }
            }
            currentRecords.append(record)
        }
        if !currentRecords.isEmpty, let key = currentDayStart {
            groups.append((key: key, header: currentHeader, records: currentRecords))
        }

        return groups.map { (header: $0.header, records: $0.records) }
    }

    var body: some View {
        VStack(spacing: 0) {
            StatsHeaderView(
                dictationStats: appState.dictationStats,
                meetingStats: appState.meetingStats
            )

            if appState.config.showIOSCompanionPrompt {
                iOSCompanionPrompt
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.bottom, MuesliTheme.spacing12)
            }

            if appState.config.resolvedOnboardingUseCase.includesVoiceNotes {
                HStack {
                    Spacer()
                    voiceNoteButton
                }
                .padding(.horizontal, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing12)
            }

            if appState.dictationRows.isEmpty {
                Spacer()
                VStack(spacing: MuesliTheme.spacing12) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Text("No dictations yet")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text(emptyStateInstruction)
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                        ForEach(Array(groupedDictations.enumerated()), id: \.element.header) { index, group in
                            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                                HStack {
                                    Text(group.header)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                        .padding(.leading, MuesliTheme.spacing4)

                                    Spacer()

                                    // Filter button on the first group header
                                    if index == 0 {
                                        dateFilterButton
                                    }
                                }

                                VStack(spacing: 1) {
                                    ForEach(group.records) { record in
                                        DictationRowView(
                                            record: record,
                                            timeOnly: formatTimeOnly(record.timestamp),
                                            onCopy: {
                                                controller.copyToClipboard(record.rawText)
                                            },
                                            onCopyTrace: record.computerUseTrace == nil ? nil : {
                                                controller.copyToClipboard(ComputerUseTraceFormatter.debugText(for: record))
                                            },
                                            onDelete: {
                                                controller.deleteDictation(id: record.id)
                                            }
                                        )
                                        .contextMenu {
                                            Button {
                                                controller.copyToClipboard(record.rawText)
                                            } label: {
                                                Label("Copy", systemImage: "doc.on.doc")
                                            }
                                            if record.computerUseTrace != nil {
                                                Button {
                                                    controller.copyToClipboard(ComputerUseTraceFormatter.debugText(for: record))
                                                } label: {
                                                    Label("Copy CUA Trace", systemImage: "list.bullet.clipboard")
                                                }
                                            }
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                                .overlay(
                                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                                )
                            }
                        }

                        // Infinite scroll trigger
                        if appState.hasMoreDictations {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    controller.loadMoreDictations()
                                }
                        }
                    }
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.bottom, MuesliTheme.spacing24)
                }
            }
        }
    }

    private var iOSCompanionPrompt: some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Muesli for iPhone")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Capture offline meetings on iPhone and prepare private iCloud sync with this Mac.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Button {
                NSWorkspace.shared.open(iOSCompanionURL)
            } label: {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)

            Button {
                controller.updateConfig { $0.showIOSCompanionPrompt = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .help("Hide iOS companion prompt")
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var emptyStateInstruction: String {
        appState.config.resolvedOnboardingUseCase.includesVoiceNotes
            ? "Click Record Voice Note to capture your first note"
            : "Hold \(appState.config.dictationHotkey.label) to start dictating"
    }

    private var voiceNoteButton: some View {
        let isRecording = appState.isVoiceNoteRecording
        return Button {
            controller.toggleVoiceNoteRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(isRecording ? "Stop Voice Note" : "Record Voice Note")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(isRecording ? MuesliTheme.recording : MuesliTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(appState.dictationState == .transcribing)
        .opacity(appState.dictationState == .transcribing ? 0.55 : 1)
    }

    @ViewBuilder
    private var dateFilterButton: some View {
        Menu {
            ForEach(availableFilters, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                    applyFilter(filter)
                } label: {
                    HStack {
                        Text(filter.label)
                        if selectedFilter == filter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                if selectedFilter != .all {
                    Text(selectedFilter.label)
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(selectedFilter != .all ? MuesliTheme.accent : MuesliTheme.textTertiary)
            .padding(.horizontal, selectedFilter != .all ? 8 : 0)
            .padding(.vertical, 3)
            .background(selectedFilter != .all ? MuesliTheme.accent.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Build filter options dynamically based on the date range of actual data.
    private var availableFilters: [DictationFilter] {
        var filters: [DictationFilter] = [.all]
        let calendar = Calendar.current
        let now = Date()

        // Check oldest dictation to determine which filters make sense
        let oldestDate: Date? = appState.dictationRows.last.flatMap { parseDate($0.timestamp) }
            ?? appState.dictationRows.first.flatMap { parseDate($0.timestamp) }

        guard let oldest = oldestDate else { return filters }
        let daysSinceOldest = calendar.dateComponents([.day], from: oldest, to: now).day ?? 0

        // Always show "Last 2 days" if data spans more than today
        if daysSinceOldest >= 1 { filters.append(.last2Days) }
        if daysSinceOldest >= 3 { filters.append(.lastWeek) }
        if daysSinceOldest >= 8 { filters.append(.last2Weeks) }
        if daysSinceOldest >= 15 { filters.append(.lastMonth) }
        if daysSinceOldest >= 31 { filters.append(.last3Months) }

        return filters
    }

    private func applyFilter(_ filter: DictationFilter) {
        let calendar = Calendar.current
        let now = Date()

        switch filter {
        case .all:
            controller.clearDictationFilter()
        case .last2Days:
            controller.filterDictations(from: calendar.date(byAdding: .day, value: -2, to: now), to: nil)
        case .lastWeek:
            controller.filterDictations(from: calendar.date(byAdding: .day, value: -7, to: now), to: nil)
        case .last2Weeks:
            controller.filterDictations(from: calendar.date(byAdding: .day, value: -14, to: now), to: nil)
        case .lastMonth:
            controller.filterDictations(from: calendar.date(byAdding: .month, value: -1, to: now), to: nil)
        case .last3Months:
            controller.filterDictations(from: calendar.date(byAdding: .month, value: -3, to: now), to: nil)
        }
    }

    // MARK: - Date parsing

    private static let parsers: [DateFormatterProtocol] = {
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        let local1: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return f
        }()
        let local2: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }()
        return [iso1, iso2, local1, local2]
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "hh:mm a"
        return f
    }()

    private func parseDate(_ raw: String) -> Date? {
        for parser in Self.parsers {
            if let date = parser.date(from: raw) {
                return date
            }
        }
        return nil
    }

    private func formatTimeOnly(_ raw: String) -> String {
        guard let date = parseDate(raw) else {
            let clean = raw.replacingOccurrences(of: "T", with: " ")
            return clean.count > 5 ? String(clean.suffix(8).prefix(5)) : clean
        }
        return Self.timeFormatter.string(from: date)
    }
}

private protocol DateFormatterProtocol {
    func date(from string: String) -> Date?
}

extension DateFormatter: DateFormatterProtocol {}
extension ISO8601DateFormatter: DateFormatterProtocol {}

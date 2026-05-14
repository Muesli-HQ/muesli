import SwiftUI
import MuesliCore

enum MeetingBrowserFilter: Hashable {
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

enum MeetingBrowserSort: Hashable {
    case newestFirst
    case oldestFirst

    var label: String {
        switch self {
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }
}

enum MeetingBrowserLogic {
    static func availableFilters(
        for meetings: [MeetingRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingBrowserFilter] {
        var filters: [MeetingBrowserFilter] = [.all]
        let oldestDate = meetings.compactMap { parseDate($0.startTime) }.min()

        guard let oldest = oldestDate else { return filters }
        let daysSinceOldest = calendar.dateComponents([.day], from: oldest, to: now).day ?? 0

        if daysSinceOldest >= 1 { filters.append(.last2Days) }
        if daysSinceOldest >= 3 { filters.append(.lastWeek) }
        if daysSinceOldest >= 8 { filters.append(.last2Weeks) }
        if daysSinceOldest >= 15 { filters.append(.lastMonth) }
        if daysSinceOldest >= 31 { filters.append(.last3Months) }

        return filters
    }

    static func filteredMeetings(
        from meetings: [MeetingRecord],
        filter: MeetingBrowserFilter,
        sort: MeetingBrowserSort,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingRecord] {
        let threshold = threshold(for: filter, now: now, calendar: calendar)
        let filtered = meetings.filter { isAfterThreshold($0, threshold: threshold) }

        return filtered.sorted { lhs, rhs in
            let lhsDate = parseDate(lhs.startTime) ?? .distantPast
            let rhsDate = parseDate(rhs.startTime) ?? .distantPast
            switch sort {
            case .newestFirst:
                return lhsDate > rhsDate
            case .oldestFirst:
                return lhsDate < rhsDate
            }
        }
    }

    private static func threshold(
        for filter: MeetingBrowserFilter,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        switch filter {
        case .all:
            return nil
        case .last2Days:
            return calendar.date(byAdding: .day, value: -2, to: now)
        case .lastWeek:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .last2Weeks:
            return calendar.date(byAdding: .day, value: -14, to: now)
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .last3Months:
            return calendar.date(byAdding: .month, value: -3, to: now)
        }
    }

    private static func isAfterThreshold(_ meeting: MeetingRecord, threshold: Date?) -> Bool {
        guard let threshold else { return true }
        guard let date = parseDate(meeting.startTime) else { return false }
        return date >= threshold
    }

    static func parseDate(_ raw: String) -> Date? {
        isoParsers.lazy.compactMap { $0.date(from: raw) }.first
            ?? localParsers.lazy.compactMap { $0.date(from: raw) }.first
    }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        return [iso1, iso2]
    }()

    private static let localParsers: [DateFormatter] = {
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
        return [local1, local2]
    }()
}

struct MeetingsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var selectedFilter: MeetingBrowserFilter = .all
    @State private var selectedSort: MeetingBrowserSort = .newestFirst

    private var scopedMeetings: [MeetingRecord] {
        appState.meetingRows
    }

    private var filteredMeetings: [MeetingRecord] {
        MeetingBrowserLogic.filteredMeetings(
            from: scopedMeetings,
            filter: selectedFilter,
            sort: selectedSort
        )
    }

    private var currentFolderName: String {
        guard let folderID = appState.selectedFolderID else { return "All Meetings" }
        return appState.folders.first(where: { $0.id == folderID })?.name ?? "All Meetings"
    }

    private var currentDocumentMeeting: MeetingRecord? {
        guard case let .document(id) = appState.meetingsNavigationState else { return nil }
        if appState.selectedMeetingID == id, let selectedMeeting = appState.selectedMeeting {
            return selectedMeeting
        }
        return controller.meeting(id: id)
    }

    private var activeLiveMeeting: MeetingRecord? {
        controller.activeLiveMeetingRecord()
    }

    var body: some View {
        Group {
            if let meeting = currentDocumentMeeting {
                MeetingDetailView(
                    meeting: meeting,
                    controller: controller,
                    appState: appState,
                    onBack: { controller.showMeetingsHome(folderID: appState.selectedFolderID) }
                )
                .id(meeting.id)
            } else {
                browserView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundBase)
        .sheet(
            isPresented: Binding(
                get: { appState.isMeetingTemplatesManagerPresented },
                set: { appState.isMeetingTemplatesManagerPresented = $0 }
            )
        ) {
            MeetingTemplatesManagerView(
                appState: appState,
                controller: controller,
                onClose: { appState.isMeetingTemplatesManagerPresented = false }
            )
        }
    }

    @ViewBuilder
    private var browserView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                if !appState.upcomingCalendarEvents.isEmpty {
                    comingUpSection
                }

                if appState.isMeetingStarting {
                    MeetingPreparationBanner(
                        status: appState.meetingStartStatus,
                        onCancel: { controller.cancelMeetingPreparation() }
                    )
                }

                if let activeLiveMeeting {
                    activeMeetingBanner(activeLiveMeeting)
                }

                browserHeader

                if filteredMeetings.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: MuesliTheme.spacing12) {
                        ForEach(filteredMeetings) { meeting in
                            MeetingListItemView(
                                record: meeting,
                                isSelected: appState.selectedMeetingID == meeting.id,
                                folders: appState.folders,
                                onSelect: { controller.showMeetingDocument(id: meeting.id) },
                                onMove: { folderID in
                                    controller.moveMeeting(id: meeting.id, toFolder: folderID)
                                },
                                onCreateFolderAndMove: { name in
                                    controller.createFolderAndMoveMeeting(name: name, meetingID: meeting.id)
                                },
                                onDelete: controller.canDeleteMeeting(meeting) ? {
                                    controller.deleteMeeting(id: meeting.id)
                                } : nil
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Coming Up

    private struct UpcomingEventGroup: Identifiable {
        let id: String
        let date: Date
        let dayLabel: String
        let dayNumber: String
        let dayOfWeek: String
        let isToday: Bool
        let events: [UnifiedCalendarEvent]
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    private static let maxUpcomingEvents = 5

    private var groupedUpcomingEvents: [UpcomingEventGroup] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let timedEvents = appState.upcomingCalendarEvents.filter { !$0.isAllDay && !appState.hiddenCalendarEventIDs.contains($0.id) }
        let grouped = Dictionary(grouping: timedEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        let dayFormatter = Self.dayFormatter
        let monthFormatter = Self.monthFormatter
        let weekdayFormatter = Self.weekdayFormatter

        let sortedDates = grouped.keys.sorted()
        var result: [UpcomingEventGroup] = []
        var remaining = Self.maxUpcomingEvents

        for date in sortedDates {
            guard remaining > 0 else { break }
            let sortedEvents = grouped[date]!.sorted { $0.startDate < $1.startDate }
            let limitedEvents = Array(sortedEvents.prefix(remaining))
            remaining -= limitedEvents.count

            let isToday = calendar.isDate(date, inSameDayAs: today)
            let isTomorrow = calendar.date(byAdding: .day, value: 1, to: today).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
            let dayLabel: String
            if isToday {
                dayLabel = "Today"
            } else if isTomorrow {
                dayLabel = "Tomorrow"
            } else {
                dayLabel = monthFormatter.string(from: date)
            }
            result.append(UpcomingEventGroup(
                id: date.description,
                date: date,
                dayLabel: dayLabel,
                dayNumber: dayFormatter.string(from: date),
                dayOfWeek: weekdayFormatter.string(from: date),
                isToday: isToday,
                events: limitedEvents
            ))
        }

        return result
    }

    @ViewBuilder
    private var comingUpSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Coming Up")
                    .font(.custom("Cormorant Garamond", size: 22).weight(.medium))
                    .foregroundStyle(MuesliTheme.textPrimary)

                if appState.isGoogleCalendarAuthenticated {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9))
                            Text("Add Google to macOS Calendar for real-time sync")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(MuesliTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)

            let groups = groupedUpcomingEvents
            let lastGroupId = groups.last?.id
            ForEach(groups) { group in
                HStack(alignment: .top, spacing: 20) {
                    // Date column
                    VStack(alignment: .center, spacing: 2) {
                        Text(group.dayNumber)
                            .font(.system(size: 24, weight: .light, design: .default))
                            .foregroundStyle(group.isToday ? MuesliTheme.accent : MuesliTheme.textPrimary)
                        Text(group.dayLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(group.isToday ? MuesliTheme.accent : MuesliTheme.textSecondary)
                        Text(group.dayOfWeek)
                            .font(.system(size: 10))
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    .frame(width: 60)

                    // Events column
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(group.events) { event in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(group.isToday ? MuesliTheme.accent : MuesliTheme.textSecondary.opacity(0.4))
                                    .frame(width: 3, height: 36)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(MuesliTheme.textPrimary)
                                        .lineLimit(1)

                                    Text(formatTimeRange(event))
                                        .font(.system(size: 11))
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                }

                                Spacer()

                                if let meetingURL = event.meetingURL,
                                   !appState.isMeetingRecording,
                                   !appState.isMeetingStarting {
                                    Button {
                                        controller.joinAndRecord(title: event.title, meetingURL: meetingURL, endDate: event.endDate)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "video.fill")
                                                .font(.system(size: 9))
                                            Text("Join & Record")
                                                .font(.system(size: 10, weight: .medium))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(nsColor: NSColor(red: 0.20, green: 0.72, blue: 0.53, alpha: 1.0)))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    .buttonStyle(.plain)
                                }

                                Menu {
                                    Button("All Meetings") {
                                        controller.createMeetingFromCalendarEvent(event, folderID: nil)
                                    }
                                    Divider()
                                    ForEach(appState.folders) { folder in
                                        Button(folder.name) {
                                            controller.createMeetingFromCalendarEvent(event, folderID: folder.id)
                                        }
                                    }
                                } label: {
                                    Text("Add to folder")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(MuesliTheme.surfacePrimary)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 0.5)
                                        )
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()

                                hideEventButton(event)
                            }
                        }
                    }
                }

                if group.id != lastGroupId {
                    Divider()
                        .foregroundStyle(MuesliTheme.surfaceBorder)
                }
            }
        }
        .padding(20)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func formatTimeRange(_ event: UnifiedCalendarEvent) -> String {
        let f = Self.timeFormatter
        return "\(f.string(from: event.startDate)) – \(f.string(from: event.endDate))"
    }

    private func hideEventButton(_ event: UnifiedCalendarEvent) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                controller.hideCalendarEvent(event.id)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary.opacity(0.6))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("Hide from Coming Up")
    }

    @ViewBuilder
    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing16) {
                    browserHeaderTitle
                    Spacer(minLength: MuesliTheme.spacing16)
                    browserHeaderActions
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    browserHeaderTitle
                    HStack {
                        Spacer(minLength: 0)
                        browserHeaderActions
                    }
                }
            }

            browserHeaderMeta
        }
    }

    @ViewBuilder
    private var browserHeaderTitle: some View {
        Text(currentFolderName)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var browserHeaderMeta: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text("\(filteredMeetings.count) meeting\(filteredMeetings.count == 1 ? "" : "s")")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize()

            Text("\u{2022}")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize()

            Text("Open a meeting to review notes, transcript, and template-driven summaries")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var browserHeaderActions: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Button {
                controller.startQuickNoteMeeting()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quick Note")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(MuesliTheme.backgroundBase)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 8)
                .background(appState.isMeetingRecording || appState.isMeetingStarting ? MuesliTheme.surfacePrimary : MuesliTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .disabled(appState.isMeetingRecording || appState.isMeetingStarting)
            .help("Start a quick meeting note")
            .fixedSize()

            sortButton
            dateFilterButton

            Button {
                controller.showMeetingTemplatesManager()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                    Text("Manage Templates")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func activeMeetingBanner(_ meeting: MeetingRecord) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(activeMeetingStatusColor(for: meeting))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    Text(activeMeetingStatusText(for: meeting))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Button {
                controller.showMeetingDocument(id: meeting.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open Notes")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)

            if meeting.status == .recording {
                Button {
                    controller.toggleMeetingRecordingPause()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: appState.isMeetingRecordingPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(appState.isMeetingRecordingPaused ? "Resume" : "Pause")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(appState.isMeetingRecordingPaused ? MuesliTheme.backgroundBase : MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 8)
                    .background(appState.isMeetingRecordingPaused ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(appState.isMeetingRecordingPaused ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!appState.isMeetingRecording)

                Button {
                    controller.stopMeetingRecording()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 8)
                    .background(MuesliTheme.recording)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(!appState.isMeetingRecording)
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func activeMeetingStatusText(for meeting: MeetingRecord) -> String {
        guard meeting.status == .recording else { return "Finalizing notes" }
        return appState.isMeetingRecordingPaused ? "Recording paused" : "Recording now"
    }

    private func activeMeetingStatusColor(for meeting: MeetingRecord) -> Color {
        guard meeting.status == .recording else { return MuesliTheme.accent }
        return appState.isMeetingRecordingPaused ? MuesliTheme.transcribing : MuesliTheme.recording
    }

    @ViewBuilder
    private var sortButton: some View {
        Menu {
            ForEach([MeetingBrowserSort.newestFirst, .oldestFirst], id: \.self) { option in
                Button {
                    selectedSort = option
                } label: {
                    HStack {
                        Text(option.label)
                        if selectedSort == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                Text(selectedSort.label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(selectedSort != .newestFirst ? MuesliTheme.accent : MuesliTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selectedSort != .newestFirst ? MuesliTheme.accent.opacity(0.12) : MuesliTheme.surfacePrimary.opacity(0.5))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var dateFilterButton: some View {
        Menu {
            ForEach(availableFilters, id: \.self) { filter in
                Button {
                    selectedFilter = filter
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

    private var availableFilters: [MeetingBrowserFilter] {
        MeetingBrowserLogic.availableFilters(for: scopedMeetings)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Image(systemName: appState.selectedFolderID == nil ? "person.2.wave.2" : "folder")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(MuesliTheme.textTertiary)

            Text(appState.selectedFolderID == nil ? "No meetings yet" : "No meetings in this folder")
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textSecondary)

            Text(
                appState.selectedFolderID == nil
                    ? "Start a recording from the menu bar to create your first meeting note."
                    : "Choose another folder or move a meeting here from the browser."
            )
            .font(MuesliTheme.callout())
            .foregroundStyle(MuesliTheme.textTertiary)
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(MuesliTheme.spacing24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerXL))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerXL)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }
}

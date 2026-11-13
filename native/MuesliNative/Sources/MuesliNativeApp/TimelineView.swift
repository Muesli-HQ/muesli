import SwiftUI
import MuesliCore
import AIElementsSwift
import AVFoundation

struct TimelineView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var playingVidshotID: String?
    @State private var contentFilter = "All activity"
    @State private var search = ""
    @State private var searchRows: [TimelineEntry] = []
    @State private var searchLimit = 50
    @State private var searchHasMore = false
    @State private var searchError: String?
    @State private var completedSearch: TimelineSearchRequest?
    @State private var settledSearch: TimelineSearchRequest?
    private var searchPending: Bool { isSearching && settledSearch != searchRequest }
    private var keepsSearchRows: Bool { searchRequest.canDisplay(completedSearch) }
    private var isSearching: Bool { !search.isEmpty || contentFilter != "All activity" }
    private var searchScope: String {
        [search, contentFilter, appState.timelineFromDate ?? "", appState.timelineToDate ?? "",
         String(describing: appState.timelineOriginFilter), String(describing: appState.timelineApplicationFilter),
         String(appState.timelineHistoryRevision)].joined(separator: "|")
    }
    private var searchRequest: TimelineSearchRequest { .init(scope: searchScope, limit: searchLimit) }
    private struct DayGroup: Identifiable {
        let id: Date
        let header: String
        let entries: [TimelineEntry]
    }

    private var groupedEntries: [DayGroup] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var entriesByDay: [Date: [TimelineEntry]] = [:]
        for entry in (isSearching ? (keepsSearchRows ? searchRows : []) : appState.timelineRows) {
            let date = MeetingBrowserLogic.parseDate(entry.timestamp) ?? .distantPast
            entriesByDay[calendar.startOfDay(for: date), default: []].append(entry)
        }
        return entriesByDay.keys.sorted(by: >).map { day in
            let header: String
            if day == today {
                header = "TODAY"
            } else if day == yesterday {
                header = "YESTERDAY"
            } else {
                header = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()
            }
            return DayGroup(id: day, header: header, entries: (entriesByDay[day] ?? []).sorted {
                (MeetingBrowserLogic.parseDate($0.timestamp) ?? .distantPast) > (MeetingBrowserLogic.parseDate($1.timestamp) ?? .distantPast)
            })
        }
    }

    var body: some View {
        ScrollView {
        LazyVStack(spacing: 0) {
            DashboardPageHeader(
                title: "Timeline",
                appState: appState,
                controller: controller
            )
                .padding(.horizontal, MuesliTheme.pageInset)
                .padding(.top, MuesliTheme.pageTop)

            StatsHeaderView(
                dictationStats: appState.dictationStats,
                meetingStats: appState.meetingStats,
                showsMeetingStat: true,
                tracksInsightsFeatureTour: true,
                onSelect: { controller.openInsights(section: $0) }
            )

            DictationFormattingSetupCard(appState: appState, controller: controller)

            HStack {
                TextField("Search activity…", text: $search).textFieldStyle(.roundedBorder)
                Picker("Activity", selection: $contentFilter) {
                    ForEach(["All activity", "Meetings", "Dictations", "Cotypist", "Quill", "Vidshots"], id: \.self) { Text($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Activity")
                .frame(width: 180)
            }.padding(.horizontal, MuesliTheme.pageInset).padding(.bottom, 12)

            filterBar
                .padding(.horizontal, MuesliTheme.pageInset)
                .padding(.bottom, MuesliTheme.spacing12)

            if searchPending && !keepsSearchRows {
                ProgressView("Searching…").font(MuesliTheme.body()).padding()
            } else if groupedEntries.isEmpty && searchError == nil {
                emptyState
            }
            timelineEntries
            if let searchError { Text(searchError).foregroundStyle(MuesliTheme.textSecondary) }
        }
        }
        .onChange(of: search) { _, _ in searchLimit = 50 }
        .onChange(of: contentFilter) { _, _ in searchLimit = 50 }
        .task(id: searchRequest) {
            guard isSearching else { searchRows = []; searchError = nil; completedSearch = nil; settledSearch = nil; return }
            let query = search, activity = contentFilter, limit = searchLimit
            let revision = appState.timelineHistoryRevision
            let request = searchRequest
            searchError = nil
            do {
                try await Task.sleep(for: .milliseconds(150))
                let rows = try await controller.searchTimeline(text: query, activity: activity, limit: limit + 1)
                try Task.checkCancellation()
                guard revision == appState.timelineHistoryRevision, request == searchRequest else { return }
                completedSearch = request
                settledSearch = request
                searchRows = Array(rows.prefix(limit)); searchHasMore = rows.count > limit; searchError = nil
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, request == searchRequest else { return }
                settledSearch = request
                searchError = "Search unavailable. Try again."
            }
        }
        .scrollPosition(id: Binding(
            get: { appState.timelineScrollAnchor },
            set: { appState.timelineScrollAnchor = $0 }
        ), anchor: .top)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MuesliTheme.spacing12) {
                    originControls
                    Spacer(minLength: 12)
                    privacyControl
                    dateFilterMenu
                }
                VStack(alignment: .leading, spacing: 10) {
                    originControls
                    HStack {
                        Spacer(minLength: 0)
                        privacyControl
                        dateFilterMenu
                    }
                }
            }
            if appState.privateMode {
                Text("Of new activity on this Mac, only meetings and their recordings are saved. Time Turner and Cotypist are paused.")
                    .font(MuesliTheme.font(size: 12))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var originControls: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            if appState.showsDeviceOriginFilter {
                RecordOriginPicker(selection: Binding(
                    get: { appState.timelineOriginFilter },
                    set: { controller.filterTimeline(origin: $0) }
                ))
            }
            if !appState.timelineTargetApplications.isEmpty || appState.timelineApplicationFilter != nil {
                TargetApplicationFilterMenu(
                    applications: appState.timelineTargetApplications,
                    selection: appState.timelineApplicationFilter,
                    onSelect: { controller.filterTimeline(application: $0) }
                )
                .featureTourTarget(.timelineApplications)
            }
        }
    }

    private var privacyControl: some View {
        HStack(spacing: 6) {
            Label("Privacy", systemImage: "eye.slash")
                .font(MuesliTheme.font(size: 12, weight: .medium))
            MuesliSettingControl(controller: controller, id: "private_mode")
                .environment(\.muesliSettingDefinitions, [controller.privateModeDefinition()])
        }
        .controlSize(.small)
        .fixedSize()
        .help("Other new activity stays temporary; switching clears temporary chats. History from other devices still syncs. Cloud providers still process requests. Anonymous events follow your analytics preference.")
    }

    private var dateFilterMenu: some View {
        Menu {
            ForEach(HistoryDateFilter.allCases, id: \.self) { filter in
                Button {
                    controller.filterTimeline(dateFilter: filter)
                } label: {
                    HStack {
                        Text(filter.label)
                        if appState.timelineDateFilter == filter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                if appState.timelineDateFilter != .all {
                    Text(appState.timelineDateFilter.label)
                        .font(MuesliTheme.font(size: 11))
                }
            }
            .foregroundStyle(
                appState.timelineDateFilter == .all
                    ? MuesliTheme.textTertiary
                    : MuesliTheme.accentText
            )
            .padding(.horizontal, appState.timelineDateFilter == .all ? 0 : 8)
            .padding(.vertical, 3)
            .background(
                appState.timelineDateFilter == .all
                    ? Color.clear
                    : MuesliTheme.accent.opacity(0.12)
            )
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Spacer()
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text(emptyStateTitle)
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textSecondary)
            Text("Try another search, source, app, or time range")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyStateTitle: String {
        if let application = appState.timelineApplicationFilter {
            return "No activity for \(application.name)"
        }
        switch appState.timelineOriginFilter {
        case .all: return "No activity yet"
        case .thisMac: return "No activity from this Mac"
        case .fromIPhone: return "No activity from iPhone"
        }
    }

    private var timelineEntries: some View {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                ForEach(groupedEntries) { group in
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text(group.header)
                            .font(MuesliTheme.font(size: 12, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(.leading, MuesliTheme.spacing4)

                        VStack(spacing: 0) {
                            ForEach(group.entries) { entry in
                                timelineRow(entry).id(entry.id)
                            }
                        }
                        .scrollTargetLayout()

                    }
                }

                if isSearching && keepsSearchRows && searchHasMore {
                    Button(searchPending ? "Loading more…" : "Load more results") { searchLimit += 50 }
                        .disabled(searchPending)
                } else if !isSearching && appState.hasMoreTimelineEntries {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { controller.loadMoreTimelineEntries() }
                }
            }
            .padding(.horizontal, MuesliTheme.pageInset)
            .padding(.bottom, MuesliTheme.spacing24)
    }

    @ViewBuilder
    private func timelineRow(_ entry: TimelineEntry) -> some View {
        switch entry {
        case .dictation(let record):
            DictationRowView(
                record: record,
                timeOnly: Self.formatTime(record.timestamp),
                onCopy: { controller.copyToClipboard(record.rawText) },
                onCopyTrace: record.computerUseTrace == nil ? nil : {
                    controller.copyToClipboard(ComputerUseTraceFormatter.debugText(for: record))
                },
                onDelete: { controller.deleteDictation(id: record.id) },
                recordingController: controller
            )
        case .meeting(let record):
            TimelineMeetingRow(record: record) {
                controller.showTimelineMeetingDocument(id: record.id)
            }
        case .quill(let record):
            TimelineQuillRow(record: record, loadConversation: { await controller.loadQuillConversation(id: record.id) }, onDelete: { controller.deleteQuillConversation(record) })
        case .cotypist(let record):
            TimelineCotypistRow(
                record: record,
                onCopy: { controller.copyToClipboard(record.acceptances.map { $0.contextBefore + $0.text }.joined(separator: "\n")) },
                onDelete: { controller.deleteCotypistSession(id: record.id) }
            )
        case .vidshot(let record):
            TimelineVidshotRow(record: record, store: controller.feedbackCapture.store,
                revision: appState.timelineHistoryRevision, playingID: $playingVidshotID,
                onSelect: {
                    appState.vidshotDetailReturnsToTimeline = true
                    appState.selectedVidshotID = record.id
                    appState.selectedTab = .vidshots
                },
                onCopy: { await controller.feedbackCapture.copy(id: record.id) },
                onDelete: { try await controller.feedbackCapture.delete(id: record.id) })
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()

    fileprivate static func formatTime(_ raw: String) -> String {
        guard let date = MeetingBrowserLogic.parseDate(raw) else {
            return MeetingBrowserLogic.formatStartTime(raw)
        }
        return timeFormatter.string(from: date)
    }
}

struct VidshotsPage: View {
    let appState: AppState
    let controller: MuesliController
    @State private var playingID: String?

    var body: some View {
        let records = controller.feedbackCapture.records
        if let id = appState.selectedVidshotID {
            FeedbackCaptureView(controller: controller.feedbackCapture, selectedID: id,
                onBack: {
                    appState.selectedVidshotID = nil
                    if appState.vidshotDetailReturnsToTimeline {
                        appState.vidshotDetailReturnsToTimeline = false
                        controller.showTimelineHome()
                    }
                }, backLabel: appState.vidshotDetailReturnsToTimeline ? "Timeline" : "Vidshots")
                .id(id)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: MuesliTheme.spacing16) {
                            vidshotsTitle
                            Spacer(minLength: MuesliTheme.spacing16)
                            recordingButton
                        }
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                            vidshotsTitle
                            recordingButton
                        }
                    }
                    .padding(.horizontal, MuesliTheme.pageInset)
                    if records.isEmpty {
                        ContentUnavailableView {
                            Label { Text("No Vidshots yet") } icon: { VidshotIcon().frame(width: 36, height: 36) }
                        } description: {
                            Text("Record a window or screen region to create a Vidshot.")
                        }
                        .frame(maxWidth: .infinity, minHeight: 250)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                                if index == 0 || !Calendar.current.isDate(
                                    Date(timeIntervalSince1970: record.createdAt),
                                    inSameDayAs: Date(timeIntervalSince1970: records[index - 1].createdAt)) {
                                    Text(Date(timeIntervalSince1970: record.createdAt).formatted(date: .abbreviated, time: .omitted))
                                        .font(MuesliTheme.font(size: 12, weight: .semibold))
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, MuesliTheme.pageInset)
                                        .padding(.top, MuesliTheme.spacing16)
                                }
                                TimelineVidshotRow(record: record, store: controller.feedbackCapture.store,
                                    revision: appState.timelineHistoryRevision, playingID: $playingID,
                                    onSelect: {
                                        appState.vidshotDetailReturnsToTimeline = false
                                        appState.selectedVidshotID = record.id
                                    },
                                    onCopy: { await controller.feedbackCapture.copy(id: record.id) },
                                    onDelete: { try await controller.feedbackCapture.delete(id: record.id) })
                            }
                        }
                    }
                }
                .padding(.top, MuesliTheme.spacing20)
            }
            .task { await controller.feedbackCapture.reload() }
        }
    }

    private var vidshotsTitle: some View {
        Text("Vidshots")
            .font(MuesliTheme.font(size: 26, weight: .bold))
            .foregroundStyle(MuesliTheme.textPrimary)
    }

    private var recordingButton: some View {
        let isRecording = controller.feedbackCapture.ownsMicrophone
        return Button {
            controller.toggleFeedbackCapture()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "stop.fill" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(isRecording ? "Finish Vidshot" : "Start Vidshot")
                    .font(MuesliTheme.font(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.muesli(.primary))
        .disabled(!controller.config.enableFeedbackCapture && !isRecording)
        .help(!controller.config.enableFeedbackCapture && !isRecording
            ? "Enable Vidshot in Settings to start recording"
            : (isRecording ? "Finish recording" : "Start a Vidshot"))
        .accessibilityIdentifier("vidshots.record")
        .fixedSize()
    }
}

struct TimelineVidshotRow: View {
    let record: FeedbackCaptureRecord
    let store: FeedbackCaptureStore?
    let revision: UInt64
    @Binding var playingID: String?
    let onSelect: () -> Void
    let onCopy: () async -> FeedbackCaptureDelivery.Result
    let onDelete: () async throws -> Void
    private enum RowAction: Hashable { case copy, delete }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedAction: RowAction?
    @State private var isHovered = false
    @State private var copyConfirmation: UUID?
    @State private var copyError = false
    @State private var transcript = ""
    @State private var appName = ""
    @State private var preview: NSImage?
    @State private var videoURL: URL?
    @State private var player: AVPlayer?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing20) {
            Button(action: onSelect) {
                Text(TimelineView.formatTime(Date(timeIntervalSince1970: record.createdAt).ISO8601Format()))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 80, alignment: .leading).padding(.top, 2)
            }.buttonStyle(.plain)
                .accessibilityLabel("Open Vidshot recorded \(Date(timeIntervalSince1970: record.createdAt).formatted())")
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Button(action: onSelect) {
                        HStack(spacing: MuesliTheme.spacing8) {
                            VidshotIcon().frame(width: 14, height: 14).foregroundStyle(MuesliTheme.accentText)
                            Text("Vidshot").font(MuesliTheme.font(size: 14, weight: .semibold)).foregroundStyle(MuesliTheme.textPrimary)
                            if !appName.isEmpty {
                                Text(appName).font(MuesliTheme.callout()).foregroundStyle(MuesliTheme.textSecondary).lineLimit(1)
                            }
                            Text(String(format: "%d:%02d", record.durationMs / 60_000, (record.durationMs / 1000) % 60))
                                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                        }
                    }.buttonStyle(.plain).accessibilityHint("Open Vidshot")
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        if copyConfirmation != nil {
                            Text("Copied").font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.successText).padding(.trailing, 4)
                        }
                        TimelineRowActionButton(
                            symbol: copyConfirmation == nil ? "doc.on.doc" : "checkmark",
                            label: "Copy Vidshot summary and transcript",
                            help: copyConfirmation == nil ? "Copy summary and transcript; image may paste in supported apps" : "Vidshot summary copied",
                            color: copyConfirmation == nil ? MuesliTheme.textTertiary : MuesliTheme.successText
                        ) {
                            Task {
                                switch await onCopy() {
                                case .copied:
                                    copyConfirmation = UUID()
                                    AccessibilityNotification.Announcement("Copied").post()
                                case .failed: copyError = true
                                case .skipped: break
                                }
                            }
                        }
                        .disabled(record.state == .recording || record.state == .processing)
                        .focused($focusedAction, equals: .copy)
                        TimelineRowActionButton(symbol: "trash", label: "Delete Vidshot", help: "Delete Vidshot",
                                                color: MuesliTheme.destructiveText) { confirmDelete = true }
                            .disabled(deleting || record.state == .recording || record.state == .processing)
                            .focused($focusedAction, equals: .delete)
                    }
                    .opacity(isHovered || focusedAction != nil || copyConfirmation != nil ? 1 : 0)
                }
                if let player {
                    MeetingVideoPlayerView(player: player)
                        .frame(maxWidth: 480)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                HStack(alignment: .top, spacing: 12) {
                    if player == nil {
                        ZStack {
                            Button(action: onSelect) {
                                Group {
                                    if let preview { Image(nsImage: preview).resizable().scaledToFill() }
                                    else { Image(systemName: "video").foregroundStyle(MuesliTheme.textTertiary) }
                                }
                                .frame(width: 120, height: 68).background(MuesliTheme.backgroundRaised)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open Vidshot")
                            if let videoURL {
                                Button {
                                    playingID = record.id
                                    let newPlayer = AVPlayer(url: videoURL)
                                    player = newPlayer
                                    newPlayer.play()
                                } label: {
                                    Image(systemName: "play.circle.fill").font(.system(size: 27))
                                        .foregroundStyle(.white).shadow(radius: 3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Play Vidshot inline")
                                .help("Play inline")
                                .zIndex(1)
                            }
                        }
                    }
                    Button(action: onSelect) {
                        Text(transcript.isEmpty ? (record.state == .recording || record.state == .processing ? "Processing…" : "No transcript available") : transcript)
                            .font(MuesliTheme.callout()).foregroundStyle(MuesliTheme.textSecondary)
                            .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Open Vidshot")
                }
            }
        }
        .padding(.horizontal, MuesliTheme.spacing20).padding(.vertical, MuesliTheme.spacing16)
        .background(isHovered ? MuesliTheme.backgroundHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
                .padding(.horizontal, MuesliTheme.spacing20)
                .allowsHitTesting(false)
        }
        .background {
            Button(action: onSelect) {
                Rectangle().fill(Color.black.opacity(0.001)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .onHover { hovering in
            withAnimation(MuesliMotion.animation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .task(id: copyConfirmation) {
            guard copyConfirmation != nil else { return }
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
            copyConfirmation = nil
        }
        .alert("Couldn’t copy Vidshot", isPresented: $copyError) {
            Button("OK", role: .cancel) {}
        } message: { Text("The Vidshot context could not be copied.") }
        .confirmationDialog("Delete this Vidshot and all its files?", isPresented: $confirmDelete) {
            Button("Delete Vidshot", role: .destructive) {
                player?.pause(); player = nil
                if playingID == record.id { playingID = nil }
                deleting = true
                Task {
                    do { try await onDelete() }
                    catch { deleteError = error.localizedDescription }
                    deleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The video, narration, transcript, frames, and capture data will be deleted.") }
        .alert("Couldn’t delete Vidshot", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
        .onChange(of: playingID) { _, id in
            if id != record.id { player?.pause(); player = nil }
        }
        .onDisappear {
            player?.pause(); player = nil
            if playingID == record.id { playingID = nil }
        }
        .task(id: "\(record.id):\(revision)") {
            guard let store else { return }
            let id = record.id
            let result = await Task.detached(priority: .utility) { () -> (String, String, URL?, Data?) in
                guard let manifest = try? store.manifest(id: id) else { return ("", "", nil, nil) }
                let name = manifest.target.appName.trimmingCharacters(in: .whitespacesAndNewlines)
                let nameLabel = ["screen region", "screen capture", "screen"].contains(name.lowercased()) ? "" : name
                let text = manifest.transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let video = manifest.video.flatMap { path -> URL? in
                    guard let url = try? store.mediaURL(id: id, path: path),
                          FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return url
                }
                if let video {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 480, height: 270)
                    if let image = try? generator.copyCGImage(at: .zero, actualTime: nil),
                       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        return (text, nameLabel, video, data)
                    }
                }
                if let frame = manifest.keyframes.first?.file, let url = try? store.mediaURL(id: id, path: frame),
                   let data = try? Data(contentsOf: url) { return (text, nameLabel, video, data) }
                return (text, nameLabel, video, nil)
            }.value
            guard !Task.isCancelled else { return }
            transcript = result.0; appName = result.1; videoURL = result.2; preview = result.3.flatMap(NSImage.init(data:))
        }
    }
}

private struct TimelineMeetingRow: View {
    let record: MeetingRecord
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing20) {
            Text(TimelineView.formatTime(record.startTime))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 80, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accentText)
                        .accessibilityLabel("Meeting")

                    Text(record.title)
                        .font(MuesliTheme.font(size: 14, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)

                    Text(record.status.displayLabel)
                        .font(MuesliTheme.font(size: 10, weight: .semibold))
                        .foregroundStyle(record.status.displayTextColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(record.status.displayColor.opacity(0.12))
                        .clipShape(Capsule())

                    if let label = SyncOriginDisplay.badgeLabel(forMeetingSource: record.source) {
                        SyncOriginBadge(label: label)
                    } else {
                        SyncOriginBadge(label: "Mac", help: "Recorded on this Mac")
                    }

                    Spacer(minLength: 0)

                    Text(Self.formatDuration(record.durationSeconds))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Text(previewText)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing16)
        .background(isHovered ? MuesliTheme.backgroundHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
                .padding(.horizontal, MuesliTheme.spacing20)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(MuesliMotion.animation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .muesliRowActivation(action: onSelect)
        .accessibilityHint("Open meeting")
    }

    private var previewText: String {
        let content: String
        if !record.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           record.status != .completed {
            content = record.manualNotes
        } else if !record.formattedNotes.isEmpty {
            content = record.formattedNotes
        } else {
            content = record.rawTranscript
        }
        let preview = MeetingPreviewText.snippet(from: content)
        return preview.isEmpty ? "No transcript or notes yet" : preview
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let minutes = rounded / 60
            let remainingSeconds = rounded % 60
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }
        return "\(rounded)s"
    }

}

/// A run of Cotypist typeahead in one app, styled like a dictation row: each accepted suggestion
/// in the sentence it completed, with the app's icon on the right.
private struct TimelineCotypistRow: View {
    private enum RowAction: Hashable {
        case copy, delete
    }

    let record: CotypistSessionRecord
    let onCopy: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    /// Actions appear on hover or keyboard focus, so a focused action is never invisible.
    @FocusState private var focusedAction: RowAction?

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing20) {
            Text(TimelineView.formatTime(record.timestamp))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 80, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                    badge
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, acceptance in
                            sentence(acceptance)
                        }
                        if hidden > 0 {
                            Text("+\(hidden) more")
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !record.targetAppName.isEmpty {
                TargetApplicationIconView(appName: record.targetAppName, bundleIdentifier: record.targetAppBundleID)
            }

            HStack(spacing: 2) {
                TimelineRowActionButton(symbol: "doc.on.doc", label: "Copy Cotypist sentences",
                                        help: "Copy the sentences with the accepted text", color: MuesliTheme.textTertiary,
                                        action: onCopy)
                    .focused($focusedAction, equals: .copy)
                TimelineRowActionButton(symbol: "trash", label: "Remove from timeline",
                                        help: "Remove from timeline", color: MuesliTheme.destructiveText,
                                        action: onDelete)
                    .focused($focusedAction, equals: .delete)
            }
            .opacity(isHovered || focusedAction != nil ? 1 : 0)
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing16)
        .background(isHovered ? MuesliTheme.backgroundHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
                .padding(.horizontal, MuesliTheme.spacing20)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(MuesliMotion.animation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
    }

    private static let maxShown = 3

    private var shown: ArraySlice<CotypistAcceptance> { record.acceptances.prefix(Self.maxShown) }
    private var hidden: Int { max(record.acceptances.count - Self.maxShown, 0) }

    private var badge: some View {
        HStack(spacing: 3) {
            Image(systemName: "text.cursor")
                .font(.system(size: 9, weight: .bold))
            Text("COTYPIST")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(MuesliTheme.accentText)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(MuesliTheme.accentSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// What the user had written, dimmed, then the accepted suggestion in full colour.
    private func sentence(_ acceptance: CotypistAcceptance) -> some View {
        (Text(acceptance.contextBefore).foregroundStyle(MuesliTheme.textTertiary)
            + Text(acceptance.text).foregroundStyle(MuesliTheme.textPrimary).fontWeight(.semibold))
            .font(MuesliTheme.reading())
            .lineLimit(2)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// One durable conversation; expansion reveals every exchange, not the bounded model context.
/// Reload expanded history after new turns or late question transcription.
struct QuillTimelineLoadKey: Equatable {
    let expanded: Bool
    let turnCount: Int
    let preview: [QuillHistoryTurn]
}

private struct TimelineQuillRow: View {
    let record: QuillConversationRecord
    let loadConversation: () async -> QuillConversationRecord?
    let onDelete: () -> Void
    @State private var expanded = false
    @State private var copiedTurn: UUID?
    @State private var fullConversation: QuillConversationRecord?
    @State private var loadFailed = false

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing20) {
            Text(TimelineView.formatTime(record.timestamp))
                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline) {
                        HStack(spacing: 3) {
                            Image(nsImage: QuillIcon.image())
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text("QUILL")
                                .font(MuesliTheme.caption())
                        }
                        .foregroundStyle(MuesliTheme.accentText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        Text(record.turns.first?.question ?? "Quill conversation")
                            .font(MuesliTheme.body()).lineLimit(2)
                        Spacer()
                        Text("\(record.turnCount) \(record.turnCount == 1 ? "turn" : "turns")")
                            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textTertiary)
                        AIIcon(expanded ? .chevronUp : .chevronDown)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse Quill conversation" : "Expand Quill conversation")
                if expanded {
                    if fullConversation == nil {
                        Text(loadFailed ? "Conversation unavailable" : "Loading conversation…")
                            .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary)
                    }
                    ForEach(fullConversation?.turns ?? []) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(turn.question ?? "Question transcript unavailable")
                                .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary)
                                .textSelection(.enabled)
                            AIResponse(turn.answer).font(MuesliTheme.body())
                            Button {
                                NSPasteboard.general.clearContents()
                                if NSPasteboard.general.setString(turn.answer, forType: .string) { copiedTurn = turn.id }
                            } label: {
                                HStack(spacing: 4) {
                                    AIIcon(copiedTurn == turn.id ? .check : .copy)
                                    Text(copiedTurn == turn.id ? "Copied" : "Copy answer")
                                }.font(MuesliTheme.caption())
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 8)
                        if turn.id != fullConversation?.turns.last?.id { Divider() }
                    }
                } else if let last = record.turns.last {
                    Text(last.answer).font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDelete) { AIIcon(.trash) }
                .buttonStyle(.plain).help("Delete Quill conversation").accessibilityLabel("Delete Quill conversation")
        }
        .padding(.horizontal, MuesliTheme.spacing20).padding(.vertical, MuesliTheme.spacing16)
        .task(id: QuillTimelineLoadKey(expanded: expanded, turnCount: record.turnCount, preview: record.turns)) {
            guard expanded else { fullConversation = nil; return }
            loadFailed = false
            let loaded = await loadConversation()
            guard !Task.isCancelled else { return }
            fullConversation = loaded
            loadFailed = loaded == nil
        }
        .aiElementsTheme(.init(surface: MuesliTheme.backgroundRaised, border: MuesliTheme.surfaceBorder,
            accent: MuesliTheme.accent, muted: MuesliTheme.textSecondary,
            textFont: { MuesliTheme.font(size: $0, weight: $1) },
            heading: MuesliTheme.title3(), subheading: MuesliTheme.headline()))
        .overlay(alignment: .bottom) { Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1) }
    }
}

/// Pagination may reuse visible rows only while their filters and source revision match.
struct TimelineSearchRequest: Equatable {
    let scope: String
    let limit: Int

    func canDisplay(_ completed: Self?) -> Bool {
        guard let completed else { return false }
        return scope == completed.scope && limit >= completed.limit
    }
}

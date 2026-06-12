import SwiftUI
import MuesliCore

private enum SearchTab: String, CaseIterable {
    case dictations = "Dictations"
    case meetings = "Meetings"
}

struct SearchResultsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var selectedTab: SearchTab = .dictations

    private var totalCount: Int {
        appState.searchResultDictations.count + appState.searchResultMeetings.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().foregroundStyle(MuesliTheme.surfaceBorder)

            if totalCount == 0 {
                emptyState
            } else {
                tabContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header with Tabs

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 0) {
            tabButton(.dictations, count: appState.searchResultDictations.count)
            tabButton(.meetings, count: appState.searchResultMeetings.count)
            Spacer()
            Button {
                controller.clearSearch()
            } label: {
                Text("Clear")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
    }

    @ViewBuilder
    private func tabButton(_ tab: SearchTab, count: Int) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            HStack(spacing: 6) {
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textTertiary)
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? MuesliTheme.accentSubtle : MuesliTheme.backgroundRaised)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? MuesliTheme.backgroundHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .dictations:
            if appState.searchResultDictations.isEmpty {
                noResultsForTab("dictations")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.searchResultDictations) { record in
                            SearchDictationRow(
                                record: record,
                                query: appState.searchQuery,
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(record.rawText, forType: .string)
                                },
                                onCopyTrace: record.computerUseTrace == nil ? nil : {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        ComputerUseTraceFormatter.debugText(for: record),
                                        forType: .string
                                    )
                                }
                            )
                        }
                    }
                    .padding(.vertical, MuesliTheme.spacing8)
                }
            }
        case .meetings:
            if appState.searchResultMeetings.isEmpty {
                noResultsForTab("meetings")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.searchResultMeetings) { record in
                            SearchMeetingRow(record: record, query: appState.searchQuery) {
                                controller.showMeetingDocument(id: record.id)
                            }
                        }
                    }
                    .padding(.vertical, MuesliTheme.spacing8)
                }
            }
        }
    }

    // MARK: - Empty States

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No results for \"\(appState.searchQuery)\"")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func noResultsForTab(_ name: String) -> some View {
        VStack(spacing: MuesliTheme.spacing8) {
            Text("No matching \(name)")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dictation Row

private struct SearchDictationRow: View {
    let record: DictationRecord
    let query: String
    let onCopy: () -> Void
    var onCopyTrace: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatTime(record.timestamp))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                snippetText(from: record.rawText, highlighting: query)
                    .font(MuesliTheme.callout())
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                if record.computerUseTrace != nil, let onCopyTrace {
                    Button(action: onCopyTrace) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.system(size: 12))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy CUA trace")
                }

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
        .background(isHovered ? MuesliTheme.backgroundHover : Color.clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .onTapGesture(perform: onCopy)
    }

    private func formatTime(_ raw: String) -> String {
        StoredTimestampFormatting.displayDateTime(raw)
    }
}

// MARK: - Meeting Row

private struct SearchMeetingRow: View {
    let record: MeetingRecord
    let query: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
            HStack(spacing: MuesliTheme.spacing8) {
                Text(formatTime(record.startTime))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text("\u{2022}")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(formatDuration(record.durationSeconds))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            let matchField = bestMatchField()
            if !matchField.isEmpty {
                snippetText(from: matchField, highlighting: query)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
        .background(isHovered ? MuesliTheme.backgroundHover : Color.clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .onTapGesture(perform: onSelect)
    }

    private func bestMatchField() -> String {
        let q = query.lowercased()
        if record.title.lowercased().contains(q) {
            return MeetingPreviewText.plainText(
                from: record.formattedNotes.isEmpty ? record.rawTranscript : record.formattedNotes
            )
        }
        if record.formattedNotes.lowercased().contains(q) {
            return MeetingPreviewText.plainText(from: record.formattedNotes)
        }
        if record.rawTranscript.lowercased().contains(q) {
            return MeetingPreviewText.plainText(from: record.rawTranscript)
        }
        return ""
    }

    private func formatTime(_ raw: String) -> String {
        StoredTimestampFormatting.displayDateTime(raw)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded < 60 { return "\(rounded)s" }
        let m = rounded / 60
        let s = rounded % 60
        if m < 60 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        let h = m / 60
        let rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }
}

// MARK: - Snippet Highlighting

private func snippetText(from text: String, highlighting query: String) -> Text {
    guard !query.isEmpty else { return Text(text) }

    guard let matchRange = text.range(of: query, options: .caseInsensitive) else {
        let truncated = text.count > 120 ? String(text.prefix(120)) + "..." : text
        return Text(truncated).foregroundStyle(MuesliTheme.textSecondary)
    }

    let matchStart = text.distance(from: text.startIndex, to: matchRange.lowerBound)
    let contextChars = 60
    let snippetStart = max(0, matchStart - contextChars)
    let snippetStartIndex = text.index(text.startIndex, offsetBy: snippetStart)
    let matchEnd = text.distance(from: text.startIndex, to: matchRange.upperBound)
    let snippetEnd = min(text.count, matchEnd + contextChars)
    let snippetEndIndex = text.index(text.startIndex, offsetBy: snippetEnd)
    let snippet = String(text[snippetStartIndex..<snippetEndIndex])

    let prefix = snippetStart > 0 ? "..." : ""
    let suffix = snippetEnd < text.count ? "..." : ""

    guard let localRange = snippet.range(of: query, options: .caseInsensitive) else {
        return Text(prefix + snippet + suffix).foregroundStyle(MuesliTheme.textSecondary)
    }

    let before = String(snippet[snippet.startIndex..<localRange.lowerBound])
    let match = String(snippet[localRange])
    let after = String(snippet[localRange.upperBound..<snippet.endIndex])

    return Text(prefix + before).foregroundStyle(MuesliTheme.textSecondary)
        + Text(match).bold().foregroundStyle(MuesliTheme.accent)
        + Text(after + suffix).foregroundStyle(MuesliTheme.textSecondary)
}

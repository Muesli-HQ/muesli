import SwiftUI
import MuesliCore
import AIElementsSwift

struct MeetingChatDocumentTarget {
    let citation: MeetingChatCitation
    let sessionID: UUID
    var showsTranscript: Bool { citation.kind == .transcript }
    func locate(in text: String) -> NSRange? {
        let ns = text as NSString; let range = citation.range.nsRange
        if range.location >= 0, range.length >= 0, range.location <= ns.length, range.length <= ns.length - range.location,
           ns.substring(with: range) == citation.excerpt { return range }
        let found = ns.range(of: citation.excerpt)
        return found.location == NSNotFound ? nil : found
    }
    static func transcriptMessageID(in text: String, range: NSRange) -> Int? {
        guard range.location >= 0, range.location < (text as NSString).length else { return nil }
        var nextID = 0
        var result: Int?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, lineRange, _, _ in
            guard let line, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let original = NSRange(lineRange, in: text)
            if range.location >= original.location && range.location < original.location + original.length { result = nextID }
            nextID += 1
        }
        return result
    }
}

struct MeetingChatCitationView: View {
    let citation: MeetingChatCitation
    let coordinator: MeetingChatCoordinator
    let onOpen: () -> Void
    @State private var checked = false
    @State private var available = false
    @State private var changed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(citation.kind.label) } icon: { AIIcon(.fileText, size: 14) }
                .font(MuesliTheme.font(.caption).weight(.medium)).foregroundStyle(.secondary)
            Text(citation.title).font(MuesliTheme.title3())
            Text("\(citation.startDate.formatted(date: .abbreviated, time: .shortened)) · \(citation.kind.label)\(citation.timestamp.map { " · \($0)" } ?? "")")
                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            ScrollView {
                Text(citation.excerpt).font(MuesliTheme.reading()).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(maxHeight: 300).background(MuesliTheme.backgroundDeep, in: RoundedRectangle(cornerRadius: 10))
            if changed { Text("This source changed since the answer was written.").font(MuesliTheme.font(.caption)).foregroundStyle(.orange) }
            if checked && !available { Text("This source is no longer available.").font(MuesliTheme.font(.caption)) }
            Button(action: onOpen) {
                Label { Text("Open in meeting") } icon: { AIIcon(.arrowUpRight, size: 14) }
            }.buttonStyle(.borderedProminent).disabled(!available).accessibilityIdentifier("meeting-chat-open-source")
        }
        .padding(20).frame(width: 440)
        .task(id: coordinator.sourceMutationVersion) {
            let source = await coordinator.source(citation.meetingID)
            available = source != nil; changed = source?.revision != citation.revision; checked = true
        }
    }
}

/// Preserve answer citation numbers while grouping repeated references to one meeting.
struct MeetingChatSourceGroup: Identifiable {
    struct Passage: Identifiable {
        let number: Int
        let citation: MeetingChatCitation
        var id: String { citation.sourceKey }
        var preview: String {
            citation.excerpt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
    let id: Int64
    let title: String
    let startDate: Date
    var passages: [Passage]

    static func grouped(_ citations: [MeetingChatCitation]) -> [Self] {
        var groups: [Self] = []
        var indices: [Int64: Int] = [:]
        for (index, citation) in citations.enumerated() {
            let passage = Passage(number: index + 1, citation: citation)
            if let groupIndex = indices[citation.meetingID] {
                groups[groupIndex].passages.append(passage)
            } else {
                indices[citation.meetingID] = groups.count
                groups.append(.init(id: citation.meetingID, title: citation.title, startDate: citation.startDate, passages: [passage]))
            }
        }
        return groups
    }
    static func label(for citations: [MeetingChatCitation]) -> String {
        let meetings = Set(citations.map(\.meetingID)).count
        return "\(meetings) meeting\(meetings == 1 ? "" : "s") · \(citations.count) passage\(citations.count == 1 ? "" : "s")"
    }
}

struct MeetingChatSourcesView: View {
    let citations: [MeetingChatCitation]
    let onSelect: (MeetingChatCitation) -> Void

    var body: some View {
        AIDisclosure(title: MeetingChatSourceGroup.label(for: citations), icon: .bookOpen) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(MeetingChatSourceGroup.grouped(citations)) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            AIIcon(.fileText, size: 15).foregroundStyle(.secondary)
                            Text(group.title).font(MuesliTheme.font(.callout).weight(.medium)).lineLimit(2)
                            Spacer(minLength: 0)
                            Text(group.startDate, format: .dateTime.month(.abbreviated).day().year())
                                .font(MuesliTheme.font(.caption2)).foregroundStyle(.secondary).fixedSize()
                        }
                        ForEach(group.passages) { passage in
                            AISourcePassage(number: passage.number,
                                metadata: passage.citation.kind.label + (passage.citation.timestamp.map { " · \($0)" } ?? ""),
                                preview: passage.preview,
                                action: { onSelect(passage.citation) })
                                .help("Read passage \(passage.number) from \(group.title)")
                                .accessibilityLabel("Passage \(passage.number), \(passage.citation.kind.label)\(passage.citation.timestamp.map { ", \($0)" } ?? ""): \(passage.preview)")
                                .accessibilityIdentifier("meeting-chat-passage-\(passage.citation.sourceKey)")
                        }
                    }
                }
            }.padding(.top, 8)
        }
    }
}

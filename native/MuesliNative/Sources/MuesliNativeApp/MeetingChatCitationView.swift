import SwiftUI
import MuesliCore

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
            Text(citation.title).font(MuesliTheme.headline())
            Text("\(citation.startDate.formatted(date: .abbreviated, time: .shortened)) · \(citation.kind.label)\(citation.timestamp.map { " · \($0)" } ?? "")")
                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            Text(citation.excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if changed { Text("This source changed since the answer was written.").font(.caption).foregroundStyle(.orange) }
            if checked && !available { Text("This source is no longer available.").font(.caption) }
            Button("Open in meeting", action: onOpen).disabled(!available).accessibilityIdentifier("meeting-chat-open-source")
        }
        .padding(20).frame(width: 440)
        .task {
            let source = await coordinator.source(citation.meetingID)
            available = source != nil; changed = source?.revision != citation.revision; checked = true
        }
    }
}

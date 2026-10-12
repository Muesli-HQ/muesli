import SwiftUI
import MuesliCore
import AIElementsSwift

/// Muesli owns source validation and link policy; the shared library owns Markdown layout.
struct MeetingChatAnswerView: View {
    let answer: String
    let citations: [MeetingChatCitation]

    var body: some View {
        AIResponse(MeetingChatClient.displayText(answer)) { text in
            MeetingChatView.attributedAnswer(text, citations: citations)
        }
        .font(MuesliTheme.reading())
    }
}

// Preserve the app's parser-facing tests while keeping implementation in the reusable package.
typealias MeetingChatMarkdownBlock = AIMarkdownBlock

extension MeetingChatView {
    static func attributedAnswer(_ raw: String, citations: [MeetingChatCitation]) -> AttributedString {
        var markdown = MeetingChatClient.displayText(raw)
        for (index, source) in citations.enumerated() { markdown = markdown.replacingOccurrences(of: "[[\(source.sourceKey)]]", with: "[[\(index + 1)]](muesli-citation:///\(source.sourceKey))") }
        var attributed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
        for run in Array(attributed.runs) {
            if let link = run.link, link.scheme != "muesli-citation" || !citations.contains(where: { String(link.path.dropFirst()) == $0.sourceKey }) { attributed[run.range].link = nil }
        }
        return attributed
    }
}

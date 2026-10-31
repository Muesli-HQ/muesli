import AppKit
import SwiftUI
import AIElementsSwift

/// The same content is measured and rendered, so Markdown and wrapped text size
/// the panel naturally. Only long answers scroll; the notch owns title/dismissal.
struct QuillAssistantContent: View {
    let answer: String
    let question: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question, !question.isEmpty {
                Text(question).font(MuesliTheme.caption())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(3).help(question)
            }
            AIResponse(answer).font(MuesliTheme.body()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .aiElementsTheme(.init(surface: MuesliTheme.backgroundRaised, border: MuesliTheme.surfaceBorder,
            accent: MuesliTheme.accent, muted: MuesliTheme.textSecondary,
            textFont: { MuesliTheme.font(size: $0, weight: $1) },
            heading: MuesliTheme.title3(), subheading: MuesliTheme.headline()))
    }
}

@MainActor
enum QuillAssistantLayout {
    static let padding: CGFloat = 16
    static let footerHeight: CGFloat = 26
    static let spacing: CGFloat = 12
    static var chromeHeight: CGFloat { padding * 2 + footerHeight + spacing }

    static func contentHeight(answer: String, question: String?, width: CGFloat) -> CGFloat {
        let measure = NSHostingView(rootView: QuillAssistantContent(answer: answer, question: question)
            .frame(width: max(1, width - padding * 2))
            .fixedSize(horizontal: false, vertical: true))
        return ceil(measure.fittingSize.height)
    }

    static func height(contentHeight: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        min(maximumHeight, max(96, contentHeight + chromeHeight))
    }
}

struct QuillAssistantView: View {
    let answer: String
    let question: String?
    let contentHeight: CGFloat
    let onFollowUp: () -> Void
    let onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: QuillAssistantLayout.spacing) {
            ScrollView {
                QuillAssistantContent(answer: answer, question: question)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: contentHeight)
            HStack(spacing: 16) {
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(answer, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        AIIcon(copied ? .check : .copy)
                        Text(copied ? "Copied" : "Copy")
                    }
                }
                Spacer()
                Button("Follow up", action: onFollowUp)
                Button(action: onDismiss) { AIIcon(.squarePen) }
                    .accessibilityLabel("New conversation")
                    .help("New conversation")
            }
            .font(MuesliTheme.caption())
            .foregroundStyle(.white.opacity(0.65))
            .buttonStyle(.plain)
            .frame(height: QuillAssistantLayout.footerHeight)
        }
        .padding(QuillAssistantLayout.padding)
        .foregroundStyle(.white)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        .preferredColorScheme(.dark)
        .onChange(of: answer) { _, _ in copied = false }
    }
}

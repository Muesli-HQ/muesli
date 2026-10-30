import SwiftUI

public enum AIReasoningState: Equatable, Sendable {
    case waiting, streaming, completed

    public var label: String {
        switch self {
        case .waiting: "Thinking…"
        case .streaming: "Thinking…"
        case .completed: "Reasoning"
        }
    }
}

/// Displays only provider-visible reasoning summaries supplied by the host.
/// This component never synthesizes reasoning, requests hidden chain of thought,
/// or runs a timer. Elapsed duration is optional and supplied by the host.
/// Manual disclosure state survives text/state updates with a stable view identity.
public struct AIReasoning: View {
    private let summary: String
    private let state: AIReasoningState
    private let elapsedSeconds: TimeInterval?
    @State private var isExpanded: Bool
    @Environment(\.aiElementsTheme) private var theme

    public init(
        summary: String,
        state: AIReasoningState,
        elapsedSeconds: TimeInterval? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.summary = summary
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if !summary.isEmpty {
                AIResponse(summary, inlineContent: Self.summaryInlineContent).font(theme.font(size: 12))
                    .foregroundStyle(theme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
        } label: {
            HStack(spacing: 8) {
                AIIcon(.brain, size: 16).accessibilityHidden(true)
                Group {
                    if state == .completed {
                        Text(state.label)
                    } else {
                        AIShimmer(state.label)
                    }
                }.font(theme.font(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if let duration = Self.durationLabel(elapsedSeconds) {
                    Text(duration).font(theme.font(size: 11).monospacedDigit())
                        .foregroundStyle(theme.muted)
                        .accessibilityLabel("Elapsed \(duration)")
                }
            }
            .accessibilityElement(children: .combine)
        }
        .foregroundStyle(theme.muted)
        .disclosureGroupStyle(AIElementsDisclosureStyle())
    }

    // Reasoning is explanatory content, not a source of executable links/actions.
    static func summaryInlineContent(_ markdown: String) -> AttributedString {
        var result = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
        for run in Array(result.runs) where run.link != nil { result[run.range].link = nil }
        return result
    }

    static func durationLabel(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        // Avoid overflow for erroneous host durations while preserving useful values.
        let total = Int(min(seconds.rounded(.down), 31_536_000))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }
}

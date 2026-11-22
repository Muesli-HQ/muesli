import SwiftUI

/// Execution state supplied by the host, never inferred from output text.
public enum AIToolState: Equatable, Sendable {
    case pending, running, completed, failed, cancelled

    public var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// A native disclosure card for a real tool invocation. The host owns execution,
/// redaction, and truncation of potentially sensitive or large input/output.
/// Keep the view's identity stable to preserve manual expansion during updates.
public struct AITool: View {
    private let title: String
    private let state: AIToolState
    private let input: String?
    private let output: String?
    private let error: String?
    @State private var isExpanded: Bool
    @Environment(\.aiElementsTheme) private var theme

    public init(
        title: String,
        state: AIToolState,
        input: String? = nil,
        output: String? = nil,
        error: String? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.title = title
        self.state = state
        self.input = input
        self.output = output
        self.error = error
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                section("Input", text: input)
                section("Output", text: output)
                section("Error", text: error)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                AIIcon(.wrench, size: 14).foregroundStyle(theme.muted)
                Text(title).font(theme.font(size: 12, weight: .medium))
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    AIExecutionIndicator(state: state).accessibilityHidden(true)
                    Text(state.label).font(theme.font(size: 11)).foregroundStyle(theme.muted)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .disclosureGroupStyle(AIElementsDisclosureStyle())
        .padding(12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
    }

    @ViewBuilder private func section(_ title: String, text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(theme.font(size: 11, weight: .semibold)).foregroundStyle(theme.muted)
                Text(verbatim: text).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shared visual treatment, without a timer or inferred progress.
struct AIExecutionIndicator: View {
    let state: AIToolState
    @Environment(\.aiElementsTheme) private var theme

    var body: some View {
        Group {
            switch state {
            case .pending: AIIcon(.circle, size: 14).foregroundStyle(theme.muted)
            case .running: AIIcon(.clock, size: 14).foregroundStyle(theme.accent)
            case .completed: AIIcon(.circleCheckBig, size: 14).foregroundStyle(theme.muted)
            case .failed: AIIcon(.circleX, size: 14).foregroundStyle(.red)
            case .cancelled: AIIcon(.circleX, size: 14).foregroundStyle(theme.muted)
            }
        }.frame(width: 16, height: 16)
    }
}

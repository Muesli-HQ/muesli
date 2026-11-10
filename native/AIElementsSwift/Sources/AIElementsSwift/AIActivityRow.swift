import SwiftUI

public enum AIActivityState: Equatable, Sendable {
    case pending
    case running
    case completed
    case failed

    fileprivate var accessibilityDescription: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

/// Displays an explicit state supplied by the execution layer.
public struct AIActivityRow: View {
    private let title: String
    private let detail: String?
    private let state: AIActivityState
    @Environment(\.aiElementsTheme) private var theme

    public init(title: String, detail: String? = nil, state: AIActivityState) {
        self.title = title
        self.detail = detail
        self.state = state
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            stateIndicator.frame(width: 16, height: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(theme.font(size: 12, weight: .medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(theme.font(size: 12)).foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.accessibilityDescription)
    }

    @ViewBuilder private var stateIndicator: some View {
        switch state {
        case .pending: AIExecutionIndicator(state: .pending)
        case .running: AIExecutionIndicator(state: .running)
        case .completed: AIExecutionIndicator(state: .completed)
        case .failed: AIExecutionIndicator(state: .failed)
        }
    }
}

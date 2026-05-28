import SwiftUI

struct JessicaHistoryView: View {
    let appState: AppState
    let controller: MuesliController

    private var history: [SalesAgentHistoryItem] {
        appState.config.salesAgentHistory
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                header

                if history.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                        ForEach(history) { item in
                            historyRow(item)
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Jessica")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Recent agent responses from voice commands and hosted Jessica.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer()
            Button {
                controller.clearSalesAgentHistory()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(MuesliTheme.body())
            }
            .buttonStyle(.plain)
            .foregroundStyle(history.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textSecondary)
            .disabled(history.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
            Text("No Jessica responses yet")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Use the Jessica Command shortcut and each response will stay here after the floating card disappears.")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MuesliTheme.spacing8) {
                Button {
                    appState.preferredSettingsPane = "computerUse"
                    appState.selectedTab = .settings
                } label: {
                    Label("Set up Jessica", systemImage: "slider.horizontal.3")
                        .font(MuesliTheme.caption())
                }
                .buttonStyle(.plain)
                Button {
                    controller.testJessicaResponseCard()
                } label: {
                    Label("Test response card", systemImage: "sparkles")
                        .font(MuesliTheme.caption())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, MuesliTheme.spacing8)
        }
        .padding(MuesliTheme.spacing20)
        .frame(maxWidth: 520, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func historyRow(_ item: SalesAgentHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center, spacing: MuesliTheme.spacing8) {
                statusPill(item.status)
                Text(providerLabel(item.provider))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(Self.timestampFormatter.string(from: item.createdAt))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("You")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(item.transcript)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(MuesliTheme.surfaceBorder)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Jessica")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.accent)
                Text(item.response)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = item.plannerCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Local action")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Text(command)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(MuesliTheme.spacing8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func statusPill(_ status: String) -> some View {
        let isDone = status == "done"
        return Text(isDone ? "Done" : status.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isDone ? MuesliTheme.accent : MuesliTheme.transcribing)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 3)
            .background((isDone ? MuesliTheme.accent : MuesliTheme.transcribing).opacity(0.12))
            .clipShape(Capsule())
    }

    private func providerLabel(_ provider: String) -> String {
        SalesAgentBackendOption.resolved(provider).label
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

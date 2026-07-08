import SwiftUI

struct DiagnosticIncidentReportView: View {
    let incident: DiagnosticIncident
    let onOpenIssue: () -> Void
    let onDismiss: () -> Void

    private var isManualReport: Bool {
        incident.kind == .manualReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: isManualReport ? "exclamationmark.bubble.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isManualReport ? MuesliTheme.accent : .orange)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text(isManualReport ? "Report a Problem" : "Diagnostic Failure Detected")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(isManualReport ? "\(AppIdentity.displayName) can prepare an anonymized GitHub issue for you to review before opening it." : "\(AppIdentity.displayName) detected a hard failure in \(incident.stage). You can review the anonymized report before opening a GitHub issue.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !isManualReport {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    diagnosticSummaryRow("Failure", value: incident.kind.title)
                    diagnosticSummaryRow("Stage", value: incident.stage)
                    diagnosticSummaryRow("Model", value: incident.model)
                    diagnosticSummaryRow("Error", value: "\(incident.errorDomain) \(incident.errorCode)")
                    diagnosticSummaryRow("Meaning", value: incident.errorMeaning?.summary ?? "Unknown; use domain/code for lookup")
                }
                .padding(MuesliTheme.spacing12)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                )
            }

            Text("No transcript, audio, meeting title, calendar title, clipboard contents, screen text, API keys, auth tokens, local file paths, raw logs, or database contents are included.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(incident.issueBody)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MuesliTheme.spacing12)
            }
            .frame(minHeight: 240)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .stroke(MuesliTheme.surfaceBorder, lineWidth: 1)
            )

            HStack {
                Spacer()
                Button("Not Now") {
                    onDismiss()
                }
                Button("Open GitHub Issue") {
                    onOpenIssue()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720, minHeight: 460)
        .background(MuesliTheme.backgroundBase)
    }

    @ViewBuilder
    private func diagnosticSummaryRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing12) {
            Text(label)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

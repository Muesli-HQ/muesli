import SwiftUI
import MuesliCore

struct DictationRowView: View {
    let record: DictationRecord
    let timeOnly: String
    let onCopy: () -> Void
    var onCopyTrace: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var showDeleteConfirmation = false
    @State private var isExpanded = false
    @State private var showsFullText = false

    private var isComputerUseCommand: Bool {
        record.source == "cua"
    }

    private var isQuilTransformation: Bool {
        record.source == "quil"
    }

    private var canExpandText: Bool {
        record.rawText.count > 160 || record.rawText.filter { $0 == "\n" }.count > 2
    }

    private var displayedText: String {
        guard !showsFullText, record.rawText.count > 160 else { return record.rawText }
        return String(record.rawText.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private var hasExpandableDetails: Bool {
        record.computerUseTrace != nil
    }

    private var syncOriginBadgeLabel: String? {
        SyncOriginDisplay.badgeLabel(forDictationSource: record.source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing20) {
                Text(timeOnly)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 80, alignment: .leading)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                        if isComputerUseCommand {
                            Text("CUA")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(MuesliTheme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        if isQuilTransformation {
                            HStack(spacing: 3) {
                                Image(nsImage: QuillIcon.image())
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 10, height: 10)
                                Text("QUILL")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                                .foregroundStyle(MuesliTheme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accentSubtle)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        if let syncOriginBadgeLabel {
                            SyncOriginBadge(label: syncOriginBadgeLabel)
                        }

                        Text(displayedText)
                            .font(MuesliTheme.reading())
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(showsFullText || !canExpandText ? nil : 3)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let trace = record.computerUseTrace, !isQuilTransformation {
                            HStack(spacing: MuesliTheme.spacing8) {
                                if trace.finalStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running" {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Computer use in progress")
                                }
                                Text(Self.displayFinalStatus(trace.finalStatus))
                                    .font(MuesliTheme.captionMedium())
                                    .foregroundStyle(statusColor(trace.finalStatus))
                            }
                        }
                    }

                    if canExpandText {
                        Button(showsFullText ? "Show less" : "Show more") {
                            showsFullText.toggle()
                        }
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.accent)
                        .buttonStyle(.plain)
                        .accessibilityLabel(showsFullText ? "Collapse dictation text" : "Show full dictation text")
                        .accessibilityIdentifier("dictation.expand.\(record.id)")
                    }

                    if isExpanded, let trace = record.computerUseTrace {
                        computerUseTraceView(trace)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let targetAppName = record.targetAppName {
                    TargetApplicationIconView(
                        appName: targetAppName,
                        bundleIdentifier: record.targetAppBundleID
                    )
                }

                HStack(spacing: 8) {
                    if hasExpandableDetails {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    if !isQuilTransformation, record.computerUseTrace != nil, let onCopyTrace {
                        Button(action: onCopyTrace) {
                            Image(systemName: "list.bullet.clipboard")
                                .font(.system(size: 12))
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy raw CUA trace")
                    }

                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .buttonStyle(.plain)

                    if onDelete != nil {
                        Button { showDeleteConfirmation = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(.red.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .opacity(isHovered || isExpanded || hasExpandableDetails ? 1 : 0)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing16)
        .background(isHovered ? MuesliTheme.backgroundHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MuesliTheme.surfaceBorder).frame(height: 1)
                .padding(.horizontal, MuesliTheme.spacing20)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if hasExpandableDetails {
                // Expanded traces contain their own disclosure controls. Do not
                // collapse the parent row when a nested detail is clicked.
                if !isExpanded { withAnimation(.easeInOut(duration: 0.15)) { isExpanded = true } }
            } else { onCopy() }
        }
        .alert("Delete Dictation", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this dictation? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func computerUseTraceView(_ trace: ComputerUseTraceRecord) -> some View {
        if isComputerUseCommand {
            ReadableComputerUseTraceView(trace: trace)
        } else {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Divider()
                    .opacity(0.5)

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    ForEach(trace.events) { event in
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                            HStack(spacing: MuesliTheme.spacing8) {
                                if !isQuilTransformation {
                                    Text(event.step.map { "Step \($0)" } ?? "Run")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                        .frame(width: 48, alignment: .leading)
                                }

                                Text(event.title)
                                    .font(MuesliTheme.captionMedium())
                                    .foregroundStyle(MuesliTheme.textSecondary)

                                if let status = ComputerUseTraceFormatter.displayStatus(for: event) {
                                    Text(status)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(statusColor(status))
                                }
                            }

                            Text(event.body)
                                .font(.system(
                                    size: 12,
                                    weight: .regular,
                                    design: ["model_output", "quil_model"].contains(event.kind) ? .monospaced : .default
                                ))
                                .foregroundStyle(MuesliTheme.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, isQuilTransformation ? 0 : 56)
                        }
                    }
                }
            }
            .padding(.top, MuesliTheme.spacing4)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "done", "executed":
            return MuesliTheme.success
        case "confirm", "needsconfirmation":
            return MuesliTheme.transcribing
        case "timed_out", "timedout", "incomplete":
            return MuesliTheme.transcribing
        case "failed", "unsupported":
            return MuesliTheme.recording
        default:
            return MuesliTheme.textTertiary
        }
    }

    private static func displayFinalStatus(_ status: String) -> String {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running":
            return "Running"
        case "interrupted":
            return "Interrupted"
        case "done":
            return "Done"
        case "timed_out", "timedout":
            return "Timed out"
        case "failed", "fail":
            return "Failed"
        case "confirm", "needsconfirmation", "needs_confirmation":
            return "Confirm"
        case "cancelled", "canceled":
            return "Cancelled"
        default:
            return status.capitalized
        }
    }
}


private struct ReadableComputerUseTraceView: View {
    let trace: ComputerUseTraceRecord
    @State private var rows: [ComputerUseTraceFormatter.ReadableRow] = []
    @State private var budget: String?
    @State private var diagnosticsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Planner summary").font(.caption).foregroundStyle(.secondary)
            Text(trace.finalMessage).font(.system(size: 12)).textSelection(.enabled)
            if let budget { Text(budget).font(.caption).foregroundStyle(.secondary) }
            ForEach(rows) { row in
                ReadableComputerUseTraceRow(row: row)
            }
            DisclosureGroup("Run diagnostics", isExpanded: $diagnosticsExpanded) {
                if diagnosticsExpanded {
                    ForEach(trace.events.filter { ["transcript", "backend", "context_budget"].contains($0.kind) }) { event in
                        Text(event.body).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .onAppear { refresh() }
        .onChange(of: trace.events) { _, _ in refresh() }
    }
    private func refresh() {
        rows = ComputerUseTraceFormatter.readableRows(trace.events)
        budget = ComputerUseTraceFormatter.budgetSummary(trace.events)
    }
}

private struct ReadableComputerUseTraceRow: View {
    let row: ComputerUseTraceFormatter.ReadableRow
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let first = row.events.first?.step {
                    let last = row.events.last?.step ?? first
                    Text(first == last ? "\(first)" : "\(first)–\(last)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(row.title).font(.system(size: 13, weight: .medium))
            }
            Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(row.outcome).font(.system(size: 11))
                .foregroundStyle(row.outcome.hasPrefix("Error") ? Color.red : Color.secondary)
            DisclosureGroup("Raw details", isExpanded: $expanded) {
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(row.events) { event in
                                Text("Step \(event.step.map(String.init) ?? "—") · \(event.kind) · \(event.timestamp)")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(event.body).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(8)
                    }.frame(maxHeight: 260)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

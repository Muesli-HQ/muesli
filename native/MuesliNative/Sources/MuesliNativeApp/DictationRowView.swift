import SwiftUI
import MuesliCore

struct DictationRowView: View {
    let record: DictationRecord
    let timeOnly: String
    let onCopy: () -> Void
    var onCopyTrace: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var recordingController: MuesliController?

    private enum RowAction: Hashable {
        case details, copyTrace, copy, delete
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var showDeleteConfirmation = false
    @State private var isExpanded = false
    @State private var showsFullText = false
    /// Row actions are revealed by hover or by keyboard focus, never left invisible but focused.
    @FocusState private var focusedAction: RowAction?
    @State private var copyConfirmation: CopyConfirmation?

    /// A fresh identity per copy restarts the confirmation timer on repeated copies.
    private struct CopyConfirmation: Equatable {
        let id = UUID()
        let action: RowAction
    }

    private let actionSize: CGFloat = 28

    private var copiedAction: RowAction? { copyConfirmation?.action }

    /// Pasteboard writes are synchronous, so the confirmation follows the write directly.
    private func copy(_ action: RowAction, using perform: () -> Void) {
        perform()
        withAnimation(rowAnimation) { copyConfirmation = CopyConfirmation(action: action) }
        AccessibilityNotification.Announcement(action == .copyTrace ? "Trace copied" : "Copied").post()
    }

    private var rowAnimation: Animation? {
        MuesliMotion.animation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion)
    }

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
                                .foregroundStyle(MuesliTheme.accentText)
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
                                .foregroundStyle(MuesliTheme.accentText)
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
                            .muesliRowActivation {
                                if hasExpandableDetails {
                                    withAnimation(rowAnimation) { isExpanded.toggle() }
                                } else {
                                    copy(.copy, using: onCopy)
                                }
                            }
                            .accessibilityHint(hasExpandableDetails ? "Show or hide details" : "Copy dictation")
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

                    if record.hasRetainedAudio, let controller = recordingController {
                        DictationRecordingControls(record: record, controller: controller)
                    }

                    if canExpandText {
                        Button {
                            showsFullText.toggle()
                        } label: {
                            Text(showsFullText ? "Show less" : "Show more")
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.accentText)
                                .padding(.horizontal, 6)
                                .frame(minHeight: 28)
                        }
                        .buttonStyle(.muesli(.quiet))
                        // Text stays aligned with the dictation and keeps its row spacing;
                        // the invisible padding only extends the target.
                        .padding(.leading, -6)
                        .padding(.vertical, -6)
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

                // 28pt targets so near-misses land on the action rather than the row's copy tap.
                HStack(spacing: 2) {
                    if let copiedAction {
                        Text(copiedAction == .copyTrace ? "Trace copied" : "Copied")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.successText)
                            .padding(.trailing, 4)
                            .transition(.opacity)
                    }

                    if hasExpandableDetails {
                        Button {
                            withAnimation(rowAnimation) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .frame(width: actionSize, height: actionSize)
                        }
                        .buttonStyle(.muesli(.quiet))
                        .focused($focusedAction, equals: .details)
                        .help(isExpanded ? "Hide details" : "Show details")
                        .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
                    }

                    if !isQuilTransformation, record.computerUseTrace != nil, let onCopyTrace {
                        Button { copy(.copyTrace, using: onCopyTrace) } label: {
                            Image(systemName: copiedAction == .copyTrace ? "checkmark" : "list.bullet.clipboard")
                                .font(.system(size: 12))
                                .foregroundStyle(copiedAction == .copyTrace ? MuesliTheme.successText : MuesliTheme.textTertiary)
                                .frame(width: actionSize, height: actionSize)
                        }
                        .buttonStyle(.muesli(.quiet))
                        .focused($focusedAction, equals: .copyTrace)
                        .help(copiedAction == .copyTrace ? "CUA trace copied" : "Copy CUA trace")
                        .accessibilityLabel("Copy CUA trace")
                    }

                    TimelineRowActionButton(
                        symbol: copiedAction == .copy ? "checkmark" : "doc.on.doc",
                        label: "Copy dictation", help: copiedAction == .copy ? "Dictation copied" : "Copy dictation",
                        color: copiedAction == .copy ? MuesliTheme.successText : MuesliTheme.textTertiary
                    ) { copy(.copy, using: onCopy) }
                    .focused($focusedAction, equals: .copy)

                    if onDelete != nil {
                        TimelineRowActionButton(symbol: "trash", label: "Delete dictation",
                                                help: "Delete dictation", color: MuesliTheme.destructiveText) {
                            showDeleteConfirmation = true
                        }
                        .focused($focusedAction, equals: .delete)
                    }
                }
                // Glyphs keep their former vertical position beside the first text line.
                .padding(.vertical, -(actionSize - 14) / 2)
                .opacity(isHovered || isExpanded || hasExpandableDetails || focusedAction != nil || copiedAction != nil ? 1 : 0)
            }
        }
        .task(id: copyConfirmation) {
            guard copyConfirmation != nil else { return }
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
            withAnimation(rowAnimation) { copyConfirmation = nil }
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
            withAnimation(rowAnimation) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if hasExpandableDetails {
                withAnimation(rowAnimation) {
                    isExpanded.toggle()
                }
            } else {
                copy(.copy, using: onCopy)
            }
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
                            .font(MuesliTheme.font(
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

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "done", "executed":
            return MuesliTheme.successText
        case "confirm", "needsconfirmation":
            return MuesliTheme.warningText
        case "timed_out", "timedout":
            return MuesliTheme.warningText
        case "failed", "unsupported":
            return MuesliTheme.destructiveText
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

private struct DictationRecordingControls: View {
    let record: DictationRecord
    let controller: MuesliController
    @State private var showPlayer = false
    @State private var recording: DictationRecordingFile?
    @State private var loadError: String?
    @State private var selectedModel: BackendOption?

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Button {
                showPlayer.toggle()
            } label: {
                Label("Recording", systemImage: "waveform")
            }
            .popover(isPresented: $showPlayer) {
                Group {
                    if let recording {
                        MeetingRecordingPlayerView(recordingPath: recording.url.path, cacheWaveform: false)
                    } else if let loadError {
                        Text(loadError)
                    } else {
                        ProgressView("Loading recording")
                    }
                }
                .frame(width: 310)
                .padding()
                .task(id: record.id) {
                    do {
                        let file = try await controller.loadDictationRecording(id: record.id)
                        try Task.checkCancellation()
                        recording = file
                    } catch {
                        if !Task.isCancelled { loadError = error.localizedDescription }
                    }
                }
                .onDisappear { recording = nil; loadError = nil }
            }
            if controller.appState.retranscribingHistoryID == record.id {
                ProgressView().controlSize(.small)
                Button("Cancel") { controller.cancelDictationRecovery() }
            } else {
                let models = BackendOption.compatibleOptions().filter { controller.appState.settingsModelAvailability.contains($0) }
                Menu("Retranscribe with…") {
                    if models.isEmpty { Text("Download a local model in Models") }
                    ForEach(models, id: \.model) { model in
                        Button(model.label) { selectedModel = model }
                    }
                }
                .fixedSize()
                .disabled(controller.appState.dictationState != .idle || controller.appState.activeAudioImportCount > 0
                    || controller.appState.modelFileMutationCount > 0 || controller.appState.isMeetingRecording
                    || controller.appState.isMeetingStarting || controller.appState.privateMode)
            }
        }
        .font(MuesliTheme.captionMedium())
        .confirmationDialog("Replace this transcript?", isPresented: Binding(
            get: { selectedModel != nil }, set: { if !$0 { selectedModel = nil } }
        ), presenting: selectedModel) { model in
            Button("Retranscribe with " + model.label) { controller.retranscribeDictation(record, with: model) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The new transcript replaces this history entry when transcription succeeds. You can replay the original recording again.")
        }
    }
}

/// The shared quiet copy/delete control used by Timeline activity rows.
struct TimelineRowActionButton: View {
    let symbol: String
    let label: String
    let help: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.muesli(.quiet))
        .help(help)
        .accessibilityLabel(label)
    }
}

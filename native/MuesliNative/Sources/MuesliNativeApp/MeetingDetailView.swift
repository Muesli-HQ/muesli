import SwiftUI
import MuesliCore

private enum MeetingDocumentMode: Hashable {
    case notes
    case transcript
}

private enum ManualNotesSaveStatus {
    case saved
    case saving

    var label: String {
        switch self {
        case .saved: return "Saved"
        case .saving: return "Saving..."
        }
    }
}

struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let controller: MuesliController
    let appState: AppState
    let onBack: (() -> Void)?
    let backLabel: String
    @State private var isSummarizing = false
    @State private var isRetranscribing = false
    @State private var isEditingNotes = false
    @State private var isEditingTranscript = false
    @State private var editableTitle: String
    @State private var editableNotes: String
    @State private var editableTranscript: String
    @State private var editableManualNotes: String
    @State private var loadedMeetingID: Int64?
    @State private var manualNotesSaveStatus: ManualNotesSaveStatus = .saved
    @State private var manualEditorCommand: MarkdownEditorCommand?
    @State private var pendingTemplateID: String
    @State private var documentMode: MeetingDocumentMode
    @State private var titleSaveTask: DispatchWorkItem?
    @State private var notesSaveTask: DispatchWorkItem?
    @State private var transcriptSaveTask: DispatchWorkItem?
    @State private var manualNotesSaveStatusTask: DispatchWorkItem?
    @State private var summaryErrorMessage: String?
    @State private var retranscriptionErrorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var transcriptResummaryPromptMeetingID: Int64?
    @State private var transcriptEditOriginalTranscript: String?
    @State private var transcriptEditHadStructuredNotes = false

    init(
        meeting: MeetingRecord?,
        controller: MuesliController,
        appState: AppState,
        onBack: (() -> Void)? = nil,
        backLabel: String = "Back to Meetings"
    ) {
        self.meeting = meeting
        self.controller = controller
        self.appState = appState
        self.onBack = onBack
        self.backLabel = backLabel
        let initialTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        _editableTitle = State(initialValue: meeting?.title ?? "")
        _editableNotes = State(initialValue: meeting.map { Self.notesContent(for: $0) } ?? "")
        _editableTranscript = State(initialValue: meeting?.rawTranscript ?? "")
        _editableManualNotes = State(initialValue: meeting?.manualNotes ?? "")
        _loadedMeetingID = State(initialValue: meeting?.id)
        _pendingTemplateID = State(initialValue: initialTemplateID)
        _documentMode = State(initialValue: meeting.map(Self.defaultDocumentMode(for:)) ?? .notes)
    }

    var body: some View {
        Group {
            if let meeting {
                VStack(alignment: .leading, spacing: 0) {
                    header(meeting)

                    Divider()
                        .background(MuesliTheme.surfaceBorder)

                    content(for: meeting)
                }
                .background(MuesliTheme.backgroundBase)
                .onChange(of: meeting.id) { _, _ in
                    syncLocalState(with: meeting)
                }
                .onChange(of: meeting.status) { _, _ in
                    syncLocalState(with: meeting)
                }
                .onChange(of: meeting.manualNotes) { _, _ in
                    syncManualNotesState(with: meeting)
                }
                .onChange(of: appState.config.customMeetingTemplates) { _, _ in
                    syncPendingTemplateSelectionIfNeeded(for: meeting)
                }
            } else {
                VStack(spacing: MuesliTheme.spacing12) {
                    Text("No meeting selected")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text("Choose a meeting from the Meetings browser to open it here.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MuesliTheme.backgroundBase)
            }
        }
        .alert("Couldn't Save Summary", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {
                summaryErrorMessage = nil
            }
        } message: {
            Text(summaryErrorMessage ?? "The updated meeting notes could not be saved.")
        }
        .alert("Couldn't Re-transcribe Meeting", isPresented: retranscriptionErrorBinding) {
            Button("OK", role: .cancel) {
                retranscriptionErrorMessage = nil
            }
        } message: {
            Text(retranscriptionErrorMessage ?? "The saved recording could not be re-transcribed.")
        }
        .alert("Re-summarize Notes?", isPresented: transcriptResummaryPromptBinding) {
            Button("Re-summarize") {
                resummarizeAfterTranscriptEdit()
            }
            Button("Not Now", role: .cancel) {
                transcriptResummaryPromptMeetingID = nil
            }
        } message: {
            Text("Your transcript edits may change the generated notes. Re-summarize now to update them from the edited transcript.")
        }
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let meeting {
                    controller.deleteMeeting(id: meeting.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
    }

    @ViewBuilder
    private func header(_ meeting: MeetingRecord) -> some View {
        let appliedTemplate = controller.meetingTemplateSnapshot(for: meeting)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(backLabel)
                            .font(MuesliTheme.callout())
                    }
                    .foregroundStyle(MuesliTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: MuesliTheme.spacing24) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    MarqueeTitleTextField(
                        text: $editableTitle,
                        onSubmit: {
                            controller.updateMeetingTitle(id: meeting.id, title: editableTitle)
                        },
                        onTextChange: {
                            debounceSaveTitle(meetingID: meeting.id)
                        }
                    )

                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(formatMeta(meeting))
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        templateChip(for: appliedTemplate)
                    }
                }

                Spacer(minLength: MuesliTheme.spacing16)

                VStack(alignment: .trailing, spacing: 10) {
                    if showsManualNotesEditor(for: meeting) {
                        recordingControlGroup(for: meeting)
                    } else {
                        documentModePicker

                        headerActions(for: meeting, appliedTemplate: appliedTemplate)
                    }
                }
            }

            if !showsManualNotesEditor(for: meeting), isRawTranscript(meeting), documentMode == .notes {
                transcriptCTA
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func content(for meeting: MeetingRecord) -> some View {
        if showsManualNotesEditor(for: meeting) {
            let isManualNotesEditable = canEditManualNotes(for: meeting)
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                manualNotesToolbar(for: meeting)
                    .disabled(!isManualNotesEditable)

                MarkdownRichTextEditor(
                    text: $editableManualNotes,
                    command: $manualEditorCommand,
                    shouldFocus: isManualNotesEditable && meeting.status == .recording,
                    isEditable: isManualNotesEditable,
                    onTextChange: { notes in
                        guard isManualNotesEditable else { return }
                        saveManualNotes(meetingID: meeting.id, notes: notes)
                    }
                )
                .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
                .background(MuesliTheme.backgroundBase)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if isEditingNotes {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                contentToolbar(for: meeting)

                TextEditor(text: $editableNotes)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(MuesliTheme.spacing24)
                    .background(MuesliTheme.backgroundBase)
                    .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: editableNotes) { _, _ in
                        debounceSaveNotes(meetingID: meeting.id)
                    }
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if isEditingTranscript {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                contentToolbar(for: meeting)

                TextEditor(text: $editableTranscript)
                    .font(.system(size: 14))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(MuesliTheme.spacing24)
                    .background(MuesliTheme.backgroundBase)
                    .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: editableTranscript) { _, _ in
                        debounceSaveTranscript(meetingID: meeting.id)
                    }
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                contentToolbar(for: meeting)

                ZStack {
                    MeetingNotesView(markdown: Self.notesContent(for: meeting))
                        .opacity(documentMode == .notes ? 1 : 0)
                        .allowsHitTesting(documentMode == .notes)
                        .accessibilityHidden(documentMode != .notes)

                    MeetingTranscriptView(transcript: meeting.rawTranscript)
                        .opacity(documentMode == .transcript ? 1 : 0)
                        .allowsHitTesting(documentMode == .transcript)
                        .accessibilityHidden(documentMode != .transcript)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var documentModePicker: some View {
        Picker("", selection: $documentMode) {
            Text("Notes").tag(MeetingDocumentMode.notes)
            Text("Transcript").tag(MeetingDocumentMode.transcript)
        }
        .pickerStyle(.segmented)
        .tint(MuesliTheme.accent)
        .frame(width: 220)
        .disabled(isEditingNotes || isEditingTranscript)
    }

    private func showsManualNotesEditor(for meeting: MeetingRecord) -> Bool {
        switch meeting.status {
        case .recording, .processing, .noteOnly, .failed:
            return true
        case .completed:
            return false
        }
    }

    private func canEditManualNotes(for meeting: MeetingRecord) -> Bool {
        meeting.status == .recording || meeting.status == .noteOnly || meeting.status == .failed
    }

    @ViewBuilder
    private func headerActions(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MuesliTheme.spacing8) {
                templateMenu(for: meeting, appliedTemplate: appliedTemplate)
                recordingAction(for: meeting)
                summaryAction(for: meeting)
                editButton(for: meeting)
                if controller.canDeleteMeeting(meeting) {
                    deleteButton
                }
            }

            VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                HStack(spacing: MuesliTheme.spacing8) {
                    templateMenu(for: meeting, appliedTemplate: appliedTemplate)
                    recordingAction(for: meeting)
                    summaryAction(for: meeting)
                }
                HStack(spacing: MuesliTheme.spacing8) {
                    editButton(for: meeting)
                    if controller.canDeleteMeeting(meeting) {
                        deleteButton
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryAction(for meeting: MeetingRecord) -> some View {
        if isSummarizing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing...")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(.horizontal, MuesliTheme.spacing8)
        } else {
            iconButton("sparkles", label: primarySummaryActionLabel(for: meeting)) {
                isSummarizing = true
                let completion: (Result<Void, Error>) -> Void = { [meeting] result in
                    isSummarizing = false
                    switch result {
                    case .success:
                        if let updated = controller.meeting(id: meeting.id) {
                            syncLocalState(with: updated)
                        }
                    case .failure(let error):
                        syncPendingTemplateSelectionIfNeeded(
                            for: controller.meeting(id: meeting.id) ?? meeting
                        )
                        summaryErrorMessage = error.localizedDescription
                    }
                }
                if hasPendingTemplateChange(for: meeting) {
                    controller.applyMeetingTemplate(id: pendingTemplateID, to: meeting, completion: completion)
                } else {
                    controller.resummarize(meeting: meeting, completion: completion)
                }
            }
        }
    }

    @ViewBuilder
    private func editButton(for meeting: MeetingRecord) -> some View {
        iconButton(
            isEditingNotes || isEditingTranscript ? "checkmark.circle" : "pencil",
            label: editButtonLabel
        ) {
            if isEditingNotes {
                notesSaveTask?.cancel()
                notesSaveTask = nil
                controller.updateMeetingNotes(id: meeting.id, notes: editableNotes)
                isEditingNotes = false
            } else if isEditingTranscript {
                guard !isRetranscribing else { return }
                transcriptSaveTask?.cancel()
                transcriptSaveTask = nil
                let shouldPromptForResummary = Self.shouldPromptForTranscriptResummary(
                    hadStructuredNotes: transcriptEditHadStructuredNotes,
                    originalTranscript: transcriptEditOriginalTranscript,
                    editedTranscript: editableTranscript
                )
                controller.updateMeetingTranscript(id: meeting.id, transcript: editableTranscript)
                isEditingTranscript = false
                transcriptEditOriginalTranscript = nil
                transcriptEditHadStructuredNotes = false
                if shouldPromptForResummary {
                    transcriptResummaryPromptMeetingID = meeting.id
                }
            } else if documentMode == .transcript {
                editableTranscript = meeting.rawTranscript
                transcriptEditOriginalTranscript = meeting.rawTranscript
                transcriptEditHadStructuredNotes = meeting.notesState == .structuredNotes
                isEditingTranscript = true
            } else {
                documentMode = .notes
                editableNotes = Self.notesContent(for: meeting)
                isEditingNotes = true
            }
        }
        .disabled(isRetranscribing && !isEditingNotes && !isEditingTranscript)
    }

    @ViewBuilder
    private func recordingAction(for meeting: MeetingRecord) -> some View {
        if let savedRecordingPath = meeting.savedRecordingPath {
            iconButton("folder", label: "Show Recording") {
                controller.revealMeetingRecordingInFinder(path: savedRecordingPath)
            }
        }
    }

    @ViewBuilder
    private func retranscribeAction(for meeting: MeetingRecord) -> some View {
        if meeting.savedRecordingPath != nil {
            if isRetranscribing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Re-transcribing...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                .padding(.horizontal, MuesliTheme.spacing8)
            } else {
                iconButton("arrow.clockwise", label: "Re-transcribe") {
                    isRetranscribing = true
                    controller.retranscribe(meeting: meeting) { [meeting] result in
                        isRetranscribing = false
                        switch result {
                        case .success:
                            if let updated = controller.meeting(id: meeting.id) {
                                syncLocalState(with: updated)
                            }
                        case .failure(let error):
                            retranscriptionErrorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(meeting.status == .recording || meeting.status == .processing || isEditingNotes || isEditingTranscript)
            }
        }
    }

    @ViewBuilder
    private func templateMenu(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        Menu {
            Button {
                pendingTemplateID = MeetingTemplates.autoID
            } label: {
                templateMenuItem(
                    title: MeetingTemplates.auto.title,
                    systemImage: MeetingTemplates.auto.icon,
                    isSelected: pendingTemplateID == MeetingTemplates.autoID
                )
            }

            Section("Built-in Templates") {
                ForEach(controller.builtInMeetingTemplates()) { template in
                    Button {
                        pendingTemplateID = template.id
                    } label: {
                        templateMenuItem(
                            title: template.title,
                            systemImage: template.icon,
                            isSelected: pendingTemplateID == template.id
                        )
                    }
                }
            }

            if !controller.customMeetingTemplates().isEmpty {
                Section("Custom Templates") {
                    ForEach(controller.customMeetingTemplates()) { template in
                        Button {
                            pendingTemplateID = template.id
                        } label: {
                            let resolved = MeetingTemplates.customDefinition(from: template)
                            templateMenuItem(
                                title: template.name,
                                systemImage: resolved.icon,
                                isSelected: pendingTemplateID == template.id
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Manage Templates…") {
                controller.showMeetingTemplatesManager()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName(forSelectionOn: meeting, appliedTemplate: appliedTemplate))
                    .font(.system(size: 10))
                Text(labelForSelection(on: meeting, appliedTemplate: appliedTemplate))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 5)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func contentToolbar(for meeting: MeetingRecord) -> some View {
        HStack {
            Spacer()

            retranscribeAction(for: meeting)
            exportMenu(for: meeting)

            Button(action: {
                controller.copyToClipboard(activeCopyText(for: meeting))
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copyButtonLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .fill(MuesliTheme.accent.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.accent.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    @ViewBuilder
    private func manualNotesToolbar(for meeting: MeetingRecord) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if canEditManualNotes(for: meeting) {
                Text(manualNotesSaveStatus.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            Spacer()

            markdownToolbarButton(systemImage: "textformat.size", label: "Heading") {
                manualEditorCommand = MarkdownEditorCommand(kind: .heading)
            }
            markdownToolbarButton(systemImage: "bold", label: "Bold") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bold)
            }
            markdownToolbarButton(systemImage: "list.bullet", label: "Bullet") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bullet)
            }
            markdownToolbarButton(systemImage: "checklist", label: "Checkbox") {
                manualEditorCommand = MarkdownEditorCommand(kind: .checkbox)
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    @ViewBuilder
    private func statusChip(for meeting: MeetingRecord) -> some View {
        let isPaused = meeting.status == .recording && appState.isMeetingRecordingPaused
        let label = isPaused ? "Paused" : meeting.status.displayLabel
        let color = isPaused ? MuesliTheme.transcribing : meeting.status.displayColor
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 6)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func recordingControlGroup(for meeting: MeetingRecord) -> some View {
        if meeting.status == .recording {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MuesliTheme.spacing8) {
                    statusChip(for: meeting)
                    pauseResumeRecordingButton
                    stopRecordingButton
                    discardRecordingButton
                }
                .recordingControlsBackground()

                VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                    statusChip(for: meeting)
                    HStack(spacing: MuesliTheme.spacing8) {
                        pauseResumeRecordingButton
                        stopRecordingButton
                        discardRecordingButton
                    }
                    .recordingControlsBackground()
                }
            }
        } else if controller.canDeleteMeeting(meeting), meeting.status == .noteOnly || meeting.status == .failed {
            HStack(spacing: MuesliTheme.spacing8) {
                statusChip(for: meeting)
                deleteButton
            }
        } else {
            statusChip(for: meeting)
        }
    }

    @ViewBuilder
    private func markdownToolbarButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MuesliTheme.textSecondary)
            .frame(width: 34, height: 30)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    @ViewBuilder
    private func exportMenu(for meeting: MeetingRecord) -> some View {
        let currentContent: MeetingExportContent = documentMode == .transcript ? .transcript : .notes
        let currentLabel = documentMode == .transcript ? "Export Transcript" : "Export Notes"
        Menu {
            Button {
                MeetingExporter.export(meeting: meeting, content: currentContent)
            } label: {
                Label(currentLabel, systemImage: documentMode == .transcript ? "text.quote" : "doc.text")
            }
            Button {
                MeetingExporter.export(meeting: meeting, content: .fullMeeting)
            } label: {
                Label("Export Full Meeting", systemImage: "doc.on.doc")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("Export")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(MuesliTheme.accent.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isEditingNotes || isEditingTranscript)
    }

    private func templateMenuItem(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : systemImage)
                .frame(width: 12)
            Text(title)
        }
    }

    @ViewBuilder
    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 5)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        iconButton("trash", label: "Delete") {
            showDeleteConfirmation = true
        }
    }

    private var pauseResumeRecordingButton: some View {
        let isPaused = appState.isMeetingRecordingPaused
        return Button {
            controller.toggleMeetingRecordingPause()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isPaused ? "Resume" : "Pause")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isPaused ? MuesliTheme.backgroundBase : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(isPaused ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isPaused ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!appState.isMeetingRecording)
        .help(isPaused ? "Resume recording" : "Pause recording")
    }

    private var stopRecordingButton: some View {
        Button {
            if let meeting {
                flushTitleSave(meetingID: meeting.id)
            }
            controller.stopMeetingRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(MuesliTheme.recording)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(!appState.isMeetingRecording)
        .help("Stop recording")
    }

    private var discardRecordingButton: some View {
        iconButton("xmark", label: "Discard") {
            controller.discardMeetingWithConfirmation()
        }
    }

    @ViewBuilder
    private func templateChip(for snapshot: MeetingTemplateSnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconName(for: snapshot))
                .font(.system(size: 10))
            Text(snapshot.name)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(MuesliTheme.accent)
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 4)
        .background(MuesliTheme.accentSubtle)
        .clipShape(Capsule())
    }

    private var transcriptCTA: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if hasApiKey {
                Image(systemName: "sparkles")
                    .foregroundStyle(MuesliTheme.accent)
                Text("Use \(primarySummaryActionLabel) to turn this raw transcript into AI meeting notes and a cleaned-up title.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            } else {
                Image(systemName: "key.fill")
                    .foregroundStyle(MuesliTheme.accent)
                Text("Add your API key in Settings to generate meeting notes")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Spacer()
                Button("Open Settings") {
                    controller.openHistoryWindow(tab: .settings)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private var hasApiKey: Bool {
        let config = appState.config
        if appState.selectedMeetingSummaryBackend == .chatGPT {
            return appState.isChatGPTAuthenticated
        } else if appState.selectedMeetingSummaryBackend == .openAI {
            return !config.openAIAPIKey.isEmpty || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        } else {
            return !config.openRouterAPIKey.isEmpty || ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil
        }
    }

    private var primarySummaryActionLabel: String {
        guard let meeting else { return "Re-summarize" }
        return primarySummaryActionLabel(for: meeting)
    }

    private var copyButtonLabel: String {
        "Copy"
    }

    private var editButtonLabel: String {
        if isEditingNotes || isEditingTranscript {
            return "Done"
        }
        return documentMode == .transcript ? "Edit Transcript" : "Edit Notes"
    }

    private func primarySummaryActionLabel(for meeting: MeetingRecord) -> String {
        hasPendingTemplateChange(for: meeting) ? "Apply Template" : "Re-summarize"
    }

    private func activeCopyText(for meeting: MeetingRecord) -> String {
        switch documentMode {
        case .notes:
            return isEditingNotes ? editableNotes : Self.notesContent(for: meeting)
        case .transcript:
            return isEditingTranscript ? editableTranscript : meeting.rawTranscript
        }
    }

    private func isRawTranscript(_ meeting: MeetingRecord) -> Bool {
        meeting.notesState != .structuredNotes
    }

    private func hasPendingTemplateChange(for meeting: MeetingRecord) -> Bool {
        resolvedPendingTemplateDefinition(for: meeting).id != controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func labelForSelection(on meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return appliedTemplate.name
        }
        return resolvedPendingTemplateDefinition(for: meeting).title
    }

    private func iconName(forSelectionOn meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return iconName(for: appliedTemplate)
        }
        return resolvedPendingTemplateDefinition(for: meeting).icon
    }

    private func iconName(for snapshot: MeetingTemplateSnapshot) -> String {
        switch snapshot.kind {
        case .auto:
            return MeetingTemplates.auto.icon
        case .builtin, .custom:
            return MeetingTemplates.resolveDefinition(
                id: snapshot.id,
                customTemplates: appState.config.customMeetingTemplates
            ).icon
        }
    }

    static func notesContent(for meeting: MeetingRecord) -> String {
        if meeting.status == .noteOnly {
            return meeting.manualNotes
        }
        if meeting.notesState != .structuredNotes {
            return "# \(meeting.title)\n\n## Raw Transcript\n\n\(meeting.rawTranscript)"
        }
        return meeting.formattedNotes
    }

    private static func defaultDocumentMode(for meeting: MeetingRecord) -> MeetingDocumentMode {
        if meeting.status == .noteOnly || meeting.status == .recording || meeting.status == .processing || meeting.status == .failed {
            return .notes
        }
        return meeting.notesState == .structuredNotes
            ? MeetingDocumentMode.notes
            : MeetingDocumentMode.transcript
    }

    private func debounceSaveTitle(meetingID: Int64) {
        titleSaveTask?.cancel()
        let title = editableTitle
        let c = controller
        c.cacheMeetingTitle(id: meetingID, title: title)
        let item = DispatchWorkItem { c.updateMeetingTitle(id: meetingID, title: title) }
        titleSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func flushTitleSave(meetingID: Int64) {
        titleSaveTask?.cancel()
        titleSaveTask = nil
        controller.updateMeetingTitle(id: meetingID, title: editableTitle)
    }

    private func debounceSaveNotes(meetingID: Int64) {
        notesSaveTask?.cancel()
        let notes = editableNotes
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingNotes(id: meetingID, notes: notes) }
        notesSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func debounceSaveTranscript(meetingID: Int64) {
        transcriptSaveTask?.cancel()
        let transcript = editableTranscript
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingTranscript(id: meetingID, transcript: transcript) }
        transcriptSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func saveManualNotes(meetingID: Int64, notes: String) {
        manualNotesSaveStatus = .saving
        controller.cacheMeetingManualNotes(id: meetingID, notes: notes)
        scheduleManualNotesSaveStatusCheck(meetingID: meetingID, notes: notes)
    }

    private func scheduleManualNotesSaveStatusCheck(meetingID: Int64, notes: String) {
        manualNotesSaveStatusTask?.cancel()
        let item = DispatchWorkItem {
            guard loadedMeetingID == meetingID else { return }
            guard editableManualNotes == notes else { return }
            if controller.hasPersistedMeetingManualNotes(id: meetingID, notes: notes) {
                manualNotesSaveStatus = .saved
            }
        }
        manualNotesSaveStatusTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: item)
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(
            get: { summaryErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    summaryErrorMessage = nil
                }
            }
        )
    }

    private var retranscriptionErrorBinding: Binding<Bool> {
        Binding(
            get: { retranscriptionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    retranscriptionErrorMessage = nil
                }
            }
        )
    }

    private var transcriptResummaryPromptBinding: Binding<Bool> {
        Binding(
            get: { transcriptResummaryPromptMeetingID != nil },
            set: { isPresented in
                if !isPresented {
                    transcriptResummaryPromptMeetingID = nil
                }
            }
        )
    }

    private static func shouldPromptForTranscriptResummary(
        hadStructuredNotes: Bool,
        originalTranscript: String?,
        editedTranscript: String
    ) -> Bool {
        guard hadStructuredNotes, let originalTranscript else { return false }
        return originalTranscript != editedTranscript
    }

    private func resummarizeAfterTranscriptEdit() {
        guard let meetingID = transcriptResummaryPromptMeetingID else { return }
        transcriptResummaryPromptMeetingID = nil
        guard let updatedMeeting = controller.meeting(id: meetingID) else { return }
        isSummarizing = true
        controller.resummarize(meeting: updatedMeeting) { [meetingID] result in
            isSummarizing = false
            switch result {
            case .success:
                if let refreshed = controller.meeting(id: meetingID) {
                    syncLocalState(with: refreshed)
                }
            case .failure(let error):
                summaryErrorMessage = error.localizedDescription
            }
        }
    }

    private func resolvedPendingTemplateDefinition(for meeting: MeetingRecord) -> MeetingTemplateDefinition {
        if let resolved = MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates
        ) {
            return resolved
        }
        return MeetingTemplates.resolveDefinition(
            id: controller.meetingTemplateSnapshot(for: meeting).id,
            customTemplates: appState.config.customMeetingTemplates
        )
    }

    private func syncPendingTemplateSelectionIfNeeded(for meeting: MeetingRecord?) {
        guard let meeting else { return }
        guard MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates
        ) == nil else {
            return
        }
        pendingTemplateID = controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func syncLocalState(with meeting: MeetingRecord?) {
        let previousMeetingID = loadedMeetingID
        let meetingChanged = previousMeetingID != meeting?.id
        loadedMeetingID = meeting?.id
        editableTitle = meeting?.title ?? ""
        if meetingChanged || !isEditingNotes {
            editableNotes = meeting.map { Self.notesContent(for: $0) } ?? ""
        }
        if meetingChanged || !isEditingTranscript {
            editableTranscript = meeting?.rawTranscript ?? ""
        }
        if meetingChanged {
            editableManualNotes = meeting?.manualNotes ?? ""
            manualNotesSaveStatus = .saved
            transcriptResummaryPromptMeetingID = nil
            transcriptEditOriginalTranscript = nil
            transcriptEditHadStructuredNotes = false
        } else {
            syncManualNotesState(with: meeting)
        }
        pendingTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        if meetingChanged {
            documentMode = meeting.map(Self.defaultDocumentMode(for:)) ?? .notes
            isEditingNotes = false
            isEditingTranscript = false
        }
    }

    private func syncManualNotesState(with meeting: MeetingRecord?) {
        let persistedManualNotes = meeting?.manualNotes ?? ""
        if manualNotesSaveStatus == .saving, editableManualNotes != persistedManualNotes {
            return
        }
        editableManualNotes = persistedManualNotes
        manualNotesSaveStatus = .saved
    }

    private func formatMeta(_ meeting: MeetingRecord) -> String {
        let time = formatTime(meeting.startTime)
        let duration = formatDuration(meeting.durationSeconds)
        return "\(time)  \u{2022}  \(duration)  \u{2022}  \(meeting.wordCount) words"
    }

    private func formatTime(_ raw: String) -> String {
        StoredTimestampFormatting.displayDateTime(raw)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        return "\(rounded)s"
    }
}

private extension View {
    func recordingControlsBackground() -> some View {
        padding(5)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }
}

private struct MarqueeTitleTextField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    @State private var isHovering = false
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var marqueeOffset: CGFloat = 0
    @State private var marqueeRunID = UUID()
    @FocusState private var isTitleFocused: Bool

    private let titleFont = Font.system(size: 30, weight: .bold)

    var body: some View {
        ZStack(alignment: .leading) {
            TextField("Meeting Title", text: $text)
                .font(titleFont)
                .foregroundStyle(MuesliTheme.textPrimary)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .opacity(shouldShowMarquee ? 0 : 1)
                .focused($isTitleFocused)
                .onSubmit(onSubmit)
                .onChange(of: text) { _, _ in
                    onTextChange()
                    restartMarqueeIfNeeded()
                }
                .onChange(of: isTitleFocused) { _, _ in
                    restartMarqueeIfNeeded()
                }

            Text(text.isEmpty ? "Meeting Title" : text)
                .font(titleFont)
                .fontWeight(.bold)
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: marqueeOffset)
                .opacity(shouldShowMarquee ? 1 : 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TitleContainerWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .overlay(
            Text(text.isEmpty ? "Meeting Title" : text)
                .font(titleFont)
                .fontWeight(.bold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TitleContentWidthPreferenceKey.self, value: proxy.size.width)
                    }
                )
        )
        .onPreferenceChange(TitleContainerWidthPreferenceKey.self) { width in
            containerWidth = width
            restartMarqueeIfNeeded()
        }
        .onPreferenceChange(TitleContentWidthPreferenceKey.self) { width in
            contentWidth = width
            restartMarqueeIfNeeded()
        }
        .onHover { hovering in
            isHovering = hovering
            restartMarqueeIfNeeded()
        }
    }

    private var overflowDistance: CGFloat {
        max(contentWidth - containerWidth, 0)
    }

    private var shouldShowMarquee: Bool {
        isHovering && !isTitleFocused && overflowDistance > 8
    }

    private func restartMarqueeIfNeeded() {
        let runID = UUID()
        marqueeRunID = runID
        guard shouldShowMarquee else {
            withAnimation(.easeOut(duration: 0.18)) {
                marqueeOffset = 0
            }
            return
        }

        marqueeOffset = 0
        let distance = overflowDistance + 28
        let duration = min(max(Double(distance) / 42.0, 3.0), 12.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard marqueeRunID == runID, shouldShowMarquee else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                marqueeOffset = -distance
            }
        }
    }
}

private struct TitleContainerWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TitleContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TranscriptChatMessage: Identifiable, Equatable {
    let id: Int
    let timestamp: String?
    let speaker: String?
    let text: String

    var isUser: Bool {
        speaker?.localizedCaseInsensitiveCompare("You") == .orderedSame
    }

    static func messages(from transcript: String) -> [TranscriptChatMessage] {
        let normalized = transcript.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var messages: [TranscriptChatMessage] = []
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parsed = parseLine(line, id: messages.count)
            messages.append(parsed)
        }

        return messages
    }

    private static func parseLine(_ line: String, id: Int) -> TranscriptChatMessage {
        if line.hasPrefix("["),
           let timestampEnd = line.firstIndex(of: "]") {
            let timestamp = String(line[line.index(after: line.startIndex)..<timestampEnd])
            let remainderStart = line.index(after: timestampEnd)
            let remainder = line[remainderStart...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerText = splitSpeakerAndText(remainder)
            return TranscriptChatMessage(
                id: id,
                timestamp: timestamp.isEmpty ? nil : timestamp,
                speaker: speakerText.speaker,
                text: speakerText.text
            )
        }

        let speakerText = splitSpeakerAndText(line)
        return TranscriptChatMessage(
            id: id,
            timestamp: nil,
            speaker: speakerText.speaker,
            text: speakerText.text
        )
    }

    private static func splitSpeakerAndText(_ text: String) -> (speaker: String?, text: String) {
        guard let separator = text.firstIndex(of: ":") else {
            return (nil, text)
        }

        let candidate = text[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelySpeakerLabel(candidate) else {
            return (nil, text)
        }

        let bodyStart = text.index(after: separator)
        let body = text[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (candidate, body.isEmpty ? text : body)
    }

    private static func isLikelySpeakerLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 32 else { return false }
        if label.localizedCaseInsensitiveCompare("You") == .orderedSame { return true }
        if label.localizedCaseInsensitiveCompare("Others") == .orderedSame { return true }
        if label.range(of: #"^Speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }
}

private struct MeetingTranscriptView: View {
    let transcript: String
    @State private var messages: [TranscriptChatMessage]

    init(transcript: String) {
        self.transcript = transcript
        _messages = State(initialValue: TranscriptChatMessage.messages(from: transcript))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                if messages.isEmpty {
                    Text("No transcript available")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(maxWidth: 860, alignment: .leading)
                        .padding(MuesliTheme.spacing24)
                } else {
                    ForEach(messages) { message in
                        TranscriptChatBubble(message: message)
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing24)
            .padding(.vertical, MuesliTheme.spacing16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: transcript) { _, newTranscript in
            messages = TranscriptChatMessage.messages(from: newTranscript)
        }
    }
}

private struct TranscriptChatBubble: View {
    let message: TranscriptChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: MuesliTheme.spacing8) {
            if message.isUser {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let metadata = metadata {
                    Text(metadata)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .textSelection(.enabled)
                }
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 8)
            .background(message.isUser ? MuesliTheme.accent.opacity(0.18) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(message.isUser ? MuesliTheme.accent.opacity(0.25) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .frame(maxWidth: 680, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private var metadata: String? {
        switch (message.speaker, message.timestamp) {
        case let (speaker?, timestamp?):
            return "\(speaker) \(timestamp)"
        case let (speaker?, nil):
            return speaker
        case let (nil, timestamp?):
            return timestamp
        case (nil, nil):
            return nil
        }
    }
}

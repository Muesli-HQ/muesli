import SwiftUI

struct FailedDictationsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var expandedID: UUID?
    @State private var pendingDiscard: FailedDictation?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if !appState.failedDictations.isEmpty {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Text("Recordings to recover")
                    .font(MuesliTheme.callout())
                Text("Failed recordings stay on this Mac until recovered or discarded. Retry uses your selected local model and saves text to history.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                        ForEach(appState.failedDictations) { record in
                            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                                HStack {
                                    Button {
                                        expandedID = expandedID == record.id ? nil : record.id
                                    } label: {
                                        Label(record.startedAt.formatted(date: .abbreviated, time: .shortened),
                                              systemImage: expandedID == record.id ? "chevron.down" : "chevron.right")
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                    if appState.recoveringDictationID == record.id {
                                        ProgressView().controlSize(.small)
                                        Button("Cancel") { controller.cancelDictationRecovery() }
                                    } else {
                                        Button("Retry locally") { controller.retryFailedDictation(record) }
                                            .disabled(appState.recoveringDictationID != nil || appState.dictationState != .idle
                                                      || appState.activeAudioImportCount > 0 || appState.modelFileMutationCount > 0
                                                      || appState.isMeetingRecording || appState.isMeetingStarting)
                                        Button("Discard", role: .destructive) { pendingDiscard = record }
                                            .disabled(appState.recoveringDictationID != nil)
                                    }
                                }
                                if expandedID == record.id {
                                    Text(record.failureMessage)
                                        .font(MuesliTheme.caption())
                                        .foregroundStyle(MuesliTheme.textSecondary)
                                    if let partial = record.partialTranscript {
                                        Text("Available transcript (may be incomplete)")
                                            .font(MuesliTheme.caption())
                                        Text(partial).textSelection(.enabled)
                                    }
                                    MeetingRecordingPlayerView(recordingPath: controller.failedDictationAudioURL(record).path)
                                    Button("Show recording in Finder") { controller.revealFailedDictation(record) }
                                }
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .frame(height: min(contentHeight, 200))
            }
            .font(MuesliTheme.body())
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .confirmationDialog("Discard this failed recording?", isPresented: Binding(
                get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }
            ), titleVisibility: .visible, presenting: pendingDiscard) { record in
                Button("Discard recording", role: .destructive) {
                    controller.discardFailedDictation(record)
                    pendingDiscard = nil
                }
            }
        }
    }
}

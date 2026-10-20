import MuesliCore
import SwiftUI

struct MeetingSpeakerEditorView: View {
    let meeting: MeetingRecord
    let controller: MuesliController
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var model = MeetingSpeakerEditorModel()
    @State private var player = MeetingSpeakerSamplePlayer()
    @State private var query = ""
    @State private var names: [MeetingSpeakerKey: String] = [:]
    @State private var newName = ""
    @State private var selectedTurn: UUID?
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var target: MeetingSpeakerKey?
    @State private var mergeSource: MeetingSpeakerKey?
    @State private var mergeTarget: MeetingSpeakerKey?

    private var captureActive: Bool {
        appState.isMeetingRecording || appState.isMeetingStarting
            || appState.meetingRetranscriptions.values.contains(where: \.isRunning)
            || !controller.canEditMeetingSpeakers
    }
    private var blocked: Bool { captureActive || model.isBusy }
    private var state: MeetingSpeakerState? { model.snapshot?.state }
    private var speakers: [MeetingSpeaker] { state?.activeSpeakers ?? [] }
    private var labels: [MeetingSpeakerKey: String] { state?.labels ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting speakers").font(.title2)
                Spacer()
                Button("Undo correction") { apply(.undo) }
                    .disabled(blocked || state?.canUndoCorrection != true)
                    .keyboardShortcut("z", modifiers: [.command, .option])
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.isBusy)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            if captureActive { Text("Finish audio capture and processing before correcting speakers.").foregroundStyle(.secondary) }
            if let error = model.error ?? player.error { Text(error).foregroundStyle(.red) }
            if let state {
                TextField("Find a name or spoken words", text: $query)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(speakers) { speaker in speakerRow(speaker, state: state) }
                        HStack {
                            TextField("New speaker name", text: $newName)
                            Button("Add speaker") {
                                apply(.addSpeaker(newName, state.speakers.first?.key.channel ?? .system))
                            }.disabled(blocked || MeetingSpeakerState.safeLabel(newName).isEmpty)
                        }
                        Divider()
                        ForEach(model.matchingTurns) { turn in
                            HStack(alignment: .top) {
                                Button {
                                    selectedTurn = turn.id; selection = NSRange(location: 0, length: 0)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text("\(turn.timestamp) · \(labels[turn.speaker] ?? "Unknown")").font(.caption)
                                        Text(turn.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.buttonStyle(.plain)
                                Menu("Assign block") {
                                    ForEach(MeetingSpeakerEditorModel.assignableSpeakers(speakers, for: turn)) { speaker in
                                        Button(labels[speaker.key] ?? speaker.fallbackLabel) { apply(.reassign(turn.id, to: speaker.key)) }
                                    }
                                }.disabled(blocked)
                            }.padding(8).background(selectedTurn == turn.id ? MuesliTheme.surfaceSelected : MuesliTheme.surfacePrimary)
                        }
                    }
                }
                if let turn = state.turns.first(where: { $0.id == selectedTurn }) {
                    Text("Select words in this block. Playback timing remains at the original block level.").font(.caption).foregroundStyle(.secondary)
                    MeetingSpeakerSelectionView(text: turn.text, selection: $selection).id(turn.id).frame(height: 100)
                    HStack {
                        Picker("Assign to", selection: $target) {
                            Text("Choose speaker").tag(nil as MeetingSpeakerKey?)
                            ForEach(speakers) { speaker in Text(labels[speaker.key] ?? speaker.fallbackLabel).tag(Optional(speaker.key)) }
                        }
                        Button("Assign selection") {
                            if let target { apply(.reassignSelection(turn.id, selection, to: target)) }
                        }.disabled(blocked || target == nil || selection.length == 0)
                    }
                }
            } else if !model.isBusy {
                Text("This transcript has no current speaker mapping. Its text is preserved. Re-transcribe retained audio to create a new mapping.")
                if controller.canRetranscribeMeeting(meeting), meeting.savedRecordingPath != nil {
                    Button("Re-transcribe retained audio") { dismiss(); controller.retranscribe(meeting: meeting) }
                }
            }
            HStack { Button("Reload editor") { reload() }.disabled(model.isBusy); Spacer() }
        }
        .padding(20).frame(minWidth: 680, minHeight: 620)
        .task(id: meeting.id) { await model.load(id: meeting.id, controller: controller) }
        .task(id: MeetingSpeakerSearchInput(
            query: query,
            version: model.snapshot?.version,
            speakerRevision: model.snapshot?.state.revision
        )) {
            await model.updateMatchingTurns(MeetingSpeakerSearchInput(
                query: query,
                version: model.snapshot?.version,
                speakerRevision: model.snapshot?.state.revision
            ))
        }
        .onChange(of: captureActive) { _, active in if active { player.stop(); model.cancelPendingPresentation() } }
        .onDisappear { player.stop(); model.cancelPendingPresentation() }
        .confirmationDialog("Combine speaker identities?", isPresented: Binding(
            get: { mergeSource != nil && mergeTarget != nil }, set: { if !$0 { mergeSource = nil; mergeTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Combine speakers") {
                if let source = mergeSource, let target = mergeTarget { apply(.merge(source, into: target)) }
                mergeSource = nil; mergeTarget = nil
            }
            Button("Cancel", role: .cancel) { mergeSource = nil; mergeTarget = nil }
        } message: { Text("Their blocks will use \(mergeTarget.flatMap { labels[$0] } ?? "the selected speaker"). The surviving identity keeps its name and colour.") }
    }

    private func speakerRow(_ speaker: MeetingSpeaker, state: MeetingSpeakerState) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Circle().fill(MeetingSpeakerStyle.colour(
                    for: speaker.key, isSelf: speaker.paletteIsSelf ?? speaker.isSelf, isPerson: true
                )).frame(width: 10, height: 10)
                Text(labels[speaker.key] ?? speaker.fallbackLabel).font(.headline)
                Spacer()
                Button(player.playingKey == speaker.key ? "Stop sample" : "Play sample") {
                    if player.playingKey == speaker.key { player.stop() }
                    else if let range = model.samples[speaker.key], let path = meeting.savedRecordingPath {
                        Task { await player.play(key: speaker.key, range: range, path: path) }
                    }
                }
                .disabled(blocked || meeting.savedRecordingPath == nil || model.samples[speaker.key] == nil)
                .help(meeting.savedRecordingPath == nil ? "No retained recording is available." :
                    model.samples[speaker.key] == nil ? "No isolated excerpt is available for this speaker." :
                    "Plays up to six seconds of isolated speech after recording ends.")
                .accessibilityLabel("Play sample for \(labels[speaker.key] ?? speaker.fallbackLabel)")
                Menu("Combine with") {
                    ForEach(speakers.filter { $0.key != speaker.key }) { other in
                        Button(labels[other.key] ?? other.fallbackLabel) { mergeSource = speaker.key; mergeTarget = other.key }
                    }
                }.disabled(blocked || speakers.count < 2)
            }
            HStack {
                TextField("Name for \(speaker.fallbackLabel)", text: Binding(
                    get: { names[speaker.key] ?? speaker.assignment?.name ?? "" }, set: { names[speaker.key] = $0 }))
                Button("Apply name") { apply(.rename(speaker.key, names[speaker.key] ?? speaker.assignment?.name ?? "")) }.disabled(blocked)
                Button("Reset name") { apply(.resetName(speaker.key)) }.disabled(blocked || (speaker.assignment == nil && speaker.selfProvenance == nil))
                if speaker.selfProvenance != nil || (speaker.assignment != nil && speaker.assignment?.provenance != .manual) {
                    Button("Reject suggestion") { apply(.declineName(speaker.key)) }.disabled(blocked)
                }
            }
        }
    }

    private func reload() { player.stop(); names = [:]; Task { await model.load(id: meeting.id, controller: controller) } }
    private func apply(_ action: MeetingSpeakerCorrection) {
        player.stop()
        Task {
            guard await model.apply(action, id: meeting.id, controller: controller) else { return }
            switch action {
            case .addSpeaker: newName = ""
            case .rename(let key, _), .resetName(let key), .declineName(let key): names[key] = nil
            case .undo: names = [:]
            default: break
            }
            if let key = target, model.snapshot?.state.activeSpeakers.contains(where: { $0.key == key }) != true { target = nil }
            selection = NSRange(location: 0, length: 0)
        }
    }
}

import SwiftUI
import MuesliCore

struct MeetingChatView: View {
    let appState: AppState
    let controller: MuesliController
    @Bindable var coordinator: MeetingChatCoordinator
    @State private var showHistory = true
    @State private var showScope = false
    @State private var citation: MeetingChatCitation?
    @State private var deletingChat: UUID?
    @State private var renamingChat: UUID?
    @State private var newTitle = ""
    private var scrollAnchor: Binding<UUID?> {
        Binding(get: { coordinator.selectedSessionID.flatMap { coordinator.scrollAnchors[$0] } },
                set: { if let session = coordinator.selectedSessionID { coordinator.scrollAnchors[session] = $0 } })
    }
    @State private var editingDraft: MeetingChatTurn?
    @State private var participantPrompt = false
    @State private var participantName = ""
    @State private var preparedIsDraft = false
    @FocusState private var composerFocused: Bool
    private var requestConfig: AppConfig { coordinator.fastAnswers ? MeetingTextGenerationClient.fastConfiguration(appState.config) : appState.config }
    private var scopeLabel: String {
        switch coordinator.scope.selection {
        case .all: return "All saved meetings"
        case .folder(let id): return "\(appState.folders.first { $0.id == id }?.name ?? "Folder") · This folder only"
        case .meetings(let ids): return "\(ids.count) selected meeting\(ids.count == 1 ? "" : "s")"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showHistory.toggle() } label: { Image(systemName: "sidebar.left") }.help("Toggle chat history")
                Text("Ask Meetings").font(MuesliTheme.title2()); Spacer()
                Button("New Chat", systemImage: "plus") { coordinator.createChat(scope: .init()); composerFocused = true }
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                if showHistory {
                    List(coordinator.sessions, selection: Binding(get: { coordinator.selectedSessionID }, set: { if let id = $0 { coordinator.selectChat(id: id) } })) { session in
                        Text(session.title).lineLimit(2).tag(session.id)
                            .contextMenu {
                                Button("Rename") { renamingChat = session.id; newTitle = session.title }
                                Button("Delete", role: .destructive) { deletingChat = session.id }
                            }
                    }.listStyle(.sidebar).frame(minWidth: 140, idealWidth: 190, maxWidth: 230)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button(scopeLabel, systemImage: "line.3.horizontal.decrease") { showScope = true }.accessibilityIdentifier("meeting-chat-scope")
                        if let start = coordinator.scope.startDate { Text("From \(start.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
                        if let end = coordinator.scope.endDateExclusive { Text("through \(end.addingTimeInterval(-0.001).formatted(date: .abbreviated, time: .omitted))").font(.caption) }
                        Spacer()
                    }.padding(16)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if coordinator.turns.isEmpty {
                                Text("Ask about decisions, details, or next steps across your saved meetings.").font(.title3).padding(.top, 30)
                                if coordinator.sourceChoices.isEmpty { Text("Save a meeting or written note to build your meeting context.").foregroundStyle(.secondary); Button("Open Meetings") { controller.showMeetingsHome() } }
                            }
                            ForEach(Array(coordinator.turns.enumerated()), id: \.element.id) { index, turn in
                                if index == 0 || coordinator.turns[index - 1].scope != turn.scope {
                                    Divider()
                                    Text("Context: " + (turn.scopeLabel ?? "Earlier meeting context")).font(.caption).foregroundStyle(.secondary)
                                }
                                turnView(turn).id(turn.id)
                            }
                        }.scrollTargetLayout().padding(24).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
                    }.scrollPosition(id: scrollAnchor)
                    if let error = coordinator.errorMessage { Text(error).foregroundStyle(.orange).font(.callout).padding(.horizontal, 16) }
                    Divider()
                    composer
                }
            }
        }
        .background(MuesliTheme.backgroundBase)
        .sheet(isPresented: $showScope) { MeetingChatScopePicker(scope: coordinator.scope, folders: appState.folders, meetings: coordinator.sourceChoices, onChange: coordinator.setScope) }
        .sheet(item: $editingDraft) { turn in MeetingChatDraftView(turn: turn) { coordinator.saveDraft(turnID: turn.id, text: $0) } }
        .popover(item: $citation) { source in
            MeetingChatCitationView(citation: source, coordinator: coordinator) {
                guard let sessionID = coordinator.selectedSessionID else { return }
                citation = nil; controller.showMeetingChatSource(.init(citation: source, sessionID: sessionID))
            }
        }
        .alert("Delete this chat?", isPresented: Binding(get: { deletingChat != nil }, set: { if !$0 { deletingChat = nil } })) {
            Button("Delete", role: .destructive) { if let id = deletingChat { coordinator.deleteChat(id: id) }; deletingChat = nil }
            Button("Cancel", role: .cancel) { deletingChat = nil }
        }
        .alert("Rename chat", isPresented: Binding(get: { renamingChat != nil }, set: { if !$0 { renamingChat = nil } })) {
            TextField("Chat title", text: $newTitle)
            Button("Save") { if let id = renamingChat, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { coordinator.renameChat(id: id, title: newTitle) }; renamingChat = nil }
            Button("Cancel", role: .cancel) { renamingChat = nil }
        }
        .alert("Whose next steps?", isPresented: $participantPrompt) {
            TextField("Participant name", text: $participantName)
            Button("Prepare question") { prepare(.myNextSteps, name: participantName) }.disabled(participantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: coordinator.selectedSessionID) { _, _ in citation = nil; preparedIsDraft = false }
        .onChange(of: coordinator.sourceMutationVersion) { _, _ in
            if let draft = editingDraft, !coordinator.turns.contains(where: { $0.id == draft.id && $0.state == .completed }) { editingDraft = nil }
            if let source = citation, !coordinator.turns.flatMap(\.citations).contains(where: { $0.meetingID == source.meetingID && $0.revision == source.revision }) { citation = nil }
        }
        .task { coordinator.reload(); await coordinator.refreshChoices() }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(MeetingChatQuickAction.allCases) { action in Button(action.label) { prepare(action, name: nil) }.disabled(coordinator.isBusy) } }
            }
            HStack {
                Toggle("Fast answers", isOn: $coordinator.fastAnswers).toggleStyle(.checkbox).help("Uses GPT-5.4 Mini for ChatGPT/OpenAI. Other providers keep their configured model.")
                Text("\(MeetingSummaryBackendOption.resolved(requestConfig.meetingSummaryBackend).label) · \(MeetingTextGenerationClient.model(requestConfig))").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("AI Settings") { appState.selectedSettingsPane = .meetings; appState.selectedTab = .settings }
            }
            TextEditor(text: $coordinator.composerDraft).font(MuesliTheme.body()).scrollContentBackground(.hidden)
                .frame(height: 65).focused($composerFocused).accessibilityLabel("Question about saved meetings")
                .onKeyPress(keys: [.return], phases: .down) { press in if press.modifiers.contains(.shift) { return .ignored }; send(); return .handled }
            HStack {
                Text(coordinator.isBusy ? coordinator.phase : "Enter to send · Shift+Enter for a new line").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if coordinator.isBusy { ProgressView().controlSize(.small); Button("Stop") { coordinator.stop() } }
                else { Button("Send", systemImage: "arrow.up") { send() }.buttonStyle(.borderedProminent).disabled(coordinator.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }.padding(16)
    }
    private func send() {
        guard controller.canUseSummaryProvider(MeetingSummaryBackendOption.resolved(requestConfig.meetingSummaryBackend)) else {
            coordinator.errorMessage = "Connect your meeting AI provider in AI Settings. Your question is saved here."; return
        }
        coordinator.send(question: coordinator.composerDraft, config: appState.config, isDraft: preparedIsDraft)
        preparedIsDraft = false
        scrollAnchor.wrappedValue = coordinator.turns.last?.id
    }
    @ViewBuilder private func turnView(_ turn: MeetingChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(turn.question).font(MuesliTheme.headline()).textSelection(.enabled)
            if let answer = turn.originalAnswer {
                Text(Self.attributedAnswer(answer, citations: turn.citations)).textSelection(.enabled).lineSpacing(4)
                    .environment(\.openURL, OpenURLAction { url in
                        let key = String(url.path.dropFirst())
                        guard url.scheme == "muesli-citation", let source = turn.citations.first(where: { $0.sourceKey == key }) else { return .discarded }
                        citation = source; return .handled
                    })
                if let coverage = turn.coverage {
                    Text("\(coverage.isPartialRecap ? "Partial recap · " : "")Searched \(coverage.eligibleMeetingCount) saved meetings; used passages from \(coverage.evidenceMeetingCount).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack { ForEach(Array(turn.citations.enumerated()), id: \.element.id) { index, source in
                    Button("[\(index + 1)] \(source.title)") { citation = source }.lineLimit(1)
                } }
                if let session = coordinator.sessions.first(where: { $0.id == turn.sessionID }) {
                    HStack {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MeetingChatExporter.plainText(turn: turn, session: session, useEditedDraft: false), forType: .string) }
                        Button("Edit draft") { editingDraft = turn }
                        Button("Export") { MeetingChatExporter.export(turn: turn, session: session, useEditedDraft: false) }
                        if turn.editableDraft != nil {
                            Button("Copy draft") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MeetingChatExporter.plainText(turn: turn, session: session, useEditedDraft: true), forType: .string) }
                            Button("Export draft") { MeetingChatExporter.export(turn: turn, session: session, useEditedDraft: true) }
                        }
                    }.font(.caption)
                    if turn.editableDraft != nil { Text("Edited draft saved").font(.caption).foregroundStyle(.secondary) }
                }
            } else if turn.state == .sourceDeleted { Text("Answer removed because a source meeting was deleted").foregroundStyle(.secondary) }
            else if turn.state.isPending { Text("\(turn.state == .finding ? "Finding meeting context" : "Writing answer")…").foregroundStyle(.secondary) }
            else {
                Text(turn.error ?? (turn.state == .stopped ? "Request stopped" : "Request interrupted")).foregroundStyle(.orange)
                Button("Retry") { coordinator.retry(turnID: turn.id, config: appState.config) }.disabled(coordinator.isBusy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func prepare(_ action: MeetingChatQuickAction, name: String?) {
        let prompt = action.prepare(scope: coordinator.scope, now: Date(), calendar: .current, userDisplayName: name)
        if prompt.needsParticipantName { participantName = ""; participantPrompt = true; return }
        if prompt.scope != coordinator.scope { coordinator.setScope(prompt.scope) }
        coordinator.composerDraft = prompt.text; preparedIsDraft = prompt.isDraft; composerFocused = true
    }
    static func attributedAnswer(_ raw: String, citations: [MeetingChatCitation]) -> AttributedString {
        var markdown = MeetingChatClient.displayText(raw)
        for (index, source) in citations.enumerated() { markdown = markdown.replacingOccurrences(of: "[[\(source.sourceKey)]]", with: "[\(index + 1)](muesli-citation:///\(source.sourceKey))") }
        var attributed = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in Array(attributed.runs) {
            if let link = run.link, link.scheme != "muesli-citation" || !citations.contains(where: { String(link.path.dropFirst()) == $0.sourceKey }) { attributed[run.range].link = nil }
        }
        return attributed
    }
}

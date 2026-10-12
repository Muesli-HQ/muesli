import SwiftUI
import MuesliCore

struct MeetingChatView: View {
    let appState: AppState
    let controller: MuesliController
    @Bindable var coordinator: MeetingChatCoordinator
    @State private var showHistory: Bool?
    private var historyIsVisible: Bool { showHistory ?? coordinator.hasChatHistory }
    @State private var showScope = false
    @State private var showModelPicker = false
    @State private var citation: MeetingChatCitation?
    @State private var deletingChat: UUID?
    @State private var renamingChat: UUID?
    @State private var newTitle = ""
    private var scrollAnchor: Binding<UUID?> {
        Binding(get: { coordinator.selectedSessionID.flatMap { coordinator.scrollAnchors[$0] } },
                set: { if let session = coordinator.selectedSessionID { coordinator.scrollAnchors[session] = $0 } })
    }
    @State private var participantPrompt = false
    @State private var participantName = ""
    @State private var preparedIsDraft = false
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var mentionIndex = 0
    @State private var dismissedMention: MeetingChatMentionQuery?
    @State private var composerFocused = false
    @State private var composerFocusRequest = UUID()
    private var mention: MeetingChatMentionQuery? {
        guard !coordinator.isBusy, !coordinator.isUpdatingChat,
              let query = MeetingChatMentionQuery.find(in: coordinator.composerDraft, selection: composerSelection),
              query != dismissedMention else { return nil }
        return query
    }
    private var mentionMatches: [MeetingChatSourceChoice] {
        guard let mention else { return [] }
        return coordinator.sourceChoices.filter {
            mention.query.isEmpty || $0.title.localizedCaseInsensitiveContains(mention.query)
        }
    }
    private var attachedMeetingIDs: [Int64]? {
        if case .meetings(let ids) = coordinator.scope.selection { return ids }
        return nil
    }
    private var requestConfig: AppConfig { appState.config }
    private var thinkingLabel: String? {
        guard [MeetingSummaryBackendOption.chatGPT.backend, MeetingSummaryBackendOption.openAI.backend].contains(requestConfig.meetingSummaryBackend) else { return nil }
        return ReasoningEffortPolicy.resolvedEffort(for: MeetingTextGenerationClient.model(requestConfig), preferred: requestConfig.meetingSummaryReasoningEffort)?.label
    }
    private var scopeLabel: String {
        switch coordinator.scope.selection {
        case .all: return "All saved meetings"
        case .folder(let id): return "\(appState.folders.first { $0.id == id }?.name ?? "Folder") · This folder only"
        case .meetings(let ids):
            if ids.isEmpty { return "No meetings selected" }
            if ids.count == 1, let source = coordinator.sourceChoices.first(where: { $0.id == ids[0] }) { return source.title }
            return "\(ids.count) selected meeting\(ids.count == 1 ? "" : "s")"
        }
    }
    var body: some View {
        // Share one canonical catalog across every setting control on this surface.
        let _ = appState.config
        return chatContent.environment(\.muesliSettingDefinitions, controller.settingsDefinitions())
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if historyIsVisible {
                    history
                    Divider()
                }
                VStack(alignment: .leading, spacing: 0) {
                    contextBar
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            if coordinator.turns.isEmpty { welcome }
                            ForEach(Array(coordinator.turns.enumerated()), id: \.element.id) { index, turn in
                                if index > 0 && coordinator.turns[index - 1].scope != turn.scope {
                                    Label(turn.scopeLabel ?? "Meeting context changed", systemImage: "line.3.horizontal.decrease")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                }
                                turnView(turn).id(turn.id)
                            }
                        }
                        .scrollTargetLayout().padding(24)
                        .frame(maxWidth: 752, alignment: .leading).frame(maxWidth: .infinity)
                    }.scrollPosition(id: scrollAnchor)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            VStack(spacing: 0) {
                                if let error = coordinator.errorMessage {
                                    Label(error, systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                                        .padding(.horizontal, 24).padding(.vertical, 8)
                                }
                                composer
                            }.background(MuesliTheme.backgroundBase)
                        }
                }.frame(minWidth: 320)
            }
        }
        .background(MuesliTheme.backgroundBase)
        .sheet(isPresented: $showScope) { MeetingChatScopePicker(scope: coordinator.scope, folders: appState.folders, meetings: coordinator.sourceChoices) { scope in Task { await coordinator.setScope(scope) } } }
        .popover(item: $citation) { source in
            MeetingChatCitationView(citation: source, coordinator: coordinator) {
                guard let sessionID = coordinator.selectedSessionID else { return }
                citation = nil; controller.showMeetingChatSource(.init(citation: source, sessionID: sessionID))
            }
        }
        .alert("Delete this chat?", isPresented: Binding(get: { deletingChat != nil }, set: { if !$0 { deletingChat = nil } })) {
            Button("Delete", role: .destructive) { if let id = deletingChat { Task { await coordinator.deleteChat(id: id) } }; deletingChat = nil }
            Button("Cancel", role: .cancel) { deletingChat = nil }
        }
        .alert("Rename chat", isPresented: Binding(get: { renamingChat != nil }, set: { if !$0 { renamingChat = nil } })) {
            TextField("Chat title", text: $newTitle)
            Button("Save") { if let id = renamingChat, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { let title = newTitle; Task { await coordinator.renameChat(id: id, title: title) } }; renamingChat = nil }
            Button("Cancel", role: .cancel) { renamingChat = nil }
        }
        .alert("Whose next steps?", isPresented: $participantPrompt) {
            TextField("Participant name", text: $participantName)
            Button("Prepare question") { let name = participantName; Task { await prepare(.myNextSteps, name: name) } }.disabled(participantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: coordinator.selectedSessionID) { _, _ in citation = nil; preparedIsDraft = false }
        .onChange(of: coordinator.composerDraft) { _, _ in dismissedMention = nil }
        .onChange(of: mention) { _, _ in mentionIndex = 0 }
        .onChange(of: coordinator.turns.count) { _, _ in
            if let activeID = coordinator.activeTurnID, coordinator.turns.contains(where: { $0.id == activeID }) {
                scrollAnchor.wrappedValue = activeID
            }
        }
        .onChange(of: coordinator.hasChatHistory) { _, hasHistory in
            if !hasHistory { showHistory = nil }
        }
        .onChange(of: coordinator.sourceMutationVersion) { _, _ in
            if let source = citation, !coordinator.turns.flatMap(\.citations).contains(where: { $0.meetingID == source.meetingID && $0.revision == source.revision }) { citation = nil }
        }
        .task { coordinator.reload(); await coordinator.refreshChoices() }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Button { showHistory = !historyIsVisible } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless).help("Toggle chat history").accessibilityLabel("Toggle chat history")
            Text("Ask Meetings").font(.system(size: 17, weight: .semibold))
            Spacer()
            Button("New chat", systemImage: "square.and.pencil") {
                Task { await coordinator.createChat(scope: .init()); focusComposer() }
            }.disabled(coordinator.isUpdatingChat).help("Start a new conversation")
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversations").font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 16)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(coordinator.sessions) { session in
                        Button { coordinator.selectChat(id: session.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).font(.system(size: 12, weight: .regular)).lineLimit(2)
                                    .foregroundStyle(coordinator.selectedSessionID == session.id ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                                Text(session.updatedAt, format: .dateTime.month(.abbreviated).day())
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                                .background(coordinator.selectedSessionID == session.id ? MuesliTheme.backgroundRaised : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(coordinator.selectedSessionID == session.id ? .isSelected : [])
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { renamingChat = session.id; newTitle = session.title }
                                Button("Delete", systemImage: "trash", role: .destructive) { deletingChat = session.id }
                            }
                    }
                }.padding(.horizontal, 6).padding(.bottom, 12)
            }
        }.frame(minWidth: 145, idealWidth: 180, maxWidth: 200).background(MuesliTheme.backgroundDeep.opacity(0.55))
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            Button { showScope = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle.stack")
                    Text(scopeLabel).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.font(.system(size: 12, weight: .medium))
            }.buttonStyle(.borderless).disabled(coordinator.isUpdatingChat)
                .accessibilityIdentifier("meeting-chat-scope").help("Choose which meetings this chat can search")
            Spacer(minLength: 0)
            if let start = coordinator.scope.startDate {
                Text(start, format: .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary)
            }
            if let end = coordinator.scope.endDateExclusive {
                Text("– " + end.addingTimeInterval(-0.001).formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .background(MuesliTheme.backgroundDeep.opacity(0.65))
    }

    private var welcomeTitle: String {
        if let ids = attachedMeetingIDs {
            if ids.count == 1, let meeting = coordinator.sourceChoices.first(where: { $0.id == ids[0] }) {
                return "Ask about " + meeting.title
            }
            return ids.isEmpty ? "Choose a meeting to get started" : "Ask about these meetings"
        }
        return "What would you like to revisit?"
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(welcomeTitle).font(.system(size: 21, weight: .medium)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                Text("Find decisions and next steps, with links back to your meetings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if coordinator.sourceChoices.isEmpty {
                Button("Open Meetings", systemImage: "rectangle.stack") { controller.showMeetingsHome() }
            } else if coordinator.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 6) {
                    ForEach(MeetingChatQuickAction.allCases) { action in
                        Button { Task { await prepare(action, name: appState.config.userName) } } label: {
                            HStack(spacing: 6) {
                                Text(action.label).font(.system(size: 12))
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }.padding(.horizontal, 10).padding(.vertical, 9)
                                .background(MuesliTheme.backgroundRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(coordinator.isUpdatingChat)
                    }
                }.frame(maxWidth: 430)
            }
        }.padding(.top, 20).padding(.bottom, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let mention { mentionSuggestions(mention) }
            if coordinator.isBusy && coordinator.activeTurnID == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(coordinator.phase.isEmpty ? "Saving question" : coordinator.phase).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 4).padding(.bottom, 3)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let ids = attachedMeetingIDs { attachmentChips(ids) }
                ZStack(alignment: .topLeading) {
                    if coordinator.composerDraft.isEmpty {
                        Text(coordinator.turns.isEmpty ? "Ask a question, or @ to attach a meeting…" : "Ask a follow-up, or @ to add context…")
                            .foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
                    }
                    MeetingChatComposerEditor(text: $coordinator.composerDraft, selection: $composerSelection,
                                              focusRequest: composerFocusRequest, onFocus: { composerFocused = $0 }, onKey: handleComposerKey)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Question about saved meetings. Type @ to attach a meeting.")

                }
                HStack(spacing: 10) {
                    Button { insertMentionTrigger() } label: { Image(systemName: "at") }
                        .buttonStyle(.borderless).help("Attach a meeting with @")
                        .accessibilityLabel("Attach a meeting").disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                    Button { showModelPicker = true } label: {
                        HStack(spacing: 5) {
                            Text(MeetingTextGenerationClient.model(requestConfig)).lineLimit(1)
                            if let thinkingLabel { Text("· " + thinkingLabel).foregroundStyle(.secondary).lineLimit(1) }
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }.font(.caption)
                    }.buttonStyle(.borderless).disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                        .help("Choose the model and thinking level shared by meeting chats and summaries")
                        .accessibilityLabel("Meeting AI model and thinking level")
                        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                            MeetingChatModelPicker(appState: appState, controller: controller)
                        }
                    Spacer(minLength: 4)
                    if !coordinator.turns.isEmpty {
                        Menu {
                            ForEach(MeetingChatQuickAction.allCases) { action in
                                Button(action.label) { Task { await prepare(action, name: appState.config.userName) } }
                            }
                        } label: { Image(systemName: "text.badge.plus") }
                            .menuStyle(.borderlessButton).fixedSize().help("Prepare a question")
                            .accessibilityLabel("Prepare a question").disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                    }
                    if coordinator.isBusy {
                        Button { coordinator.stop() } label: { Image(systemName: "stop.fill").frame(width: 20, height: 24) }
                            .help("Stop answer").accessibilityLabel("Stop answer")
                    } else {
                        Button { send() } label: { Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(width: 20, height: 24) }
                            .buttonStyle(.borderedProminent).tint(MuesliTheme.accent)
                            .help("Send question").accessibilityLabel("Send question")
                            .disabled(coordinator.isUpdatingChat || coordinator.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding(10).background(MuesliTheme.backgroundRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(composerFocused ? MuesliTheme.accent.opacity(0.45) : MuesliTheme.surfaceBorder, lineWidth: 1))
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Check the sources for important details.")
                    Spacer()
                    Text("↵ Send · ⇧↵ New line")
                }
                Text("↵ Send · ⇧↵ New line · Check the sources")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: 704).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
    }
    private func attachmentChips(_ ids: [Int64]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !ids.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ids, id: \.self) { id in
                            let source = coordinator.sourceChoices.first { $0.id == id }
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(source?.title ?? "Unavailable meeting").lineLimit(1)
                                Button {
                                    let sessionID = coordinator.selectedSessionID
                                    Task {
                                        guard coordinator.selectedSessionID == sessionID else { return }
                                        _ = await coordinator.removeMeetingFromScope(id: id)
                                    }
                                } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                    .buttonStyle(.borderless).help("Remove \(source?.title ?? "meeting") from context")
                                    .accessibilityLabel("Remove \(source?.title ?? "meeting") from context")
                                    .disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                            }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                                .background(MuesliTheme.backgroundBase, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(MuesliTheme.surfaceBorder, lineWidth: 1))
                        }
                    }
                }
            }
            if ids.isEmpty {
                Text(coordinator.turns.contains(where: { $0.state == .completed && $0.originalAnswer != nil })
                     ? "No meetings selected for new searches. Follow-ups use available conversation context; type @ to look up new details."
                     : "No meetings selected for new searches. Type @ to add meetings, or change context above.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func mentionSuggestions(_ mention: MeetingChatMentionQuery) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Attach a meeting", systemImage: "at").font(.caption.weight(.semibold))
                Spacer()
                Text("↑↓ Choose · ↵ Attach · Esc Close").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            if mentionMatches.isEmpty {
                Text("No saved meetings match “\(mention.query)”.")
                    .font(.callout).foregroundStyle(.secondary).padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                ForEach(Array(mentionMatches.enumerated()), id: \.element.id) { index, meeting in
                    Button { attachMeeting(meeting, mention: mention) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(meeting.startDate, format: .dateTime.month(.abbreviated).day().year())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if attachedMeetingIDs?.contains(meeting.id) == true {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                            .background(index == mentionIndex ? MuesliTheme.surfaceSelected : Color.clear)
                    }.id(index).buttonStyle(.plain).accessibilityLabel("Attach \(meeting.title), \(meeting.startDate.formatted(date: .abbreviated, time: .omitted))")
                }
                        }
                    }.frame(height: CGFloat(min(mentionMatches.count, 3)) * 53)
                        .onChange(of: mentionIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
                }
            }
            if attachedMeetingIDs == nil {
                Divider()
                Text("Attaching a meeting narrows this chat to attached meetings and clears date filters.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
            }
        }.background(MuesliTheme.backgroundBase, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MuesliTheme.surfaceBorder, lineWidth: 1))
            .accessibilityIdentifier("meeting-chat-mention-suggestions")
    }

    private func focusComposer() {
        composerFocused = true
        composerFocusRequest = UUID()
    }

    private func insertMentionTrigger() {
        let text = coordinator.composerDraft
        let ns = text as NSString
        let location = min(max(0, composerSelection.location), ns.length)
        let prefix = ns.substring(to: location)
        let trigger = prefix.isEmpty || prefix.last?.isWhitespace == true ? "@" : " @"
        coordinator.composerDraft = ns.replacingCharacters(in: NSRange(location: location, length: 0), with: trigger)
        composerSelection = NSRange(location: location + (trigger as NSString).length, length: 0)
        dismissedMention = nil; focusComposer()
    }

    private func attachMeeting(_ meeting: MeetingChatSourceChoice, mention: MeetingChatMentionQuery) {
        let original = coordinator.composerDraft
        let sessionID = coordinator.selectedSessionID
        Task {
            guard coordinator.selectedSessionID == sessionID else { return }
            guard await coordinator.addMeetingToScope(id: meeting.id) else { return }
            if coordinator.composerDraft == original {
                coordinator.composerDraft = mention.removing(from: original)
                composerSelection = NSRange(location: mention.range.location, length: 0)
            }
            dismissedMention = nil; focusComposer()
        }
    }

    private func handleComposerKey(_ key: MeetingChatComposerEditor.Key) -> Bool {
        if let mention {
            switch key {
            case .up:
                mentionIndex = max(0, mentionIndex - 1); return true
            case .down:
                mentionIndex = min(max(0, mentionMatches.count - 1), mentionIndex + 1); return true
            case .escape:
                dismissedMention = mention; return true
            case .submit, .tab:
                if mentionMatches.indices.contains(mentionIndex) { attachMeeting(mentionMatches[mentionIndex], mention: mention) }
                return true
            }
        }
        if key == .submit { send(); return true }
        return false
    }

    private func send() {
        guard !coordinator.isBusy, !coordinator.isUpdatingChat else { return }
        guard controller.canUseSummaryProvider(MeetingSummaryBackendOption.resolved(requestConfig.meetingSummaryBackend)) else {
            coordinator.errorMessage = "Connect your meeting AI provider in AI Settings. Your question is saved here."; return
        }
        let question = coordinator.composerDraft; let config = appState.config; let draft = preparedIsDraft; let sessionID = coordinator.selectedSessionID
        Task {
            guard coordinator.selectedSessionID == sessionID else { return }
            await coordinator.send(question: question, config: config, isDraft: draft)
            if coordinator.selectedSessionID == sessionID { scrollAnchor.wrappedValue = coordinator.turns.last?.id }
            else if let turnID = coordinator.activeTurnID, coordinator.turns.contains(where: { $0.id == turnID }) { scrollAnchor.wrappedValue = turnID }
        }
        preparedIsDraft = false
    }
    @ViewBuilder private func turnView(_ turn: MeetingChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Spacer(minLength: 36)
                Text(turn.question).font(MuesliTheme.body()).lineSpacing(4).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 16))
            }
            VStack(alignment: .leading, spacing: 14) {
                if turn.state.isPending {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            MeetingChatWaitingLabel(phase: turn.id == coordinator.activeTurnID && !coordinator.phase.isEmpty
                                 ? coordinator.phase
                                 : (turn.state == .finding ? "Finding meeting context" : "Writing answer"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if turn.id == coordinator.activeTurnID && !coordinator.activities.isEmpty {
                            DisclosureGroup {
                                activityRows.padding(.top, 6)
                            } label: {
                                Text("\(coordinator.activities.count) research steps").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                if turn.id == coordinator.activityTurnID {
                    if !turn.state.isPending && !coordinator.activities.isEmpty {
                        DisclosureGroup {
                            activityRows.padding(.top, 8)
                        } label: {
                            Label("Meeting research · \(coordinator.activities.count) steps", systemImage: "checklist")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    if !visibleReasoningSummaries.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(visibleReasoningSummaries.enumerated()), id: \.offset) { _, summary in
                                    Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.padding(.top, 8)
                        } label: {
                            Label("Reasoning summary", systemImage: "text.alignleft")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                }
                if let answer = turn.originalAnswer {
                    MeetingChatAnswerView(answer: answer, citations: turn.citations)
                        .environment(\.openURL, OpenURLAction { url in
                            let key = String(url.path.dropFirst())
                            guard url.scheme == "muesli-citation", let source = turn.citations.first(where: { $0.sourceKey == key }) else { return .discarded }
                            citation = source; return .handled
                        })
                    if !turn.citations.isEmpty {
                        MeetingChatSourcesView(citations: turn.citations) { citation = $0 }
                    }
                    if let coverage = turn.coverage, coverage.eligibleMeetingCount > 0 {
                        Text("\(coverage.isPartialRecap ? "Partial recap · " : "")\(coverage.eligibleMeetingCount) meeting\(coverage.eligibleMeetingCount == 1 ? "" : "s") in scope")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    answerActions(turn)
                } else if turn.state == .sourceDeleted {
                    Label("Answer removed because a source meeting was deleted", systemImage: "doc.badge.ellipsis")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !turn.state.isPending {
                    Label(turn.error ?? (turn.state == .stopped ? "Request stopped" : "Request interrupted"), systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Try again", systemImage: "arrow.clockwise") {
                        let config = appState.config; Task { await coordinator.retry(turnID: turn.id, config: config) }
                    }.disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleReasoningSummaries: [String] {
        coordinator.reasoningSummaries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var activityRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(coordinator.activities) { activity in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: activity.state == .completed ? "checkmark.circle" : "magnifyingglass")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.title).font(.caption.weight(.medium))
                        if !activity.detail.isEmpty { Text(activity.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func answerActions(_ turn: MeetingChatTurn) -> some View {
        if let session = coordinator.sessions.first(where: { $0.id == turn.sessionID }) {
            HStack(spacing: 14) {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetingChatExporter.plainText(turn: turn, session: session, useEditedDraft: false), forType: .string)
                }
                Menu {
                    Button("Export answer…") { MeetingChatExporter.export(turn: turn, session: session, useEditedDraft: false) }
                    if turn.editableDraft != nil {
                        Button("Copy edited draft") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MeetingChatExporter.plainText(turn: turn, session: session, useEditedDraft: true), forType: .string)
                        }
                        Button("Export edited draft…") { MeetingChatExporter.export(turn: turn, session: session, useEditedDraft: true) }
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                if turn.editableDraft != nil { Image(systemName: "checkmark.circle").help("Edited draft saved").accessibilityLabel("Edited draft saved") }
            }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func prepare(_ action: MeetingChatQuickAction, name: String?) async {
        let prompt = action.prepare(scope: coordinator.scope, now: Date(), calendar: .current, userDisplayName: name)
        if prompt.needsParticipantName { participantName = ""; participantPrompt = true; return }
        guard await coordinator.applyPreparedPrompt(prompt) else { return }
        preparedIsDraft = prompt.isDraft; focusComposer()
    }
    static func attributedAnswer(_ raw: String, citations: [MeetingChatCitation]) -> AttributedString {
        var markdown = MeetingChatClient.displayText(raw)
        for (index, source) in citations.enumerated() { markdown = markdown.replacingOccurrences(of: "[[\(source.sourceKey)]]", with: "[[\(index + 1)]](muesli-citation:///\(source.sourceKey))") }
        var attributed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
        for run in Array(attributed.runs) {
            if let link = run.link, link.scheme != "muesli-citation" || !citations.contains(where: { String(link.path.dropFirst()) == $0.sourceKey }) { attributed[run.range].link = nil }
        }
        return attributed
    }
}

/// Native block layout keeps headings and lists intact; inline parsing shares the
/// citation allowlist with the chat. Model-provided image and web URLs never load.
private struct MeetingChatAnswerView: View {
    let answer: String
    let citations: [MeetingChatCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code).font(.system(size: 12, design: .monospaced)).padding(12)
                    }.background(MuesliTheme.backgroundDeep, in: RoundedRectangle(cornerRadius: 8))
                case .line(let line):
                    lineView(line)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        Text(MeetingChatView.attributedAnswer(cell, citations: citations))
                                            .font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                                            .frame(minWidth: 120, maxWidth: 240, alignment: .leading)
                                            .padding(10)
                                            .background(index == 0 ? MuesliTheme.backgroundRaised : MuesliTheme.backgroundDeep)
                                            .overlay(Rectangle().stroke(MuesliTheme.surfaceBorder, lineWidth: 0.5))
                                    }
                                }
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 8))
                    }.padding(.vertical, 4)
                }
            }
        }.font(MuesliTheme.reading()).lineSpacing(4).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MeetingChatMarkdownBlock] { MeetingChatMarkdownBlock.parse(MeetingChatClient.displayText(answer)) }

    @ViewBuilder private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = min(raw.prefix { $0 == " " }.count / 2, 4)
        if line.isEmpty {
            Color.clear.frame(height: 5)
        } else if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            Text(MeetingChatView.attributedAnswer(String(line[heading.upperBound...]), citations: citations))
                .font(line.hasPrefix("# ") ? MuesliTheme.title3() : MuesliTheme.headline()).padding(.top, 8)
        } else if let list = line.range(of: #"^(?:[-*+] \[[ xX]\] |[-*+] |\d+[.)]\s+)"#, options: .regularExpression) {
            let marker = String(line[..<list.upperBound]).trimmingCharacters(in: .whitespaces)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker.count == 1 ? "•" : marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(MeetingChatView.attributedAnswer(String(line[list.upperBound...]), citations: citations))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(indent) * 16)
        } else if line.hasPrefix("> ") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(MuesliTheme.surfacePrimary).frame(width: 3)
                Text(MeetingChatView.attributedAnswer(String(line.dropFirst(2)), citations: citations)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        } else {
            Text(MeetingChatView.attributedAnswer(raw, citations: citations)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// A small, local block parser. It never interprets HTML or fetches remote content.
enum MeetingChatMarkdownBlock: Equatable {
    case line(String)
    case code(String)
    case table([[String]])

    static func parse(_ markdown: String) -> [Self] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [Self] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                result.append(.code(code.joined(separator: "\n")))
                if index < lines.count { index += 1 }
                continue
            }
            if index + 1 < lines.count, line.contains("|"),
               let header = tableCells(line), let separators = tableCells(lines[index + 1]),
               header.count == separators.count,
               separators.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                var rows = [header]
                index += 2
                while index < lines.count, lines[index].contains("|"),
                      let cells = tableCells(lines[index]), cells.count == header.count {
                    rows.append(cells); index += 1
                }
                result.append(.table(rows))
                continue
            }
            result.append(.line(line)); index += 1
        }
        return result
    }

    private static func tableCells(_ line: String) -> [String]? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        // A trailing escaped pipe is cell content, not a table delimiter.
        if text.hasSuffix("|"), !text.hasSuffix(#"\|"#) { text.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inlineCode = false
        for character in text {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character); escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "`" { inlineCode.toggle(); cell.append(character) }
            else if character == "|" && !inlineCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
            } else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells.count > 1 ? cells : nil
    }
}


/// Caret-aware UTF-16 ranges match NSTextView, including titles after emoji.
struct MeetingChatMentionQuery: Equatable {
    let range: NSRange
    let query: String

    static func find(in text: String, selection: NSRange) -> Self? {
        let ns = text as NSString
        guard selection.length == 0, selection.location >= 0, selection.location <= ns.length else { return nil }
        let prefix = ns.substring(to: selection.location)
        guard let at = prefix.lastIndex(of: "@"), at == prefix.startIndex || prefix[prefix.index(before: at)].isWhitespace else { return nil }
        let query = String(prefix[prefix.index(after: at)...])
        guard query.count <= 80, !query.contains(where: \.isNewline) else { return nil }
        return .init(range: NSRange(at..<prefix.endIndex, in: prefix), query: query)
    }

    func removing(from text: String) -> String {
        let ns = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= ns.length,
              range.length <= ns.length - range.location,
              ns.substring(with: range) == "@" + query else { return text }
        return ns.replacingCharacters(in: range, with: "")
    }
}

/// AppKit supplies reliable caret/IME handling on the app's macOS 14 deployment target.
private struct MeetingChatComposerEditor: NSViewRepresentable {
    enum Key { case up, down, escape, submit, tab }
    @Binding var text: String
    @Binding var selection: NSRange
    var focusRequest: UUID
    let onFocus: (Bool) -> Void
    let onKey: (Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = Editor()
        editor.delegate = context.coordinator
        editor.onKey = onKey
        editor.onFocus = onFocus
        editor.isRichText = false
        editor.allowsUndo = true
        editor.insertionPointColor = .controlAccentColor
        editor.minSize = NSSize(width: 0, height: 34)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 0, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Question about saved meetings. Type @ to attach a meeting.")
        scroll.documentView = editor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(100, proposal.width ?? 400)
        return CGSize(width: width, height: MeetingChatComposerLayout.height(for: text, width: width))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        editor.onKey = onKey
        editor.onFocus = onFocus
        if editor.string != text {
            editor.undoManager?.removeAllActions()
            editor.string = text
        }
        let length = (text as NSString).length
        let safe = NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location)))
        if editor.selectedRange() != safe { editor.setSelectedRange(safe) }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            editor.window?.makeFirstResponder(editor)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MeetingChatComposerEditor
        var isUpdating = false
        var lastFocusRequest: UUID
        init(_ parent: MeetingChatComposerEditor) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }
        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.selection = editor.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let editor = notification.object as? NSTextView else { return }
            parent.selection = editor.selectedRange()
        }
    }
    final class Editor: NSTextView {
        var onKey: ((Key) -> Bool)?
        var onFocus: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { DispatchQueue.main.async { [weak self] in self?.onFocus?(true) } }
            return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { DispatchQueue.main.async { [weak self] in self?.onFocus?(false) } }
            return result
        }
        override func keyDown(with event: NSEvent) {
            guard !hasMarkedText(), event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { super.keyDown(with: event); return }
            let key: Key?
            switch event.keyCode {
            case 126: key = .up
            case 125: key = .down
            case 53: key = .escape
            case 48: key = .tab
            case 36, 76: key = event.modifierFlags.contains(.shift) ? nil : .submit
            default: key = nil
            }
            if let key, onKey?(key) == true { return }
            super.keyDown(with: event)
        }
    }
}


private struct MeetingChatModelPicker: View {
    let appState: AppState
    let controller: MuesliController
    @Environment(\.muesliSettingDefinitions) private var definitions
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false
    @State private var errorMessage: String?

    private var modelSettingID: String? {
        let backend = appState.config.meetingSummaryBackend
        if backend == MeetingSummaryBackendOption.chatGPT.backend { return "summary_chatgpt_model" }
        if backend == MeetingSummaryBackendOption.openAI.backend { return "summary_openai_model" }
        if backend == MeetingSummaryBackendOption.anthropic.backend { return "summary_anthropic_model" }
        if backend == MeetingSummaryBackendOption.claudeCode.backend { return "summary_claude_code_model" }
        if backend == MeetingSummaryBackendOption.openRouter.backend { return "summary_openrouter_model" }
        return nil
    }
    private func snapshot(_ id: String) -> MuesliSetting.Snapshot? {
        definitions.first { $0.id == id }?.snapshot(config: appState.config, source: .manualUI)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Model").font(MuesliTheme.headline())
                Text(MeetingSummaryBackendOption.resolved(appState.config.meetingSummaryBackend).label)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            if let id = modelSettingID, let state = snapshot(id) {
                ScrollView {
                    VStack(spacing: 2) {
                        if !state.choices.contains(where: { $0.id == state.current }) {
                            HStack {
                                Text(state.current.isEmpty ? MeetingTextGenerationClient.model(appState.config) : state.current)
                                Spacer()
                                Image(systemName: "checkmark")
                            }.font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                            Text("Custom model · configured in AI Settings").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        ForEach(state.choices, id: \.id) { choice in
                            Button { apply(id, value: choice.id) } label: {
                                HStack {
                                    Text(choice.label).font(.callout)
                                    Spacer()
                                    if choice.id == state.current { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                                }.padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                                    .background(choice.id == state.current ? MuesliTheme.surfaceSelected.opacity(0.65) : Color.clear)
                            }.buttonStyle(.plain).disabled(state.unavailable[choice.id] != nil)
                                .help(state.unavailable[choice.id] ?? choice.label)
                                .accessibilityAddTraits(choice.id == state.current ? .isSelected : [])
                        }
                    }
                }.frame(maxHeight: 280)
            } else {
                Text(MeetingTextGenerationClient.model(appState.config)).font(.callout).padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let thinking = snapshot("summary_thinking"), !thinking.choices.isEmpty {
                Divider()
                HStack {
                    Text("Thinking level").font(.callout)
                    Spacer()
                    Menu {
                        ForEach(thinking.choices, id: \.id) { choice in
                            Button { apply("summary_thinking", value: choice.id) } label: {
                                if choice.id == thinking.current { Label(choice.label, systemImage: "checkmark") }
                                else { Text(choice.label) }
                            }.disabled(thinking.unavailable[choice.id] != nil)
                        }
                    } label: {
                        Text(thinking.choices.first { $0.id == thinking.current }?.label ?? thinking.current)
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Meeting AI thinking level")
                }.padding(16)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Shared with meeting summaries. Changes apply to your next question.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("AI Settings…", systemImage: "slider.horizontal.3") {
                    dismiss(); appState.selectedSettingsPane = .meetings; appState.selectedTab = .settings
                }.buttonStyle(.borderless).font(.caption)
            }.padding(16)
        }.frame(width: 310).disabled(applying)
            .alert("Setting could not be changed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private func apply(_ id: String, value: String) {
        applying = true
        Task { @MainActor in
            defer { applying = false }
            do { try await controller.applySetting(id, value: value) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

/// Vary only a genuine provider-wait phase; retrieval/tool events retain their real labels.
private struct MeetingChatWaitingLabel: View {
    let phase: String
    @State private var startedAt = Date()
    @State private var phrases = MeetingChatWaitingStatus.phrases.shuffled()
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: startedAt, by: 5)) { timeline in
            Text(MeetingChatWaitingStatus.label(phase: phase, elapsed: timeline.date.timeIntervalSince(startedAt), phrases: phrases))
        }.onChange(of: phase) { _, _ in startedAt = Date() }
    }
}

enum MeetingChatWaitingStatus {
    static let phrases = ["Thinking", "Working through your question", "Preparing your answer", "Putting the answer together"]
    static func label(phase: String, elapsed: TimeInterval, phrases: [String] = MeetingChatWaitingStatus.phrases) -> String {
        guard ["Contacting meeting AI", "Writing answer", "Preparing answer"].contains(phase), !phrases.isEmpty else { return phase }
        return phrases[Int(max(0, elapsed) / 5) % phrases.count] + "…"
    }
}


/// Measure the native font at the available width and cap long drafts for scrolling.
enum MeetingChatComposerLayout {
    static func height(for text: String, width: CGFloat) -> CGFloat {
        let measured = NSAttributedString(string: text + "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 14)])
            .boundingRect(with: NSSize(width: max(80, width - 10), height: CGFloat.greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(144, max(34, ceil(measured.height) + 16))
    }
}

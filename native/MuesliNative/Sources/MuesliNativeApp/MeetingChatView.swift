import SwiftUI
import MuesliCore
import AIElementsSwift

struct MeetingChatView: View {
    let appState: AppState
    let controller: MuesliController
    @Bindable var coordinator: MeetingChatCoordinator
    var embeddedMeetingID: Int64? = nil
    @State private var expanded = false
    @State private var showHistory = false
    private var isEmbedded: Bool { embeddedMeetingID != nil }
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
            .aiElementsTheme(.init(surface: MuesliTheme.backgroundRaised, border: MuesliTheme.surfaceBorder,
                                   accent: MuesliTheme.accent, muted: MuesliTheme.textSecondary,
                                   textFont: { MuesliTheme.font(size: $0, weight: $1) },
                                   heading: MuesliTheme.title3(), subheading: MuesliTheme.headline()))
            .font(MuesliTheme.body())
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if !isEmbedded || expanded {
                header
                    .background(isEmbedded ? MuesliTheme.backgroundDeep : MuesliTheme.backgroundBase)
                    .zIndex(1)
            }
            if isEmbedded && expanded { Divider().overlay(MuesliTheme.surfaceBorder).allowsHitTesting(false) }
            if !isEmbedded && coordinator.turns.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        welcome
                        composer
                        recentChats
                    }.frame(maxWidth: 752).frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            } else {
                if !isEmbedded || (expanded && !coordinator.turns.isEmpty) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(Array(coordinator.turns.enumerated()), id: \.element.id) { index, turn in
                                if (index == 0 && turn.scope != coordinator.scope) ||
                                    (index > 0 && coordinator.turns[index - 1].scope != turn.scope) {
                                    Text(turn.scopeLabel ?? "Meeting context changed")
                                        .font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                                }
                                turnView(turn).id(turn.id)
                            }
                        }.scrollTargetLayout().padding(24)
                            .frame(maxWidth: 752, alignment: .leading).frame(maxWidth: .infinity)
                    }.scrollPosition(id: scrollAnchor)
                        .frame(height: isEmbedded ? 260 : nil)
                        .contentShape(Rectangle())
                        .clipped()
                }
                ZStack {
                    composer
                        .frame(height: isEmbedded && !expanded ? 0 : nil)
                        .opacity(isEmbedded && !expanded ? 0 : 1)
                        .clipped()
                        .allowsHitTesting(!isEmbedded || expanded)
                        .accessibilityHidden(isEmbedded && !expanded)
                    if isEmbedded && !expanded { restingComposer }
                }
            }
        }
        .background(isEmbedded && expanded ? MuesliTheme.backgroundDeep : MuesliTheme.backgroundBase)
        .clipShape(RoundedRectangle(cornerRadius: isEmbedded && expanded ? 20 : 0))
        .overlay {
            if isEmbedded && expanded {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, isEmbedded && expanded ? 16 : 0)
        .padding(.vertical, isEmbedded && expanded ? 12 : 0)
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
        .onChange(of: coordinator.sourceMutationVersion) { _, _ in
            if let source = citation, !coordinator.turns.flatMap(\.citations).contains(where: { $0.meetingID == source.meetingID && $0.revision == source.revision }) { citation = nil }
        }
        .task(id: embeddedMeetingID) {
            // The shared coordinator refreshes history on mutations and source
            // changes; browsing notes must not synchronously reload it again.
            if let id = embeddedMeetingID { coordinator.prepareMeetingDraft(id: id) }
            await coordinator.refreshChoices()
        }
        .onChange(of: coordinator.isBusy || coordinator.isUpdatingChat) { _, busy in
            if !busy, let id = embeddedMeetingID { coordinator.prepareMeetingDraft(id: id) }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            if !isEmbedded && coordinator.selectedSessionID != nil {
                Button { controller.showMeetingChatIndex() } label: {
                    Label { Text("Chat") } icon: { AIIcon(.arrowLeft) }
                }
                .buttonStyle(.plain).help("Back to all chats")
                .accessibilityLabel("Back to Chat")
                Divider().frame(height: 16)
            }
            Button { showHistory.toggle() } label: {
                AIIcon(.clock).frame(width: 32, height: 32).contentShape(Rectangle())
            }
                .buttonStyle(.plain).help("Recent chats").accessibilityLabel("Recent chats")
                .popover(isPresented: $showHistory) { history.frame(width: 280, height: 340) }
            if isEmbedded {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chat").font(MuesliTheme.font(size: 13, weight: .semibold))
                    if let title = coordinator.sessions.first(where: { $0.id == coordinator.selectedSessionID })?.title {
                        Text(title).font(MuesliTheme.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Text(coordinator.sessions.first { $0.id == coordinator.selectedSessionID }?.title ?? "Chat").lineLimit(1).font(MuesliTheme.font(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            if isEmbedded {
                Button { controller.showMeetingChat() } label: {
                    AIIcon(.arrowUpRight).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).help("Open Chat").accessibilityLabel("Open Chat")
                Button { expanded = false } label: {
                    AIIcon(.chevronDown).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).help("Collapse chat").accessibilityLabel("Collapse chat")
            }
            Button {
                coordinator.startDraft(scope: embeddedMeetingID.map { .init(selection: .meetings([$0])) } ?? .init()); focusComposer()
            } label: {
                Label { Text("New chat") } icon: { AIIcon(.squarePen) }
                    .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(coordinator.isBusy || coordinator.isUpdatingChat).help("Start a new conversation")
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversations").font(MuesliTheme.font(size: 11, weight: .medium))
                .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 16)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(coordinator.sessions) { session in
                        Button { coordinator.selectChat(id: session.id); showHistory = false; expanded = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).font(MuesliTheme.font(size: 12, weight: .regular)).lineLimit(2)
                                    .foregroundStyle(coordinator.selectedSessionID == session.id ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                                Text(session.updatedAt, format: .dateTime.month(.abbreviated).day())
                                    .font(MuesliTheme.font(size: 10)).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
                                .background(coordinator.selectedSessionID == session.id ? MuesliTheme.backgroundRaised : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(coordinator.selectedSessionID == session.id ? .isSelected : [])
                            .contextMenu {
                                Button { renamingChat = session.id; newTitle = session.title } label: { Label { Text("Rename") } icon: { AIIcon(.squarePen) } }
                                Button(role: .destructive) { deletingChat = session.id } label: { Label { Text("Delete") } icon: { AIIcon(.trash) } }
                            }
                    }
                }.padding(.horizontal, 6).padding(.bottom, 12)
            }
        }.frame(maxWidth: .infinity).background(MuesliTheme.backgroundDeep.opacity(0.55))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What’s on your mind?")
                .font(MuesliTheme.font(size: 24, weight: .medium)).tracking(-0.5)
            Text("Ask your meetings.").font(MuesliTheme.font(.callout)).foregroundStyle(.secondary)
        }.padding(.horizontal, 24)
    }

    private var recentChats: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { suggestions }
                VStack(alignment: .leading, spacing: 8) { suggestions }
            }
            if !coordinator.sessions.isEmpty {
                Text("Recent chats").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary).padding(.top, 16)
                ForEach(coordinator.sessions) { session in
                    Button { coordinator.selectChat(id: session.id) } label: {
                        HStack(spacing: 12) {
                            AIIcon(.clock).foregroundStyle(.secondary)
                            Text(session.title).lineLimit(1)
                            Spacer()
                            Text(session.updatedAt, format: .dateTime.month(.abbreviated).day()).font(MuesliTheme.font(.caption)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 24)
    }

    private var suggestions: some View {
        ForEach(MeetingChatQuickAction.allCases) { action in
            Button { Task { await prepare(action, name: appState.config.userName) } } label: {
                Text(action.label).font(MuesliTheme.font(.caption)).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(MuesliTheme.backgroundRaised.opacity(0.6), in: Capsule())
            }.buttonStyle(.plain).disabled(coordinator.isBusy || coordinator.isUpdatingChat)
        }
    }

    private var restingComposer: some View {
        HStack(spacing: 12) {
            Button {
                expanded = true
                focusComposer()
            } label: {
                HStack {
                    Text(coordinator.composerDraft.isEmpty
                         ? (coordinator.turns.isEmpty
                            ? (coordinator.scope.selection == .meetings(embeddedMeetingID.map { [$0] } ?? [])
                               ? "Ask about this meeting…" : "Ask your meetings…")
                            : "Continue conversation…")
                         : coordinator.composerDraft)
                        .lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    AIIcon(.chevronUp).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Chat context: " + scopeLabel)
                .accessibilityIdentifier("meeting-chat-expand")
        }.padding(.horizontal, 20).padding(.vertical, 16)
            .background(MuesliTheme.backgroundRaised, in: Capsule())
            .overlay(Capsule().stroke(MuesliTheme.surfaceBorder, lineWidth: 1).allowsHitTesting(false))
            .frame(maxWidth: 704).padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = coordinator.errorMessage {
                Text(error).foregroundStyle(.orange).font(MuesliTheme.font(.callout)).textSelection(.enabled)
            }
            if let mention { mentionSuggestions(mention) }
            if coordinator.isBusy && coordinator.activeTurnID == nil {
                AIShimmer(coordinator.phase.isEmpty ? "Saving question" : coordinator.phase)
                    .padding(.horizontal, 4).padding(.bottom, 3)
            }
            AIPromptInput(isFocused: composerFocused, header: {
                if let ids = attachedMeetingIDs, !ids.isEmpty { attachmentChips(ids) }
            }, editor: {
                ZStack(alignment: .topLeading) {
                    if coordinator.composerDraft.isEmpty {
                        Text(coordinator.turns.isEmpty ? "Ask a question, or @ to attach a meeting…" : "Ask a follow-up, or @ to add context…")
                            .foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
                    }
                    MeetingChatComposerEditor(text: $coordinator.composerDraft, selection: $composerSelection,
                                              focusRequest: isEmbedded && !expanded ? nil : composerFocusRequest, undoIdentity: coordinator.composerUndoIdentity, onFocus: { composerFocused = $0; if $0 && isEmbedded { expanded = true } }, onKey: handleComposerKey)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Question about saved meetings. Type @ to attach a meeting.")

                }
            }, footer: {
                HStack(spacing: 10) {
                    Button { insertMentionTrigger() } label: { AIIcon(.atSign) }
                        .buttonStyle(.borderless).help("Attach a meeting with @")
                        .accessibilityLabel("Attach a meeting").disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                    Button { showScope = true } label: {
                        HStack(spacing: 5) {
                            AIIcon(.slidersHorizontal)
                            if attachedMeetingIDs == nil { Text(scopeLabel).font(MuesliTheme.font(.caption)).lineLimit(1) }
                            if let dates = MeetingChatScopePresentation.dateLabel(coordinator.scope) {
                                Text(dates).font(MuesliTheme.font(.caption)).lineLimit(1)
                            }
                        }
                    }
                        .buttonStyle(.plain).help("Meeting context: " + scopeLabel)
                        .accessibilityLabel("Choose meeting context").accessibilityIdentifier("meeting-chat-scope")
                        .disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                    Spacer(minLength: 4)
                    Button { showModelPicker = true } label: {
                        HStack(spacing: 5) {
                            Text(MeetingTextGenerationClient.model(requestConfig)).lineLimit(1)
                            if let thinkingLabel { Text("· " + thinkingLabel).foregroundStyle(.secondary).lineLimit(1) }
                            AIIcon(.chevronDown, size: 10)
                        }.font(MuesliTheme.font(.caption))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                        .help("Choose the model and thinking level shared by meeting chats and summaries")
                        .accessibilityLabel("Meeting AI model and thinking level")
                        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                            MeetingChatModelPicker(appState: appState, controller: controller)
                        }
                    if !coordinator.turns.isEmpty {
                        Menu {
                            ForEach(MeetingChatQuickAction.allCases) { action in
                                Button(action.label) { Task { await prepare(action, name: appState.config.userName) } }
                            }
                        } label: { AIIcon(.plus) }
                            .menuStyle(.borderlessButton).fixedSize().help("Prepare a question")
                            .accessibilityLabel("Prepare a question").disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                    }
                    if coordinator.isBusy {
                        Button { coordinator.stop() } label: { AIIcon(.square).frame(width: 20, height: 24) }
                            .help("Stop answer").accessibilityLabel("Stop answer")
                    } else {
                        Button { send() } label: {
                            AIIcon(.arrowUp, size: 16)
                                .foregroundStyle(MuesliTheme.onAccent)
                                .frame(width: 32, height: 32)
                                .background(MuesliTheme.accent, in: Circle())
                                .contentShape(Circle())
                        }
                            .buttonStyle(.plain)
                            .opacity(coordinator.isUpdatingChat || coordinator.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                            .accessibilityIdentifier("meeting-chat-send")
                            .help("Send question").accessibilityLabel("Send question")
                            .disabled(coordinator.isUpdatingChat || coordinator.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            })
            Text("↵ Send · ⇧↵ New line")
                .font(MuesliTheme.font(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                            AIAttachment(title: source?.title ?? "Unavailable meeting", onRemove: {
                                let sessionID = coordinator.selectedSessionID
                                Task {
                                    guard coordinator.selectedSessionID == sessionID else { return }
                                    _ = await coordinator.removeMeetingFromScope(id: id)
                                }
                            })
                            .help("Remove \(source?.title ?? "meeting") from context")
                            .disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                        }
                    }
                }.frame(height: 30)
            }

        }
    }

    private func mentionSuggestions(_ mention: MeetingChatMentionQuery) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label { Text("Attach a meeting") } icon: { AIIcon(.atSign) }.font(MuesliTheme.font(.caption).weight(.semibold))
                Spacer()
                Text("↑↓ Choose · ↵ Attach · Esc Close").font(MuesliTheme.font(size: 10)).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            if mentionMatches.isEmpty {
                Text("No saved meetings match “\(mention.query)”.")
                    .font(MuesliTheme.font(.callout)).foregroundStyle(.secondary).padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                ForEach(Array(mentionMatches.enumerated()), id: \.element.id) { index, meeting in
                    Button { attachMeeting(meeting, mention: mention) } label: {
                        HStack(spacing: 10) {
                            AIIcon(.fileText).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.title).font(MuesliTheme.font(size: 13, weight: .medium)).lineLimit(1)
                                Text(meeting.startDate, format: .dateTime.month(.abbreviated).day().year())
                                    .font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if attachedMeetingIDs?.contains(meeting.id) == true {
                                AIIcon(.check).foregroundStyle(.secondary)
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
                    .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary).padding(10)
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

    private var modelContextWindow: Int? {
        guard MeetingSummaryBackendOption.resolved(appState.config.meetingSummaryBackend) == .openRouter else { return nil }
        return appState.openRouterSummaryModels.first { $0.id == appState.config.openRouterModel }?.contextWindowTokens
    }

    private func send() {
        guard !coordinator.isBusy, !coordinator.isUpdatingChat else { return }
        guard controller.canUseSummaryProvider(MeetingSummaryBackendOption.resolved(requestConfig.meetingSummaryBackend)) else {
            coordinator.errorMessage = "Connect your meeting AI provider in AI Settings. Your question is saved here."; return
        }
        let question = coordinator.composerDraft; let config = appState.config; let draft = preparedIsDraft; let sessionID = coordinator.selectedSessionID
        Task {
            guard coordinator.selectedSessionID == sessionID else { return }
            await coordinator.send(question: question, config: config, isDraft: draft, contextWindowTokens: modelContextWindow)
            if coordinator.selectedSessionID == sessionID { scrollAnchor.wrappedValue = coordinator.turns.last?.id }
            else if let turnID = coordinator.activeTurnID, coordinator.turns.contains(where: { $0.id == turnID }) { scrollAnchor.wrappedValue = turnID }
        }
        preparedIsDraft = false
        if isEmbedded { expanded = true }
    }
    @ViewBuilder private func turnView(_ turn: MeetingChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            AIMessage(role: .user) {
                Text(turn.question).font(MuesliTheme.body()).lineSpacing(4).textSelection(.enabled)
            }
            AIMessage(role: .assistant) {
                VStack(alignment: .leading, spacing: 14) {
                    if turn.state.isPending {
                        VStack(alignment: .leading, spacing: 10) {
                            // Streaming reasoning already provides its own thinking indicator.
                            if !(turn.id == coordinator.activityTurnID && coordinator.reasoningIsStreaming && !visibleReasoningSummaries.isEmpty) {
                                MeetingChatWaitingLabel(phase: turn.id == coordinator.activeTurnID && !coordinator.phase.isEmpty
                                     ? coordinator.phase
                                     : (turn.state == .finding ? "Finding meeting context" : "Writing answer"))
                                    .font(MuesliTheme.font(.callout)).foregroundStyle(.secondary)
                            }
                            if turn.id == coordinator.activeTurnID && !coordinator.activities.isEmpty {
                                AIDisclosure(title: "\(coordinator.activities.count) research steps", icon: .search) {
                                    activityRows
                                }
                            }
                        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if turn.id == coordinator.activityTurnID {
                        if !turn.state.isPending && !coordinator.activities.isEmpty {
                            AIDisclosure(title: "Meeting research · \(coordinator.activities.count) steps", icon: .search) {
                                activityRows
                            }
                        }
                        if !visibleReasoningSummaries.isEmpty {
                            AIReasoning(summary: visibleReasoningSummaries.joined(separator: "\n\n"),
                                        state: coordinator.reasoningIsStreaming ? .streaming : .completed)
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
                        answerActions(turn)
                    } else if turn.state == .sourceDeleted {
                        Label { Text("Answer removed because a source meeting was deleted") } icon: { AIIcon(.fileText) }
                            .font(MuesliTheme.font(.callout)).foregroundStyle(.secondary)
                    } else if !turn.state.isPending {
                        Label { Text(turn.error ?? (turn.state == .stopped ? "Request stopped" : "Request interrupted")) } icon: { AIIcon(.circleAlert) }
                            .font(MuesliTheme.font(.callout)).foregroundStyle(.secondary)
                        Button {
                            let config = appState.config; Task { await coordinator.retry(turnID: turn.id, config: config, contextWindowTokens: modelContextWindow) }
                        } label: { Label { Text("Try again") } icon: { AIIcon(.rotateCcw) } }.disabled(coordinator.isBusy || coordinator.isUpdatingChat)
                    }
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
                AITool(title: activity.title, state: toolState(activity.state),
                       input: activity.detail.isEmpty ? nil : activity.detail,
                       output: activity.output, error: activity.error)
            }
        }
    }

    private func toolState(_ state: MeetingChatActivity.State) -> AIToolState {
        switch state {
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    @ViewBuilder private func answerActions(_ turn: MeetingChatTurn) -> some View {
        if let session = coordinator.sessions.first(where: { $0.id == turn.sessionID }) {
            HStack(spacing: 14) {
                MeetingChatCopyButton(text: MeetingChatExporter.clipboardText(turn: turn))
                Menu {
                    Button("Export answer…") { MeetingChatExporter.export(turn: turn, session: session, useEditedDraft: false) }
                    if turn.editableDraft != nil {
                        Button("Copy edited draft") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MeetingChatExporter.clipboardText(turn: turn, useEditedDraft: true), forType: .string)
                        }
                        Button("Export edited draft…") { MeetingChatExporter.export(turn: turn, session: session, useEditedDraft: true) }
                    }
                } label: { Label { Text("Export") } icon: { AIIcon(.download) } }.menuStyle(.borderlessButton).fixedSize()
                if turn.editableDraft != nil { AIIcon(.check).help("Edited draft saved").accessibilityLabel("Edited draft saved") }
            }.buttonStyle(.borderless).font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
        }
    }
    private func prepare(_ action: MeetingChatQuickAction, name: String?) async {
        let prompt = action.prepare(scope: coordinator.scope, now: Date(), calendar: .current, userDisplayName: name)
        if prompt.needsParticipantName { participantName = ""; participantPrompt = true; return }
        guard await coordinator.applyPreparedPrompt(prompt) else { return }
        preparedIsDraft = prompt.isDraft; focusComposer()
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
    var focusRequest: UUID?
    var undoIdentity: UUID
    let onFocus: (Bool) -> Void
    let onKey: (Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = Editor()
        editor.string = text
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
        editor.font = AppFonts.font(size: 14)
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
        MeetingChatComposerTextSync.apply(text, to: editor, resetUndo: context.coordinator.undoIdentity != undoIdentity)
        context.coordinator.undoIdentity = undoIdentity
        let length = (text as NSString).length
        let safe = NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location)))
        if editor.selectedRange() != safe { editor.setSelectedRange(safe) }
        if focusRequest == nil, editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
        if let focusRequest, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            editor.requestComposerFocus()
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MeetingChatComposerEditor
        var isUpdating = false
        var lastFocusRequest: UUID?
        var undoIdentity: UUID
        init(_ parent: MeetingChatComposerEditor) {
            self.parent = parent
            lastFocusRequest = nil
            undoIdentity = parent.undoIdentity
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
        private var pendingFocus = false
        func requestComposerFocus() {
            pendingFocus = true
            applyPendingFocus()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyPendingFocus()
        }
        private func applyPendingFocus() {
            guard pendingFocus, let window else { return }
            if window.makeFirstResponder(self) { pendingFocus = false }
        }
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


private struct MeetingChatCopyButton: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copyID: UUID?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text, forType: .string) {
                copyID = UUID()
            }
        } label: {
            Label {
                Text(copyID == nil ? "Copy" : "Copied")
            } icon: {
                AIIcon(copyID == nil ? .copy : .check)
                    .id(copyID == nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            .frame(minWidth: 64, alignment: .leading)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: copyID == nil)
        .help(copyID == nil ? "Copy answer" : "Answer copied")
        .task(id: copyID) {
            guard copyID != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copyID = nil
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
            AIShimmer(MeetingChatWaitingStatus.label(phase: phase, elapsed: timeline.date.timeIntervalSince(startedAt), phrases: phrases))
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
        let measured = NSAttributedString(string: text + "\u{200B}", attributes: [.font: AppFonts.font(size: 14)])
            .boundingRect(with: NSSize(width: max(80, width - 10), height: CGFloat.greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(144, max(34, ceil(measured.height) + 16))
    }
}


/// Synchronize host-originated edits through NSTextView's undo registration.
/// A different draft identity (chat switch or accepted send) is a hard boundary,
/// including when the two drafts happen to contain identical text.
@MainActor
enum MeetingChatComposerTextSync {
    static func apply(_ text: String, to editor: NSTextView, resetUndo: Bool) {
        guard resetUndo || editor.string != text else { return }
        // Direct text-storage replacements do not inherit NSTextView's typing attributes
        // when the composer is empty. Supply them explicitly for presets and restored drafts.
        var attributes = editor.typingAttributes
        attributes[.font] = AppFonts.font(size: 14)
        attributes[.foregroundColor] = NSColor.labelColor
        editor.typingAttributes = attributes
        if resetUndo {
            editor.breakUndoCoalescing()
            editor.undoManager?.removeAllActions()
            if editor.string != text {
                editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            }
            return
        }
        guard editor.string != text else { return }
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.breakUndoCoalescing()
        guard editor.shouldChangeText(in: range, replacementString: text) else { return }
        editor.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        editor.didChangeText()
        editor.breakUndoCoalescing()
    }
}

/// Keep active date restrictions visible independently of attachment chips.
enum MeetingChatScopePresentation {
    static func dateLabel(_ scope: MeetingChatScope) -> String? {
        let start = scope.startDate?.formatted(date: .abbreviated, time: .omitted)
        let end = scope.endDateExclusive?.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
        switch (start, end) {
        case let (.some(start), .some(end)): return "\(start) – \(end)"
        case let (.some(start), nil): return "From \(start)"
        case let (nil, .some(end)): return "Through \(end)"
        default: return nil
        }
    }
}

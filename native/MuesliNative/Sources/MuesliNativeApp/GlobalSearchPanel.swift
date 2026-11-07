import AppKit
import SwiftUI
import MuesliCore

extension GlobalSearchKind {
    var searchLabel: String {
        switch self {
        case .dictation: "Dictations"
        case .meeting: "Meetings"
        case .command: "Commands"
        case .quill: "Quill"
        case .cotypist: "Cotypist"
        case .screenHistory: "Screen history"
        case .chat: "Chat"
        case .recap: "Recaps"
        case .vidshot: "Vidshots"
        }
    }
    @MainActor var searchImage: Image {
        if self == .screenHistory { return Image(nsImage: TimeTurnerIcon.image()) }
        if self == .vidshot { return Image(nsImage: VidshotIcon.image()) }
        return Image(systemName: searchSymbol)
    }
    private var searchSymbol: String {
        switch self {
        case .dictation: "waveform"
        case .meeting: "person.2"
        case .command: "cursorarrow"
        case .quill: "feather"
        case .cotypist: "text.cursor"
        case .screenHistory: "clock.arrow.circlepath"
        case .chat: "bubble.left.and.bubble.right"
        case .recap: "doc.text"
        case .vidshot: "viewfinder"
        }
    }
}

struct GlobalSearchRequest: Equatable {
    var text = ""
    var kind: GlobalSearchKind?
    var app = ""
    var person: MeetingParticipantDraft?
    var period: GlobalSearchPeriod = .all
    var retry = 0
    var showsPeople = false
    func query(now: Date = Date(), calendar: Calendar = .current) -> GlobalSearchQuery {
        let from: Date
        switch period {
        case .all: from = .distantPast
        case .today: from = calendar.startOfDay(for: now)
        case .week: from = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: from = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        }
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(text: text, kinds: kind.map { [$0] } ?? Set(GlobalSearchKind.allCases),
                     from: from, until: now, app: app.isEmpty ? nil : app, person: person, limit: person == nil ? 100 : 101)
    }
}

enum GlobalSearchPeriod: String, CaseIterable {
    case all = "Any time", today = "Today", week = "Past 7 days", month = "Past 30 days"
}

@MainActor @Observable
final class GlobalSearchPresentation {
    var results: [GlobalSearchResult] = []
    var people: [MeetingParticipantDraft] = []
    private var showingPeople = false
    var selection: String?
    var isLoading = false
    var hasMore = false
    var error: String?
    var unavailableKinds: Set<GlobalSearchKind> = []
    var availabilityMessage: String? {
        guard !unavailableKinds.isEmpty else { return nil }
        let names = unavailableKinds.map(\.searchLabel).sorted().joined(separator: ", ")
        return "Some results unavailable: " + names
    }
    private var generation = UUID()

    func refresh(_ request: GlobalSearchRequest, using worker: GlobalSearchWorker, debounce: Bool) async {
        if request.showsPeople && request.person == nil {
            let text = request.text
            await refreshPeople(debounce: debounce) { try await worker.people(matching: text) }
            return
        }
        await refreshResponse(request, debounce: debounce) { try await worker.searchResponse($0) }
    }

    func refreshPeople(debounce: Bool, search: @Sendable () async throws -> [MeetingParticipantDraft]) async {
        let token = UUID()
        generation = token; showingPeople = true; error = nil; unavailableKinds = []; hasMore = false
        if debounce { people = []; selection = nil }
        results = []; isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(200)) }
            let found = try await search()
            try Task.checkCancellation()
            guard generation == token else { return }
            people = found
            if !found.contains(where: { $0.participantIdentifier == selection }) { selection = found.first?.participantIdentifier }
        } catch is CancellationError {} catch {
            guard generation == token, !Task.isCancelled else { return }
            people = []; selection = nil; self.error = "People couldn’t load. Try again."
        }
    }

    func refresh(_ request: GlobalSearchRequest, debounce: Bool,
                 search: @Sendable (GlobalSearchQuery) async throws -> [GlobalSearchResult]) async {
        await refreshResponse(request, debounce: debounce) { .init(results: try await search($0)) }
    }

    func refreshResponse(_ request: GlobalSearchRequest, debounce: Bool,
                         search: @Sendable (GlobalSearchQuery) async throws -> GlobalSearchResponse) async {
        let token = UUID()
        generation = token
        showingPeople = false; people = []; hasMore = false
        error = nil
        if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.person == nil {
            results = []; selection = nil; unavailableKinds = []; isLoading = false; return
        }
        isLoading = true
        if debounce { results = []; selection = nil; unavailableKinds = [] }
        defer { if generation == token { isLoading = false } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(200)) }
            try Task.checkCancellation()
            let response = try await search(request.query())
            let found = request.person == nil ? response.results : Array(response.results.prefix(100))
            try Task.checkCancellation()
            guard generation == token else { return }
            results = found
            hasMore = request.person != nil && response.results.count > 100
            unavailableKinds = response.unavailableKinds
            if !found.contains(where: { $0.id == selection }) { selection = found.first?.id }
        } catch is CancellationError {} catch {
            guard generation == token, !Task.isCancelled else { return }
            results = []; selection = nil; unavailableKinds = []
            self.error = "Search couldn’t load. Try again."
        }
    }

    func loadMore(_ request: GlobalSearchRequest, using worker: GlobalSearchWorker) async {
        guard request.person != nil, hasMore, !isLoading else { return }
        let token = generation
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let revision = try await worker.changeToken()
            var query = request.query(); query.offset = results.count
            let response = try await worker.searchResponse(query)
            guard !Task.isCancelled, generation == token else { return }
            guard try await worker.changeToken() == revision else {
                await refresh(request, using: worker, debounce: false)
                return
            }
            results.append(contentsOf: response.results.prefix(100))
            hasMore = response.results.count > 100
            unavailableKinds = response.unavailableKinds
        } catch is CancellationError {} catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = "Search couldn’t load. Try again."
        }
    }

    func move(_ delta: Int) {
        let ids = showingPeople ? people.map(\.participantIdentifier) : results.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == selection } ?? 0
        selection = ids[max(0, min(ids.count - 1, current + delta))]
    }
}

/// Retain readable text across transient errors, but only a fresh successful
/// resolution permits copying. Navigation/close invalidates in-flight refreshes.
@MainActor @Observable
final class GlobalSearchPreview {
    var text: String?
    var source: GlobalSearchResult?
    var error: String?
    private var generation = UUID()
    func clear() { generation = UUID(); text = nil; source = nil; error = nil }
    func show(_ text: String, source: GlobalSearchResult) {
        clear(); self.text = text; self.source = source
    }
    func refresh(resolve: (GlobalSearchResult) async throws -> GlobalSearchDestination?) async -> Bool {
        guard let source else { return true }
        let token = generation
        do {
            let current = try await resolve(source)
            guard !Task.isCancelled, token == generation else { return true }
            if case .text(let text) = current { self.text = text; error = nil }
            else { clear(); error = "This item is no longer available." }
            return true
        } catch {
            guard !Task.isCancelled, token == generation else { return true }
            self.error = "Preview couldn’t refresh. Retrying…"
            return false
        }
    }
}

struct GlobalSearchPanel: View {
    let controller: MuesliController
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var analyticsOpenedResult = false
    @State private var analyticsReported = false
    @State private var analyticsConsent: String?
    @State private var request = GlobalSearchRequest()
    @State private var model = GlobalSearchPresentation()
    @State private var opening = false
    @State private var openTask: Task<Void, Never>?
    @State private var preview = GlobalSearchPreview()
    @State private var copied = false
    @State private var navigationError: String?
    @State private var peopleSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(MuesliTheme.textSecondary)
                GlobalSearchField(text: $request.text, onMove: model.move, onSubmit: openSelection, onEscape: close)
                    .frame(height: 40)
                if model.isLoading || opening { ProgressView().controlSize(.small) }
                Button(action: close) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.muesli(.quiet)).accessibilityLabel("Close search")
            }.padding(16)
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip("All", kind: nil)
                    ForEach(GlobalSearchKind.allCases, id: \.self) { kind in
                        chip(kind.searchLabel, kind: kind)
                        if kind == .meeting { peopleChip }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }.scrollIndicators(.hidden)
            HStack(spacing: 12) {
                if !request.showsPeople || request.person != nil {
                Picker("Date", selection: $request.period) {
                    ForEach(GlobalSearchPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 145).accessibilityLabel("Search date range")
                }
                if !request.showsPeople {
                TextField("Filter by app…", text: $request.app)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .accessibilityLabel("Filter by app name or bundle ID")
                }
                if let person = request.person {
                    Button { request.person = nil; request.text = peopleSearchText } label: {
                        Label(person.displayName, systemImage: "chevron.left")
                    }.buttonStyle(.muesli(.quiet)).help("Back to people")
                }
                Spacer()
            }.padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            if let message = navigationError ?? model.availabilityMessage {
                HStack {
                    Text(message).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    Spacer()
                    Button("Retry") { request.retry += 1 }.buttonStyle(.muesli(.quiet))
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let text = preview.text {
                previewView(text)
            } else if let error = model.error {
                VStack {
                    empty(error)
                    Button("Retry") { request.retry += 1 }.buttonStyle(.muesli(.quiet)).padding(.bottom, 24)
                }
            } else if request.showsPeople && request.person == nil {
                if model.people.isEmpty {
                    empty(model.isLoading ? "Searching…" : "No people found.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(model.people, id: \.participantIdentifier) { person in
                                    personRow(person).id(person.participantIdentifier)
                                }
                            }.padding(10)
                        }.onChange(of: model.selection) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            } else if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.person == nil {
                empty("Search your words, meetings, chats and screen history")
            } else if model.results.isEmpty {
                empty(model.isLoading ? "Searching…" : (model.unavailableKinds.isEmpty
                    ? "No matches. Try another word or filter." : "No verified matches in the available sources."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.results) { result in resultRow(result).id(result.id) }
                            if model.hasMore {
                                Button("Show more meetings") { Task { await model.loadMore(request, using: controller.globalSearchWorker) } }
                                    .disabled(model.isLoading).padding(12)
                            }
                        }.padding(10)
                    }
                    .onChange(of: model.selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                let count = request.showsPeople && request.person == nil ? model.people.count : model.results.count
                Text(request.person != nil && model.hasMore ? "\(count) meetings · more available" : count == 100 && request.person == nil ? "Top 100 matches · narrow your search for more" : "\(count) matches")
                Spacer()
                Text("↑ ↓ Select   ↵ Open   esc Close")
            }.font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary).padding(12)
        }
        .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textPrimary)
        .background(MuesliTheme.backgroundBase)
        .frame(width: min(780, (NSScreen.main?.visibleFrame.width ?? 900) - 80), height: 580)
        .onAppear { analyticsConsent = ProductAnalytics.emitter.token() }
        .onDisappear {
            guard !analyticsReported else { return }
            analyticsReported = true
            ProductAnalytics.emitter.emit(.init(feature: .search, kind: .session_finished,
                fields: [.results: ProductAnalytics.bucket(model.results.count), .opened: analyticsOpenedResult ? .yes : .no]), token: analyticsConsent)
        }
        .task(id: request) {
            openTask?.cancel(); opening = false; preview.clear(); navigationError = nil
            var partialRetryAt = Date().addingTimeInterval(30)
            var revision = try? await controller.globalSearchWorker.changeToken()
            await model.refresh(request, using: controller.globalSearchWorker, debounce: true)
            // Refresh only this bounded, visible query; preserve selection across new captures.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                let updated = try? await controller.globalSearchWorker.changeToken()
                let retryPartial = !model.unavailableKinds.isEmpty && Date() >= partialRetryAt
                guard updated == nil || updated != revision || retryPartial else { continue }
                revision = updated
                partialRetryAt = Date().addingTimeInterval(30)
                await model.refresh(request, using: controller.globalSearchWorker, debounce: false)
                let refreshed = await preview.refresh { try await controller.globalSearchWorker.destination(for: $0) }
                if !refreshed { revision = nil }
                if preview.text == nil, let error = preview.error { navigationError = error }

            }
        }
        .onDisappear { openTask?.cancel(); preview.clear() }
        .onExitCommand(perform: close)
    }

    private func chip(_ title: String, kind: GlobalSearchKind?) -> some View {
        Button { request.showsPeople = false; request.person = nil; request.kind = kind } label: {
            Text(title).font(MuesliTheme.callout())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(!request.showsPeople && request.kind == kind ? MuesliTheme.accentSubtle : MuesliTheme.backgroundRaised)
                .clipShape(Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(!request.showsPeople && request.kind == kind ? .isSelected : [])
    }

    private var peopleChip: some View {
        Button { request.showsPeople = true; request.person = nil; request.kind = .meeting; request.app = "" } label: {
            Text("People").font(MuesliTheme.callout()).padding(.horizontal, 10).padding(.vertical, 6)
                .background(request.showsPeople ? MuesliTheme.accentSubtle : MuesliTheme.backgroundRaised)
                .clipShape(Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(request.showsPeople ? .isSelected : [])
    }

    private func personRow(_ person: MeetingParticipantDraft) -> some View {
        Button { model.selection = person.participantIdentifier; openSelection() } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle").font(.system(size: 23))
                    .foregroundStyle(MuesliTheme.accentText).frame(width: 34, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.displayName).font(MuesliTheme.headline()).lineLimit(1)
                    if let email = person.emailAddress, !email.isEmpty {
                        Text(email).font(MuesliTheme.callout()).foregroundStyle(MuesliTheme.textSecondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if person.participantIdentifier == model.selection { Image(systemName: "return").foregroundStyle(MuesliTheme.textSecondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(person.participantIdentifier == model.selection ? MuesliTheme.backgroundHover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(person.participantIdentifier == model.selection ? .isSelected : [])
    }

    private func resultRow(_ result: GlobalSearchResult) -> some View {
        Button { model.selection = result.id; openSelection() } label: {
            HStack(alignment: .top, spacing: 12) {
                result.kind.searchImage.resizable().scaledToFit().frame(width: 23, height: 23)
                    .foregroundStyle(MuesliTheme.accentText).frame(width: 34, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title.isEmpty ? result.kind.searchLabel : result.title)
                        .font(MuesliTheme.headline()).lineLimit(1)
                    Text(result.excerpt.replacingOccurrences(of: "\n", with: " "))
                        .font(MuesliTheme.callout()).foregroundStyle(MuesliTheme.textSecondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(result.kind.searchLabel)
                        Text("·")
                        Text(result.date.formatted(date: .abbreviated, time: .shortened))
                        if !result.appName.isEmpty { Text("· " + result.appName).lineLimit(1) }
                        if result.kind == .screenHistory && !result.mediaAvailable { Text("· Text only") }
                    }.font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if result.id == model.selection { Image(systemName: "return").foregroundStyle(MuesliTheme.textSecondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(result.id == model.selection ? MuesliTheme.backgroundHover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(result.id == model.selection ? .isSelected : [])
    }

    private func empty(_ message: String) -> some View {
        Text(message).font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary)
            .multilineTextAlignment(.center).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back to results") { preview.clear() }
                Spacer()
                Button(copied ? "Copied" : "Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }.disabled(preview.error != nil)
            }.buttonStyle(.muesli(.quiet))
            if let error = preview.error {
                Text(error).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            }
            if let result = preview.source {
                Text(result.kind.searchLabel + " · " + result.date.formatted(date: .abbreviated, time: .shortened))
                    .font(MuesliTheme.headline())
            }
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func close() { openTask?.cancel(); dismiss() }

    private func openSelection() {
        if request.showsPeople && request.person == nil {
            guard let person = model.people.first(where: { $0.participantIdentifier == model.selection }) else { return }
            peopleSearchText = request.text
            request.text = ""; request.person = person; request.kind = .meeting; request.period = .all
            return
        }
        guard !opening, let result = model.results.first(where: { $0.id == model.selection }) else { return }
        opening = true
        navigationError = nil
        openTask = Task { @MainActor in
            defer { if !Task.isCancelled { opening = false } }
            do {
                let resolved = try await controller.globalSearchWorker.resolveDestination(for: result)
                guard !Task.isCancelled else { return }
                let destination: GlobalSearchDestination
                switch resolved {
                case .available(let value): destination = value
                case .missing: navigationError = "This item is no longer available."; return
                case .unavailable: navigationError = "This item is temporarily unavailable. Try again."; return
                }
                analyticsOpenedResult = true
                switch destination {
                case .text(let text): preview.show(text, source: result); copied = false
                case .meeting(let record):
                    controller.clearSearch()
                    appState.selectedTab = .meetings
                    appState.meetingDetailReturnDestination = .meetings
                    appState.selectedMeetingID = record.id
                    appState.selectedMeetingRecord = record
                    appState.meetingChatDocumentTarget = nil
                    appState.meetingsNavigationState = .document(record.id)
                    dismiss()
                case .chat(let id):
                    controller.clearSearch()
                    controller.showMeetingChat()
                    controller.meetingChatCoordinator.selectChat(id: id)
                    dismiss()
                case .capture(let capture):
                    controller.clearSearch()
                    appState.openTimeTurnerCapture(capture)
                    dismiss()
                case .vidshot(let id):
                    controller.clearSearch()
                    appState.vidshotDetailReturnsToTimeline = false
                    appState.selectedVidshotID = id
                    appState.selectedTab = .vidshots
                    dismiss()
                case .recap(let recap):
                    controller.clearSearch()
                    appState.openTimeTurnerRecap(recap)
                    dismiss()
                }
            } catch {
                guard !Task.isCancelled else { return }
                navigationError = "This item couldn’t be opened. Try again."
            }
        }
    }
}

/// Keep native editing/undo/IME; handle navigation only after composition has finished.
private struct GlobalSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false
        field.font = AppFonts.regular(22)
        field.placeholderString = "Search all history…"
        field.setAccessibilityLabel("Search all history")
        field.delegate = context.coordinator
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.textColor = NSColor(MuesliTheme.textPrimary)
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: GlobalSearchField
        init(_ parent: GlobalSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            default: return false
            }
            return true
        }
    }
}

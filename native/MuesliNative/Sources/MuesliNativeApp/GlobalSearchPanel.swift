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
        }
    }
    var searchImage: Image {
        if self == .screenHistory { return Image(nsImage: TimeTurnerIcon.image()) }
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
        }
    }
}

struct GlobalSearchRequest: Equatable {
    var text = ""
    var kind: GlobalSearchKind?
    var app = ""
    var period: GlobalSearchPeriod = .all
    var retry = 0
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
                     from: from, until: now, app: app.isEmpty ? nil : app, limit: 100)
    }
}

enum GlobalSearchPeriod: String, CaseIterable {
    case all = "Any time", today = "Today", week = "Past 7 days", month = "Past 30 days"
}

@MainActor @Observable
final class GlobalSearchPresentation {
    var results: [GlobalSearchResult] = []
    var selection: String?
    var isLoading = false
    var error: String?
    private var generation = UUID()

    func refresh(_ request: GlobalSearchRequest, using worker: GlobalSearchWorker, debounce: Bool) async {
        await refresh(request, debounce: debounce) { try await worker.search($0) }
    }

    func refresh(_ request: GlobalSearchRequest, debounce: Bool,
                 search: @Sendable (GlobalSearchQuery) async throws -> [GlobalSearchResult]) async {
        let token = UUID()
        generation = token
        error = nil
        if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []; selection = nil; isLoading = false; return
        }
        isLoading = true
        if debounce { results = []; selection = nil }
        defer { if generation == token { isLoading = false } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(200)) }
            try Task.checkCancellation()
            let found = try await search(request.query())
            try Task.checkCancellation()
            guard generation == token else { return }
            results = found
            if !found.contains(where: { $0.id == selection }) { selection = found.first?.id }
        } catch is CancellationError {} catch {
            guard generation == token, !Task.isCancelled else { return }
            results = []; selection = nil
            self.error = "Search couldn’t load. Try again."
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? 0
        selection = results[max(0, min(results.count - 1, current + delta))].id
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
    @State private var request = GlobalSearchRequest()
    @State private var model = GlobalSearchPresentation()
    @State private var opening = false
    @State private var openTask: Task<Void, Never>?
    @State private var preview = GlobalSearchPreview()
    @State private var copied = false

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
                    ForEach(GlobalSearchKind.allCases, id: \.self) { chip($0.searchLabel, kind: $0) }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }.scrollIndicators(.hidden)
            HStack(spacing: 12) {
                Picker("Date", selection: $request.period) {
                    ForEach(GlobalSearchPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 145).accessibilityLabel("Search date range")
                TextField("Filter by app…", text: $request.app)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .accessibilityLabel("Filter by app name or bundle ID")
                Spacer()
            }.padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            if let text = preview.text {
                previewView(text)
            } else if let error = model.error {
                VStack {
                    empty(error)
                    Button("Retry") { request.retry += 1 }.buttonStyle(.muesli(.quiet)).padding(.bottom, 24)
                }
            } else if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                empty("Search your words, meetings, chats and screen history")
            } else if model.results.isEmpty {
                empty(model.isLoading ? "Searching…" : "No matches. Try another word or filter.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.results) { result in resultRow(result).id(result.id) }
                        }.padding(10)
                    }
                    .onChange(of: model.selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                Text(model.results.count == 100 ? "Top 100 matches · narrow your search for more" : "\(model.results.count) matches")
                Spacer()
                Text("↑ ↓ Select   ↵ Open   esc Close")
            }.font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary).padding(12)
        }
        .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textPrimary)
        .background(MuesliTheme.backgroundBase)
        .frame(width: min(780, (NSScreen.main?.visibleFrame.width ?? 900) - 80), height: 580)
        .task(id: request) {
            openTask?.cancel(); opening = false; preview.clear()
            var revision = try? await controller.globalSearchWorker.changeToken()
            await model.refresh(request, using: controller.globalSearchWorker, debounce: true)
            // Refresh only this bounded, visible query; preserve selection across new captures.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                let updated = try? await controller.globalSearchWorker.changeToken()
                guard updated == nil || updated != revision else { continue }
                revision = updated
                await model.refresh(request, using: controller.globalSearchWorker, debounce: false)
                let refreshed = await preview.refresh { try await controller.globalSearchWorker.destination(for: $0) }
                if !refreshed { revision = nil }
                if preview.text == nil, let error = preview.error { model.error = error }

            }
        }
        .onDisappear { openTask?.cancel(); preview.clear() }
        .onExitCommand(perform: close)
    }

    private func chip(_ title: String, kind: GlobalSearchKind?) -> some View {
        Button { request.kind = kind } label: {
            Text(title).font(MuesliTheme.callout())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(request.kind == kind ? MuesliTheme.accentSubtle : MuesliTheme.backgroundRaised)
                .clipShape(Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(request.kind == kind ? .isSelected : [])
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
        guard !opening, let result = model.results.first(where: { $0.id == model.selection }) else { return }
        opening = true
        openTask = Task { @MainActor in
            defer { if !Task.isCancelled { opening = false } }
            do {
                let resolved = try await controller.globalSearchWorker.destination(for: result)
                guard !Task.isCancelled else { return }
                guard let destination = resolved else {
                    model.error = "This item is no longer available."; return
                }
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
                case .recap(let recap):
                    controller.clearSearch()
                    appState.openTimeTurnerRecap(recap)
                    dismiss()
                }
            } catch {
                guard !Task.isCancelled else { return }
                model.error = "This item couldn’t be opened. Try again."
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

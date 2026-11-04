import SwiftUI
import AIElementsSwift
import AppKit
import MuesliCore

struct TimeTurnerRecapView: View {
    let day: Date
    var template: MuesliHistoryTask = .dailyRecap
    var query: String = ""
    var invocation: MuesliSkillInvocation?
    var meetingScope: MeetingChatScope?
    var selection: TimeTurnerRecapSelection? = nil
    let controller: MuesliController
    var onMeeting: ((MeetingChatCitation) -> Void)? = nil
    let onCapture: (VisualMemoryItem) -> Void
    @State private var model = TimeTurnerRecapModel()
    @State private var expanded = true
    @State private var copied = false
    @State private var sourcesPresented = false
    @State private var selectedSource: TimeTurnerRecapSource?
    private var memory: VisualMemoryController { controller.visualMemory }
    private var provider: MeetingSummaryBackendOption { .resolved(controller.config.meetingSummaryBackend) }
    private var selectedModel: String { MeetingTextGenerationClient.model(controller.config) }
    private var selectionID: String {
        template.id + "|" + query + "|" + (selection?.key ?? SavedTimeTurnerRecap.key(dayStart: Calendar.current.startOfDay(for: day), timeZone: Calendar.current.timeZone.identifier))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); actions }
                VStack(alignment: .leading, spacing: 10) { heading; actions }
            }
            if model.hasGenerated, Set(model.includedInputs) != Set(TimeTurnerRecapInput.selected(controller.config)) {
                SettingsNote("Sources changed. Regenerate to apply.")
            }
            if model.isLoading { ProgressView("Loading recap…").font(MuesliTheme.body()) }
            if !model.hasGenerated && !model.isGenerating && !model.isLoading {
                Text(invocation != nil ? "Uses the sources needed for your request." : "Generate from this day’s selected sources using \(provider.label).")
                    .font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
            if model.isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading selected sources…").font(MuesliTheme.caption())
                }.accessibilityElement(children: .combine)
            }
            if let error = model.error { Text(error).font(MuesliTheme.caption()).foregroundStyle(.orange) }
            if model.hasGenerated, expanded {
                if model.insights.isEmpty {
                    Text("No supported takeaways in the sampled history.").font(MuesliTheme.body()).foregroundStyle(.secondary)
                }
                ForEach(TimeTurnerRecapInsight.Section.allCases, id: \.self) { section in
                    let insights = model.insights.filter { $0.section == section }
                    if !insights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if template.templatePrompt == nil { Text(section.title).font(MuesliTheme.headline()) }
                            ForEach(insights) { insight in
                                VStack(alignment: .leading, spacing: 7) {
                                    if template.templatePrompt != nil {
                                        AIResponse(insight.text)
                                    } else {
                                        Text(insight.text).font(MuesliTheme.body()).textSelection(.enabled)
                                    }
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 8) { sourceButtons(insight) }
                                        VStack(alignment: .leading, spacing: 6) { sourceButtons(insight) }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(model.savedKey == nil ? "Based on sampled excerpts · Temporary recap" : "Based on sampled excerpts · Saved on this Mac")
                    .font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MuesliTheme.surfaceBorder).allowsHitTesting(false))
        .task(id: selectionID) {
            if invocation != nil { generate() }
            else if template == .dailyRecap {
                await model.load(day: day, selection: selection, root: memory.store?.root, databaseURL: controller.timeTurnerRecapDatabaseURL)
            } else { model.cancel(clear: true) }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await model.revalidate(root: memory.store?.root, databaseURL: controller.timeTurnerRecapDatabaseURL)
            }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
        .sheet(item: $selectedSource) { source in
            if let history = source.history {
                RecapHistoryPreview(source: history, databaseURL: controller.timeTurnerRecapDatabaseURL)
            }
        }
        .onChange(of: model.requestID) { _, _ in selectedSource = nil }
        .onChange(of: selectionID) { _, _ in copied = false }
        .onDisappear { model.cancel(clear: true) }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "text.page").foregroundStyle(MuesliTheme.accent)
                Text(template.title).font(MuesliTheme.headline())
            }
            if let selection, selection.timeZone != Calendar.current.timeZone.identifier {
                Text("\(selection.dayLabel) · \(selection.timeZone)")
                    .font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
            if let date = model.generatedAt {
                Text("Generated \(date.formatted(date: .abbreviated, time: .shortened))").font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
            Text(model.hasGenerated ? "\(model.providerLabel) · \(model.modelLabel)" : "\(provider.label) · \(selectedModel)").font(MuesliTheme.caption()).foregroundStyle(.secondary)
                .help("Generation sends text from your selected sources to your meeting provider. Local endpoints process according to their configuration. Screenshots are not uploaded.")
        }
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Button { sourcesPresented.toggle() } label: {
                Label("Sources", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("recap.sources")
            .popover(isPresented: $sourcesPresented) {
                RecapSourceSettings(controller: controller).disabled(model.isGenerating)
            }
            if model.hasGenerated {
                Button {
                    let requestID = model.requestID
                    let selectedDay = selectionID
                    Task {
                        await model.revalidate(root: memory.store?.root, databaseURL: controller.timeTurnerRecapDatabaseURL)
                        guard selectedDay == selectionID, requestID == model.requestID,
                              model.hasGenerated, !model.isGenerating else { return }
                        let text = template.templatePrompt == nil ? TimeTurnerRecap.plainText(model.insights) : model.insights.map(\.text).joined(separator: "\n\n")
                        guard !text.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(text, forType: .string)
                        if copied { ProductAnalytics.event(.recap, .result_action, fields: [.action: .copy]) }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy summary", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(model.isGenerating || model.isLoading || model.insights.isEmpty)
                .help("Copy summary text without screenshot references or model details")
            }
            if model.isGenerating {
                Button("Cancel") { model.cancel() }
            } else {
                Button(model.hasGenerated ? "Regenerate" : (template == .dailyRecap ? "Generate recap" : "Run skill")) {
                    expanded = true
                    generate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading)
                .help("Use \(selectedModel) with the selected sources")
            }
            if model.hasGenerated {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .accessibilityLabel(expanded ? "Collapse recap" : "Expand recap")
            }
        }
    }
    private func generate() {
        model.generate(day: day, selection: selection, root: memory.store?.root,
            databaseURL: controller.timeTurnerRecapDatabaseURL, config: controller.config,
            template: template, query: query, skillPrompt: invocation?.prompt, meetingScope: meetingScope)
    }

    @ViewBuilder private func sourceButtons(_ insight: TimeTurnerRecapInsight) -> some View {
        ForEach(insight.sources, id: \.self) { id in
            if let source = model.sources.first(where: { $0.id == id }) {
                Button {
                    let requestID = model.requestID
                    Task {
                        await model.revalidate(root: memory.store?.root, databaseURL: controller.timeTurnerRecapDatabaseURL)
                        guard requestID == model.requestID, model.hasGenerated, model.sources.contains(where: { $0.id == source.id }) else { return }
                        if let capture = source.capture, let root = memory.store?.root {
                            // Archives may move a capture without changing its evidence identity.
                            let current = try? await Task.detached(priority: .utility) {
                                try VisualMemoryStore(root: root, readOnly: true).moment(id: capture.id)
                            }.value
                            guard requestID == model.requestID, let current else { return }
                            onCapture(current)
                        }
                        else if source.history != nil { selectedSource = source }
                        else if let meeting = source.meeting {
                            if let onMeeting { onMeeting(meeting) }
                            else { controller.showMeetingChatSource(.init(citation: meeting, sessionID: UUID()), fromTimeTurner: true) }
                        }
                    }
                } label: {
                    if let capture = source.capture {
                        RecapCaptureThumbnail(captureID: capture.id, date: source.date, memory: memory)
                    } else {
                        Label(source.history.map { $0.kind.label + " · " + source.date.formatted(date: .omitted, time: .shortened) } ?? source.title, systemImage: source.history == nil ? "text.bubble" : "doc.text")
                            .font(MuesliTheme.caption()).lineLimit(1).padding(8)
                            .background(MuesliTheme.backgroundDeep, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.buttonStyle(.plain)
                    .accessibilityLabel(source.capture != nil ? "Open screenshot at \(source.date.formatted(date: .omitted, time: .shortened))" : source.title)
                    .help(source.excerpt)
            }
        }
    }
}


/// Resolve the current media location: saved recap snapshots can predate compaction.
private struct RecapCaptureThumbnail: View {
    let captureID: String
    let date: Date
    let memory: VisualMemoryController
    @State private var capture: VisualMemoryItem?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let capture {
                    MemoryImageView(item: capture, memory: memory, maximumSize: 320, compact: true)
                } else if loaded {
                    Label("Preview unavailable", systemImage: "photo")
                        .font(MuesliTheme.caption()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 144, height: 90)
            .background(MuesliTheme.backgroundDeep)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(6)
        .background(MuesliTheme.backgroundDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MuesliTheme.surfaceBorder).allowsHitTesting(false))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .task(id: "\(captureID)|\(memory.catalogRevision)") {
            guard let root = memory.store?.root else { loaded = true; return }
            let id = captureID
            let current = try? await Task.detached(priority: .utility) {
                try VisualMemoryStore(root: root, readOnly: true).moment(id: id)
            }.value
            guard !Task.isCancelled else { return }
            capture = current
            loaded = true
        }
    }
}


private struct RecapSourceSettings: View {
    let controller: MuesliController
    @State private var presentationCatalog = SettingsPresentationCatalog()
    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text("Skill sources").font(MuesliTheme.font(size: 18, weight: .semibold))
            SettingsRow(label: "Time Turner", controlWidth: nil) {
                Label("Always included", systemImage: "checkmark.circle.fill")
                    .font(MuesliTheme.font(size: 12)).foregroundStyle(MuesliTheme.textSecondary)
            }
            Divider()
            ForEach(TimeTurnerRecapInput.allCases, id: \.self) { source in
                SettingsRow(label: source.label, controlWidth: nil) {
                    MuesliSettingControl(controller: controller, id: source.settingID)
                }
            }
            SettingsNote("Used by all skills. Saved recaps change only when regenerated.")
            SettingsNote("Saved chats use the conversation’s update date; messages may be older.")
        }
        .padding(20).frame(width: 360)
        .environment(\.muesliSettingDefinitions, presentationCatalog.definitions(for: controller))
    }
}

private struct RecapHistoryPreview: View {
    let source: TimeTurnerRecapHistorySource
    let databaseURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(source.kind.label).font(MuesliTheme.headline())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(source.date.formatted(date: .abbreviated, time: .shortened))
                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
            if let text { ScrollView { Text(text).font(MuesliTheme.body()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            else if let error { Text(error).font(MuesliTheme.body()) }
            else { ProgressView() }
        }
        .padding(20).frame(minWidth: 380, idealWidth: 600, minHeight: 300, idealHeight: 480)
        .task {
            repeat {
                do {
                    let source = source, databaseURL = databaseURL
                    let current = try await Task.detached(priority: .utility) {
                        try TimeTurnerRecapHistory(databaseURL: databaseURL).read(kind: source.kind, id: source.id)
                    }.value
                    guard !Task.isCancelled else { return }
                    guard let current, current.revision == source.revision else {
                        text = nil; error = "This source changed or was removed."; return
                    }
                    text = current.text; error = nil
                } catch { text = nil; self.error = "This source is temporarily unavailable." }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

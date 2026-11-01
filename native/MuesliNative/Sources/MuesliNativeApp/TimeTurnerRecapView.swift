import SwiftUI
import MuesliCore

struct TimeTurnerRecapView: View {
    let day: Date
    let controller: MuesliController
    let onCapture: (VisualMemoryItem) -> Void
    @State private var model = TimeTurnerRecapModel()
    @State private var expanded = true
    private var memory: VisualMemoryController { controller.visualMemory }
    private var provider: MeetingSummaryBackendOption { .resolved(controller.config.meetingSummaryBackend) }
    private var selectedModel: String { MeetingTextGenerationClient.model(controller.config) }
    private var selectionID: String {
        "\(Calendar.current.startOfDay(for: day).timeIntervalSince1970)|\(Calendar.current.timeZone.identifier)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); actions }
                VStack(alignment: .leading, spacing: 10) { heading; actions }
            }
            if model.isLoading { ProgressView("Loading recap…").font(MuesliTheme.body()) }
            if !model.hasGenerated && !model.isGenerating && !model.isLoading {
                Text("Generate from this day’s sampled screen text and meetings using \(provider.label).")
                    .font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
            if model.isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading sampled history and meeting notes…").font(MuesliTheme.caption())
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
                            Text(section.title).font(MuesliTheme.headline())
                            ForEach(insights) { insight in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(insight.text).font(MuesliTheme.body()).textSelection(.enabled)
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 8) { sourceButtons(insight) }
                                        VStack(alignment: .leading, spacing: 6) { sourceButtons(insight) }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Based on sampled excerpts · Saved on this Mac")
                    .font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MuesliTheme.surfaceBorder).allowsHitTesting(false))
        .task(id: selectionID) {
            await model.load(day: day, root: memory.store?.root, databaseURL: controller.timeTurnerRecapDatabaseURL)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await model.revalidate(root: memory.store?.root, databaseURL: controller.timeTurnerRecapDatabaseURL)
            }
        }
        .onDisappear { model.cancel(clear: true) }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "text.page").foregroundStyle(MuesliTheme.accent)
                Text("Daily recap").font(MuesliTheme.headline())
            }
            if let date = model.generatedAt {
                Text("Generated \(date.formatted(date: .abbreviated, time: .shortened))").font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
            Text(model.hasGenerated ? "\(model.providerLabel) · \(model.modelLabel)" : "\(provider.label) · \(selectedModel)").font(MuesliTheme.caption()).foregroundStyle(.secondary)
                .help("Generation sends sampled OCR and meeting excerpts to your selected meeting provider. Local endpoints process according to their configuration. Screenshots are not uploaded.")
        }
    }
    private var actions: some View {
        HStack(spacing: 10) {
            if model.isGenerating {
                Button("Cancel") { model.cancel() }
            } else {
                Button(model.hasGenerated ? "Regenerate" : "Generate recap") {
                    expanded = true
                    model.generate(day: day, root: memory.store?.root,
                        databaseURL: controller.timeTurnerRecapDatabaseURL, config: controller.config)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading)
                .help("Use \(selectedModel) to recap this day's sampled screen text and meetings")
            }
            if model.hasGenerated {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .accessibilityLabel(expanded ? "Collapse recap" : "Expand recap")
            }
        }
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
                        else if let meeting = source.meeting {
                            controller.showMeetingChatSource(.init(citation: meeting, sessionID: UUID()), fromTimeTurner: true)
                        }
                    }
                } label: {
                    if let capture = source.capture {
                        RecapCaptureThumbnail(captureID: capture.id, date: source.date, memory: memory)
                    } else {
                        Label(source.title, systemImage: "text.bubble")
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

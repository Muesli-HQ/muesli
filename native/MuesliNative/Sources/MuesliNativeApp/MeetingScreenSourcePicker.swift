import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor
struct MeetingScreenSource: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let filter: SCContentFilter
    let isDisplay: Bool
    let icon: NSImage?
}

@MainActor
struct MeetingScreenSourcePicker: View {
    let sources: [MeetingScreenSource]
    let complete: (MeetingScreenSource?, Bool) -> Void
    @State private var selectedID: String?
    @State private var displays = false
    @State private var announce = false

    private var visibleSources: [MeetingScreenSource] { sources.filter { $0.isDisplay == displays } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose what to record").font(MuesliTheme.font(.title2).bold())
            Text("Screen and meeting audio are saved on this Mac.").foregroundStyle(.secondary)
            Picker("Source", selection: $displays) {
                Text("Windows").tag(false)
                Text("Entire displays").tag(true)
            }.pickerStyle(.segmented).frame(width: 280)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(visibleSources) { source in
                        Button { selectedID = source.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MeetingScreenThumbnail(source: source)
                                    .frame(height: 120).frame(maxWidth: .infinity)
                                    .background(.black.opacity(0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                HStack(spacing: 6) {
                                    if let icon = source.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                                    Text(source.title).font(MuesliTheme.font(.headline)).lineLimit(1)
                                }
                                Text(source.subtitle).font(MuesliTheme.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(10)
                            .background(selectedID == source.id ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedID == source.id ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selectedID == source.id ? 2 : 1))
                        }.buttonStyle(.plain)
                        .accessibilityLabel("\(source.title), \(source.subtitle)")
                        .accessibilityAddTraits(selectedID == source.id ? .isSelected : [])
                    }
                }.padding(2)
                if visibleSources.isEmpty { Text("No available windows. Choose an entire display instead.").foregroundStyle(.secondary).padding() }
            }
            Divider()
            Toggle("Play ‘This meeting is being recorded’", isOn: $announce)
            Text("Let participants know before recording. Playback on this Mac may not reach remote participants.")
                .font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { complete(nil, false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Record Screen") { complete(sources.first { $0.id == selectedID }, announce) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 700, height: 540)
        .font(MuesliTheme.body())
        .onChange(of: displays) { _, _ in selectedID = nil }
    }
}

@MainActor
private struct MeetingScreenThumbnail: View {
    let source: MeetingScreenSource
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed { Label("Preview unavailable", systemImage: "rectangle.on.rectangle").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: source.id) {
            let config = SCStreamConfiguration()
            let rect = source.filter.contentRect
            config.width = 440
            config.height = max(2, Int(440 * rect.height / max(1, rect.width)))
            config.showsCursor = false
            config.scalesToFit = true
            config.ignoreShadowsSingleWindow = true
            do {
                let captured = try await SCScreenshotManager.captureImage(contentFilter: source.filter, configuration: config)
                guard !Task.isCancelled else { return }
                image = NSImage(cgImage: captured, size: .zero)
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

import AppKit
import SwiftUI
import ScreenCaptureKit
import MuesliCore

@MainActor
enum TimeTurnerDisplayIdentity {
    static func stableID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    static func metadata(_ display: SCDisplay) -> VisualMemoryDisplay {
        let name = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.localizedName ?? "Display \(display.displayID)"
        return .init(id: display.displayID, uuid: stableID(display.displayID) ?? "display-\(display.displayID)", name: name)
    }
}

/// A resource picker, like app exclusions. Changes stay in a draft until Finish/Save.
/// Preview frames live only in memory and are not added to screen history.
struct TimeTurnerDisplayPicker: View {
    @Binding var selection: [String: String]
    @Binding var initialized: Bool
    @State private var sources: [MeetingScreenSource] = []
    @State private var revision = 0
    @State private var previewRevision = 0
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose displays").font(MuesliTheme.title2())
            Text("Capture these displays whenever they’re connected. New displays won’t be added automatically.")
                .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(sources) { source in
                        let selected = selection[source.id] != nil
                        Button {
                            if selected { selection.removeValue(forKey: source.id) }
                            else { selection[source.id] = source.title }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MeetingScreenThumbnail(source: source)
                                    .id(previewRevision)
                                    .frame(height: 120).frame(maxWidth: .infinity)
                                    .background(MuesliTheme.backgroundBase)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                HStack {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? MuesliTheme.accentText : MuesliTheme.textSecondary)
                                    Text(source.title).font(MuesliTheme.headline()).lineLimit(1)
                                }
                                Text(source.subtitle).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MuesliTheme.backgroundRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selected ? MuesliTheme.accentText : MuesliTheme.surfaceBorder, lineWidth: selected ? 2 : 1)
                                    .allowsHitTesting(false)
                            }
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(source.title), \(source.subtitle)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(2)
                ForEach(selection.keys.filter { id in !sources.contains { $0.id == id } }.sorted(), id: \.self) { id in
                    HStack {
                        Label(selection[id] ?? "Display", systemImage: "display")
                        Text("Disconnected").foregroundStyle(MuesliTheme.textSecondary)
                        Spacer()
                        Button("Remove") { selection.removeValue(forKey: id) }
                    }.font(MuesliTheme.body()).padding(.vertical, 6)
                }
                if loading { ProgressView().controlSize(.small).padding() }
                if let error { Text(error).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary) }
                if !loading && sources.isEmpty && error == nil {
                    Text("No displays available.").font(MuesliTheme.body())
                }
            }
            HStack {
                Text("\(selection.count) selected").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                Spacer()
                Button("Refresh") { revision += 1 }
            }
        }
        .task(id: revision) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in revision += 1 }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard !Task.isCancelled else { return }
            sources = content.displays.sorted { $0.displayID < $1.displayID }.compactMap { display in
                guard CGDisplayMirrorsDisplay(display.displayID) == kCGNullDirectDisplay,
                      let uuid = TimeTurnerDisplayIdentity.stableID(display.displayID) else { return nil }
                let metadata = TimeTurnerDisplayIdentity.metadata(display)
                return MeetingScreenSource(id: uuid, title: metadata.name,
                    subtitle: "\(display.width) × \(display.height) · Display \(display.displayID)",
                    filter: SCContentFilter(display: display, excludingWindows: []), isDisplay: true, icon: nil)
            }
            previewRevision += 1
            // Preselect connected displays only for the first presentation, never on hot-plug.
            if !initialized && !sources.isEmpty {
                selection = Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
                initialized = true
            }
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = CGPreflightScreenCaptureAccess()
                ? "Couldn’t load displays. Try refreshing."
                : "Allow Screen Recording in System Settings, then refresh."
            loading = false
        }
    }
}

struct TimeTurnerDisplaySelectionSheet: View {
    let controller: MuesliController
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [String: String]
    @State private var initialized: Bool

    init(controller: MuesliController, selection: [String: String]) {
        self.controller = controller
        _selection = State(initialValue: selection)
        _initialized = State(initialValue: !selection.isEmpty)
    }

    var body: some View {
        VStack(spacing: 20) {
            TimeTurnerDisplayPicker(selection: $selection, initialized: $initialized)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    controller.saveTimeTurnerDisplays(selection)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(selection.isEmpty)
            }
        }.padding(24).frame(width: 560, height: 470)
            .font(MuesliTheme.body())
    }
}

extension MuesliController {
    /// Explicit resource selection is saved atomically with the capture mode.
    /// configureAmbient invalidates any in-flight sample using the previous selection.
    func saveTimeTurnerDisplays(_ selection: [String: String]) {
        guard !selection.isEmpty else { return }
        updateConfig {
            $0.timeTurnerSelectedDisplays = selection
            $0.timeTurnerCaptureScope = "selected_displays"
        }
    }
}

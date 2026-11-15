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

    static var connected: [VisualMemoryDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay, let uuid = stableID(id) else { return nil }
            return VisualMemoryDisplay(id: id, uuid: uuid, name: screen.localizedName)
        }
    }

    static func metadata(_ display: SCDisplay) -> VisualMemoryDisplay {
        let name = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.localizedName ?? "Display \(display.displayID)"
        return .init(id: display.displayID, uuid: stableID(display.displayID) ?? "display-\(display.displayID)", name: name)
    }
}

enum TimeTurnerCaptureScope: String, CaseIterable {
    case focused, all = "all_displays", selected = "selected_displays"

    var label: String {
        switch self {
        case .focused: "Focused window"
        case .all: "All displays"
        case .selected: "Selected displays"
        }
    }
}

struct TimeTurnerCaptureChoice: Equatable {
    var scope: TimeTurnerCaptureScope
    var displays: [String: String]

    init(scope: TimeTurnerCaptureScope, displays: [String: String]) {
        self.scope = scope
        self.displays = displays
    }

    init(config: AppConfig) {
        scope = TimeTurnerCaptureScope(rawValue: config.timeTurnerCaptureScope) ?? .focused
        displays = config.timeTurnerSelectedDisplays
    }

    func includesEntireDisplay(_ id: String) -> Bool {
        scope == .all || (scope == .selected && displays[id] != nil)
    }

    mutating func toggleDisplay(_ id: String, connected: [String: String]) {
        guard let name = connected[id] else { return }
        switch scope {
        case .focused: displays = [id: name]
        case .all:
            displays = connected
            displays.removeValue(forKey: id)
        case .selected:
            if displays[id] != nil { displays.removeValue(forKey: id) }
            else { displays[id] = name }
        }
        scope = .selected
    }

    var isValid: Bool { scope != .selected || !displays.isEmpty }
}

/// A resource picker, like app exclusions. Changes stay in a draft until Finish/Save.
/// Preview frames live only in memory and are not added to screen history.
struct TimeTurnerDisplayPicker: View {
    @Binding var choice: TimeTurnerCaptureChoice
    @Binding var initialized: Bool
    @State private var sources: [MeetingScreenSource] = []
    @State private var revision = 0
    @State private var previewRevision = 0
    @State private var loading = true
    @State private var error: String?

    private var connected: [String: String] {
        Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    private var instructions: String {
        switch choice.scope {
        case .focused: "Choose one or more displays, or continue with just the focused window."
        case .all: "All displays are checked, including any you connect later. Uncheck a display to limit capture."
        case .selected: "Capture the checked displays whenever they’re connected."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(instructions)
                .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(sources) { source in
                        let selected = choice.includesEntireDisplay(source.id)
                        Button {
                            initialized = true
                            choice.toggleDisplay(source.id, connected: connected)
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
                if choice.scope == .selected && !loading && error == nil {
                    ForEach(choice.displays.keys.filter { id in !sources.contains { $0.id == id } }.sorted(), id: \.self) { id in
                        HStack {
                            Label(choice.displays[id] ?? "Display", systemImage: "display")
                            Text("Disconnected").foregroundStyle(MuesliTheme.textSecondary)
                            Spacer()
                            Button("Remove") { choice.displays.removeValue(forKey: id) }
                        }.font(MuesliTheme.body()).padding(.vertical, 6)
                    }
                }
                if loading { ProgressView().controlSize(.small).padding() }
                if let error { Text(error).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary) }
                if !loading && sources.isEmpty && error == nil {
                    Text("No displays available.").font(MuesliTheme.body())
                }
            }
            HStack {
                if choice.scope == .selected {
                    Text("\(choice.displays.count) selected").font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }
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
            initializeSelectionIfNeeded()
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = CGPreflightScreenCaptureAccess()
                ? "Couldn’t load displays. Try refreshing."
                : "Allow Screen Recording in System Settings, then refresh."
            loading = false
        }
    }

    private func initializeSelectionIfNeeded() {
        guard choice.scope == .selected, !initialized, !sources.isEmpty else { return }
        choice.displays = connected
        initialized = true
    }
}

struct TimeTurnerDisplaySelectionSheet: View {
    let controller: MuesliController
    @Environment(\.dismiss) private var dismiss
    @State private var choice: TimeTurnerCaptureChoice
    @State private var initialized: Bool
    @State private var saving = false
    @State private var saveError: String?

    init(controller: MuesliController, selection: [String: String]) {
        self.controller = controller
        _choice = State(initialValue: TimeTurnerCaptureChoice(scope: .selected, displays: selection))
        _initialized = State(initialValue: !selection.isEmpty)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Choose displays").font(MuesliTheme.title2())
            TimeTurnerDisplayPicker(choice: $choice, initialized: $initialized)
            if let saveError { SettingsNote(saveError, tone: .warning) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            try await controller.applySetting("time_turner_capture_scope", value: TimeTurnerCaptureScope.selected.rawValue,
                                                              selectedDisplays: choice.displays)
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!choice.isValid)
            }
        }.disabled(saving).padding(24).frame(width: 560, height: 470)
            .font(MuesliTheme.body())
    }
}

extension MuesliController {
    func finishTimeTurnerSetup(choice: TimeTurnerCaptureChoice, original: TimeTurnerCaptureChoice) async throws {
        guard !config.timeTurnerEnabled else { return }
        guard choice.isValid else { throw MuesliSettings.Failure.rejected("Choose at least one display.") }
        if choice != original {
            try await applySetting("time_turner_capture_scope", value: choice.scope.rawValue,
                                   selectedDisplays: choice.scope == .selected ? choice.displays : nil)
        }
        try await applySetting("time_turner_enabled", value: "on")
    }
}

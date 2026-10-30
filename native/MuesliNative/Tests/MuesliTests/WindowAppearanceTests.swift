import AppKit
import Foundation
import MuesliCore
import SwiftUI
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("WindowAppearance", .serialized)
struct WindowAppearanceTests {

    @Test("Ultra Dark resolves black backgrounds and white accents")
    func ultraDarkPalette() throws {
        let original = MuesliTheme.appearance.ultraDark
        MuesliTheme.appearance.ultraDark = true
        defer { MuesliTheme.appearance.ultraDark = original }
        let appearance = try #require(NSAppearance(named: .darkAqua))
        appearance.performAsCurrentDrawingAppearance {
            let background = MuesliTheme.backgroundDeepNSColor.usingColorSpace(.deviceRGB)!
            let accent = NSColor(MuesliTheme.defaultAccent).usingColorSpace(.deviceRGB)!
            let foreground = NSColor(MuesliTheme.onAccent).usingColorSpace(.deviceRGB)!
            #expect(background.redComponent == 0 && background.greenComponent == 0 && background.blueComponent == 0)
            #expect(accent.redComponent == 1 && accent.greenComponent == 1 && accent.blueComponent == 1)
            #expect(foreground.redComponent == 0)
        }
    }

    @Test("Ultra Dark switches retain the saved accent while primary actions stay white")
    func ultraDarkToggleAccent() throws {
        let originalMode = MuesliTheme.appearance.ultraDark
        let originalAccent = MuesliTheme.accentOverrideHex
        defer {
            MuesliTheme.appearance.ultraDark = originalMode
            MuesliTheme.accentOverrideHex = originalAccent
        }
        MuesliTheme.appearance.ultraDark = true
        let appearance = try #require(NSAppearance(named: .darkAqua))
        appearance.performAsCurrentDrawingAppearance {
            MuesliTheme.accentOverrideHex = nil
            let defaultToggle = NSColor(MuesliTheme.toggleAccent).usingColorSpace(.deviceRGB)!
            #expect(defaultToggle.blueComponent > defaultToggle.redComponent)
            MuesliTheme.accentOverrideHex = "FF0000"
            let customToggle = NSColor(MuesliTheme.toggleAccent).usingColorSpace(.deviceRGB)!
            #expect(customToggle.redComponent == 1 && customToggle.greenComponent == 0)
            let action = NSColor(MuesliTheme.accent).usingColorSpace(.deviceRGB)!
            #expect(action.redComponent == 1 && action.greenComponent == 1 && action.blueComponent == 1)
        }
    }

    @Test("ordinary Dark keeps its colored accent and layered background")
    func ordinaryDarkPalette() throws {
        let original = MuesliTheme.appearance.ultraDark
        MuesliTheme.appearance.ultraDark = false
        defer { MuesliTheme.appearance.ultraDark = original }
        let appearance = try #require(NSAppearance(named: .darkAqua))
        appearance.performAsCurrentDrawingAppearance {
            let background = MuesliTheme.backgroundDeepNSColor.usingColorSpace(.deviceRGB)!
            let accent = NSColor(MuesliTheme.defaultAccent).usingColorSpace(.deviceRGB)!
            #expect(background.redComponent > 0)
            #expect(accent.blueComponent > accent.redComponent)
        }
    }

    @Test("dark mode maps to the dark AppKit appearance")
    func darkModeMapsToDarkAqua() {
        #expect(AppAppearanceMode.dark.appearanceName == .darkAqua)
    }

    @Test("light mode maps to the light AppKit appearance")
    func lightModeMapsToAqua() {
        #expect(AppAppearanceMode.light.appearanceName == .aqua)
    }

    @Test("system appearance clears AppKit overrides")
    func systemAppearanceInherits() {
        #expect(AppAppearanceMode.system.appearanceName == nil)
    }

    @Test("legacy appearance preferences retain their selected theme", arguments: [true, false])
    func legacyAppearance(dark: Bool) throws {
        let data = Data("{\"dark_mode\":\(dark)}".utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.appearanceMode == (dark ? .dark : .light))
    }

    @Test("system choice persists and explicit themes clear it")
    func appearanceRoundTrip() throws {
        var config = AppConfig()
        for mode in [AppAppearanceMode.system, .ultraDark, .light, .ultraDark, .system, .dark] {
            config.appearanceMode = mode
            let saved = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            #expect(saved.appearanceMode == mode)
            #expect(saved.followSystemAppearance == (mode == .system))
            #expect(saved.ultraDarkAppearance == (mode == .ultraDark))
        }
    }

    @Test("appearance uses the shared settings executor and persists each choice")
    func appearanceSetting() async throws {
        // Create AppKit before applying a setting, including when this suite runs alone.
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let configStore = ConfigStore(supportDirectory: directory)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: configStore)
        let setting = try #require(controller.settingsDefinitions().first { $0.id == "appearance" })
        #expect(setting.snapshot(config: controller.config).choices.map(\.id) == ["light", "system", "dark", "ultra_dark"])
        let sidebarSetting = controller.appearanceDefinition()
        #expect(sidebarSetting.id == setting.id)
        #expect(sidebarSetting.snapshot(config: controller.config).choices.map(\.id)
            == setting.snapshot(config: controller.config).choices.map(\.id))
        #expect(setting.snapshot(config: controller.config, source: .voice).unavailable["ultra_dark"] != nil)
        #expect(setting.snapshot(config: controller.config, source: .manualUI).unavailable["ultra_dark"] == nil)
        #expect(!AppAppearanceMode.quickChoices.contains(.ultraDark))
        let originalAppearance = NSApp?.appearance
        defer { NSApp?.appearance = originalAppearance }
        for mode in [AppAppearanceMode.light, .ultraDark, .dark, .system] {
            try await controller.applySetting("appearance", value: mode.rawValue)
            #expect(controller.appState.config.appearanceMode == mode)
            #expect(configStore.load().appearanceMode == mode)
            #expect(sidebarSetting.read(configStore.load()) == mode.rawValue)
            if let app = NSApp { #expect(app.appearance?.name == mode.appearanceName) }
        }
    }

    @Test("live dashboard releases explicit appearance when switching to System")
    func liveDashboardReturnsToSystem() async throws {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        defer { app.appearance = originalAppearance }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: ConfigStore(supportDirectory: directory))
        // Avoid the Timeline's first-run bridge onboarding and its telemetry in this UI fixture.
        controller.appState.selectedTab = .shortcuts
        let dashboard = RecentHistoryWindowController(store: store, controller: controller)
        dashboard.show()
        defer { dashboard.close() }
        let window = try #require(dashboard.presentationWindow)
        for mode in [AppAppearanceMode.light, .ultraDark, .system, .dark, .system] {
            try await controller.applySetting("appearance", value: mode.rawValue)
            dashboard.applyThemeAppearance()
            // Let SwiftUI commit its appearance preferences to the actual hosting window.
            try await Task.sleep(for: .milliseconds(200))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(window.appearance?.name == mode.appearanceName)
            let expected = mode == .ultraDark ? NSAppearance.Name.darkAqua : (mode.appearanceName ?? app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
            #expect(window.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        }
    }

    @Test("settings breakpoint preserves native editor focus selection and undo")
    func settingsBreakpointPreservesEditor() async throws {
        _ = NSApplication.shared
        let state = SettingsEditorLayoutState()
        let host = NSHostingView(rootView: SettingsEditorLayoutHarness(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(state.editor)
        editor.allowsUndo = true
        editor.undoManager?.groupsByEvent = false
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("Endpoint draft", replacementRange: NSRange(location: 0, length: 0))
        editor.undoManager?.endUndoGrouping()
        let selection = NSRange(location: 2, length: 5)
        editor.setSelectedRange(selection)
        #expect(window.makeFirstResponder(editor))
        #expect(editor.undoManager?.canUndo == true)
        for stacked in [true, false, true] {
            state.stacked = stacked
            host.frame.size.width = stacked ? 420 : 700
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(state.creationCount == 1)
            #expect(state.editor === editor)
            #expect(window.firstResponder === editor)
            #expect(editor.selectedRange() == selection)
            #expect(editor.string == "Endpoint draft")
            #expect(editor.undoManager?.canUndo == true)
        }
        editor.undoManager?.undo()
        #expect(editor.string.isEmpty)
    }

    @Test("dashboard can shrink beside a call window")
    func dashboardUsesCompactMinimumWidth() {
        #expect(DashboardWindowLayout.minimumContentWidth == 520)
        #expect(DashboardWindowLayout.minimumContentWidth < 900)
        #expect(DashboardWindowLayout.minimumContentHeight == 600)
    }

    @Test("menu bar meeting placement uses the top-right of the active display")
    func menuBarMeetingPlacementUsesTopRightOfDisplay() {
        let visibleFrame = NSRect(x: -1920, y: 23, width: 1920, height: 1057)
        let frame = DashboardWindowPlacement.compactTrailingFrame(
            currentFrame: NSRect(x: 180, y: 140, width: 1120, height: 790),
            visibleFrame: visibleFrame,
            targetFrameWidth: DashboardWindowLayout.minimumContentWidth
        )

        #expect(frame.maxX == visibleFrame.maxX)
        #expect(frame.maxY == visibleFrame.maxY)
        #expect(frame.width == DashboardWindowLayout.minimumContentWidth)
        #expect(frame.height == 790)
    }

    @Test("menu bar meeting placement stays inside a smaller display")
    func menuBarMeetingPlacementClampsToDisplay() {
        let visibleFrame = NSRect(x: 0, y: 25, width: 500, height: 575)
        let frame = DashboardWindowPlacement.compactTrailingFrame(
            currentFrame: NSRect(x: 100, y: 100, width: 1120, height: 790),
            visibleFrame: visibleFrame,
            targetFrameWidth: DashboardWindowLayout.minimumContentWidth
        )

        #expect(frame == visibleFrame)
    }

    @Test("compact quick notes hides the sidebar only for an open meeting")
    func compactQuickNotesPresentationPolicy() {
        #expect(DashboardWindowLayout.usesCompactQuickNotes(width: 520, hasOpenMeeting: true))
        #expect(!DashboardWindowLayout.usesCompactQuickNotes(width: 600, hasOpenMeeting: true))
        #expect(!DashboardWindowLayout.usesCompactQuickNotes(width: 520, hasOpenMeeting: false))
    }

    @Test("dashboard renders one working custom sidebar toggle")
    func dashboardRendersOneWorkingSidebarToggle() {
        var actionCount = 0
        let expandedControl = SidebarToggleButton(isCollapsed: false) {
            actionCount += 1
        }
        let expandedRenderer = ImageRenderer(content: expandedControl)
        expandedRenderer.proposedSize = ProposedViewSize(width: 36, height: 36)

        #expect(expandedControl.accessibilityTitle == "Collapse sidebar")
        #expect(expandedRenderer.nsImage != nil)

        expandedControl.action()
        #expect(actionCount == 1)

        let collapsedControl = SidebarToggleButton(isCollapsed: true) {}
        let collapsedRenderer = ImageRenderer(content: collapsedControl)
        collapsedRenderer.proposedSize = ProposedViewSize(width: 36, height: 36)

        #expect(collapsedControl.accessibilityTitle == "Expand sidebar")
        #expect(collapsedRenderer.nsImage != nil)
    }

    @Test("meeting header chooses its compact layout at a constrained width")
    func meetingHeaderRendersCompactControls() {
        let selection = LayoutSelectionRecorder()
        let content =
            ResponsiveHorizontalLayout(
                wideIdentifier: "meeting.header.wide",
                compactIdentifier: "meeting.header.compact"
            ) {
                LayoutSelectionProbe(name: "wide", width: 600, recorder: selection)
            } compact: {
                LayoutSelectionProbe(name: "compact", width: 100, recorder: selection)
            }
            .frame(width: 360, height: DashboardWindowLayout.minimumContentHeight)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(
            width: 360,
            height: DashboardWindowLayout.minimumContentHeight
        )

        #expect(renderer.nsImage != nil)

        #expect(selection.names == ["compact"])
    }

    @Test("compact formatting follows editable note-taking workflows")
    func compactFormattingPolicy() {
        #expect(CompactMeetingFormattingPolicy.showsFormattingControls(for: .recording, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .recording, isPreparing: true))
        #expect(CompactMeetingFormattingPolicy.showsFormattingControls(for: .noteOnly, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .failed, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .processing, isPreparing: false))
        #expect(!CompactMeetingFormattingPolicy.showsFormattingControls(for: .completed, isPreparing: false))
    }

    @Test("compact threshold preserves dashboard detail identity")
    func compactThresholdPreservesDashboardDetailIdentity() async {
        let presentation = DashboardLayoutPresentation()
        let lifecycle = DashboardDetailLifecycleRecorder()
        let hostingView = NSHostingView(
            rootView: DashboardLayoutIdentityHarness(
                presentation: presentation,
                lifecycle: lifecycle
            )
        )
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 700, height: DashboardWindowLayout.minimumContentHeight)
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView

        hostingView.layoutSubtreeIfNeeded()
        #expect(await waitForAppearance(lifecycle))
        #expect(lifecycle.appearanceCount == 1)
        #expect(lifecycle.disappearanceCount == 0)

        presentation.usesCompactQuickNotes = true
        hostingView.frame.size.width = DashboardWindowLayout.minimumContentWidth
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        #expect(lifecycle.appearanceCount == 1)
        #expect(lifecycle.disappearanceCount == 0)

        presentation.usesCompactQuickNotes = false
        hostingView.frame.size.width = 700
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        #expect(lifecycle.appearanceCount == 1)
        #expect(lifecycle.disappearanceCount == 0)
    }

    private func waitForAppearance(_ lifecycle: DashboardDetailLifecycleRecorder) async -> Bool {
        for _ in 0..<50 {
            if lifecycle.appearanceCount > 0 {
                return true
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lifecycle.appearanceCount > 0
    }

    @Test("expanded sidebar fits the window when the folder tree is taller than it")
    func expandedSidebarScrollsLongFolderTree() {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-sidebar-test-\(UUID().uuidString)", isDirectory: true)
        let store = DictationStore(databaseURL: supportDirectory.appendingPathComponent("muesli.db"))
        try? store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
        // 40 visible folder rows are far taller than the minimum window.
        controller.appState.folders = (1...40).map { index in
            MeetingFolder(id: Int64(index), name: "Folder \(index)", createdAt: "2026-01-01T00:00:00Z")
        }

        let height = DashboardWindowLayout.minimumContentHeight
        let hostingController = NSHostingController(
            rootView: SidebarView(appState: controller.appState, controller: controller)
        )
        let fitted = hostingController.sizeThatFits(in: NSSize(width: 260, height: height))

        // Without a scroll container the stack cannot shrink below the height
        // of every row, so it reports far more than the window offers.
        #expect(fitted.height <= height)
    }

    @Test("dashboard wires the production sidebar toggle and compact meeting header")
    func dashboardWiresProductionSidebarAndCompactMeetingComposition() {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-window-test-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = supportDirectory.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: databaseURL)
        try? store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
        let meeting = MeetingRecord(
            id: 42,
            title: "Compact Header Test",
            startTime: ISO8601DateFormatter().string(from: Date()),
            durationSeconds: 0,
            rawTranscript: "",
            formattedNotes: "",
            wordCount: 0,
            folderID: nil,
            status: .recording
        )
        controller.appState.selectedTab = .meetings
        controller.appState.selectedMeetingID = meeting.id
        controller.appState.selectedMeetingRecord = meeting
        controller.appState.meetingsNavigationState = .document(meeting.id)

        let sidebarPresentation = DashboardSidebarPresentation()
        let rootView = DashboardRootView(
            appState: controller.appState,
            controller: controller,
            sidebarPresentation: sidebarPresentation
        )
        let productionSidebar = rootView.sidebarView
        #expect(!productionSidebar.isCollapsed)
        #expect(SidebarToggleButton.accessibilityIdentifier == "dashboard.sidebar.toggle")

        productionSidebar.onToggleCollapsed()
        #expect(sidebarPresentation.isCollapsed)
        #expect(rootView.sidebarView.isCollapsed)

        let renderer = ImageRenderer(
            content: rootView.frame(
                width: DashboardWindowLayout.minimumContentWidth,
                height: DashboardWindowLayout.minimumContentHeight
            )
        )
        renderer.proposedSize = ProposedViewSize(
            width: DashboardWindowLayout.minimumContentWidth,
            height: DashboardWindowLayout.minimumContentHeight
        )

        let image = renderer.nsImage
        #expect(image != nil)
        #expect(image?.size.width == DashboardWindowLayout.minimumContentWidth)
        #expect(image?.size.height == DashboardWindowLayout.minimumContentHeight)
    }

}

@MainActor
private final class LayoutSelectionRecorder {
    var names: [String] = []
}

private struct LayoutSelectionProbe: View {
    let name: String
    let width: CGFloat
    let recorder: LayoutSelectionRecorder

    var body: some View {
        Color.clear
            .frame(width: width, height: 40)
            .onAppear { recorder.names.append(name) }
    }
}

@MainActor
@Observable
private final class DashboardLayoutPresentation {
    var usesCompactQuickNotes = false
}

@MainActor
private final class DashboardDetailLifecycleRecorder {
    var appearanceCount = 0
    var disappearanceCount = 0
}

private struct DashboardLayoutIdentityHarness: View {
    let presentation: DashboardLayoutPresentation
    let lifecycle: DashboardDetailLifecycleRecorder

    var body: some View {
        DashboardContentLayout(
            usesCompactQuickNotes: presentation.usesCompactQuickNotes
        ) {
            Color.clear
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
        } detail: {
            DashboardDetailIdentityProbe(lifecycle: lifecycle)
        }
    }
}

private struct DashboardDetailIdentityProbe: View {
    let lifecycle: DashboardDetailLifecycleRecorder

    var body: some View {
        Color.clear
            .onAppear { lifecycle.appearanceCount += 1 }
            .onDisappear { lifecycle.disappearanceCount += 1 }
    }
}


@MainActor
@Observable
private final class SettingsEditorLayoutState {
    var stacked = false
    @ObservationIgnored var editor: SettingsIdentityTextView?
    @ObservationIgnored var creationCount = 0
}

private struct SettingsEditorLayoutHarness: View {
    let state: SettingsEditorLayoutState
    var body: some View {
        SettingsRow(label: "Endpoint", description: "Provider URL") {
            SettingsIdentityEditor(state: state).frame(height: 28)
        }
        .environment(\.settingsStacksControls, state.stacked)
    }
}

private struct SettingsIdentityEditor: NSViewRepresentable {
    let state: SettingsEditorLayoutState
    func makeNSView(context: Context) -> SettingsIdentityTextView {
        let editor = SettingsIdentityTextView()
        state.editor = editor
        state.creationCount += 1
        return editor
    }
    func updateNSView(_ nsView: SettingsIdentityTextView, context: Context) {}
}

@MainActor
private final class SettingsIdentityTextView: NSTextView {
    private let testUndo = UndoManager()
    override var undoManager: UndoManager? { testUndo }
}

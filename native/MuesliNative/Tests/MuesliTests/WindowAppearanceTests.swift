import AppKit
import Foundation
import MuesliCore
import SwiftUI
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("WindowAppearance", .serialized)
struct WindowAppearanceTests {

    @Test("dark mode maps to the dark AppKit appearance")
    func darkModeMapsToDarkAqua() {
        #expect(RecentHistoryWindowController.appearanceName(for: true) == .darkAqua)
    }

    @Test("light mode maps to the light AppKit appearance")
    func lightModeMapsToAqua() {
        #expect(RecentHistoryWindowController.appearanceName(for: false) == .aqua)
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

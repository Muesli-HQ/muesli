import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("WindowAppearance")
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
        #expect(DashboardWindowLayout.minimumContentWidth == 620)
        #expect(DashboardWindowLayout.minimumContentWidth < 900)
        #expect(DashboardWindowLayout.minimumContentHeight == 600)
    }

    @Test("dashboard uses its custom sidebar without a navigation toolbar toggle")
    func dashboardUsesOnlyCustomSidebarToggle() throws {
        let source = try dashboardRootViewSource()
        #expect(source.contains("HSplitView"))
        #expect(!source.contains("NavigationSplitView"))
        #expect(!source.contains("navigationSplitViewColumnWidth"))
    }

    @Test("meeting header has compact fallbacks for narrow notes windows")
    func meetingHeaderHasCompactFallbacks() throws {
        let source = try meetingDetailViewSource()
        #expect(source.contains("private func responsiveTitleAndActions"))
        #expect(source.contains("private func responsiveContextControls"))
        #expect(source.components(separatedBy: "ViewThatFits(in: .horizontal)").count >= 5)
    }

    private func appSource(named name: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func meetingDetailViewSource() throws -> String {
        try appSource(named: "MeetingDetailView.swift")
    }

    private func dashboardRootViewSource() throws -> String {
        try appSource(named: "DashboardRootView.swift")
    }
}

import CoreGraphics
import Testing
@testable import MuesliNativeApp

@Suite("Accessibility permission guide")
struct AccessibilityPermissionGuideTests {
    @Test("lays the guide out inside the System Settings content area")
    func layoutFitsSettingsContent() throws {
        let settingsWindow = CGRect(x: 100, y: 80, width: 1_000, height: 800)
        let frames = try #require(AccessibilityPermissionGuideLayout.frames(for: settingsWindow))

        #expect(settingsWindow.contains(frames.target))
        #expect(settingsWindow.contains(frames.card))
        #expect(frames.card.contains(frames.dragSource))
        #expect(frames.target.minY > frames.card.maxY)
        #expect(frames.target.minX > settingsWindow.minX + 250)
    }

    @Test("does not present when System Settings is too small")
    func rejectsSmallSettingsWindows() {
        #expect(AccessibilityPermissionGuideLayout.frames(
            for: CGRect(x: 0, y: 0, width: 719, height: 800)
        ) == nil)
        #expect(AccessibilityPermissionGuideLayout.frames(
            for: CGRect(x: 0, y: 0, width: 900, height: 499)
        ) == nil)
    }

    @Test("presents only for an active untrusted Accessibility request")
    func presentationPolicy() {
        let settingsBundleID = AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID

        #expect(AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isTrusted: false,
            frontmostBundleID: settingsBundleID,
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: false,
            isTrusted: false,
            frontmostBundleID: settingsBundleID,
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isTrusted: true,
            frontmostBundleID: settingsBundleID,
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isTrusted: false,
            frontmostBundleID: "com.apple.finder",
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isTrusted: false,
            frontmostBundleID: settingsBundleID,
            hasSettingsWindow: false
        ))
    }

    @Test("converts Quartz window coordinates to AppKit coordinates")
    func convertsWindowCoordinates() {
        let converted = SystemSettingsWindowGeometry.appKitFrame(
            fromQuartz: CGRect(x: 120, y: 100, width: 900, height: 700),
            primaryScreenMaxY: 1_200
        )

        #expect(converted == CGRect(x: 120, y: 400, width: 900, height: 700))
    }
}

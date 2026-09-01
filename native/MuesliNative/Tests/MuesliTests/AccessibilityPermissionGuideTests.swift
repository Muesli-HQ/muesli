import CoreGraphics
import Testing
@testable import MuesliNativeApp

@Suite("Accessibility permission guide")
struct AccessibilityPermissionGuideTests {
    @Test("lays out a compact guide inside the System Settings content area")
    func layoutFitsSettingsContent() throws {
        let settingsWindow = CGRect(x: 100, y: 80, width: 1_000, height: 800)
        let frames = try #require(AccessibilityPermissionGuideLayout.frames(for: settingsWindow))

        #expect(settingsWindow.contains(frames.guide))
        #expect(frames.guide.contains(frames.dragSource))
        #expect(frames.guide.contains(frames.completedGuide))
        #expect(frames.guide.height == 128)
        #expect(frames.guide.width <= 640)
        #expect(frames.dragSource.height == 70)
        #expect(frames.dragSource.minY - frames.guide.minY == 12)
        #expect(frames.guide.minX > settingsWindow.minX + 250)
        #expect(frames.dragDirection == .up)
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

    @Test("presents only for an active ungranted permission request")
    func presentationPolicy() {
        let settingsBundleID = AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID

        #expect(AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: settingsBundleID,
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: false,
            isGranted: false,
            frontmostBundleID: settingsBundleID,
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isGranted: true,
            frontmostBundleID: settingsBundleID,
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: "com.apple.finder",
            hasSettingsWindow: true
        ))
        #expect(!AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isGranted: false,
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

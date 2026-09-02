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
        #expect(settingsWindow.contains(frames.permissionListDropRegion))
        #expect(!frames.guide.intersects(frames.permissionListDropRegion))
        #expect(frames.permissionListDropRegion.height > frames.dragSource.height)
        #expect(frames.guide.height == 128)
        #expect(frames.guide.width <= 640)
        #expect(frames.dragSource.height == 70)
        #expect(frames.dragSource.minY - frames.guide.minY == 12)
        #expect(frames.guide.minX > settingsWindow.minX + 250)
        #expect(frames.dragDirection == .up)
    }

    @Test("completes only for an accepted drop in the active System Settings permission list")
    func validatesPermissionListDrop() throws {
        let settingsWindow = CGRect(x: 100, y: 80, width: 1_000, height: 800)
        let frames = try #require(AccessibilityPermissionGuideLayout.frames(for: settingsWindow))
        let targetPoint = CGPoint(
            x: frames.permissionListDropRegion.midX,
            y: frames.permissionListDropRegion.midY
        )

        #expect(AccessibilityPermissionGuideDropPolicy.isPermissionListDrop(
            operationAccepted: true,
            dropPoint: targetPoint,
            frontmostBundleID: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID,
            settingsWindow: settingsWindow
        ))
        #expect(!AccessibilityPermissionGuideDropPolicy.isPermissionListDrop(
            operationAccepted: false,
            dropPoint: targetPoint,
            frontmostBundleID: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID,
            settingsWindow: settingsWindow
        ))
        #expect(!AccessibilityPermissionGuideDropPolicy.isPermissionListDrop(
            operationAccepted: true,
            dropPoint: CGPoint(x: frames.dragSource.midX, y: frames.dragSource.midY),
            frontmostBundleID: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID,
            settingsWindow: settingsWindow
        ))
        #expect(!AccessibilityPermissionGuideDropPolicy.isPermissionListDrop(
            operationAccepted: true,
            dropPoint: targetPoint,
            frontmostBundleID: "com.apple.finder",
            settingsWindow: settingsWindow
        ))
    }

    @Test("preserves completion when reopening the same permission guide")
    func invocationPolicy() {
        let reopeningSamePermission = AccessibilityPermissionGuideInvocationPolicy.shouldResetDragCompletion(
            previousPermission: .accessibility,
            nextPermission: .accessibility
        )
        let changingPermission = AccessibilityPermissionGuideInvocationPolicy.shouldResetDragCompletion(
            previousPermission: .accessibility,
            nextPermission: .inputMonitoring
        )
        let firstInvocation = AccessibilityPermissionGuideInvocationPolicy.shouldResetDragCompletion(
            previousPermission: nil,
            nextPermission: .accessibility
        )

        #expect(!reopeningSamePermission)
        #expect(changingPermission)
        #expect(firstInvocation)
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

    @Test("keeps onboarding suppressed while an unrelated app is frontmost")
    func suppressionPolicy() {
        let settingsBundleID = AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID
        let muesliBundleID = "com.muesli.dev.b"

        #expect(AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: settingsBundleID,
            muesliBundleID: muesliBundleID,
            isCurrentlySuppressed: false
        ))
        #expect(AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: "com.apple.finder",
            muesliBundleID: muesliBundleID,
            isCurrentlySuppressed: true
        ))
        #expect(!AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: muesliBundleID,
            muesliBundleID: muesliBundleID,
            isCurrentlySuppressed: true
        ))
        #expect(!AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: true,
            frontmostBundleID: settingsBundleID,
            muesliBundleID: muesliBundleID,
            isCurrentlySuppressed: true
        ))
    }

    @Test("only drag-guide permissions hide onboarding while keeping it mounted")
    func onboardingSystemSettingsYieldPolicy() {
        #expect(OnboardingSystemSettingsYieldPolicy.behavior(for: nil) == .orderedBehind)
        #expect(OnboardingSystemSettingsYieldPolicy.behavior(for: .accessibility) == .hiddenButMounted)
        #expect(OnboardingSystemSettingsYieldPolicy.behavior(for: .inputMonitoring) == .hiddenButMounted)
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

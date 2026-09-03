import CoreGraphics
import Foundation
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
        #expect(frames.guide.contains(frames.postDropGuide))
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

    @Test("recognizes only likely drop attempts in the active System Settings permission region")
    func validatesLikelyPermissionListDropAttempt() throws {
        let settingsWindow = CGRect(x: 100, y: 80, width: 1_000, height: 800)
        let frames = try #require(AccessibilityPermissionGuideLayout.frames(for: settingsWindow))
        let targetPoint = CGPoint(
            x: frames.permissionListDropRegion.midX,
            y: frames.permissionListDropRegion.midY
        )

        #expect(AccessibilityPermissionGuideDropPolicy.isLikelyPermissionListDropAttempt(
            operationAccepted: true,
            dropPoint: targetPoint,
            frontmostBundleID: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID,
            settingsWindow: settingsWindow
        ))
        #expect(!AccessibilityPermissionGuideDropPolicy.isLikelyPermissionListDropAttempt(
            operationAccepted: false,
            dropPoint: targetPoint,
            frontmostBundleID: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID,
            settingsWindow: settingsWindow
        ))
        #expect(!AccessibilityPermissionGuideDropPolicy.isLikelyPermissionListDropAttempt(
            operationAccepted: true,
            dropPoint: CGPoint(x: frames.dragSource.midX, y: frames.dragSource.midY),
            frontmostBundleID: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID,
            settingsWindow: settingsWindow
        ))
        #expect(!AccessibilityPermissionGuideDropPolicy.isLikelyPermissionListDropAttempt(
            operationAccepted: true,
            dropPoint: targetPoint,
            frontmostBundleID: "com.apple.finder",
            settingsWindow: settingsWindow
        ))
    }

    @Test("an accepted drop attempt does not claim that Muesli was added")
    func attemptedDropCopyIsNonDefinitive() {
        #expect(AccessibilityPermissionGuideCopy.attemptedDropTitle(appName: "MuesliDevB") == "Turn MuesliDevB on")
        #expect(AccessibilityPermissionGuideCopy.attemptedDropDetail == "If it appears above, turn on its switch")
    }

    @Test("restores the drag source after an ungranted drop attempt")
    func restoresDragSourceAfterFailedDropAttempt() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let deadline = AccessibilityPermissionGuideRetryPolicy.retryDeadline(startingAt: start)

        #expect(AccessibilityPermissionGuideRetryPolicy.permissionCheckInterval == 0.5)
        #expect(AccessibilityPermissionGuideRetryPolicy.attemptedDropRetryWindow == 10)
        #expect(deadline == start.addingTimeInterval(10))
        #expect(!AccessibilityPermissionGuideRetryPolicy.shouldRestoreDragSource(
            didAttemptDrop: true,
            isGranted: false,
            retryDeadline: deadline,
            now: start.addingTimeInterval(9.999),
            isMuesliFrontmost: false
        ))
        #expect(AccessibilityPermissionGuideRetryPolicy.shouldRestoreDragSource(
            didAttemptDrop: true,
            isGranted: false,
            retryDeadline: deadline,
            now: deadline,
            isMuesliFrontmost: false
        ))
        #expect(AccessibilityPermissionGuideRetryPolicy.shouldRestoreDragSource(
            didAttemptDrop: true,
            isGranted: false,
            retryDeadline: deadline,
            now: start,
            isMuesliFrontmost: true
        ))
        #expect(!AccessibilityPermissionGuideRetryPolicy.shouldRestoreDragSource(
            didAttemptDrop: true,
            isGranted: true,
            retryDeadline: deadline,
            now: deadline,
            isMuesliFrontmost: true
        ))
        #expect(!AccessibilityPermissionGuideRetryPolicy.shouldRestoreDragSource(
            didAttemptDrop: false,
            isGranted: false,
            retryDeadline: deadline,
            now: deadline,
            isMuesliFrontmost: false
        ))
        #expect(!AccessibilityPermissionGuideRetryPolicy.shouldRestoreDragSource(
            didAttemptDrop: true,
            isGranted: false,
            retryDeadline: nil,
            now: deadline,
            isMuesliFrontmost: false
        ))
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

    @Test("suppresses onboarding only while a usable System Settings guide is frontmost")
    func suppressionPolicy() {
        let settingsBundleID = AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID
        let muesliBundleID = "com.muesli.dev.b"

        #expect(AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: settingsBundleID,
            hasUsableGuide: true
        ))
        #expect(!AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: settingsBundleID,
            hasUsableGuide: false
        ))
        #expect(!AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: "com.apple.finder",
            hasUsableGuide: false
        ))
        #expect(!AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: muesliBundleID,
            hasUsableGuide: true
        ))
        #expect(!AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: true,
            frontmostBundleID: settingsBundleID,
            hasUsableGuide: true
        ))

        #expect(AccessibilityPermissionGuideSuppressionPolicy.onboardingPresentation(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: settingsBundleID,
            muesliBundleID: muesliBundleID,
            hasUsableGuide: true
        ) == .suppressed)
        #expect(AccessibilityPermissionGuideSuppressionPolicy.onboardingPresentation(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: "com.apple.finder",
            muesliBundleID: muesliBundleID,
            hasUsableGuide: false
        ) == .restoredWithoutActivation)
        #expect(AccessibilityPermissionGuideSuppressionPolicy.onboardingPresentation(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: muesliBundleID,
            muesliBundleID: muesliBundleID,
            hasUsableGuide: false
        ) == .restoredAndActive)
        #expect(AccessibilityPermissionGuideSuppressionPolicy.onboardingPresentation(
            isRequested: true,
            isGranted: true,
            frontmostBundleID: settingsBundleID,
            muesliBundleID: muesliBundleID,
            hasUsableGuide: true
        ) == .restoredAndActive)
    }

    @Test("only drag-guide permissions let the guide control onboarding suppression")
    func onboardingSystemSettingsYieldPolicy() {
        #expect(OnboardingSystemSettingsYieldPolicy.behavior(for: nil) == .orderedBehind)
        #expect(OnboardingSystemSettingsYieldPolicy.behavior(for: .accessibility) == .guideControlled)
        #expect(OnboardingSystemSettingsYieldPolicy.behavior(for: .inputMonitoring) == .guideControlled)
    }

    @Test("maps both guided permission names to their guide type")
    func guidedPermissionNameMapping() {
        #expect(PermissionDragGuidePermission(permissionName: "Accessibility") == .accessibility)
        #expect(PermissionDragGuidePermission(permissionName: "Input Monitoring") == .inputMonitoring)
        #expect(PermissionDragGuidePermission(permissionName: "Microphone") == nil)
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

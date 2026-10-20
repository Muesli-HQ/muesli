import Foundation
import Testing
import SwiftUI
@testable import MuesliNativeApp

@Suite("Feature tour")
struct FeatureTourTests {
    private let tour = FeatureTourCatalog.latest

    @Test("marketing versions compare numeric components and ignore prerelease suffixes")
    func versionComparison() throws {
        #expect(try #require(MarketingVersion("0.8.3")) < #require(MarketingVersion("0.8.5")))
        #expect(try #require(MarketingVersion("0.8.5")) == #require(MarketingVersion("0.8.5.0")))
        #expect(try #require(MarketingVersion("0.8.5-preprod.2")) == #require(MarketingVersion("0.8.5")))
        #expect(MarketingVersion("not-a-version") == nil)
        #expect(MarketingVersion("999999999999999999999999.0") == nil)
        #expect(tour.displayVersion == "0.8.5")
        #expect(FeatureTour(version: "0.8.0", steps: []).displayVersion == "0.8")
    }

    @Test("target frame tracking ignores subpixel layout churn")
    func frameTrackingTolerance() {
        let current: [FeatureTourTarget: CGRect] = [
            .insightsEntry: CGRect(x: 20, y: 30, width: 200, height: 80)
        ]
        #expect(!FeatureTourFrameTracking.hasMeaningfulChange(
            from: current,
            to: [.insightsEntry: CGRect(x: 20.25, y: 30.25, width: 200, height: 80)]
        ))
        #expect(FeatureTourFrameTracking.hasMeaningfulChange(
            from: current,
            to: [.insightsEntry: CGRect(x: 21, y: 30, width: 200, height: 80)]
        ))
        #expect(FeatureTourFrameTracking.hasMeaningfulChange(
            from: current,
            to: [.meetingsSidebar: CGRect(x: 20, y: 30, width: 200, height: 80)]
        ))
    }

    @Test("callout layout uses rendered height and falls back to a visible edge")
    func calloutLayout() {
        let container = CGSize(width: 900, height: 600)
        let callout = CGSize(width: 380, height: 310)
        let bottomTarget = CGRect(x: 280, y: 500, width: 220, height: 50)

        let bottomPosition = FeatureTourCalloutLayout.position(
            spotlight: bottomTarget,
            containerSize: container,
            calloutSize: callout,
            target: .liveCaptionsSetting
        )
        #expect(bottomPosition.y < bottomTarget.minY)

        let topTarget = CGRect(x: 280, y: 30, width: 220, height: 50)
        let abovePreferred = FeatureTourCalloutLayout.position(
            spotlight: topTarget,
            containerSize: container,
            calloutSize: callout,
            target: .experimentalModels
        )
        #expect(abovePreferred.y > topTarget.maxY)

        let calloutFrame = CGRect(
            x: abovePreferred.x - callout.width / 2,
            y: abovePreferred.y - callout.height / 2,
            width: callout.width,
            height: callout.height
        )
        #expect(calloutFrame.minX >= 20)
        #expect(calloutFrame.maxX <= container.width - 20)
        #expect(calloutFrame.minY >= 20)
        #expect(calloutFrame.maxY <= container.height - 20)
    }

    @Test("tour background hit region leaves the real control interactive")
    func spotlightAllowsInteraction() {
        let shape = FeatureTourDimmingShape(
            spotlight: CGRect(x: 100, y: 100, width: 200, height: 60), cornerRadius: 10
        )
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(!path.contains(CGPoint(x: 200, y: 130), eoFill: true))
        #expect(path.contains(CGPoint(x: 50, y: 50), eoFill: true))
    }

    @Test("missing meeting targets keep the callout centered and available")
    func missingMeetingTargetLayout() {
        let position = FeatureTourCalloutLayout.position(
            spotlight: nil,
            containerSize: CGSize(width: 900, height: 600),
            calloutSize: CGSize(width: 380, height: 310),
            target: .meetingRetranscription
        )
        #expect(position == CGPoint(x: 450, y: 300))
    }

    @Test("dashboard presentation waits for its first ordered layout")
    func dashboardPresentationReadiness() {
        var readiness = DashboardPresentationReadiness<String>()

        let queuedBeforeReady = readiness.enqueue("feature tour")
        let firstLayoutRequest = readiness.requestInitialLayout()
        let duplicateLayoutRequest = readiness.requestInitialLayout()
        #expect(queuedBeforeReady == [])
        #expect(firstLayoutRequest)
        #expect(!duplicateLayoutRequest)

        readiness.cancelInitialLayout()
        let retriedLayoutRequest = readiness.requestInitialLayout()
        #expect(!readiness.isReady)
        #expect(retriedLayoutRequest)

        let firstLayoutActions = readiness.completeInitialLayout()
        let readyLayoutRequest = readiness.requestInitialLayout()
        let immediateActions = readiness.enqueue("future tour")
        #expect(firstLayoutActions == ["feature tour"])
        #expect(readiness.isReady)
        #expect(!readyLayoutRequest)
        #expect(immediateActions == ["future tour"])
    }

    @Test("existing users without legacy version markers see the first feature tour")
    func legacyUpgrade() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("fresh installs and pre-target versions do not see the tour")
    func ineligibleLaunches() {
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: false,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.4",
            previousVersion: "0.8.3",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("upgrade crossing the target version presents once")
    func crossingTarget() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5-preprod.2",
            previousVersion: "0.8.4",
            lastPresentedTourVersion: "0.8.4",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5",
            previousVersion: "0.8.4",
            lastPresentedTourVersion: "0.8.5",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.4",
            previousVersion: "0.8.3",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("prerelease upgrade at the target version presents only to established users")
    func prereleaseUpgradeAtTargetVersion() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5-preprod.2",
            previousVersion: "0.8.5-preprod.1",
            lastPresentedTourVersion: "0.8.4",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5-preprod.2",
            previousVersion: "0.8.5-preprod.2",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("0.8.5 highlights navigate to the relevant existing controls")
    func catalogShape() {
        #expect(tour.version == "0.8.5")
        #expect(tour.steps.count == 6)
        #expect(Set(tour.steps.map(\.id)).count == tour.steps.count)
        #expect(tour.steps.map(\.target) == [
            .recordingIndicatorStyle, .computerUseShortcut, .meetingSummaryProvider,
            .meetingRetranscription, .dictationRecordingMode, .bodhanFlexCard,
        ])
        #expect(FeatureTourTarget.recordingIndicatorStyle.navigationRoute == .settings(.appearance))
        #expect(FeatureTourTarget.computerUseShortcut.navigationRoute == .tab(.shortcuts))
        #expect(FeatureTourTarget.meetingSummaryProvider.navigationRoute == .settings(.meetings))
        #expect(FeatureTourTarget.meetingRetranscription.navigationRoute == .meetingRetranscription)
        #expect(FeatureTourTarget.dictationRecordingMode.navigationRoute == .tab(.shortcuts))
    }

    @Test("model feature-tour targets resolve routes without UI state")
    func modelNavigationRoutes() {
        #expect(FeatureTourTarget.parakeetFamilyCard.navigationRoute == .models(.dictation))
        #expect(FeatureTourTarget.bodhanFlexCard.navigationRoute == .models(.dictation))
        #expect(FeatureTourTarget.streamingModels.navigationRoute == .models(.streaming))
        #expect(FeatureTourTarget.experimentalModels.navigationRoute == .models(.dictation))
    }

    @Test("store suppresses fresh installs and presents a legacy upgrade only once")
    func storeLifecycle() throws {
        let suiteName = "FeatureTourTests.storeLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FeatureTourStore(defaults: defaults)

        #expect(store.automaticTour(
            currentVersion: "0.8.5",
            hasCompletedOnboarding: false,
            canPresent: false
        ) == nil)

        // A fresh install that later completes onboarding is already recorded at
        // 0.8.5 and does not receive a second onboarding-like flow.
        #expect(store.automaticTour(
            currentVersion: "0.8.5",
            hasCompletedOnboarding: true,
            canPresent: true
        ) == nil)

        defaults.removePersistentDomain(forName: suiteName)
        let legacyStore = FeatureTourStore(defaults: defaults)
        let presented = try #require(legacyStore.automaticTour(
            currentVersion: "0.8.5",
            hasCompletedOnboarding: true,
            canPresent: true
        ))
        legacyStore.markOffered(presented)

        #expect(legacyStore.automaticTour(
            currentVersion: "0.8.5",
            hasCompletedOnboarding: true,
            canPresent: true
        ) == nil)
    }

    @Test("permission repair defers the tour without consuming upgrade eligibility")
    func permissionRepairDeferral() throws {
        let suiteName = "FeatureTourTests.permissionRepair.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FeatureTourStore(defaults: defaults)

        #expect(store.automaticTour(
            currentVersion: "0.8.5",
            hasCompletedOnboarding: true,
            canPresent: false
        ) == nil)
        #expect(store.automaticTour(
            currentVersion: "0.8.5",
            hasCompletedOnboarding: true,
            canPresent: true
        ) != nil)
    }
}

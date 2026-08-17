import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Feature tour")
struct FeatureTourTests {
    private let tour = FeatureTourCatalog.latest

    @Test("marketing versions compare numeric components and ignore prerelease suffixes")
    func versionComparison() throws {
        #expect(try #require(MarketingVersion("0.8.1")) < #require(MarketingVersion("0.8.2")))
        #expect(try #require(MarketingVersion("0.8.2")) == #require(MarketingVersion("0.8.2.0")))
        #expect(try #require(MarketingVersion("0.8.2-preprod.2")) == #require(MarketingVersion("0.8.2")))
        #expect(MarketingVersion("not-a-version") == nil)
        #expect(MarketingVersion("999999999999999999999999.0") == nil)
        #expect(tour.displayVersion == "0.8.2")
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
            currentVersion: "0.8.2",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("fresh installs and pre-target versions do not see the tour")
    func ineligibleLaunches() {
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.2",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: false,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.1",
            previousVersion: "0.8.0",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("upgrade crossing the target version presents once")
    func crossingTarget() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.2-preprod.2",
            previousVersion: "0.8.1",
            lastPresentedTourVersion: "0.8.0",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.2",
            previousVersion: "0.8.1",
            lastPresentedTourVersion: "0.8.2",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.1",
            previousVersion: "0.8.0",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("prerelease upgrade at the target version presents only to established users")
    func prereleaseUpgradeAtTargetVersion() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.2-preprod.2",
            previousVersion: "0.8.2-preprod.1",
            lastPresentedTourVersion: "0.8.0",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.2-preprod.2",
            previousVersion: "0.8.2-preprod.2",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("0.8.2 catalog highlights a small set of unique product locations")
    func catalogShape() {
        #expect(tour.version == "0.8.2")
        #expect(tour.steps.map(\.target) == [.timelineSidebar])

        let fullTour = FeatureTourCatalog.latest(
            includeApplicationFilter: true,
            includeAppleSpeech: true,
            includeMeetingPeople: true
        )
        #expect(fullTour.steps.count == 4)
        #expect(Set(fullTour.steps.map(\.id)).count == fullTour.steps.count)
        #expect(Set(fullTour.steps.map(\.target)).count == fullTour.steps.count)
        #expect(fullTour.steps.map(\.target) == [
            .timelineSidebar,
            .timelineApplications,
            .appleSpeechCard,
            .meetingPeople,
        ])

        let timelineStep = fullTour.steps.first
        #expect(timelineStep?.message.contains("sidebar") == true)

        let applicationStep = fullTour.steps.first { $0.target == .timelineApplications }
        #expect(applicationStep?.id == "timeline-apps")
        #expect(applicationStep?.message.contains("Mail") == true)

        let appleSpeechStep = fullTour.steps.first { $0.target == .appleSpeechCard }
        #expect(appleSpeechStep?.id == "apple-speech")
        #expect(appleSpeechStep?.title == "Try Apple's native on-device speech model")
        #expect(appleSpeechStep?.message.contains("macOS 26") == true)
        #expect(appleSpeechStep?.target.modelsCategory == .dictation)

        let peopleStep = fullTour.steps.last
        #expect(peopleStep?.id == "meeting-people")
        #expect(peopleStep?.title == "Meeting attendees are now available!")
        #expect(peopleStep?.message.contains("Apple Contacts") == true)
    }

    @Test("catalog omits targets that cannot be rendered")
    func unavailableTargetsAreOmitted() {
        let tour = FeatureTourCatalog.latest(
            includeApplicationFilter: false,
            includeAppleSpeech: false,
            includeMeetingPeople: false
        )
        #expect(tour.steps.map(\.target) == [.timelineSidebar])
        #expect(!tour.steps.contains { $0.id == "timeline-apps" })
        #expect(!tour.steps.contains { $0.id == "apple-speech" })
        #expect(!tour.steps.contains { $0.id == "meeting-people" })
    }

    @Test("store suppresses fresh installs and presents a legacy upgrade only once")
    func storeLifecycle() throws {
        let suiteName = "FeatureTourTests.storeLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FeatureTourStore(defaults: defaults)

        #expect(store.automaticTour(
            currentVersion: "0.8.2",
            hasCompletedOnboarding: false,
            canPresent: false
        ) == nil)

        // A fresh install that later completes onboarding is already recorded at
        // 0.8.2 and does not receive a second onboarding-like flow.
        #expect(store.automaticTour(
            currentVersion: "0.8.2",
            hasCompletedOnboarding: true,
            canPresent: true
        ) == nil)

        defaults.removePersistentDomain(forName: suiteName)
        let legacyStore = FeatureTourStore(defaults: defaults)
        let presented = try #require(legacyStore.automaticTour(
            currentVersion: "0.8.2",
            hasCompletedOnboarding: true,
            canPresent: true
        ))
        legacyStore.markOffered(presented)

        #expect(legacyStore.automaticTour(
            currentVersion: "0.8.2",
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
            currentVersion: "0.8.2",
            hasCompletedOnboarding: true,
            canPresent: false
        ) == nil)
        #expect(store.automaticTour(
            currentVersion: "0.8.2",
            hasCompletedOnboarding: true,
            canPresent: true
        ) != nil)
    }
}

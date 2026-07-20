import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Feature tour")
struct FeatureTourTests {
    private let tour = FeatureTourCatalog.latest

    @Test("marketing versions compare numeric components and ignore prerelease suffixes")
    func versionComparison() throws {
        #expect(try #require(MarketingVersion("0.7.1")) < #require(MarketingVersion("0.8.0")))
        #expect(try #require(MarketingVersion("0.8")) == #require(MarketingVersion("0.8.0")))
        #expect(try #require(MarketingVersion("0.8.0-preprod.1")) == #require(MarketingVersion("0.8.0")))
        #expect(MarketingVersion("not-a-version") == nil)
        #expect(MarketingVersion("999999999999999999999999.0") == nil)
        #expect(tour.displayVersion == "0.8")
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

    @Test("existing users without legacy version markers see the first feature tour")
    func legacyUpgrade() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.0",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("fresh installs and pre-target versions do not see the tour")
    func ineligibleLaunches() {
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.0",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: false,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.7.1",
            previousVersion: "0.7.0",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("upgrade crossing the target version presents once")
    func crossingTarget() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.0-preprod.1",
            previousVersion: "0.7.1",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.0",
            previousVersion: "0.7.1",
            lastPresentedTourVersion: "0.8.0",
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

    @Test("0.8 catalog points each walkthrough step at a unique product location")
    func catalogShape() {
        #expect(tour.version == "0.8.0")
        #expect(tour.steps.count == 6)
        #expect(Set(tour.steps.map(\.id)).count == tour.steps.count)
        #expect(Set(tour.steps.map(\.target)).count == tour.steps.count)

        let authenticatedTour = FeatureTourCatalog.latest(includeCloudCleanup: true)
        #expect(authenticatedTour.steps.count == 7)
        #expect(authenticatedTour.steps.contains { $0.target == .cloudCleanupSetting })

        let dictionaryStep = tour.steps.first { $0.target == .dictionarySuggestions }
        #expect(dictionaryStep?.message.contains("off by default") == true)

        let streamingStep = tour.steps.first { $0.target == .streamingModels }
        #expect(streamingStep?.message.contains("Nemotron 3.5") == true)
        #expect(streamingStep?.message.contains("Parakeet Realtime") == true)
        #expect(streamingStep?.target.modelsCategory == .streaming)

        let experimentalStep = tour.steps.last
        #expect(experimentalStep?.id == "experimental-models")
        #expect(experimentalStep?.target == .experimentalModels)
        #expect(experimentalStep?.message.contains("Indic ASR") == true)
        #expect(experimentalStep?.message.contains("Gemma 4") == true)
        #expect(experimentalStep?.target.modelsCategory == .dictation)
    }

    @Test("store suppresses fresh installs and presents a legacy upgrade only once")
    func storeLifecycle() throws {
        let suiteName = "FeatureTourTests.storeLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FeatureTourStore(defaults: defaults)

        #expect(store.automaticTour(
            currentVersion: "0.8.0",
            hasCompletedOnboarding: false,
            canPresent: false
        ) == nil)

        // A fresh install that later completes onboarding is already recorded at
        // 0.8 and does not receive a second onboarding-like flow.
        #expect(store.automaticTour(
            currentVersion: "0.8.0",
            hasCompletedOnboarding: true,
            canPresent: true
        ) == nil)

        defaults.removePersistentDomain(forName: suiteName)
        let legacyStore = FeatureTourStore(defaults: defaults)
        let presented = try #require(legacyStore.automaticTour(
            currentVersion: "0.8.0",
            hasCompletedOnboarding: true,
            canPresent: true
        ))
        legacyStore.markOffered(presented)

        #expect(legacyStore.automaticTour(
            currentVersion: "0.8.0",
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
            currentVersion: "0.8.0",
            hasCompletedOnboarding: true,
            canPresent: false
        ) == nil)
        #expect(store.automaticTour(
            currentVersion: "0.8.0",
            hasCompletedOnboarding: true,
            canPresent: true
        ) != nil)
    }
}

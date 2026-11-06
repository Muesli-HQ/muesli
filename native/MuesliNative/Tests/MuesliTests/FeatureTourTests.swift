import Foundation
import Testing
import SwiftUI
@testable import MuesliNativeApp

@Suite("Feature tour")
struct FeatureTourTests {
    private let tour = FeatureTourCatalog.latest

    @MainActor @Test("new badges dismiss individually and remain dismissed across relaunches")
    func featureDiscoveryPersistence() throws {
        let suite = "muesli.feature-discovery.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NewFeatureDiscovery(defaults: defaults)
        #expect(NewFeature.allCases.allSatisfy(store.isNew))
        store.markUsed(.chat)
        store.markUsed(.chat)
        #expect(!store.isNew(.chat))
        #expect(store.isNew(.timeTurner))
        let reopened = NewFeatureDiscovery(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!reopened.isNew(.chat))
        #expect(reopened.isNew(.granolaImport))
        #expect(defaults.stringArray(forKey: "featureDiscovery.0.8.6.seen") == ["chat"])
        #expect(NewFeatureDiscovery(defaults: defaults, release: "next").isNew(.chat))
        #expect(NewFeature.sidebar(.meetingChat) == .chat)
        #expect(NewFeature.sidebar(.timeTurner) == .timeTurner)
        #expect(NewFeature.sidebar(.settings) == nil)
        #expect(NewFeature.setting("buffered_live_dictation") == .liveDictation)
        #expect(NewFeature.setting("cotypist_enabled") == .cotypist)
        #expect(NewFeature.setting("dictation_format_preset_com.example") == .appFormatting)
        #expect(NewFeature.setting("quill_enabled") == nil)
    }

    @Test("settings tour scrolling only targets its mounted destination pane")
    func settingsScrollOwnership() {
        #expect(SettingsTourScrollRequest(target: .meetingSummaryProvider, pane: .meetings).scrollTarget == .meetingSummaryProvider)
        #expect(SettingsTourScrollRequest(target: .meetingSummaryProvider, pane: .general).scrollTarget == nil)
        #expect(SettingsTourScrollRequest(target: .quillSettings, pane: .experimental).scrollTarget == .quillSettings)
        #expect(SettingsTourScrollRequest(target: .insightsEntry, pane: .general).scrollTarget == nil)
        #expect(SettingsTourScrollRequest(target: nil, pane: .meetings).scrollTarget == nil)
        #expect(SettingsTourScrollRequest(target: .appFormatting, pane: .dictation).scrollTarget == .appFormatting)
        #expect(SettingsTourScrollRequest(target: .cotypistSettings, pane: .dictation).scrollTarget == nil)
    }

    @Test("marketing versions compare numeric components and ignore prerelease suffixes")
    func versionComparison() throws {
        #expect(try #require(MarketingVersion("0.8.3")) < #require(MarketingVersion("0.8.6")))
        #expect(try #require(MarketingVersion("0.8.6")) == #require(MarketingVersion("0.8.6.0")))
        #expect(try #require(MarketingVersion("0.8.6-preprod.2")) == #require(MarketingVersion("0.8.6")))
        #expect(MarketingVersion("not-a-version") == nil)
        #expect(MarketingVersion("999999999999999999999999.0") == nil)
        #expect(tour.displayVersion == "0.8.6")
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

        let importButton = CGRect(x: 700, y: 40, width: 100, height: 32)
        let importPosition = FeatureTourCalloutLayout.position(
            spotlight: importButton, containerSize: container,
            calloutSize: callout, target: .granolaImport
        )
        #expect(importPosition.y - callout.height / 2 > importButton.maxY)
        #expect(importPosition.x + callout.width / 2 <= container.width - 20)
    }

    @Test("tour background hit region leaves the real control interactive")
    func spotlightAllowsInteraction() {
        let shape = FeatureTourDimmingShape(
            spotlight: CGRect(x: 100, y: 100, width: 200, height: 60), cornerRadius: 10
        )
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(!path.contains(CGPoint(x: 200, y: 130), eoFill: true))
        #expect(path.contains(CGPoint(x: 50, y: 50), eoFill: true))
        let regions = FeatureTourHitRegions.background(around: shape.spotlight, in: CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(!regions.contains { $0.contains(CGPoint(x: 200, y: 130)) })
        for point in [CGPoint(x: 200, y: 50), CGPoint(x: 50, y: 130), CGPoint(x: 400, y: 130), CGPoint(x: 200, y: 300)] {
            #expect(regions.filter { $0.contains(point) }.count == 1)
        }
        let clipped = FeatureTourHitRegions.background(around: CGRect(x: -20, y: -10, width: 80, height: 40), in: CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(clipped.allSatisfy { $0.minX >= 0 && $0.minY >= 0 && $0.maxX <= 900 && $0.maxY <= 600 })
        #expect(!clipped.contains { $0.contains(CGPoint(x: 20, y: 10)) })
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
            currentVersion: "0.8.6",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("fresh installs and pre-target versions do not see the tour")
    func ineligibleLaunches() {
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.6",
            previousVersion: nil,
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: false,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5",
            previousVersion: "0.8.3",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("upgrade crossing the target version presents once")
    func crossingTarget() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.6-preprod.2",
            previousVersion: "0.8.5",
            lastPresentedTourVersion: "0.8.5",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.6",
            previousVersion: "0.8.5",
            lastPresentedTourVersion: "0.8.6",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.5",
            previousVersion: "0.8.3",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("prerelease upgrade at the target version presents only to established users")
    func prereleaseUpgradeAtTargetVersion() {
        #expect(FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.6-preprod.2",
            previousVersion: "0.8.6-preprod.1",
            lastPresentedTourVersion: "0.8.5",
            hasCompletedOnboarding: true,
            tour: tour
        ))
        #expect(!FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: "0.8.6-preprod.2",
            previousVersion: "0.8.6-preprod.2",
            lastPresentedTourVersion: nil,
            hasCompletedOnboarding: true,
            tour: tour
        ))
    }

    @Test("0.8.6 highlights cover the agreed features without promoting failure recovery")
    func catalogShape() {
        #expect(tour.version == "0.8.6")
        #expect(tour.steps.count == 11)
        #expect(Set(tour.steps.map(\.id)).count == tour.steps.count)
        #expect(tour.steps.map(\.target) == [
            .granolaImport, .chatSidebar, .timeTurnerSidebar, .liveDictation, .quillSettings,
            .cotypistSettings, .appFormatting, .meetingsSidebar, .searchSidebar,
            .modelLibrary, .cleanupModels,
        ])
        #expect(tour.steps.first?.id == "granola-import")
        #expect(tour.steps.first?.icon == .symbol("square.and.arrow.down"))
        #expect(FeatureTourTarget.granolaImport.navigationRoute == .meetingsBrowser)
        #expect(tour.steps.first(where: { $0.id == "time-turner" })?.icon == .timeTurner)
        #expect(tour.steps.first(where: { $0.id == "quill-assistant" })?.icon == .quill)
        #expect(!tour.steps.contains { $0.id.contains("recovery") })
        #expect(FeatureTourTarget.chatSidebar.navigationRoute == .tab(.meetingChat))
        #expect(FeatureTourTarget.timeTurnerSidebar.navigationRoute == .tab(.timeTurner))
        #expect(FeatureTourTarget.searchSidebar.navigationRoute == .tab(.timeline))
        #expect(FeatureTourTarget.cleanupModels.navigationRoute == .models(.postProcessing))
    }

    @Test("models scrolling rejects superseded categories and unrelated settings targets")
    func modelsScrollOwnership() {
        #expect(ModelsTourScrollRequest(target: .modelLibrary, category: .dictation).scrollTarget == .modelLibrary)
        #expect(ModelsTourScrollRequest(target: .modelLibrary, category: .postProcessing).scrollTarget == nil)
        #expect(ModelsTourScrollRequest(target: .cleanupModels, category: .postProcessing).scrollTarget == .cleanupModels)
        #expect(ModelsTourScrollRequest(target: .cleanupModels, category: .dictation).scrollTarget == nil)
        #expect(ModelsTourScrollRequest(target: .bodhanFlexCard, category: .dictation).scrollTarget == .bodhanFlexCard)
        #expect(ModelsTourScrollRequest(target: .experimentalModels, category: .dictation).scrollTarget == .experimentalModels)
        #expect(ModelsTourScrollRequest(target: .quillSettings, category: .quill).scrollTarget == nil)
        #expect(ModelsTourScrollRequest(target: nil, category: .dictation).scrollTarget == nil)
    }

    @Test("tour sidebar destinations keep targets in both sidebar layouts")
    func sidebarTargets() {
        #expect(DashboardTab.meetingChat.sidebarFeatureTourTarget == .chatSidebar)
        #expect(DashboardTab.timeTurner.sidebarFeatureTourTarget == .timeTurnerSidebar)
        #expect(DashboardTab.meetings.sidebarFeatureTourTarget == .meetingsSidebar)
        #expect(DashboardTab.timeline.sidebarFeatureTourTarget == .timelineSidebar)
        #expect(DashboardTab.settings.sidebarFeatureTourTarget == nil)
    }

    @Test("settings targets follow their current settings sections")
    func settingsNavigationRoutes() {
        #expect(FeatureTourTarget.quillSettings.navigationRoute == .settings(.experimental))
        #expect(FeatureTourTarget.dictationProviderSetting.navigationRoute == .settings(.dictation))
        #expect(FeatureTourTarget.cloudCleanupSetting.navigationRoute == .settings(.dictation))
        #expect(FeatureTourTarget.liveDictation.navigationRoute == .settings(.dictation))
        #expect(FeatureTourTarget.appFormatting.navigationRoute == .settings(.dictation))
        #expect(FeatureTourTarget.cotypistSettings.navigationRoute == .settings(.experimental))
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
            currentVersion: "0.8.6",
            hasCompletedOnboarding: false,
            canPresent: false
        ) == nil)

        // A fresh install that later completes onboarding is already recorded at
        // 0.8.6 and does not receive a second onboarding-like flow.
        #expect(store.automaticTour(
            currentVersion: "0.8.6",
            hasCompletedOnboarding: true,
            canPresent: true
        ) == nil)

        defaults.removePersistentDomain(forName: suiteName)
        let legacyStore = FeatureTourStore(defaults: defaults)
        let presented = try #require(legacyStore.automaticTour(
            currentVersion: "0.8.6",
            hasCompletedOnboarding: true,
            canPresent: true
        ))
        legacyStore.markOffered(presented)

        #expect(legacyStore.automaticTour(
            currentVersion: "0.8.6",
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
            currentVersion: "0.8.6",
            hasCompletedOnboarding: true,
            canPresent: false
        ) == nil)
        #expect(store.automaticTour(
            currentVersion: "0.8.6",
            hasCompletedOnboarding: true,
            canPresent: true
        ) != nil)
    }
}

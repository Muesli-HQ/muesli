import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dashboard window presence")
struct DashboardWindowPresencePolicyTests {
    @Test("Existing configurations keep the current menu-bar-only behavior")
    func missingCloseBehaviorUsesMenuBarOnly() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        #expect(config.dashboardCloseBehavior == .menuBarOnly)
    }

    @Test("Dock behavior round-trips through configuration JSON")
    func dockBehaviorRoundTrip() throws {
        var config = AppConfig()
        config.dashboardCloseBehavior = .keepInDock

        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(json?["dashboard_close_behavior"] as? String == "keep_in_dock")
        #expect(decoded.dashboardCloseBehavior == .keepInDock)
    }

    @Test("Unknown close behavior falls back safely")
    func unknownCloseBehaviorUsesMenuBarOnly() throws {
        let data = Data(#"{"dashboard_close_behavior":"unknown"}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.dashboardCloseBehavior == .menuBarOnly)
    }

    @Test("An open dashboard always uses a regular Dock application")
    func openDashboardUsesRegularPolicy() {
        for behavior in DashboardCloseBehavior.allCases {
            #expect(
                DashboardWindowPresencePolicy.activationPolicy(
                    openWindowCount: 1,
                    closeBehavior: behavior
                ) == .regular
            )
        }
    }

    @Test("Closed dashboard follows the configured presence")
    func closedDashboardUsesConfiguredPolicy() {
        #expect(
            DashboardWindowPresencePolicy.activationPolicy(
                openWindowCount: 0,
                closeBehavior: .menuBarOnly
            ) == .accessory
        )
        #expect(
            DashboardWindowPresencePolicy.activationPolicy(
                openWindowCount: 0,
                closeBehavior: .keepInDock
            ) == .regular
        )
    }
}

import AppKit

enum DashboardWindowPresencePolicy {
    static func activationPolicy(
        openWindowCount: Int,
        closeBehavior: DashboardCloseBehavior
    ) -> NSApplication.ActivationPolicy {
        if openWindowCount > 0 || closeBehavior == .keepInDock {
            return .regular
        }
        return .accessory
    }
}

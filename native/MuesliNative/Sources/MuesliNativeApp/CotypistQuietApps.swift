import AppKit

/// Apps Cotypist can be kept quiet in. Each candidate is a finite on/off setting in the shared
/// catalog (`cotypist_quiet_app.<bundle ID>`), so Settings and voice change the list through the
/// same validated path. Candidates are the apps already quiet, recommended apps that are
/// installed, and open apps with windows.
@MainActor
enum CotypistQuietApps {
    struct App: Equatable {
        let bundleID: String
        let name: String
    }

    static let settingPrefix = "cotypist_quiet_app."

    static func settingID(_ bundleID: String) -> String { settingPrefix + bundleID }

    /// Installed apps people usually keep Cotypist out of: password managers, and editors with
    /// their own completions.
    static let recommendedBundleIDs = [
        "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ]

    static func candidates(quiet: [String]) -> [App] {
        var seen = Set<String>()
        var apps: [App] = []
        for bundleID in quiet + recommended(excluding: []) + running(excluding: []).map(\.bundleID)
        where seen.insert(bundleID).inserted {
            apps.append(App(bundleID: bundleID, name: name(of: bundleID)))
        }
        return apps
    }

    static func recommended(excluding quiet: [String]) -> [String] {
        recommendedBundleIDs.filter { !quiet.contains($0) && info(bundleID: $0).installed }
    }

    /// Open apps with windows, other than Muesli itself.
    static func running(excluding quiet: [String]) -> [App] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { App(bundleID: $0, name: app.localizedName ?? name(of: $0)) } }
            .filter { !quiet.contains($0.bundleID) && $0.bundleID != Bundle.main.bundleIdentifier }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func name(of bundleID: String) -> String { info(bundleID: bundleID).name }

    static func icon(of bundleID: String) -> NSImage? { info(bundleID: bundleID).icon }

    /// Menus draw images at their own size: a 16-point copy.
    static func menuIcon(of bundleID: String) -> NSImage? {
        guard let icon = icon(of: bundleID)?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    // MARK: - App metadata

    /// LaunchServices lookups, once per app: views read these on every redraw.
    private static var cache: [String: (name: String, icon: NSImage?, installed: Bool)] = [:]

    private static func info(bundleID: String) -> (name: String, icon: NSImage?, installed: Bool) {
        if let cached = cache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let info = (
            name: url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "Unknown app",
            icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
            installed: url != nil
        )
        cache[bundleID] = info
        return info
    }
}

import AppKit
import Observation

/// Apps Cotypist can be kept quiet in. Each candidate is a finite on/off setting in the shared
/// catalog (`cotypist_quiet_app.<bundle ID>`, grouped for voice discovery), so Settings and voice
/// change the list through the same validated path. Candidates are the apps already quiet,
/// apps just chosen in the file picker, recommended apps that are installed, and open apps.
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

    /// Apps chosen in Settings' file picker, so they become settings before they're applied.
    static var chosen: [String] = []

    static func candidates(quiet: [String]) -> [App] {
        var seen = Set<String>()
        var apps: [App] = []
        for bundleID in quiet + chosen + recommended(excluding: []) + running(excluding: []).map(\.bundleID)
        where seen.insert(bundleID).inserted {
            apps.append(App(bundleID: bundleID, name: name(of: bundleID)))
        }
        return apps
    }

    static func recommended(excluding quiet: [String]) -> [String] {
        recommendedBundleIDs.filter { !quiet.contains($0) && info(bundleID: $0).installed }
    }

    /// Open apps with windows, other than Muesli itself.
    private static let runningCache = CotypistRunningAppsCache()

    static func running(excluding quiet: [String]) -> [App] {
        runningCache.apps.filter { !quiet.contains($0.bundleID) }
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

/// Enumerate on workspace events, not each Settings render. The observable snapshot
/// still invalidates the catalog when an app launches, exits, or becomes foreground.
@MainActor
@Observable
final class CotypistRunningAppsCache {
    private(set) var apps: [CotypistQuietApps.App] = []
    @ObservationIgnored private let scan: @MainActor () -> [CotypistQuietApps.App]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(observeWorkspace: Bool = true, scan: @escaping @MainActor () -> [CotypistQuietApps.App] = {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                app.bundleIdentifier.map { CotypistQuietApps.App(bundleID: $0, name: app.localizedName ?? CotypistQuietApps.name(of: $0)) }
            }
            .filter { $0.bundleID != Bundle.main.bundleIdentifier }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }) {
        self.scan = scan
        refresh()
        if observeWorkspace {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didActivateApplicationNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                })
            }
        }
    }

    func refresh() {
        let current = scan()
        if apps != current { apps = current }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

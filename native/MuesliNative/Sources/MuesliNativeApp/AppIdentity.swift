import Foundation
import MuesliCore

public enum AppIdentity {
    private static let defaultName = "Muesli"

    static var bundleName: String {
        stringValue(for: "CFBundleName") ?? defaultName
    }

    static var displayName: String {
        stringValue(for: "CFBundleDisplayName") ?? (bundleName.hasPrefix("Muesli")
            ? "muesli" + bundleName.dropFirst(6) : bundleName)
    }

    /// A short label for builds other than the release app ("DEV", "DEV A",
    /// "CANARY", "PREPROD"), shown in the menu bar and the sidebar. The build
    /// script also bakes it into the app icon; see scripts/muesli_build_badge.sh.
    /// Nil for the release app, which has no MuesliBuildBadge key.
    static var buildBadge: String? { stringValue(for: "MuesliBuildBadge") }

    /// The menu bar form of `buildBadge` (D, DA, PP, C), from the build
    /// script's MuesliBuildBadgeShort key. Nil for the release app.
    static var buildBadgeShort: String? { stringValue(for: "MuesliBuildBadgeShort") }

    static var marketingVersion: String {
        stringValue(for: "CFBundleShortVersionString") ?? "0.0.0"
    }

    static var supportDirectoryName: String {
        // Keep legacy data paths independent of display-name capitalization.
        stringValue(for: "MuesliSupportDirectoryName") ?? (bundleName.hasPrefix("muesli")
            ? "Muesli" + bundleName.dropFirst(6) : bundleName)
    }

    /// Public so App Intents (a separate module from the rest of the app)
    /// can resolve the *running* app identity's data directory — e.g.
    /// MuesliDev vs Muesli — instead of hardcoding the production default.
    public static var supportDirectoryURL: URL {
        MuesliPaths.defaultSupportDirectoryURL(appName: supportDirectoryName)
    }

    private static func stringValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

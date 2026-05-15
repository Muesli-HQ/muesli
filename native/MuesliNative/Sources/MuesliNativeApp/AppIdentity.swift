import Foundation
import MuesliCore

enum AppIdentity {
    private static let defaultName = "Muesli"
    private static var displayNameOverride: String?

    static var bundleName: String {
        stringValue(for: "CFBundleName") ?? defaultName
    }

    static var displayName: String {
        displayNameOverride ?? bundleDisplayName
    }

    static var bundleDisplayName: String {
        stringValue(for: "CFBundleDisplayName") ?? bundleName
    }

    static var supportDirectoryName: String {
        stringValue(for: "MuesliSupportDirectoryName") ?? bundleName
    }

    static var supportDirectoryURL: URL {
        MuesliPaths.defaultSupportDirectoryURL(appName: supportDirectoryName)
    }

    static func configureDisplayNameOverride(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        displayNameOverride = trimmed.isEmpty ? nil : trimmed
    }

    private static func stringValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import Foundation

enum MuesliTelemetryChannel: String, CaseIterable, Sendable {
    case production
    case preprod
    case dev
    case canary
    case unconfigured
}

struct TelemetryRuntimeConfiguration: Equatable, Sendable {
    static let appIDInfoKey = "MuesliTelemetryDeckAppID"
    static let channelInfoKey = "MuesliTelemetryChannel"
    static let disabledSDKAppID = "00000000-0000-0000-0000-000000000000"

    let appID: String
    let channel: MuesliTelemetryChannel
    let bundleID: String
    let isEnabled: Bool

    var sdkAppID: String {
        isEnabled ? appID : Self.disabledSDKAppID
    }

    static func current(bundle: Bundle = .main) -> TelemetryRuntimeConfiguration {
        resolve(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    static func resolve(
        infoDictionary: [String: Any],
        bundleIdentifier: String?
    ) -> TelemetryRuntimeConfiguration {
        let rawAppID = stringValue(for: appIDInfoKey, in: infoDictionary) ?? ""
        let rawChannel = stringValue(for: channelInfoKey, in: infoDictionary) ?? "unconfigured"
        let channel = MuesliTelemetryChannel(rawValue: rawChannel) ?? .unconfigured
        let hasValidAppID = UUID(uuidString: rawAppID) != nil
        let hasConfiguredChannel = channel != .unconfigured

        return TelemetryRuntimeConfiguration(
            appID: hasValidAppID && hasConfiguredChannel ? rawAppID : "",
            channel: hasValidAppID && hasConfiguredChannel ? channel : .unconfigured,
            bundleID: normalizedBundleID(bundleIdentifier),
            isEnabled: hasValidAppID && hasConfiguredChannel
        )
    }

    var defaultParameters: [String: String] {
        [
            "muesli.channel": channel.rawValue,
            "muesli.bundle_id": bundleID,
        ]
    }

    private static func stringValue(for key: String, in dictionary: [String: Any]) -> String? {
        guard let value = dictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedBundleID(_ value: String?) -> String {
        guard let value else { return "unknown" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

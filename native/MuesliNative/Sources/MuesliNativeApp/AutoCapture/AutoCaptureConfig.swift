import Foundation

// MARK: - AutoCaptureConfig

/// User-facing configuration for the Auto-Capture v0 subsystem.
///
/// Nested into `AppConfig` under the `auto_capture` JSON key. All fields have
/// sensible defaults so older config files migrate cleanly via the
/// fallback-on-missing-key pattern used elsewhere in `AppConfig`.
struct AutoCaptureConfig: Codable, Equatable {

    /// Master opt-in toggle. Defaults to `false` so upgrades are non-breaking.
    var enabled: Bool

    /// Bundle IDs the coordinator is allowed to auto-start for. Defaults to
    /// the dedicated meeting apps that `MeetingDetector` knows about; users
    /// can add or remove apps from the Settings pane.
    var allowedAppBundleIDs: Set<String>

    /// Bundle IDs the user has already acknowledged via the first-run modal.
    /// First-run cadence is once per bundle ID — see ADR-0005.
    var acknowledgedAppBundleIDs: Set<String>

    /// Delay between detection firing and the recording starting, in seconds.
    /// Capped to `[minStartDelaySeconds, maxStartDelaySeconds]` at read time.
    var startDelaySeconds: Double

    /// When true, only auto-capture if the detection also matches a calendar
    /// event. Strict mode for shared-desk environments.
    var requireCalendarMatch: Bool

    /// When true, the coordinator is muted while macOS Focus / DND is active.
    /// Default true per ADR-0006. The actual Focus probe is supplied to the
    /// coordinator by `MuesliController` at construction time.
    var disableDuringFocus: Bool

    /// Per-browser opt-in flags for the v1 AppleScript URL poller. All flags
    /// default to off so users running v0 see no behavioural change after
    /// upgrading to a v1 build. See ADR-0003.
    var browserUrlPolling: BrowserURLPollingConfig

    static let defaultStartDelaySeconds: Double = 5
    static let minStartDelaySeconds: Double = 0
    static let maxStartDelaySeconds: Double = 60

    /// First-run modal timeout — see ADR-0005. Modal auto-declines after this
    /// many seconds to prevent runaway prompts on a background-only desk.
    static let confirmationTimeoutSeconds: Double = 30

    /// Default allowed apps. Mirrors `MeetingDetector.dedicatedApps`'s keys at
    /// the time of writing; intentionally inlined so this struct stays
    /// independent from `MeetingDetector` for testability.
    static let defaultAllowedAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "us.zoom.ZoomPhone",
        "com.apple.FaceTime",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.webex.meetingmanager",
        "com.cisco.webexmeetingsapp",
        "net.whatsapp.WhatsApp",
        "com.google.Chrome",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.apple.Safari",
    ]

    init(
        enabled: Bool = false,
        allowedAppBundleIDs: Set<String> = AutoCaptureConfig.defaultAllowedAppBundleIDs,
        acknowledgedAppBundleIDs: Set<String> = [],
        startDelaySeconds: Double = AutoCaptureConfig.defaultStartDelaySeconds,
        requireCalendarMatch: Bool = false,
        disableDuringFocus: Bool = true,
        browserUrlPolling: BrowserURLPollingConfig = .disabled
    ) {
        self.enabled = enabled
        self.allowedAppBundleIDs = allowedAppBundleIDs
        self.acknowledgedAppBundleIDs = acknowledgedAppBundleIDs
        self.startDelaySeconds = AutoCaptureConfig.clampedStartDelay(startDelaySeconds)
        self.requireCalendarMatch = requireCalendarMatch
        self.disableDuringFocus = disableDuringFocus
        self.browserUrlPolling = browserUrlPolling
    }

    /// Returns the start delay clamped to the allowed range. Used at decode
    /// time and whenever the slider sends a new value.
    static func clampedStartDelay(_ value: Double) -> Double {
        min(max(value, minStartDelaySeconds), maxStartDelaySeconds)
    }

    /// Whether the supplied bundle ID is currently allowed to auto-start.
    /// Unknown bundle IDs default to allowed so that newly-supported apps
    /// don't require a config migration.
    func isAllowed(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        if allowedAppBundleIDs.isEmpty { return true }
        return allowedAppBundleIDs.contains(bundleID)
    }

    /// Whether the supplied bundle ID has been acknowledged by the user.
    /// Nil / empty IDs are treated as acknowledged so unknown detections
    /// still flow through the calendar-match strict path.
    func isAcknowledged(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return acknowledgedAppBundleIDs.contains(bundleID)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case allowedAppBundleIDs = "allowed_app_bundle_ids"
        case acknowledgedAppBundleIDs = "acknowledged_app_bundle_ids"
        case startDelaySeconds = "start_delay_seconds"
        case requireCalendarMatch = "require_calendar_match"
        case disableDuringFocus = "disable_during_focus"
        case browserUrlPolling = "browser_url_polling"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutoCaptureConfig()
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? defaults.enabled
        self.allowedAppBundleIDs =
            (try? c.decode(Set<String>.self, forKey: .allowedAppBundleIDs)) ?? defaults.allowedAppBundleIDs
        self.acknowledgedAppBundleIDs =
            (try? c.decode(Set<String>.self, forKey: .acknowledgedAppBundleIDs)) ?? defaults.acknowledgedAppBundleIDs
        let rawDelay = (try? c.decode(Double.self, forKey: .startDelaySeconds)) ?? defaults.startDelaySeconds
        self.startDelaySeconds = AutoCaptureConfig.clampedStartDelay(rawDelay)
        self.requireCalendarMatch =
            (try? c.decode(Bool.self, forKey: .requireCalendarMatch)) ?? defaults.requireCalendarMatch
        self.disableDuringFocus =
            (try? c.decode(Bool.self, forKey: .disableDuringFocus)) ?? defaults.disableDuringFocus
        self.browserUrlPolling =
            (try? c.decode(BrowserURLPollingConfig.self, forKey: .browserUrlPolling)) ?? defaults.browserUrlPolling
    }
}

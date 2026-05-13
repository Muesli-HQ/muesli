import Foundation

// MARK: - BrowserURLPollingConfig

/// Per-browser opt-in flags for the v1 AppleScript URL poller.
///
/// All flags default to `false` so the feature is fully opt-in. The poller is
/// inert until the user enables at least one browser in the Auto-Capture
/// settings pane. JSON keys are snake-case and migrate cleanly via the
/// fallback-on-missing-key pattern.
struct BrowserURLPollingConfig: Codable, Equatable {

    /// Whether Muesli is allowed to poll Google Chrome's active tab URL via
    /// AppleScript while Chrome is using the microphone.
    var chrome: Bool

    /// Whether Muesli is allowed to poll Microsoft Edge.
    var edge: Bool

    /// Whether Muesli is allowed to poll Brave.
    var brave: Bool

    /// Whether Muesli is allowed to poll Arc.
    var arc: Bool

    /// Whether Muesli is allowed to poll Safari (via the Safari AppleScript
    /// dictionary; user-facing copy mentions this requires Automation access
    /// per ADR-0003).
    var safari: Bool

    /// All flags off. Used as the default value when `AutoCaptureConfig` is
    /// decoded from a config that pre-dates v1.
    static let disabled = BrowserURLPollingConfig()

    init(
        chrome: Bool = false,
        edge: Bool = false,
        brave: Bool = false,
        arc: Bool = false,
        safari: Bool = false
    ) {
        self.chrome = chrome
        self.edge = edge
        self.brave = brave
        self.arc = arc
        self.safari = safari
    }

    enum CodingKeys: String, CodingKey {
        case chrome
        case edge
        case brave
        case arc
        case safari
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrowserURLPollingConfig()
        self.chrome = (try? c.decode(Bool.self, forKey: .chrome)) ?? defaults.chrome
        self.edge = (try? c.decode(Bool.self, forKey: .edge)) ?? defaults.edge
        self.brave = (try? c.decode(Bool.self, forKey: .brave)) ?? defaults.brave
        self.arc = (try? c.decode(Bool.self, forKey: .arc)) ?? defaults.arc
        self.safari = (try? c.decode(Bool.self, forKey: .safari)) ?? defaults.safari
    }

    /// True if any browser is enabled. The poller treats this as the master
    /// switch for whether it should install its mic-ownership watchdog.
    var anyEnabled: Bool {
        chrome || edge || brave || arc || safari
    }

    /// Map from supported browser bundle IDs to their per-browser flag.
    /// Bundle IDs match `MeetingDetector.browserApps` so we stay in lock-step
    /// with the rest of the detection pipeline.
    func isEnabled(forBundleID bundleID: String) -> Bool {
        switch bundleID {
        case BrowserURLPollingConfig.chromeBundleID: return chrome
        case BrowserURLPollingConfig.edgeBundleID: return edge
        case BrowserURLPollingConfig.braveBundleID: return brave
        case BrowserURLPollingConfig.arcBundleID: return arc
        case BrowserURLPollingConfig.safariBundleID: return safari
        default: return false
        }
    }

    /// Bundle IDs currently enabled, in a stable order.
    var enabledBundleIDs: [String] {
        var ids: [String] = []
        if chrome { ids.append(BrowserURLPollingConfig.chromeBundleID) }
        if edge { ids.append(BrowserURLPollingConfig.edgeBundleID) }
        if brave { ids.append(BrowserURLPollingConfig.braveBundleID) }
        if arc { ids.append(BrowserURLPollingConfig.arcBundleID) }
        if safari { ids.append(BrowserURLPollingConfig.safariBundleID) }
        return ids
    }

    static let chromeBundleID = "com.google.Chrome"
    static let edgeBundleID = "com.microsoft.edgemac"
    static let braveBundleID = "com.brave.Browser"
    static let arcBundleID = "company.thebrowser.Browser"
    static let safariBundleID = "com.apple.Safari"

    /// Browsers we can drive via AppleScript today, ordered for the Settings UI.
    static let supportedBundleIDs: [String] = [
        chromeBundleID,
        edgeBundleID,
        braveBundleID,
        arcBundleID,
        safariBundleID,
    ]
}

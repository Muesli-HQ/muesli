import AppKit
import Foundation
import MuesliCore

/// Non-release builds (MuesliDev, dev lanes, canary, preprod) often run beside the
/// installed release app, frequently with settings copied from it by
/// `scripts/dev-seed-from-prod.sh`. Muesli's global key monitors are passive, so
/// both processes see the same press and both start dictating. A non-release build
/// therefore skips new presses of any shortcut the running release app also
/// handles. Release builds never create the guard.
enum ReleaseHotkeyYieldPolicy {
    static let releaseBundleIdentifier = "com.muesli.app"

    static func appliesTo(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, bundleIdentifier != releaseBundleIdentifier else { return false }
        return bundleIdentifier.hasPrefix("com.muesli.")
    }

    /// Shortcuts the release app listens for with these saved settings. Before
    /// onboarding finishes, release has not started its shortcut monitors.
    static func handledHotkeys(in config: AppConfig) -> [HotkeyConfig] {
        guard config.hasCompletedOnboarding else { return [] }
        return [
            (config.enablePushToTalk, config.dictationHotkey),
            (config.enableQuilMode, config.quilHotkey),
            (config.enableComputerUseHotkey, config.computerUseHotkey),
            (config.enableMeetingRecordingHotkey, config.meetingRecordingHotkey),
            (config.enableFeedbackCapture, config.feedbackCaptureHotkey),
        ].compactMap { enabled, hotkey in enabled ? hotkey : nil }
    }

    /// True when one physical press triggers both shortcuts. A bare modifier and a
    /// chord containing it do not clash: the bare-key monitor cancels its press as
    /// soon as the chord's other key goes down. Chords fire only on an exact
    /// modifier match, so ⌥R and ⌥⇧R never fire together.
    static func samePressTriggersBoth(_ hotkey: HotkeyConfig, _ other: HotkeyConfig) -> Bool {
        guard hotkey.isCombination == other.isCombination else { return false }
        guard hotkey.isCombination else { return ShortcutHotkeyPolicy.hotkeysConflict(hotkey, other) }
        return hotkey.combinationKeyCode == other.combinationKeyCode
            && hotkey.resolvedCombinationModifiers == other.resolvedCombinationModifiers
    }

    /// Copy for the card a skipped press shows. It must fit one line each beside
    /// the icon and button of `MeetingNotificationController`'s widest card. During
    /// setup the dashboard is closed, so the card points back to onboarding.
    static func collisionNotice(
        shortcut: String,
        duringSetup: Bool
    ) -> (title: String, subtitle: String, actionLabel: String) {
        (
            title: "\(shortcut) also starts muesli",
            subtitle: duringSetup ? "Go Back to choose another one" : "Skipped here while muesli runs",
            actionLabel: duringSetup ? "Show Setup" : "Change Shortcut"
        )
    }

    static func shouldYield(
        _ hotkey: HotkeyConfig,
        releaseIsRunning: Bool,
        releaseHotkeys: [HotkeyConfig]
    ) -> Bool {
        releaseIsRunning && releaseHotkeys.contains { samePressTriggersBoth(hotkey, $0) }
    }
}

/// Tracks whether the release app is running from workspace launch and quit
/// notifications, so a shortcut press reads a stored flag instead of asking
/// the system.
final class ReleaseAppPresence {
    private(set) var isRunning: Bool
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        let releaseID = ReleaseHotkeyYieldPolicy.releaseBundleIdentifier
        self.center = center
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: releaseID).isEmpty
        for (name, running) in [
            (NSWorkspace.didLaunchApplicationNotification, true),
            (NSWorkspace.didTerminateApplicationNotification, false),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == releaseID else { return }
                self?.isRunning = running
            })
        }
    }

    deinit { observers.forEach(center.removeObserver) }
}

/// Reads the release `config.json` read-only and caches its shortcuts until the
/// file changes. A shortcut press costs one stored flag and one file-date check;
/// the file itself is read only after release saves new settings.
final class ReleaseAppHotkeyGuard {
    private let releaseConfigURL: URL
    private let releaseIsRunning: () -> Bool
    private var cache: (modified: Date?, hotkeys: [HotkeyConfig])?

    init(
        releaseConfigURL: URL = MuesliPaths.defaultSupportDirectoryURL(appName: "Muesli")
            .appendingPathComponent("config.json"),
        releaseIsRunning: @escaping () -> Bool
    ) {
        self.releaseConfigURL = releaseConfigURL
        self.releaseIsRunning = releaseIsRunning
    }

    /// Nil for the release build, so its key handling is unchanged.
    static func forCurrentBuild(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> ReleaseAppHotkeyGuard? {
        guard ReleaseHotkeyYieldPolicy.appliesTo(bundleIdentifier: bundleIdentifier) else { return nil }
        let presence = ReleaseAppPresence()
        return ReleaseAppHotkeyGuard(releaseIsRunning: { presence.isRunning })
    }

    func shouldYield(_ hotkey: HotkeyConfig) -> Bool {
        guard releaseIsRunning() else { return false }
        return ReleaseHotkeyYieldPolicy.shouldYield(hotkey, releaseIsRunning: true, releaseHotkeys: releaseHotkeys())
    }

    private func releaseHotkeys() -> [HotkeyConfig] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: releaseConfigURL.path))?[.modificationDate] as? Date
        if let cache, cache.modified == modified { return cache.hotkeys }
        let config: AppConfig
        if modified == nil {
            // No file: the release app has never saved settings, so it uses defaults.
            config = AppConfig()
        } else if let data = try? Data(contentsOf: releaseConfigURL),
                  let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            // A read that failed mid-save is retried on the next press; until then
            // keep the last settings that were read successfully.
            return cache?.hotkeys ?? []
        }
        let hotkeys = ReleaseHotkeyYieldPolicy.handledHotkeys(in: config)
        cache = (modified, hotkeys)
        return hotkeys
    }
}

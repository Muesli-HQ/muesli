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

    /// Shortcuts the release app listens for with these saved settings.
    static func handledHotkeys(in config: AppConfig) -> [HotkeyConfig] {
        [
            (config.enablePushToTalk, config.dictationHotkey),
            (config.enableQuilMode, config.quilHotkey),
            (config.enableComputerUseHotkey, config.computerUseHotkey),
            (config.enableMeetingRecordingHotkey, config.meetingRecordingHotkey),
            (config.enableFeedbackCapture, config.feedbackCaptureHotkey),
        ].compactMap { enabled, hotkey in enabled ? hotkey : nil }
    }

    /// True when one physical press triggers both shortcuts. A bare modifier and a
    /// chord containing it do not clash: the bare-key monitor cancels its press as
    /// soon as the chord's other key goes down.
    static func samePressTriggersBoth(_ hotkey: HotkeyConfig, _ other: HotkeyConfig) -> Bool {
        hotkey.isCombination == other.isCombination
            && ShortcutHotkeyPolicy.hotkeysConflict(hotkey, other)
    }

    static func collisionNotice(shortcut: String, appName: String) -> (title: String, subtitle: String) {
        (
            title: "\(shortcut) is also muesli's shortcut",
            subtitle: "\(appName) skips it while muesli is running, so only muesli responds. Change \(appName)'s shortcut to use both."
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

/// Checks the running release app only when a shortcut press begins, so there is
/// no observer to keep alive. Reads the release `config.json` read-only and caches
/// it until the file changes.
final class ReleaseAppHotkeyGuard {
    private let releaseConfigURL: URL
    private let releaseIsRunning: () -> Bool
    private var cache: (modified: Date?, hotkeys: [HotkeyConfig])?

    init(
        releaseConfigURL: URL = MuesliPaths.defaultSupportDirectoryURL(appName: "Muesli")
            .appendingPathComponent("config.json"),
        releaseIsRunning: @escaping () -> Bool = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: ReleaseHotkeyYieldPolicy.releaseBundleIdentifier
            ).isEmpty
        }
    ) {
        self.releaseConfigURL = releaseConfigURL
        self.releaseIsRunning = releaseIsRunning
    }

    /// Nil for the release build, so its key handling is unchanged.
    static func forCurrentBuild(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> ReleaseAppHotkeyGuard? {
        ReleaseHotkeyYieldPolicy.appliesTo(bundleIdentifier: bundleIdentifier) ? ReleaseAppHotkeyGuard() : nil
    }

    func shouldYield(_ hotkey: HotkeyConfig) -> Bool {
        guard releaseIsRunning() else { return false }
        return ReleaseHotkeyYieldPolicy.shouldYield(hotkey, releaseIsRunning: true, releaseHotkeys: releaseHotkeys())
    }

    private func releaseHotkeys() -> [HotkeyConfig] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: releaseConfigURL.path))?[.modificationDate] as? Date
        if let cache, cache.modified == modified { return cache.hotkeys }
        // Same fallback as ConfigStore: a missing or unreadable file means defaults.
        let config = (try? Data(contentsOf: releaseConfigURL))
            .flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) } ?? AppConfig()
        let hotkeys = ReleaseHotkeyYieldPolicy.handledHotkeys(in: config)
        cache = (modified, hotkeys)
        return hotkeys
    }
}

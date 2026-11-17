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
    /// Called on the main queue after release launches or quits.
    var onChange: (() -> Void)?
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
                guard let self, app?.bundleIdentifier == releaseID else { return }
                self.isRunning = running
                self.onChange?()
            })
        }
    }

    deinit { observers.forEach(center.removeObserver) }
}

/// Keeps a snapshot of the shortcuts the release app handles. A shortcut press
/// reads only that snapshot and a stored running flag; all file access happens
/// on a background queue. The release `config.json` is read read-only, and only
/// after its modification date changes. Refreshes run at start, when the
/// release support folder changes, when release launches or quits, and after
/// each press, so a missed folder event costs at most one stale press.
final class ReleaseAppHotkeyGuard {
    private let releaseConfigURL: URL
    private let releaseIsRunning: () -> Bool
    private let ioQueue: DispatchQueue
    private let deliver: (@escaping () -> Void) -> Void
    /// Read and written only through `deliver` (the main queue in the app).
    private var releaseHotkeys: [HotkeyConfig] = []
    /// Read and written only on `ioQueue`.
    private var lastRead: (modified: Date?, hotkeys: [HotkeyConfig])?
    private var folderWatcher: DispatchSourceFileSystemObject?

    /// Until the first refresh lands the snapshot is empty, so nothing is yielded.
    init(
        releaseConfigURL: URL = MuesliPaths.defaultSupportDirectoryURL(appName: "Muesli")
            .appendingPathComponent("config.json"),
        releaseIsRunning: @escaping () -> Bool,
        ioQueue: DispatchQueue = DispatchQueue(label: "com.muesli.release-hotkey-guard", qos: .utility),
        deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.releaseConfigURL = releaseConfigURL
        self.releaseIsRunning = releaseIsRunning
        self.ioQueue = ioQueue
        self.deliver = deliver
        refresh()
    }

    deinit { folderWatcher?.cancel() }

    /// Nil for the release build, so its key handling is unchanged.
    static func forCurrentBuild(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> ReleaseAppHotkeyGuard? {
        guard ReleaseHotkeyYieldPolicy.appliesTo(bundleIdentifier: bundleIdentifier) else { return nil }
        let presence = ReleaseAppPresence()
        let releaseGuard = ReleaseAppHotkeyGuard(releaseIsRunning: { presence.isRunning })
        presence.onChange = { [weak releaseGuard] in releaseGuard?.refresh() }
        // The presence object lives as long as the guard's running-flag closure.
        return releaseGuard
    }

    /// The yield callback for one monitor. `ownsRunningSession` covers sessions the
    /// monitor did not latch itself, such as a meeting started from the menu bar,
    /// whose stop press would otherwise look new and be skipped.
    func yieldHandler(
        ownsRunningSession: @escaping () -> Bool = { false },
        onYield: @escaping (HotkeyConfig) -> Void
    ) -> (HotkeyConfig) -> Bool {
        { [weak self] hotkey in
            guard let self, !ownsRunningSession(), self.shouldYield(hotkey) else { return false }
            onYield(hotkey)
            return true
        }
    }

    func shouldYield(_ hotkey: HotkeyConfig) -> Bool {
        guard releaseIsRunning() else { return false }
        refresh()
        return ReleaseHotkeyYieldPolicy.shouldYield(hotkey, releaseIsRunning: true, releaseHotkeys: releaseHotkeys)
    }

    func refresh() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.watchReleaseFolderIfNeeded()
            guard let hotkeys = self.readReleaseHotkeys() else { return }
            self.deliver { [weak self] in self?.releaseHotkeys = hotkeys }
        }
    }

    /// Waits for queued refreshes; tests pass a `deliver` that runs inline.
    func waitForRefreshForTests() {
        ioQueue.sync {}
    }

    /// Nil when a read fails mid-save: the last good snapshot stays, and the next
    /// refresh tries again even if the file date has not changed.
    private func readReleaseHotkeys() -> [HotkeyConfig]? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: releaseConfigURL.path))?[.modificationDate] as? Date
        if let lastRead, lastRead.modified == modified { return lastRead.hotkeys }
        let config: AppConfig
        if modified == nil {
            // No file: the release app has never saved settings, so it uses defaults.
            config = AppConfig()
        } else if let data = try? Data(contentsOf: releaseConfigURL),
                  let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            return nil
        }
        let hotkeys = ReleaseHotkeyYieldPolicy.handledHotkeys(in: config)
        lastRead = (modified, hotkeys)
        return hotkeys
    }

    /// Settings are saved by replacing `config.json`, which shows up as a write to
    /// its folder. A folder that does not exist yet is watched on a later refresh.
    private func watchReleaseFolderIfNeeded() {
        guard folderWatcher == nil else { return }
        let fd = open(releaseConfigURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                source.cancel()
                self.folderWatcher = nil
            }
            self.refresh()
        }
        source.setCancelHandler { close(fd) }
        folderWatcher = source
        source.resume()
    }
}

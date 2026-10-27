import AppKit
import Carbon
import Foundation

/// Turning Cotypist on and off. "On" means the Cotypist input source is the active one.
///
/// macOS won't let an app add an input source to the user's list: enabling from code isn't
/// persisted, and selecting a source that hasn't been added fails. Once the user has added it,
/// selecting it from code works. So turning on tries to select it; if that fails, Muesli opens
/// Keyboard settings with a guide and keeps retrying, which succeeds the moment it's been added.
@MainActor
final class CotypistSetup: ObservableObject {
    static let shared = CotypistSetup()

    enum State: Equatable {
        case off
        case on
        /// Waiting for the user to add the input source in System Settings.
        case addingInputSource
    }

    @Published private(set) var state: State = .off
    /// Guidance that took long enough to suggest the input-source cache needs a re-login.
    @Published private(set) var suggestsRelogin = false

    static var isAvailable: Bool { Bundle.main.bundleIdentifier?.hasPrefix("com.muesli.dev") == true }

    static var inputModeID: String { (Bundle.main.bundleIdentifier ?? "com.muesli.app") + ".inputmethod.Cotypist.en" }
    static var displayName: String { "\(AppIdentity.displayName) Cotypist" }

    private static let previousSourceKey = "cotypistPreviousInputSourceID"
    private static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
    private static let retryInterval: TimeInterval = 0.5
    private static let reloginHintAfter: TimeInterval = 60
    private static let giveUpAfter: TimeInterval = 300

    private let guide = CotypistSetupGuideController()
    private var retryTimer: Timer?
    private var guidanceStartedAt: Date?
    private var selectionObserver: NSObjectProtocol?

    private init() {
        // Track switches made elsewhere (the input menu, ⌃Space) so the toggle stays truthful.
        selectionObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func setOn(_ on: Bool) {
        on ? turnOn() : turnOff()
    }

    func turnOn() {
        rememberPreviousSource()
        if Self.selectCotypist() {
            finishGuidance()
            state = .on
            return
        }
        startGuidance()
    }

    func turnOff() {
        finishGuidance()
        if Self.currentSourceID() == Self.inputModeID {
            let previous = UserDefaults.standard.string(forKey: Self.previousSourceKey)
            if !(previous.map(Self.select) ?? false) {
                // Fall back to the keyboard layout macOS uses for plain ASCII typing.
                if let layout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                    TISSelectInputSource(layout)
                }
            }
        }
        refresh()
    }

    /// Re-opens Keyboard settings and the guide while waiting for the input source to be added.
    func showGuide() {
        guard state == .addingInputSource else { return }
        NSWorkspace.shared.open(Self.keyboardSettingsURL)
        guide.show(inputSourceName: Self.displayName, suggestsRelogin: suggestsRelogin)
    }

    private func refresh() {
        if Self.currentSourceID() == Self.inputModeID {
            finishGuidance()
            state = .on
        } else if state != .addingInputSource {
            state = .off
        }
    }

    // MARK: - Guidance

    private func startGuidance() {
        state = .addingInputSource
        suggestsRelogin = false
        guidanceStartedAt = Date()
        NSWorkspace.shared.open(Self.keyboardSettingsURL)
        guide.onClose = { [weak self] in self?.cancelGuidance() }
        guide.show(inputSourceName: Self.displayName, suggestsRelogin: false)
        retryTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retrySelection() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// Selecting fails until the input source has been added; the first success completes setup.
    private func retrySelection() {
        guard state == .addingInputSource, let startedAt = guidanceStartedAt else { return }
        if Self.selectCotypist() {
            finishGuidance()
            state = .on
            return
        }
        let waited = Date().timeIntervalSince(startedAt)
        if waited > Self.giveUpAfter {
            cancelGuidance()
        } else if waited > Self.reloginHintAfter && !suggestsRelogin {
            // A newly installed input method can be missing from Settings until macOS rebuilds
            // its input-source cache, which happens at login.
            suggestsRelogin = true
            guide.show(inputSourceName: Self.displayName, suggestsRelogin: true)
        }
    }

    private func cancelGuidance() {
        finishGuidance()
        refresh()
    }

    private func finishGuidance() {
        retryTimer?.invalidate()
        retryTimer = nil
        guidanceStartedAt = nil
        guide.dismiss()
        if state == .addingInputSource { state = .off }
    }

    // MARK: - Text Input Sources

    private func rememberPreviousSource() {
        guard let current = Self.currentSourceID(), current != Self.inputModeID else { return }
        UserDefaults.standard.set(current, forKey: Self.previousSourceKey)
    }

    private static func selectCotypist() -> Bool { select(inputModeID) }

    @discardableResult
    private static func select(_ sourceID: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return false }
        return TISSelectInputSource(source) == noErr && currentSourceID() == sourceID
    }

    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }
}

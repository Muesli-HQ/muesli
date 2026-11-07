import ApplicationServices
import Foundation

/// macOS Automation consent for reading a browser's active tab.
///
/// An Apple Event raises the consent dialog only while the event is waiting. The tab lookup gives
/// up after 1.8 s, so the dialog was withdrawn before anyone could click it. The consent request
/// here has no deadline, runs once per browser, and the lookup stays off until the answer is in.
enum BrowserAutomationPermission {
    enum State: Equatable {
        case granted
        case denied
        case undetermined
        /// The browser is not running, so macOS cannot say.
        case unavailable
    }

    static func state(forStatus status: OSStatus) -> State {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        default: return .unavailable
        }
    }

    static func state(bundleID: String) -> State {
        state(forStatus: determine(bundleID: bundleID, askUserIfNeeded: false))
    }

    /// Shows the macOS consent dialog for `bundleID` unless one is already open for it.
    /// Returns immediately; the dialog waits for the user on a background queue.
    static func requestOnce(bundleID: String) {
        guard pending.begin(bundleID) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = determine(bundleID: bundleID, askUserIfNeeded: true)
            pending.finish(bundleID)
            fputs("[meeting-monitor] browser_automation_prompt app=\(bundleID) status=\(status)\n", stderr)
        }
    }

    private static let pending = PendingRequests()

    private static func determine(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, askUserIfNeeded
        )
    }

    private final class PendingRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var bundleIDs: Set<String> = []

        func begin(_ bundleID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return bundleIDs.insert(bundleID).inserted
        }

        func finish(_ bundleID: String) {
            lock.lock()
            bundleIDs.remove(bundleID)
            lock.unlock()
        }
    }
}

import AppKit
import ApplicationServices
import Foundation

protocol ChatwootCallDetectionBrowserProbing: Sendable {
    func probe(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionBrowserProbeResult
}

enum ChatwootCallDetectionBrowserProbeResult: Sendable {
    case noSource, permissionRequired, timedOut, sourceMismatch
    case focusedBrowser(bundleID: String)
}

/// Production support matrix: Safari/Chrome source probing only; every Chatwoot UI
/// version remains unsupported for positive detection. AX cannot currently attest
/// document/route generation or remote connected state, so no AX labels or titles are
/// promoted into the synthetic profile. No browser scripts, DOM/chat dumps or prompts.
struct ChatwootCallDetectionCollector: ChatwootCallDetectionSnapshotProviding {
    static let browserBundleIDs: Set<String> = ["com.apple.Safari", "com.google.Chrome"]
    private let probe: any ChatwootCallDetectionBrowserProbing

    init(probe: any ChatwootCallDetectionBrowserProbing = ChatwootCallDetectionAXProbe()) {
        self.probe = probe
    }

    func snapshot(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionSnapshotResult {
        guard !Task.isCancelled, ContinuousClock().now < deadline else { return .unavailable(.timedOut) }
        let result = await probe.probe(deadline: deadline)
        guard !Task.isCancelled, ContinuousClock().now < deadline else { return .unavailable(.timedOut) }
        switch result {
        case .noSource: return .unavailable(.noSource)
        case .permissionRequired: return .unavailable(.permissionRequired)
        case .timedOut: return .unavailable(.timedOut)
        case .sourceMismatch: return .unavailable(.sourceMismatch)
        case .focusedBrowser: return .unavailable(.unsupported)
        }
    }
}

struct ChatwootCallDetectionAXProbe: ChatwootCallDetectionBrowserProbing {
    private struct ProcessIdentity: Sendable, Equatable {
        let bundleID: String
        let pid: Int32
        let launchedAt: Date
    }

    func probe(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionBrowserProbeResult {
        guard !Task.isCancelled, ContinuousClock().now < deadline else { return .timedOut }
        guard let before = await frontmostIdentity() else { return .noSource }
        guard ChatwootCallDetectionCollector.browserBundleIDs.contains(before.bundleID) else {
            return .focusedBrowser(bundleID: before.bundleID)
        }
        guard AXIsProcessTrusted() else { return .permissionRequired }
        let windowResult = focusedWindow(pid: before.pid, deadline: deadline)
        guard !Task.isCancelled, ContinuousClock().now < deadline else { return .timedOut }
        guard let after = await frontmostIdentity(), before == after else { return .sourceMismatch }
        return windowResult ?? .focusedBrowser(bundleID: before.bundleID)
    }

    @MainActor private func frontmostIdentity() -> ProcessIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              let bundleID = app.bundleIdentifier, let launchedAt = app.launchDate else { return nil }
        return ProcessIdentity(bundleID: bundleID, pid: app.processIdentifier, launchedAt: launchedAt)
    }

    /// One process-pinned AX call, no traversal or text read. AX objects remain local
    /// to this synchronous function and never survive an await or cross a process.
    private func focusedWindow(pid: Int32, deadline: ContinuousClock.Instant) -> ChatwootCallDetectionBrowserProbeResult? {
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else { return .timedOut }
        let components = remaining.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, Float(min(seconds, 0.2))) == .success else { return .timedOut }
        var window: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        switch error {
        case .success:
            guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return .noSource }
            return nil
        case .apiDisabled: return .permissionRequired
        case .cannotComplete: return .timedOut
        case .noValue, .invalidUIElement: return .noSource
        default: return .focusedBrowser(bundleID: "")
        }
    }
}

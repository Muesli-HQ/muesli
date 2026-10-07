import AppKit
import ApplicationServices
import Foundation

/// Bounded, nonprompting process/permission inventory. No production UI version is validated.
/// Identity is backed by Homebrew's wechat cask, not a local code-signing acceptance run:
/// https://github.com/Homebrew/homebrew-cask/blob/main/Casks/w/wechat.rb
/// Until real macOS call UI evidence is reviewed, this collector never produces observations.
final class WeChatCallDetectionCollector: WeChatCallDetectionSnapshotProviding, @unchecked Sendable {
    static let bundleID = "com.tencent.xinWeChat"
    private let probe: @Sendable () async -> WeChatCallDetectionSnapshotResult
    private let lock = NSLock()
    private var inFlight = false // all access is protected by lock

    init(probe: @escaping @Sendable () async -> WeChatCallDetectionSnapshotResult = {
        await WeChatCallDetectionCollector.productionSnapshot()
    }) {
        self.probe = probe
    }

    /// Resource occupancy remains true until actual probe exit, even after caller timeout.
    var isProbeInFlight: Bool { lock.withLock { inFlight } }

    func snapshot() async -> WeChatCallDetectionSnapshotResult {
        guard reserve() else { return .unavailable(.timedOut) }
        defer { release() }
        guard !Task.isCancelled else { return .unavailable(.timedOut) }
        let result = await probe()
        guard !Task.isCancelled else { return .unavailable(.timedOut) }
        switch result {
        case .unavailable: return result
        case .snapshot: return .unavailable(.unsupported)
        }
    }

    private func reserve() -> Bool {
        lock.withLock {
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
    }
    private func release() { lock.withLock { inFlight = false } }

    @MainActor private static func productionSnapshot() -> WeChatCallDetectionSnapshotResult {
        guard !Task.isCancelled else { return .unavailable(.timedOut) }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        guard !applications.isEmpty else { return .unavailable(.noSource) }
        guard applications.count == 1 else { return .unavailable(.ambiguous) }
        let application = applications[0]
        guard application.bundleIdentifier == bundleID, application.processIdentifier > 0,
              let launchDate = application.launchDate,
              launchDate.timeIntervalSince1970.isFinite else { return .unavailable(.sourceMismatch) }
        guard AXIsProcessTrusted() else { return .unavailable(.permissionRequired) }
        // No window/title heuristics: chat, voice notes and ringing can share audio/UI controls.
        // A future validated profile must establish scoped connected state and session generation.
        return .unavailable(.unsupported)
    }
}

import AppKit
import ApplicationServices
import Foundation

struct LINECallDetectionMetadata: Sendable {
    let bundleID: String
    let processID: Int32
    let processLaunchID: String
    let windowCount: Int
}
enum LINECallDetectionProbeResult: Sendable {
    case metadata(LINECallDetectionMetadata)
    case unavailable(CallDetectionUnavailableReason)
}

/// Bounded, read-only process/AX metadata collection, without a permission prompt.
/// Identity verified via Apple's lookup for macOS app 539883307 (2026-10-07).
/// LINE 26.5.0 call AX markers/connection state are unverified: production never
/// emits semantic snapshots. No window titles, chat text or participants are read.
struct LINECallDetectionCollector: LINECallDetectionSnapshotProviding {
    private let probe: @MainActor @Sendable () -> LINECallDetectionProbeResult
    private let clock: @Sendable () -> ContinuousClock.Instant

    init(
        probe: @escaping @MainActor @Sendable () -> LINECallDetectionProbeResult = {
            LINECallDetectionCollector.liveProbe()
        },
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.probe = probe
        self.clock = clock
    }

    func snapshot() async -> LINECallDetectionCollection {
        guard !Task.isCancelled else { return .unavailable(.timedOut) }
        let started = clock()
        let result = await MainActor.run {
            guard !Task.isCancelled else { return LINECallDetectionProbeResult.unavailable(.timedOut) }
            return probe()
        }
        guard !Task.isCancelled, started.duration(to: clock()) <= .milliseconds(250) else {
            return .unavailable(.timedOut)
        }
        switch result {
        case .unavailable(let reason): return .unavailable(reason)
        case .metadata(let value):
            guard value.bundleID == "jp.naver.line.mac", value.processID > 0,
                  !value.processLaunchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable(.sourceMismatch)
            }
            guard (0...8).contains(value.windowCount) else { return .unavailable(.unsupported) }
            if value.windowCount == 0 { return .unavailable(.noSource) }
            return .unavailable(.unsupported)
        }
    }

    @MainActor private static func liveProbe() -> LINECallDetectionProbeResult {
        let clock = ContinuousClock()
        let started = clock.now
        guard !Task.isCancelled else { return .unavailable(.timedOut) }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac")
            .filter { !$0.isTerminated }
        guard !apps.isEmpty else { return .unavailable(.noSource) }
        guard apps.count == 1 else { return .unavailable(.ambiguous) }
        let app = apps[0]
        guard let launch = app.launchDate, launch.timeIntervalSince1970.isFinite,
              app.bundleIdentifier == "jp.naver.line.mac", app.processIdentifier > 0 else {
            return .unavailable(.sourceMismatch)
        }
        guard AXIsProcessTrusted() else { return .unavailable(.permissionRequired) }
        guard !Task.isCancelled, started.duration(to: clock.now) < .milliseconds(250) else {
            return .unavailable(.timedOut)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementSetMessagingTimeout(element, 0.05) == .success else {
            return .unavailable(.unsupported)
        }
        // A count query avoids materializing an unbounded AX window/child tree.
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(element, kAXWindowsAttribute as CFString, &count)
        guard !Task.isCancelled, started.duration(to: clock.now) <= .milliseconds(250) else {
            return .unavailable(.timedOut)
        }
        guard error == .success else {
            return .unavailable(error == .cannotComplete ? .timedOut : .unsupported)
        }
        guard !app.isTerminated,
              let live = NSRunningApplication(processIdentifier: app.processIdentifier),
              !live.isTerminated, live.launchDate == launch,
              live.bundleIdentifier == app.bundleIdentifier else { return .unavailable(.sourceMismatch) }
        return .metadata(.init(bundleID: "jp.naver.line.mac", processID: app.processIdentifier,
                               processLaunchID: String(launch.timeIntervalSince1970), windowCount: count))
    }
}

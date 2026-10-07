import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
#endif

struct TelegramCallDetectionProcess: Sendable, Equatable {
    let bundleID: String
    let processID: Int32
    let launchID: String
}

enum TelegramCallDetectionProbeResult: Sendable, Equatable {
    case windows(Int)
    case unavailable(CallDetectionUnavailableReason)
}

/// A bounded, read-only capability probe, not a verified live-call recognizer.
/// It never reads chat titles/contents, recursively walks children, or acts on AX.
struct TelegramCallDetectionCollector: Sendable {
    typealias Inventory = @Sendable () async -> [TelegramCallDetectionProcess]
    typealias Probe = @Sendable (TelegramCallDetectionProcess) -> TelegramCallDetectionProbeResult
    private let inventory: Inventory
    private let isTrusted: @Sendable () -> Bool
    private let probe: Probe

    init(
        inventory: @escaping Inventory = { await runningProcesses() },
        isTrusted: @escaping @Sendable () -> Bool = { accessibilityTrusted() },
        probe: @escaping Probe = { probeWindows($0) }
    ) {
        self.inventory = inventory
        self.isTrusted = isTrusted
        self.probe = probe
    }

    static func productionRead() async -> TelegramCallDetectionReadResult {
        #if os(macOS)
        return await Self().collect()
        #else
        return .unavailable(.unsupported)
        #endif
    }

    func collect() async -> TelegramCallDetectionReadResult {
        let before = matching(await inventory())
        guard !before.isEmpty else { return .unavailable(.noSource) }
        guard before.count == 1 else { return .unavailable(.ambiguous) }
        let process = before[0]
        guard process.processID > 0, TelegramCallDetectionClassifier.validOpaqueKey(process.launchID) else {
            return .unavailable(.sourceMismatch)
        }
        guard isTrusted() else { return .unavailable(.permissionRequired) }
        let probe = probe
        // Do not block the adapter actor or MainActor with synchronous AX calls.
        let report = await Task.detached(priority: .utility) { probe(process) }.value
        let after = matching(await inventory())
        guard after == before else { return .unavailable(.sourceMismatch) }
        guard isTrusted() else { return .unavailable(.permissionRequired) }
        switch report {
        case .unavailable(let reason): return .unavailable(reason)
        case .windows(let count):
            guard (0...8).contains(count) else { return .unavailable(.unsupported) }
            // An AX window and a running Telegram process cannot prove a call.
            // No source-backed, runtime-verified call-surface profile is available.
            return .unavailable(.unsupported)
        }
    }

    private func matching(_ processes: [TelegramCallDetectionProcess]) -> [TelegramCallDetectionProcess] {
        // Stop after two matches: enough to reject ambiguity without broad inspection.
        Array(processes.lazy.filter { TelegramCallDetectionClassifier.bundleIDs.contains($0.bundleID) }.prefix(2))
    }

    private static func runningProcesses() async -> [TelegramCallDetectionProcess] {
        #if os(macOS)
        return await MainActor.run {
            var matches: [TelegramCallDetectionProcess] = []
            for app in NSWorkspace.shared.runningApplications {
                guard let bundle = app.bundleIdentifier,
                      TelegramCallDetectionClassifier.bundleIDs.contains(bundle), !app.isTerminated else { continue }
                let launch = app.launchDate?.timeIntervalSince1970
                matches.append(TelegramCallDetectionProcess(
                    bundleID: bundle, processID: app.processIdentifier,
                    launchID: launch.map { $0.isFinite ? String($0.bitPattern, radix: 16) : "" } ?? ""
                ))
                if matches.count == 2 { break }
            }
            return matches
        }
        #else
        return []
        #endif
    }

    private static func accessibilityTrusted() -> Bool {
        #if os(macOS)
        return AXIsProcessTrusted() // No prompt/options or system settings action.
        #else
        return false
        #endif
    }

    private static func probeWindows(_ process: TelegramCallDetectionProcess) -> TelegramCallDetectionProbeResult {
        #if os(macOS)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        let app = AXUIElementCreateApplication(process.processID)
        guard AXUIElementSetMessagingTimeout(app, 0.05) == .success else { return .unavailable(.unsupported) }
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count)
        guard countError == .success else { return .unavailable(reason(for: countError)) }
        guard count >= 0, count <= 8 else { return .unavailable(.unsupported) }
        guard ContinuousClock.now < deadline else { return .unavailable(.timedOut) }
        guard count > 0 else { return .windows(0) }
        var values: CFArray?
        let rangeError = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, count, &values)
        guard rangeError == .success else { return .unavailable(reason(for: rangeError)) }
        guard let windows = values as? [AXUIElement], windows.count == count else { return .unavailable(.unsupported) }
        for window in windows {
            guard ContinuousClock.now < deadline else { return .unavailable(.timedOut) }
            guard AXUIElementSetMessagingTimeout(window, 0.05) == .success else { return .unavailable(.unsupported) }
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == process.processID else {
                return .unavailable(.sourceMismatch)
            }
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            guard roleError == .success else { return .unavailable(reason(for: roleError)) }
            guard role as? String == kAXWindowRole as String else { return .unavailable(.unsupported) }
        }
        guard ContinuousClock.now < deadline else { return .unavailable(.timedOut) }
        return .windows(Int(count))
        #else
        return .unavailable(.unsupported)
        #endif
    }

    #if os(macOS)
    private static func reason(for error: AXError) -> CallDetectionUnavailableReason {
        switch error {
        case .apiDisabled: return .permissionRequired
        case .cannotComplete: return .timedOut
        case .invalidUIElement: return .sourceMismatch
        default: return .unsupported
        }
    }
    #endif
}

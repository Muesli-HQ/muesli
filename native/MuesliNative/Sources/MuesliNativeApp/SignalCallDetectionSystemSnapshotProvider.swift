import Foundation
import AppKit
import ApplicationServices

struct SignalCallDetectionProcess: Sendable, Equatable {
    let bundleID: String
    let processID: Int32
    let launchedAt: Date?
}

enum SignalCallDetectionWindowRead: Sendable {
    case count(Int)
    case unavailable(CallDetectionUnavailableReason)
}

protocol SignalCallDetectionInventoryReading: Sendable {
    func processes() async -> [SignalCallDetectionProcess]
    func isAccessibilityTrusted() async -> Bool
    func windowCount(process: SignalCallDetectionProcess, deadline: Date) async -> SignalCallDetectionWindowRead
}

/// Passive, bounded Signal stable-release inventory. No connected-call AX
/// profile is verified: inventory alone ALWAYS fails closed with unsupported.
/// Signal Desktop source 832279c26138f2ea47c6bb7d6b9f7e0f80eb9e96 verifies:
/// - package.json build.appId = org.whispersystems.signal-desktop
/// - CallScreen.dom.tsx separates accepted direct calls and group transport/join
/// - CallingLobby.dom.tsx also has mic and hangup controls before acceptance.
/// These DOM facts do not establish macOS AX roles, identifiers, or labels.
/// No titles, chat text, names, audio activity or private database reads are used.
struct SignalCallDetectionSystemSnapshotProvider: SignalCallDetectionSnapshotProvider {
    private let inventory: any SignalCallDetectionInventoryReading
    private let now: @Sendable () -> Date

    init(inventory: any SignalCallDetectionInventoryReading = SignalCallDetectionSystemInventory(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.inventory = inventory
        self.now = now
    }

    func snapshot(deadline: Date) async -> SignalCallDetectionSnapshotRead {
        guard withinBudget(deadline) else { return .unavailable(.timedOut) }
        let before = await inventory.processes().filter { $0.bundleID == "org.whispersystems.signal-desktop" }
        guard withinBudget(deadline) else { return .unavailable(.timedOut) }
        guard !before.isEmpty else { return .unavailable(.noSource) }
        guard before.count == 1 else { return .unavailable(.ambiguous) }
        let process = before[0]
        guard process.processID > 0, let launch = process.launchedAt,
              launch.timeIntervalSince1970.isFinite else { return .unavailable(.sourceMismatch) }
        let trusted = await inventory.isAccessibilityTrusted()
        guard withinBudget(deadline) else { return .unavailable(.timedOut) }
        guard trusted else { return .unavailable(.permissionRequired) }
        let windows = await inventory.windowCount(process: process, deadline: deadline)
        guard withinBudget(deadline) else { return .unavailable(.timedOut) }
        let count: Int
        switch windows {
        case let .count(value): count = value
        case let .unavailable(reason): return .unavailable(reason)
        }
        let after = await inventory.processes().filter { $0.bundleID == "org.whispersystems.signal-desktop" }
        guard withinBudget(deadline) else { return .unavailable(.timedOut) }
        guard after.count <= 1 else { return .unavailable(.ambiguous) }
        guard after == before else { return .unavailable(.sourceMismatch) }
        guard count >= 0 && count <= 8 else { return .unavailable(.unsupported) }
        guard count > 0 else { return .unavailable(.noSource) }
        return .unavailable(.unsupported)
    }

    private func withinBudget(_ deadline: Date) -> Bool {
        !Task.isCancelled && now() < deadline
    }
}

struct SignalCallDetectionSystemInventory: SignalCallDetectionInventoryReading {
    func processes() async -> [SignalCallDetectionProcess] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, app.bundleIdentifier == "org.whispersystems.signal-desktop" else { return nil }
                return SignalCallDetectionProcess(bundleID: "org.whispersystems.signal-desktop",
                                                   processID: app.processIdentifier, launchedAt: app.launchDate)
            }
        }
    }

    func isAccessibilityTrusted() async -> Bool {
        AXIsProcessTrusted() // Never request permission as a detection side effect.
    }

    func windowCount(process: SignalCallDetectionProcess, deadline: Date) async -> SignalCallDetectionWindowRead {
        // AX messaging is synchronous. Never run it on MainActor or the adapter
        // actor. The adapter's outer deadline can retire this detached read.
        await Task<SignalCallDetectionWindowRead, Never>.detached {
            guard !Task.isCancelled, Date() < deadline else { return .unavailable(.timedOut) }
            let app = AXUIElementCreateApplication(process.processID)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0,
                  AXUIElementSetMessagingTimeout(app, Float(min(0.1, remaining))) == .success else {
                return .unavailable(.timedOut)
            }
            var windows: CFArray?
            // Eight supported inventory windows plus one overflow sentinel;
            // never copy an unbounded tree/list or any window title/content.
            let status = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 9, &windows)
            guard !Task.isCancelled, Date() < deadline else { return .unavailable(.timedOut) }
            guard status == .success, let windows else {
                if status == .cannotComplete { return .unavailable(.timedOut) }
                if status == .apiDisabled { return .unavailable(.permissionRequired) }
                return .unavailable(.unsupported)
            }
            return .count(CFArrayGetCount(windows))
        }.value
    }
}

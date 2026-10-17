import AppKit
import Foundation

struct RunningApplicationState {
    let runningApps: [RunningAppSnapshot]
    let foregroundBundleID: String?
}

struct RunningApplicationStoreOwners {
    private var owners: Set<UUID> = []

    mutating func acquire(_ owner: UUID) -> Bool {
        guard owners.insert(owner).inserted else { return false }
        return owners.count == 1
    }

    mutating func release(_ owner: UUID) -> Bool {
        guard owners.remove(owner) != nil else { return false }
        return owners.isEmpty
    }
}

/// Immutable copies let the speaker monitor inspect processes without querying
/// LaunchServices or hopping to MainActor on each poll.
final class MeetingSpeakerRunningAppsSnapshotStore: @unchecked Sendable {
    static let shared = MeetingSpeakerRunningAppsSnapshotStore()

    private let lock = NSLock()
    private var apps: [RunningAppSnapshot] = []

    func replace(_ apps: [RunningAppSnapshot]) {
        lock.lock()
        self.apps = apps
        lock.unlock()
    }

    func snapshot() -> [RunningAppSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return apps
    }
}

@MainActor
final class RunningApplicationStore {
    static let shared = RunningApplicationStore()

    var onChanged: ((MeetingDetectionTrigger) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var runningApps: [RunningAppSnapshot] = []
    private var foregroundBundleID: String?
    private var owners = RunningApplicationStoreOwners()

    func start(owner: UUID) {
        guard owners.acquire(owner) else { return }
        refreshState()

        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
                self?.onChanged?(.workspaceActivated)
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
                self?.onChanged?(.workspaceActivated)
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
                self?.onChanged?(.workspaceActivated)
            }
        })
    }

    func stop(owner: UUID) {
        guard owners.release(owner) else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
        runningApps.removeAll()
        MeetingSpeakerRunningAppsSnapshotStore.shared.replace([])
        foregroundBundleID = nil
    }

    func snapshot() -> RunningApplicationState {
        RunningApplicationState(
            runningApps: runningApps,
            foregroundBundleID: foregroundBundleID
        )
    }

    private func refreshState() {
        let apps: [RunningAppSnapshot] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppSnapshot(
                bundleID: bundleID,
                appName: app.localizedName ?? MeetingCandidateResolver.browserApps[bundleID] ?? bundleID,
                processIdentifier: app.processIdentifier,
                isActive: app.isActive
            )
        }
        runningApps = apps
        MeetingSpeakerRunningAppsSnapshotStore.shared.replace(apps)
        foregroundBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

import AppKit
import Foundation

struct RunningApplicationState {
    let runningApps: [RunningAppSnapshot]
    let foregroundBundleID: String?
}

@MainActor
final class RunningApplicationStore {
    var onChanged: ((MeetingDetectionTrigger) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var runningApps: [RunningAppSnapshot] = []
    private var foregroundBundleID: String?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
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

    func stop() {
        guard isStarted else { return }
        isStarted = false
        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
        runningApps.removeAll()
        foregroundBundleID = nil
    }

    func snapshot() -> RunningApplicationState {
        RunningApplicationState(
            runningApps: runningApps,
            foregroundBundleID: foregroundBundleID
        )
    }

    private func refreshState() {
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppSnapshot(
                bundleID: bundleID,
                appName: app.localizedName ?? MeetingCandidateResolver.browserApps[bundleID] ?? bundleID,
                processIdentifier: app.processIdentifier,
                isActive: app.isActive
            )
        }
        foregroundBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

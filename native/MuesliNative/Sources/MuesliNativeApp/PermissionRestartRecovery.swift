import AppKit
import AVFoundation
import Foundation

enum PermissionRestartDestination: String {
    case permissions
    case timeTurnerPermissions
}

enum PermissionRecoveryIntentLifetime {
    // Allow time for System Settings and authentication, but not a later session.
    static let maximumAge: TimeInterval = 15 * 60

    static func isCurrent(requestedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(requestedAt)
        return age.isFinite && age >= 0 && age < maximumAge
    }
}

/// One-shot navigation intent survives both our relaunch and macOS Quit & Reopen.
/// It stores no permission status and never enables a feature.
@MainActor
final class PermissionRestartResumeStore {
    static let shared = PermissionRestartResumeStore()
    private static let key = "permissionRestart.destination"
    private static let timestampKey = "permissionRestart.requestedAt"
    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func save(_ destination: PermissionRestartDestination) {
        defaults.set(now(), forKey: Self.timestampKey)
        defaults.set(destination.rawValue, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.timestampKey)
    }

    /// Consume only a recent setup intent; legacy or malformed timestamps fail closed.
    func consume(fallbackToPermissions: Bool) -> PermissionRestartDestination? {
        let destination = defaults.string(forKey: Self.key).flatMap(PermissionRestartDestination.init(rawValue:))
        let requestedAt = defaults.object(forKey: Self.timestampKey) as? Date
        let current = requestedAt.map { PermissionRecoveryIntentLifetime.isCurrent(requestedAt: $0, now: now()) } ?? false
        clear()
        return (current ? destination : nil) ?? (fallbackToPermissions ? .permissions : nil)
    }
}

enum PermissionRestartPresentation {
    /// Permission setup must allow the system's Quit & Reopen action to reach
    /// our normal termination delegate. AppKit otherwise rejects it before
    /// applicationShouldTerminate while the setup sheet remains open.
    @MainActor static func allowTermination(from window: NSWindow?) {
        guard let window else { return }
        var current: NSWindow? = host(in: window)
        while let window = current {
            window.preventsApplicationTerminationWhenModal = false
            current = window.sheetParent
        }
    }

    /// A feature's setup sheet must not hide or queue the restart notice.
    @MainActor static func host(in window: NSWindow) -> NSWindow {
        var host = window
        while let sheet = host.attachedSheet { host = sheet }
        return host
    }
}

/// A request is not proof of a grant: macOS can keep reporting false until relaunch.
/// Keep recovery intent in memory, without persisting or overriding permission status.
@MainActor
final class PermissionRestartRecovery {
    static let shared = PermissionRestartRecovery()
    private struct PendingNotice {
        let requestedAt: Date
        var visitedSettings = false
    }
    private var pendingNotice: [FeaturePermission: PendingNotice] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func requested(_ permission: FeaturePermission, wasGranted: Bool) {
        guard permission.mayNeedRestart, !wasGranted else { return }
        pendingNotice[permission] = PendingNotice(requestedAt: now())
    }

    /// Native prompt dismissal alone is not a visit to the permission settings.
    func applicationActivated(bundleID: String?) {
        guard bundleID == AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID else { return }
        for permission in Array(pendingNotice.keys) {
            pendingNotice[permission]?.visitedSettings = true
        }
    }

    func takeNotice() -> [FeaturePermission] {
        let date = now()
        let permissions = pendingNotice.filter {
            $0.value.visitedSettings && PermissionRecoveryIntentLifetime.isCurrent(requestedAt: $0.value.requestedAt, now: date)
        }.keys.sorted { $0.rawValue < $1.rawValue }
        pendingNotice.removeAll()
        return permissions
    }
}

extension FeaturePermission {
    var mayNeedRestart: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording: true
        case .microphone: false
        }
    }

    @MainActor var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }
}

struct PermissionRestartActivity: Equatable {
    var recording = false
    var processing = false
    var assistant = false
    var unsentChat = false

    var blockingMessage: String? {
        if recording { return "Finish and save the current recording or dictation before restarting muesli." }
        if processing { return "Wait for transcription, imports and file changes to finish before restarting muesli." }
        if assistant { return "Finish or cancel the current AI request before restarting muesli." }
        if unsentChat { return "Send or clear the chat draft before restarting muesli." }
        return nil
    }
}

enum ApplicationRelaunch {
    static let permissionsArgument = "--muesli-permission-recovery"

    /// Wait for this exact process to exit, rather than racing shutdown with a fixed sleep.
    /// A bounded helper exits without reopening if termination never completes.
    static func arguments(processID: Int32, bundlePath: String, restorePermissions: Bool) -> [String] {
        ["-c", """
        attempts=0
        while /bin/kill -0 "$1" 2>/dev/null; do
          attempts=$((attempts + 1))
          [ "$attempts" -lt 120 ] || exit 0
          /bin/sleep 1
        done
        if [ "$3" = 1 ]; then
          /usr/bin/open -n -a "$2" --args --muesli-permission-recovery
        else
          /usr/bin/open -n -a "$2"
        fi
        """, "--", String(processID), bundlePath, restorePermissions ? "1" : "0"]
    }

    static func schedule(restorePermissions: Bool) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments(processID: ProcessInfo.processInfo.processIdentifier,
                                     bundlePath: Bundle.main.bundleURL.path,
                                     restorePermissions: restorePermissions)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
}

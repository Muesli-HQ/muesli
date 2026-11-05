import AppKit
import AVFoundation
import Foundation

enum PermissionRestartPresentation {
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
    private var pendingNotice = Set<FeaturePermission>()

    func requested(_ permission: FeaturePermission, wasGranted: Bool) {
        guard permission.mayNeedRestart, !wasGranted else { return }
        pendingNotice.insert(permission)
    }

    func takeNotice() -> [FeaturePermission] {
        let permissions = pendingNotice.sorted { $0.rawValue < $1.rawValue }
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

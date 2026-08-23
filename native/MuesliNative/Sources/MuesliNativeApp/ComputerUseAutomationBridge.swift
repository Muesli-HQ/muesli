import Foundation

/// Non-production entry point that starts a Computer Use command from outside the
/// app, so an acceptance sweep can run unattended.
///
/// Muesli already records every CUA run — a `dictations` row with `source = "cua"`
/// joined to a `computer_use_traces` row — so reading results needs no app support.
/// Starting a run does: CUA lives in this executable target and `muesli-cli` cannot
/// import it, leaving the hotkey as the only way in. That makes a 100-attempt sweep
/// 100 spoken commands.
///
/// This bridge bypasses **only** audio capture. The command text is handed to the
/// same `handleComputerUseCommand` the transcribed path calls, so a sweep measures
/// the real planner loop rather than a parallel one.
///
/// Two independent conditions gate it, because a listener that runs arbitrary
/// computer-use commands is a real attack surface:
///
/// 1. `enableComputerUseAutomationBridge` is off by default.
/// 2. Production builds refuse regardless of configuration — `isPermittedBuild`
///    rejects the production bundle identifier before the flag is even read.
///
/// Either alone would do; both are cheap.
enum ComputerUseAutomationBridge {
    /// Bundle identifier that must never accept externally-posted commands.
    static let productionBundleIdentifier = "com.muesli.app"

    /// Scoped to this build's bundle identifier so parallel dev lanes do not
    /// answer each other's commands.
    static var notificationName: Notification.Name {
        let identifier = Bundle.main.bundleIdentifier ?? "com.muesli.dev"
        return Notification.Name("\(identifier).cua.run")
    }

    static var isPermittedBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "") != productionBundleIdentifier
    }

    struct Request: Equatable {
        let command: String
        let runTag: String?
    }

    /// Decodes the `{"command": "...", "run_tag": "..."}` payload carried as the
    /// notification's object. Returns nil for anything malformed, blank, or
    /// implausibly long — a bad payload is ignored, never partially executed.
    static func decode(payload: String?) -> Request? {
        guard let payload,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCommand = object["command"] as? String else {
            return nil
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.count <= 500 else { return nil }
        let rawTag = (object["run_tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Request(command: command, runTag: rawTag?.isEmpty == false ? rawTag : nil)
    }

    final class Observer {
        private var token: NSObjectProtocol?
        private let center: DistributedNotificationCenter

        init(center: DistributedNotificationCenter = .default()) {
            self.center = center
        }

        var isObserving: Bool { token != nil }

        /// Starts listening when the build and configuration both permit it.
        /// Returns whether observation is active afterwards, so the caller can log it.
        @discardableResult
        func sync(enabled: Bool, handler: @escaping (Request) -> Void) -> Bool {
            let shouldObserve = enabled && ComputerUseAutomationBridge.isPermittedBuild
            if shouldObserve == isObserving { return isObserving }
            if shouldObserve {
                token = center.addObserver(
                    forName: ComputerUseAutomationBridge.notificationName,
                    object: nil,
                    queue: .main
                ) { notification in
                    guard let request = ComputerUseAutomationBridge.decode(
                        payload: notification.object as? String
                    ) else {
                        fputs("[cua-bridge] ignored malformed command payload\n", stderr)
                        return
                    }
                    handler(request)
                }
                fputs("[cua-bridge] listening on \(ComputerUseAutomationBridge.notificationName.rawValue)\n", stderr)
            } else {
                if let token { center.removeObserver(token) }
                token = nil
                fputs("[cua-bridge] stopped listening\n", stderr)
            }
            return isObserving
        }

        deinit {
            if let token { center.removeObserver(token) }
        }
    }
}

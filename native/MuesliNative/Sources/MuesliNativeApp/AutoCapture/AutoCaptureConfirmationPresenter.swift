import AppKit
import Foundation
import os

// MARK: - AutoCaptureConfirmationPresenting

/// Result returned by the first-run confirmation modal.
enum AutoCaptureConfirmationOutcome: Equatable {
    /// User explicitly approved. `rememberForApp` means the user also chose
    /// "Don't ask again for <app>".
    case approved(rememberForApp: Bool)
    /// User explicitly declined. `rememberForApp` indicates they declined and
    /// asked us to remember (so we don't pester them again).
    case declined(rememberForApp: Bool)
    /// Modal timed out — treated as a soft decline by the coordinator.
    case timedOut
}

/// Renders a first-run "Auto-capture is about to start" confirmation modal.
/// Pure abstraction so the coordinator can be unit-tested without AppKit.
@MainActor
protocol AutoCaptureConfirmationPresenting: AnyObject {
    /// Present the confirmation modal for the supplied app. The completion is
    /// invoked exactly once, on the main actor, with the user's choice. If
    /// the modal is still on screen after `AutoCaptureConfig.confirmationTimeoutSeconds`
    /// the implementation must invoke `completion(.timedOut)` and dismiss the
    /// modal itself.
    func present(
        appName: String,
        bundleID: String?,
        meetingTitle: String?,
        completion: @escaping @MainActor (AutoCaptureConfirmationOutcome) -> Void
    )
}

// MARK: - AutoCaptureAlertPresenter

/// Default AppKit implementation. Uses an `NSAlert` modal sheet on a hidden
/// utility panel so the prompt is always reachable for a menu-bar-only app.
@MainActor
final class AutoCaptureAlertPresenter: AutoCaptureConfirmationPresenting {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture")

    private var activeAlert: NSAlert?
    private var activePanel: NSPanel?
    private var pendingCompletion: ((AutoCaptureConfirmationOutcome) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    func present(
        appName: String,
        bundleID: String?,
        meetingTitle: String?,
        completion: @escaping @MainActor (AutoCaptureConfirmationOutcome) -> Void
    ) {
        if activeAlert != nil {
            completion(.declined(rememberForApp: false))
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Start recording this meeting?"
        let subject = meetingTitle?.isEmpty == false ? meetingTitle! : appName
        alert.informativeText = "Muesli detected \(subject) and is set to auto-capture meetings from \(appName)."

        let recordButton = alert.addButton(withTitle: "Start Recording")
        recordButton.keyEquivalent = "\r"
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again for \(appName)"

        let panel = makeHostPanel()
        activePanel = panel
        activeAlert = alert
        pendingCompletion = completion

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AutoCaptureConfig.confirmationTimeoutSeconds * 1_000_000_000))
            guard let self else { return }
            self.finish(outcome: .timedOut)
        }

        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            let remember = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn:
                self.finish(outcome: .approved(rememberForApp: remember))
            case .alertSecondButtonReturn:
                self.finish(outcome: .declined(rememberForApp: remember))
            default:
                self.finish(outcome: .declined(rememberForApp: remember))
            }
        }

        Self.logger.notice("auto_capture confirmation_shown app=\(appName, privacy: .public) bundle=\(bundleID ?? "nil", privacy: .public)")
    }

    private func makeHostPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .modalPanel
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    private func finish(outcome: AutoCaptureConfirmationOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let completion = pendingCompletion
        pendingCompletion = nil
        if let panel = activePanel {
            activePanel = nil
            panel.orderOut(nil)
        }
        activeAlert = nil
        completion?(outcome)
    }
}

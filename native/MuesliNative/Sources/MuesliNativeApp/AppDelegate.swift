import AppKit
import Foundation
import Sparkle
import TelemetryDeck
import MuesliCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MuesliController?
    private(set) var updaterController: SPUStandardUpdaterController?
    private let sparkleUpdateDelegate = SparkleUpdateDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStandardEditMenu()

        let telemetryConfig = TelemetryDeck.Config(appID: "7F2B7846-1CB5-4FE6-8ABC-56F217B06A86")
        TelemetryDeck.initialize(config: telemetryConfig)
        TelemetryDeck.signal("app.launched")

        do {
            let runtime = try RuntimePaths.resolve()
            AppFonts.registerIfNeeded(runtime: runtime)
            if let appIcon = runtime.appIcon, let image = NSImage(contentsOf: appIcon) {
                NSApplication.shared.applicationIconImage = image
            }
            let controller = MuesliController(runtime: runtime)
            sparkleUpdateDelegate.appState = controller.appState
            if Self.hasConfiguredSparkleFeed {
                let updaterController = SPUStandardUpdaterController(
                    startingUpdater: true,
                    updaterDelegate: sparkleUpdateDelegate,
                    userDriverDelegate: sparkleUpdateDelegate
                )
                controller.updaterController = updaterController
                self.updaterController = updaterController
            }
            self.controller = controller
            controller.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "\(AppIdentity.displayName) failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller?.shouldTerminateApplication() == false {
            return .terminateCancel
        }
        return .terminateNow
    }

    private static var hasConfiguredSparkleFeed: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc func openPreferences(_ sender: Any?) {
        controller?.openSettingsTab()
    }

    @objc func focusSearch(_ sender: Any?) {
        controller?.focusSearchField()
    }

    private func installStandardEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.openPreferences(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(AppIdentity.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)

        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(
            title: "Find",
            action: #selector(AppDelegate.focusSearch(_:)),
            keyEquivalent: "f"
        )
        findItem.target = self
        editMenu.addItem(findItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

@MainActor
final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var appState: AppState?
    private var lastPresentedAt: Date?
    private var updateCycleGeneration = 0

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        updateCycleGeneration += 1
        let generation = updateCycleGeneration
        let restoreStatus = recoverableUpdateStatus(appState?.sparkleUpdateStatus ?? .idle)
        appState?.sparkleUpdateStatus = .checking
        restoreStaleUpdateCheck(generation: generation, to: restoreStatus)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        finishUpdateCheck(with: .available(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        if UpdateFailureGuidance.isNoUpdateError(nsError) {
            finishUpdateCheck(with: .upToDate)
        } else {
            finishUpdateCheck(with: .failed(message: nsError.localizedDescription))
        }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        finishUpdateCheck(with: .downloaded(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        finishUpdateCheck(with: .installing(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .install:
            finishUpdateCheck(with: .installing(version: item.displayVersionString))
        case .dismiss where state.stage == .downloaded:
            finishUpdateCheck(with: .downloaded(version: item.displayVersionString))
        case .dismiss:
            finishUpdateCheck(with: .available(version: item.displayVersionString))
        case .skip:
            finishUpdateCheck(with: .idle)
        @unknown default:
            finishUpdateCheck(with: .available(version: item.displayVersionString))
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if UpdateFailureGuidance.isNoUpdateError(nsError) {
            finishUpdateCheck(with: .upToDate)
            return
        }

        finishUpdateCheck(with: .failed(message: nsError.localizedDescription))
        guard UpdateFailureGuidance.shouldShowFallback(for: nsError) else { return }

        // Sparkle shows its own error alert first. Delay briefly so this
        // recovery path appears after the generic updater failure alert.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.showManualInstallGuidance()
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        appState?.sparkleLastCheckedAt = Date()
        guard let error else { return }
        let nsError = error as NSError
        // didAbortWithError is the primary error callback; this keeps the
        // final-cycle handler self-contained for any Sparkle path that ends here.
        if UpdateFailureGuidance.isNoUpdateError(nsError) {
            finishUpdateCheck(with: .upToDate)
        } else {
            finishUpdateCheck(with: .failed(message: nsError.localizedDescription))
        }
    }

    private func finishUpdateCheck(with status: SparkleUpdateStatus) {
        updateCycleGeneration += 1
        appState?.sparkleUpdateStatus = status
    }

    private func restoreStaleUpdateCheck(generation: Int, to restoreStatus: SparkleUpdateStatus) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.updateCycleGeneration == generation else { return }
            guard case .checking = self.appState?.sparkleUpdateStatus else { return }
            self.finishUpdateCheck(with: restoreStatus)
        }
    }

    private func recoverableUpdateStatus(_ status: SparkleUpdateStatus) -> SparkleUpdateStatus {
        switch status {
        case .checking, .busy:
            return .idle
        default:
            return status
        }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        activateBeforeSparklePresentsUI()
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        activateBeforeSparklePresentsUI()
    }

    private func showManualInstallGuidance() {
        if let lastPresentedAt, Date().timeIntervalSince(lastPresentedAt) < 60 {
            return
        }
        lastPresentedAt = Date()

        let alert = NSAlert()
        alert.messageText = "Update did not finish"
        alert.informativeText = UpdateFailureGuidance.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: UpdateFailureGuidance.downloadPageURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    private nonisolated func activateBeforeSparklePresentsUI() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.activateApplicationForSparkle()
            }
        } else {
            // Sparkle calls this immediately before presenting update UI.
            // Complete activation before returning so LSUIElement update
            // prompts are ordered in front of the current app. This block only
            // performs AppKit activation and does not wait on Sparkle work.
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Self.activateApplicationForSparkle()
                }
            }
        }
    }

    @MainActor
    private static func activateApplicationForSparkle() {
        // Sparkle UI is opened from an LSUIElement menu-bar app. This is a
        // user-initiated update action, so use strong activation even though
        // AppKit deprecated the argumented API on macOS 14.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

enum UpdateFailureGuidance {
    private static let noUpdateErrorCode = 1001

    static let downloadPageURLString = "https://muesli-hq.github.io/muesli/"

    static let message = """
    Please quit Muesli, reopen it from Applications, and try the update once more.

    If this keeps happening, download the latest DMG and replace Muesli manually. This can happen when the local updater cannot finish preparing or replacing the app.
    """

    static func isNoUpdateError(_ error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }
        if error.code == noUpdateErrorCode { return true }
        return error.userInfo[SPUNoUpdateFoundReasonKey] != nil
    }

    static func shouldShowFallback(for error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }

        let installStageCodes: Set<Int> = [
            4000, // SUFileCopyFailure
            4001, // SUAuthenticationFailure
            4002, // SUMissingUpdateError
            4003, // SUMissingInstallerToolError
            4004, // SURelaunchError
            4005, // SUInstallationError
            4009, // SUNotValidUpdateError
            4010, // SUAgentInvalidationError
            4012, // SUInstallationWriteNoPermissionError
            4013, // SUInstallationTranslocationError
        ]

        return installStageCodes.contains(error.code)
    }
}

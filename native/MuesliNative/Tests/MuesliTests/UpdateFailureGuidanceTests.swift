import Foundation
import Sparkle
import Testing
@testable import MuesliNativeApp

@Suite("Update failure guidance")
struct UpdateFailureGuidanceTests {
    @Test("classifies Sparkle no-update errors as up to date")
    func classifiesNoUpdateErrorCode() {
        let error = NSError(domain: SUSparkleErrorDomain, code: 1001)

        #expect(UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test("classifies Sparkle no-update reason as up to date")
    func classifiesNoUpdateReason() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1002,
            userInfo: [SPUNoUpdateFoundReasonKey: 1]
        )

        #expect(UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test("does not classify localized text alone as up to date")
    func rejectsLocalizedTextWithoutSparkleSignal() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "You’re up to date!"]
        )

        #expect(!UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test("does not classify unrelated Sparkle errors as up to date")
    func rejectsUnrelatedSparkleErrors() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )

        #expect(!UpdateFailureGuidance.isNoUpdateError(error))
    }

    @Test(
        "shows fallback for Sparkle installation failures",
        arguments: [4000, 4001, 4002, 4003, 4004, 4005, 4009, 4010, 4012, 4013]
    )
    func showsFallbackForInstallationFailures(code: Int) {
        let error = NSError(domain: SUSparkleErrorDomain, code: code)

        #expect(UpdateFailureGuidance.shouldShowFallback(for: error))
    }

    @Test(
        "does not show fallback for non-install Sparkle errors",
        arguments: [1001, 3001, 3002, 4006, 4007, 4008, 4011]
    )
    func hidesFallbackForNonInstallSparkleErrors(code: Int) {
        let error = NSError(domain: SUSparkleErrorDomain, code: code)

        #expect(!UpdateFailureGuidance.shouldShowFallback(for: error))
    }

    @Test("does not show fallback for unrelated errors")
    func hidesFallbackForUnrelatedErrors() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        #expect(!UpdateFailureGuidance.shouldShowFallback(for: error))
    }
}

@Suite("Update action routing")
struct UpdateActionRoutingTests {
    @Test("status-bar update action enters the standard Sparkle UI")
    func statusBarUpdateActionUsesStandardSparkleFlow() throws {
        let source = try muesliControllerSource()
        let statusBarSource = try statusBarControllerSource()

        #expect(source.contains("""
            @objc func checkForUpdates() {
                presentStandardUpdateCheck()
            }
        """))
        #expect(statusBarSource.contains("#selector(MuesliController.checkForUpdates)"))
        #expect(statusBarSource.contains("item.target = controller"))
        #expect(statusBarSource.contains("item.isEnabled = controller.updaterController != nil"))
        #expect(!statusBarSource.contains("#selector(SPUStandardUpdaterController.checkForUpdates(_:))"))
        #expect(!source.contains("func retryUpdateCheck()"))
        #expect(!source.contains("checkForUpdateInformation()"))
    }

    @Test("standard update presentation does not preflight canCheckForUpdates")
    func standardUpdatePresentationLetsSparkleRefocusExistingUI() throws {
        let source = try muesliControllerSource()

        #expect(source.contains("updaterController.checkForUpdates(nil)"))
        #expect(source.contains("focusUpdaterWindowsCreatedAfterUpdateAction(excluding: existingWindows)"))
        #expect(try index(of: "updaterController.checkForUpdates(nil)", in: source) <
            index(of: "focusUpdaterWindowsCreatedAfterUpdateAction(excluding: existingWindows)", in: source))
        #expect(source.contains("activateApplicationForSparkle()"))
        #expect(!source.contains("canCheckForUpdates"))
        #expect(!source.contains("func installAvailableUpdate()"))
        #expect(!source.contains("restoreStaleUpdateCheck(generation: generation, to: restoreStatus)"))
        #expect(!source.contains("""
        DispatchQueue.main.async { [weak self] in
            updaterController.checkForUpdates(nil)
        """))
    }

    @Test("About page does not expose unreliable in-app install controls")
    func aboutPageUsesMenuBarGuidanceOnly() throws {
        let source = try aboutViewSource()

        #expect(source.contains("Use the menu bar icon > Check for Updates..."))
        #expect(!source.contains("let controller: MuesliController"))
        #expect(!source.contains("controller.checkForUpdates()"))
        #expect(!source.contains("Install Update"))
        #expect(!source.contains("Finish Update"))
        #expect(!source.contains("retryUpdateCheck()"))
        #expect(!source.contains("installAvailableUpdate()"))
        #expect(!source.contains("performUpdateAction"))
    }

    @Test("Sidebar update badge is status-only and does not start updates")
    func sidebarUpdateBadgeIsStatusOnly() throws {
        let source = try sidebarViewSource()

        #expect(source.contains("private var pendingUpdateCTA: UpdateCTA?"))
        #expect(source.contains("label: \"Update\""))
        #expect(source.contains("Open About for update instructions"))
        #expect(!source.contains("if updateCTA != nil"))
        #expect(!source.contains("Update Now"))
        #expect(!source.contains("controller.checkForUpdates()"))
        #expect(!source.contains("Open About to install the update"))
        #expect(!source.contains("Open About to finish installing the update"))
    }

    @Test("updater focus only targets windows created by the update action")
    func updaterFocusTargetsNewUpdaterWindowsOnly() throws {
        let source = try muesliControllerSource()

        #expect(source.contains("focusUpdaterWindowsCreatedAfterUpdateAction(excluding: existingWindows)"))
        #expect(source.contains("return !existingWindows.contains(ObjectIdentifier(window)) && isLikelyUpdaterWindow(window)"))
        #expect(source.contains("isLikelyUpdaterWindow(window)"))
        #expect(source.contains("className.localizedCaseInsensitiveContains(\"SPU\")"))
        #expect(source.contains("title.localizedCaseInsensitiveContains(\"update\")"))
        #expect(source.contains("title.localizedCaseInsensitiveContains(\"new version\")"))
        #expect(source.contains("title.localizedCaseInsensitiveContains(\"available\")"))
        #expect(source.contains("return false"))
        #expect(!source.contains("window.collectionBehavior ="))
        #expect(!source.contains("return window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
        #expect(!source.contains(".moveToActiveSpace"))
        #expect(!source.contains(".fullScreenAuxiliary"))
        #expect(!source.contains(".canJoinAllSpaces"))
        #expect(!source.contains("orderFrontRegardless()"))
    }

    @Test("Sparkle delegate cannot leave the About UI checking forever")
    func sparkleDelegateRestoresStaleCheckingState() throws {
        let source = try appDelegateSource()

        #expect(source.contains("private var updateCycleGeneration = 0"))
        #expect(source.contains("let restoreStatus = recoverableUpdateStatus(appState?.sparkleUpdateStatus ?? .idle)"))
        #expect(source.contains("finishUpdateCheck(with:"))
        #expect(source.contains("30_000_000_000"))
        #expect(source.contains("self.updateCycleGeneration == generation"))
        #expect(source.contains("guard case .checking = self.appState?.sparkleUpdateStatus else { return }"))
        #expect(source.contains("self.finishUpdateCheck(with: restoreStatus)"))
    }

    @Test("Sparkle focus handling activates without manually ordering app windows")
    func sparkleFocusHandlingDoesNotOrderApplicationWindows() throws {
        let source = try appDelegateSource()

        #expect(source.contains("activateBeforeSparklePresentsUI()"))
        #expect(source.contains("DispatchQueue.main.sync"))
        #expect(source.contains("Complete activation before returning"))
        #expect(!source.contains("DispatchSemaphore(value: 0)"))
        #expect(!source.contains("activationCompleted.wait(timeout:"))
        #expect(source.contains("NSApplication.shared.activate(ignoringOtherApps: true)"))
        #expect(!source.contains("orderFrontRegardless()"))
    }

    private func muesliControllerSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent("MuesliController.swift")
        return try String(contentsOf: controllerURL, encoding: .utf8)
    }

    private func appDelegateSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegateURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent("AppDelegate.swift")
        return try String(contentsOf: appDelegateURL, encoding: .utf8)
    }

    private func aboutViewSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let aboutViewURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent("AboutView.swift")
        return try String(contentsOf: aboutViewURL, encoding: .utf8)
    }

    private func statusBarControllerSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let statusBarControllerURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent("StatusBarController.swift")
        return try String(contentsOf: statusBarControllerURL, encoding: .utf8)
    }

    private func sidebarViewSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarViewURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent("SidebarView.swift")
        return try String(contentsOf: sidebarViewURL, encoding: .utf8)
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        guard let range = haystack.range(of: needle) else {
            throw TestFailure("Could not find \(needle)")
        }
        return range.lowerBound
    }
}

@Suite("Sidebar hit areas")
struct SidebarHitAreaTests {
    @Test("primary sidebar rows use their full highlighted surface as the hit target")
    func primarySidebarRowsExpandBeforeApplyingHitShape() throws {
        let source = try sidebarViewSource()
        let sidebarItem = try sourceSection(
            in: source,
            from: "private func sidebarItem",
            to: "private var darkModeToggle"
        )

        #expect(sidebarItem.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(sidebarItem.contains(".background("))
        #expect(sidebarItem.contains(".contentShape(Rectangle())"))
        #expect(try index(of: ".frame(maxWidth: .infinity, alignment: .leading)", in: sidebarItem) <
            index(of: ".contentShape(Rectangle())", in: sidebarItem))
    }

    @Test("meeting filter rows use the full row width as the hit target")
    func meetingFilterRowsExpandBeforeApplyingHitShape() throws {
        let source = try sidebarViewSource()
        let meetingFilterRow = try sourceSection(
            in: source,
            from: "private func meetingFilterRow",
            to: "private func folderRenameField"
        )

        #expect(meetingFilterRow.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(meetingFilterRow.contains(".background("))
        #expect(meetingFilterRow.contains(".contentShape(Rectangle())"))
        #expect(try index(of: ".frame(maxWidth: .infinity, alignment: .leading)", in: meetingFilterRow) <
            index(of: ".contentShape(Rectangle())", in: meetingFilterRow))
    }

    private func sidebarViewSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarViewURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent("SidebarView.swift")
        return try String(contentsOf: sidebarViewURL, encoding: .utf8)
    }

    private func sourceSection(in source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source[startRange.upperBound...].range(of: end) else {
            throw TestFailure("Could not find source section from \(start) to \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        guard let range = haystack.range(of: needle) else {
            throw TestFailure("Could not find \(needle)")
        }
        return range.lowerBound
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

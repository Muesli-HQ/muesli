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

        let body = try methodBody(named: "checkForUpdates", in: source)
        #expect(body.contains("presentStandardUpdateCheck()"))
        #expect(!body.contains("checkForUpdateInformation()"))
        #expect(!source.contains("func retryUpdateCheck()"))
    }

    @Test("standard update presentation does not preflight canCheckForUpdates")
    func standardUpdatePresentationLetsSparkleRefocusExistingUI() throws {
        let source = try muesliControllerSource()
        let body = try methodBody(named: "presentStandardUpdateCheck", in: source)

        #expect(body.contains("checkForUpdates(nil)"))
        #expect(body.contains("restoreStaleUpdateCheck(generation: generation, to: restoreStatus)"))
        #expect(!body.contains("canCheckForUpdates"))
        #expect(!source.contains("func installAvailableUpdate()"))
    }

    @Test("About page does not launch Sparkle directly")
    func aboutPageIsPassiveUpdateGuidance() throws {
        let source = try aboutViewSource()

        #expect(source.contains("Use the Muesli menu bar icon > Check for Updates..."))
        #expect(!source.contains("retryUpdateCheck()"))
        #expect(!source.contains("Install Update"))
        #expect(!source.contains("Finish Update"))
        #expect(!source.contains("performUpdateAction"))
    }

    @Test("updater focus only targets windows created by the update action")
    func updaterFocusTargetsNewUpdaterWindowsOnly() throws {
        let source = try muesliControllerSource()

        #expect(source.contains("focusUpdaterWindowsCreatedAfterUpdateAction(excluding: existingWindows)"))
        #expect(source.contains("!existingWindows.contains(ObjectIdentifier(window))"))
        #expect(source.contains("isLikelyUpdaterWindow(window)"))
        #expect(!source.contains("window.collectionBehavior ="))
        #expect(!source.contains(".moveToActiveSpace"))
        #expect(!source.contains(".fullScreenAuxiliary"))
        #expect(!source.contains(".canJoinAllSpaces"))
    }

    @Test("Sparkle delegate cannot leave the About UI checking forever")
    func sparkleDelegateRestoresStaleCheckingState() throws {
        let source = try appDelegateSource()
        let body = try methodBody(named: "restoreStaleUpdateCheck", in: source)

        #expect(source.contains("private var updateCycleGeneration = 0"))
        #expect(source.contains("let restoreStatus = recoverableUpdateStatus(appState?.sparkleUpdateStatus ?? .idle)"))
        #expect(source.contains("finishUpdateCheck(with:"))
        #expect(body.contains("30_000_000_000"))
        #expect(body.contains("self.updateCycleGeneration == generation"))
        #expect(body.contains("guard case .checking = self.appState?.sparkleUpdateStatus else { return }"))
        #expect(body.contains("self.finishUpdateCheck(with: restoreStatus)"))
    }

    @Test("Sparkle focus handling activates without manually ordering app windows")
    func sparkleFocusHandlingDoesNotOrderApplicationWindows() throws {
        let source = try appDelegateSource()

        #expect(source.contains("activateSynchronouslyBeforeSparklePresentsUI()"))
        #expect(source.contains("NSApplication.shared.activate()"))
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

    private func methodBody(named name: String, in source: String) throws -> String {
        let pattern = #"(?s)func \#(name)\([^)]*\) \{\s*(.*?)\n    \}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let bodyRange = Range(match.range(at: 1), in: source) else {
            throw TestFailure("Could not find \(name) body")
        }
        return String(source[bodyRange])
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

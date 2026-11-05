import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Permission restart recovery")
struct PermissionRestartRecoveryTests {
    @Test("restart notice is hosted above an open feature setup sheet")
    @MainActor
    func noticeUsesVisibleSetupSheet() {
        _ = NSApplication.shared
        let dashboard = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 500),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        let setup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        dashboard.isReleasedWhenClosed = false
        setup.isReleasedWhenClosed = false
        defer { dashboard.endSheet(setup); setup.orderOut(nil); dashboard.close() }
        #expect(PermissionRestartPresentation.host(in: dashboard) === dashboard)
        dashboard.beginSheet(setup)
        #expect(dashboard.attachedSheet === setup)
        #expect(PermissionRestartPresentation.host(in: dashboard) === setup)
        let unrelated = NSWindow()
        unrelated.preventsApplicationTerminationWhenModal = true
        dashboard.preventsApplicationTerminationWhenModal = true
        setup.preventsApplicationTerminationWhenModal = true
        PermissionRestartPresentation.allowTermination(from: dashboard)
        #expect(!setup.preventsApplicationTerminationWhenModal)
        #expect(!dashboard.preventsApplicationTerminationWhenModal)
        #expect(unrelated.preventsApplicationTerminationWhenModal)
    }

    @Test("only new requests for restart-sensitive permissions queue a notice")
    @MainActor
    func requestsCoalesceWithoutClaimingAccess() {
        let recovery = PermissionRestartRecovery()
        recovery.requested(.microphone, wasGranted: false)
        recovery.requested(.screenRecording, wasGranted: true)
        #expect(recovery.takeNotice().isEmpty)
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.requested(.inputMonitoring, wasGranted: false)
        recovery.requested(.accessibility, wasGranted: false)
        #expect(recovery.takeNotice() == [.accessibility, .inputMonitoring, .screenRecording])
        #expect(recovery.takeNotice().isEmpty)
        // Choosing Later consumes the notice; a new process does not inherit it.
        #expect(PermissionRestartRecovery().takeNotice().isEmpty)
    }

    @Test("restart refuses active work and becomes available when it finishes", arguments: [
        PermissionRestartActivity(recording: true),
        PermissionRestartActivity(processing: true),
        PermissionRestartActivity(assistant: true),
        PermissionRestartActivity(unsentChat: true),
    ])
    func protectsWork(activity: PermissionRestartActivity) {
        #expect(activity.blockingMessage != nil)
        #expect(PermissionRestartActivity().blockingMessage == nil)
    }

    @Test("relauncher waits for old process and passes the bundle path literally", arguments: [false, true])
    func waitsForProcessExit(restorePermissions: Bool) throws {
        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldProcess.arguments = ["30"]
        try oldProcess.run()
        defer { if oldProcess.isRunning { oldProcess.terminate(); oldProcess.waitUntilExit() } }

        let path = "/tmp/muesli '$literal' $(no-command) `no-command`.app"
        var arguments = ApplicationRelaunch.arguments(processID: oldProcess.processIdentifier,
                                                     bundlePath: path, restorePermissions: restorePermissions)
        // Exercise the actual wait/argument script without launching any application.
        arguments[1] = arguments[1].replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/printf '%s\\n'")
        let helper = Process()
        let output = Pipe()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments
        helper.standardOutput = output
        try helper.run()
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        #expect(oldProcess.isRunning)
        #expect(helper.isRunning)
        oldProcess.terminate()
        oldProcess.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        let expected = ["-n", "-a", path] + (restorePermissions ? ["--args", ApplicationRelaunch.permissionsArgument] : [])
        #expect(result.split(separator: "\n").map(String.init) == expected)
    }
}

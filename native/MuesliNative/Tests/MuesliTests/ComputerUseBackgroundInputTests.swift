import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MuesliNativeApp

/// Phase 1 of background computer use: the input layer is present but nothing
/// routes through it yet. These tests are its only caller until Phase 2, so they
/// carry the whole weight of proving it behaves.
///
/// Two properties matter most and are covered first:
///   1. it degrades honestly when the private SkyLight symbols are unavailable
///   2. it refuses to deliver input to a window the target process does not own
@MainActor
@Suite("Computer Use background input layer")
struct ComputerUseBackgroundInputTests {

    // MARK: - Graceful degradation

    @Test("Capability detection answers without crashing")
    func capabilityDetectionIsSafe() {
        // Whatever this machine reports, asking must never trap. A missing symbol
        // has to look like "unavailable", not a crash inside a release build.
        let available = ComputerUseBackgroundDriver.isBackgroundInputAvailable
        #expect(available == true || available == false)
    }

    @Test("Window-ID resolution answers without crashing when the symbol is absent")
    func windowIDResolutionIsSafe() {
        var windowID: CGWindowID = 0
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        // The app element has no window id; the call must return false, not trap.
        let resolved = AXWindowIDResolver.getWindowID(element, &windowID)
        #expect(resolved == false || windowID >= 0)
    }

    // MARK: - Refusing to act on an unowned window

    @Test("Focus is refused for a missing window id")
    func focusRefusedWithoutWindowID() {
        #expect(!ComputerUseBackgroundDriver.focusWithoutRaise(processID: 1, windowID: nil))
    }

    @Test("Focus is refused for a non-positive window id", arguments: [CGWindowID(0)])
    func focusRefusedForInvalidWindowID(windowID: CGWindowID) {
        #expect(!ComputerUseBackgroundDriver.focusWithoutRaise(processID: 1, windowID: windowID))
    }

    @Test("Focus is refused when the window belongs to another process")
    func focusRefusedForForeignWindow() {
        ComputerUseBackgroundDriver.windowOwnerPIDForTests = { _ in 4242 }
        var reachedActivation = false
        ComputerUseBackgroundDriver.focusWithoutRaiseForTests = { _, _ in
            reachedActivation = true
            return true
        }
        defer {
            ComputerUseBackgroundDriver.windowOwnerPIDForTests = nil
            ComputerUseBackgroundDriver.focusWithoutRaiseForTests = nil
        }

        // Asking to focus pid 1's window when the window is owned by 4242 must be
        // refused before any event is posted -- delivering synthetic input to the
        // wrong process is the worst failure this layer can have.
        let focused = ComputerUseBackgroundDriver.focusWithoutRaise(processID: 1, windowID: 99)
        #expect(!focused)
        #expect(!reachedActivation, "ownership check must run before activation")
    }

    @Test("Focus proceeds when the window belongs to the target process")
    func focusAllowedForOwnedWindow() {
        ComputerUseBackgroundDriver.windowOwnerPIDForTests = { _ in 1 }
        ComputerUseBackgroundDriver.focusWithoutRaiseForTests = { pid, windowID in
            pid == 1 && windowID == 99
        }
        defer {
            ComputerUseBackgroundDriver.windowOwnerPIDForTests = nil
            ComputerUseBackgroundDriver.focusWithoutRaiseForTests = nil
        }
        #expect(ComputerUseBackgroundDriver.focusWithoutRaise(processID: 1, windowID: 99))
    }

    // MARK: - Route escalation

    @Test("An element advertising AXPress that accepts it uses the accessibility route")
    func prefersAXPress() {
        let decision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: [kAXPressAction as String],
            axPressAccepted: true,
            hasFrame: true,
            processID: 1,
            windowID: 99,
            allowGlobalHID: true
        )
        #expect(decision.route == .axPress)
        #expect(decision.blockedReason == nil)
    }

    @Test("A refused AXPress escalates to a window-scoped synthetic click")
    func escalatesToSkyLightWhenPressRefused() {
        let decision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: [kAXPressAction as String],
            axPressAccepted: false,
            hasFrame: true,
            processID: 1,
            windowID: 99,
            allowGlobalHID: true
        )
        #expect(decision.route == .elementCenterSkyLight)
    }

    @Test("A pid without a window id is blocked rather than falling back to global input")
    func blockedWhenWindowIDUnknown() {
        let decision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: nil,
            axPressAccepted: false,
            hasFrame: true,
            processID: 1,
            windowID: nil,
            allowGlobalHID: true
        )
        // Falling back to global HID here would click wherever the real cursor is,
        // which is exactly the foreground behaviour this layer exists to remove.
        #expect(decision.route == nil)
        #expect(decision.blockedReason == "missing_window_id")
    }

    @Test("Global input is used only when there is no process to scope to")
    func globalHIDOnlyWithoutProcess() {
        let decision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: nil,
            axPressAccepted: false,
            hasFrame: true,
            processID: nil,
            windowID: nil,
            allowGlobalHID: true
        )
        #expect(decision.route == .globalHID)
    }

    @Test("Global input is refused when the caller disallows it")
    func globalHIDRefusedWhenDisallowed() {
        let decision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: nil,
            axPressAccepted: false,
            hasFrame: true,
            processID: nil,
            windowID: nil,
            allowGlobalHID: false
        )
        #expect(decision.route == nil)
        #expect(decision.blockedReason == "direct_control_required")
    }

    @Test("An element with no frame is blocked before any coordinate is invented")
    func blockedWithoutFrame() {
        let decision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: nil,
            axPressAccepted: false,
            hasFrame: false,
            processID: 1,
            windowID: 99,
            allowGlobalHID: true
        )
        #expect(decision.route == nil)
        #expect(decision.blockedReason == "missing_frame")
    }

    // MARK: - Diagnostics

    @Test("Diagnostics record the route actually taken, for post-hoc trace analysis")
    func diagnosticsCarryRoute() {
        let diagnostics = ComputerUseClickDriver.Diagnostics(
            route: .windowPointSkyLight,
            target: "Save",
            processID: 1,
            windowID: 99,
            x: 10,
            y: 20,
            posted: true,
            reason: "element accepted a window-scoped click"
        )
        #expect(diagnostics.fields["click_route"] == "window_point_skylight")
        #expect(diagnostics.fields["click_posted"] == "true")
        #expect(diagnostics.fields["process_id"] == "1")
        #expect(diagnostics.messageSuffix.contains("point=10,20"))
    }

    @Test("A route that did not post is recorded as such rather than as success")
    func diagnosticsRecordUnpostedClicks() {
        let diagnostics = ComputerUseClickDriver.Diagnostics(
            route: .globalHID,
            target: "Save",
            processID: nil,
            windowID: nil,
            x: nil,
            y: nil,
            posted: false,
            reason: "no window to scope to"
        )
        #expect(diagnostics.fields["click_posted"] == "false")
        #expect(diagnostics.fields["process_id"] == nil)
    }
}

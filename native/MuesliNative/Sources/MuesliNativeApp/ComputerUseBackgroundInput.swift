import AppKit
import ApplicationServices
import Darwin

/// Scoped pointer routing recovered from the earlier Swift driver. Deliberately
/// excludes PSN focus handshakes and CGEvent private-object memory inspection.
@MainActor
enum ComputerUseBackgroundInput {
    private typealias SetField = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias SetLocation = @convention(c) (CGEvent, Double, Double) -> Void
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setField: SetField? = symbol("SLEventSetIntegerValueField", as: SetField.self)
    private static let setLocation: SetLocation? = symbol("CGEventSetWindowLocation", as: SetLocation.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let value = dlsym(handle, name) else { return nil }
        return unsafeBitCast(value, to: type)
    }

    /// Once down is posted, cleanup must run even when posting triggers cancellation.
    static func postPair(_ down: CGEvent, _ up: CGEvent, pid: pid_t,
                         post: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) -> Bool {
        guard !Task.isCancelled else { return false }
        post(down, pid)
        post(up, pid)
        return true
    }

    static func localPoint(_ point: CGPoint, frame: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, frame.contains(point) else { return nil }
        return CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    private static func stamp(_ event: CGEvent, point: CGPoint, target: ComputerUseBackgroundTarget) -> Bool {
        guard ComputerUseWindowIdentity.isOnScreen(target),
              let frame = ComputerUseWindowIdentity.frame(target),
              let local = localPoint(point, frame: frame), let setField, let setLocation else { return false }
        event.location = point
        event.flags = []
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
        setLocation(event, local.x, local.y)
        for field: UInt32 in [51, 91, 92] { setField(event, field, Int64(target.windowID)) }
        setField(event, 40, Int64(target.processID))
        return true
    }

    static func click(point: CGPoint, target: ComputerUseBackgroundTarget, right: Bool, count: Int) -> ComputerUseExecutionResult {
        guard let source = CGEventSource(stateID: .privateState) else { return .unsupported("Private input source unavailable") }
        for ordinal in 1...max(1, min(count, 2)) {
            guard !Task.isCancelled else { return .cancelled() }
            guard ComputerUseWindowIdentity.resolve(target) != nil,
                  let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: right ? .right : .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: right ? .right : .left),
                  stamp(down, point: point, target: target), stamp(up, point: point, target: target) else {
                return .unsupported("Exact-window pointer routing unavailable; no global fallback was used")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(ordinal))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(ordinal))
            // No suspension or cancellation check between down/up: always balance
            // an event that has already been delivered, using the same route.
            _ = postPair(down, up, pid: target.processID)
        }
        return .executed("Dispatched window-scoped click; verify effect in the next target snapshot")
    }

    static func scroll(point: CGPoint, target: ComputerUseBackgroundTarget, direction: ComputerUseScrollDirection, pages: Double) -> ComputerUseExecutionResult {
        guard !Task.isCancelled else { return .cancelled() }
        let delta = ComputerUseToolExecutor.scrollDeltas(direction: direction, pages: min(max(pages, 0.1), 3))
        guard ComputerUseWindowIdentity.resolve(target) != nil,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: delta.vertical, wheel2: delta.horizontal, wheel3: 0),
              stamp(event, point: point, target: target) else {
            return .unsupported("Exact-window scroll routing unavailable")
        }
        event.postToPid(target.processID)
        return .executed("Dispatched window-scoped scroll; verify effect in the next target snapshot")
    }

    /// PID keyboard delivery does not itself prove a window target. Refuse when
    /// the app's key window cannot be matched, or the user is working in that app.
    static func key(_ call: ComputerUseToolCall, target: ComputerUseBackgroundTarget) -> ComputerUseExecutionResult {
        guard !Task.isCancelled else { return .cancelled() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processID,
              ComputerUseWindowIdentity.resolve(target) != nil,
              let focusedWindow = ComputerUseWindowIdentity.attribute(AXUIElementCreateApplication(target.processID), kAXFocusedWindowAttribute),
              ComputerUseWindowIdentity.windowID(of: focusedWindow) == target.windowID else {
            return .unsupported("Keyboard delivery cannot be scoped to the acquired background window; use an exact AX element")
        }
        // Chromium authenticates synthetic key events through private event-record
        // internals. Do not recreate the old guessed-pointer authentication path.
        guard !["com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser"].contains(target.bundleID) else {
            return .unsupported("Authenticated background keys are unavailable for this browser; use AX text/actions or scoped navigation")
        }
        guard let code = ComputerUseExecutor.keyCode(for: call.key ?? ""),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return .unsupported("Background key unavailable")
        }
        // Shortcut modifiers can change application-wide state; this increment
        // supports plain keys only. AX actions avoid Cmd+V/clipboard interference.
        guard call.modifiers?.isEmpty != false else { return .unsupported("Modified background keys are not supported") }
        down.flags = []; up.flags = []
        _ = postPair(down, up, pid: target.processID)
        return .executed("Dispatched PID key after exact key-window check; verify target effect")
    }
}

/// A short targeted restoration guard, not a blanket activation suppressor.
/// Physical input since action start invalidates restoration to the old app.
@MainActor
final class ComputerUseBackgroundFocusGuard {
    private var observer: NSObjectProtocol?
    private(set) var focusChanged = false
    private var restorationInvalidated = false
    private var priorPID: pid_t?
    private var priorKeyWindow: CGWindowID?
    private var actionStarted: TimeInterval = 0
    private(set) var diagnostics: [String] = []

    private var userActed: Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - actionStarted
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged, .mouseMoved].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) <= elapsed
        }
    }

    static func isUnexpectedWindowChange(prior: CGWindowID?, current: CGWindowID?, targetWasFrontmost: Bool, userActed: Bool) -> Bool {
        targetWasFrontmost && !userActed && prior != nil && current != nil && prior != current
    }

    static func shouldRestore(activatedBundle: String?, targetBundle: String, priorPID: pid_t?, activatedPID: pid_t,
                              userActed: Bool) -> Bool {
        activatedBundle == targetBundle && priorPID != nil && priorPID != activatedPID && !userActed
    }

    func begin(bundleID: String) {
        end()
        focusChanged = false
        diagnostics = []
        restorationInvalidated = false
        let prior = NSWorkspace.shared.frontmostApplication
        priorPID = prior?.processIdentifier
        priorKeyWindow = (prior?.bundleIdentifier == bundleID ? prior : nil).flatMap {
            ComputerUseWindowIdentity.attribute(AXUIElementCreateApplication($0.processIdentifier), kAXFocusedWindowAttribute)
        }.flatMap { ComputerUseWindowIdentity.windowID(of: $0) }
        actionStarted = ProcessInfo.processInfo.systemUptime
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      activated.processIdentifier != prior?.processIdentifier else { return }
                guard activated.bundleIdentifier == bundleID else {
                    self.restorationInvalidated = true
                    return
                }
                let userActed = self.userActed || self.restorationInvalidated
                self.diagnostics.append("target activation pid=\(activated.processIdentifier), prior=\(prior?.processIdentifier ?? 0), userActivity=\(userActed)")
                if !userActed { self.focusChanged = true }
                if Self.shouldRestore(activatedBundle: activated.bundleIdentifier, targetBundle: bundleID,
                                      priorPID: prior?.processIdentifier, activatedPID: activated.processIdentifier, userActed: userActed) {
                    // NSRunningApplication can reject activation of our own
                    // accessory app. Use NSApplication for that case; the
                    // subsequent focus check still verifies the actual result.
                    if prior?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        self.diagnostics.append("restoreRequested=selfApplication")
                    } else {
                        let accepted = prior?.activate(options: []) ?? false
                        self.diagnostics.append("restoreRequested=\(accepted)")
                    }
                }
            }
        }
    }

    /// App activation notifications alone miss key-window changes within Chrome.
    func checkWindowFocus() {
        if focusChanged, NSWorkspace.shared.frontmostApplication?.processIdentifier == priorPID {
            diagnostics.append("appFocusRestored=true; transient activation recorded")
            focusChanged = false
        }
        guard let priorPID, let priorKeyWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == priorPID,
              let window = ComputerUseWindowIdentity.attribute(AXUIElementCreateApplication(priorPID), kAXFocusedWindowAttribute),
              let current = ComputerUseWindowIdentity.windowID(of: window) else { return }
        if Self.isUnexpectedWindowChange(prior: priorKeyWindow, current: current, targetWasFrontmost: true,
                                         userActed: userActed || restorationInvalidated) {
            diagnostics.append("target key window changed \(priorKeyWindow)->\(current)")
            focusChanged = true
        }
    }

    func end() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

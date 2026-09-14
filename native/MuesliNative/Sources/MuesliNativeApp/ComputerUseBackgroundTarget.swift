import AppKit
import ApplicationServices
import Darwin

/// Identity survives snapshots, but never permits adoption of a sibling window.
struct ComputerUseBackgroundTarget: Equatable {
    let processID: pid_t
    let windowID: CGWindowID
    let bundleID: String
    let retainedWindow: AXUIElement?

    init(processID: pid_t, windowID: CGWindowID, bundleID: String, retainedWindow: AXUIElement? = nil) {
        self.processID = processID
        self.windowID = windowID
        self.bundleID = bundleID
        self.retainedWindow = retainedWindow
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processID == rhs.processID && lhs.windowID == rhs.windowID && lhs.bundleID == rhs.bundleID
    }

    func accepts(processID: Int?, windowID: Int?, bundleID: String) -> Bool {
        (processID == nil || processID == Int(self.processID)) &&
        (windowID == nil || windowID == Int(self.windowID)) &&
        (bundleID.isEmpty || bundleID == self.bundleID)
    }
}

@MainActor
enum ComputerUseWindowIdentity {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let axHandle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let getWindow: GetWindow? = {
        guard let axHandle, let symbol = dlsym(axHandle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    struct Enablement {
        let requested: Bool
        let status: AXError?
        let enabled: Bool
        var diagnostic: String {
            "AXEnhancedUserInterface requested=\(requested), status=\(status?.rawValue ?? 0), readback=\(enabled)"
        }
    }

    static func ensureEnablement(read: () -> Bool?, write: () -> AXError) -> Enablement {
        if read() == true { return Enablement(requested: false, status: nil, enabled: true) }
        let status = write()
        // Chrome can apply this attribute and return .notImplemented. Readback,
        // then a live window identity, are the evidence; the return code is not.
        return Enablement(requested: true, status: status, enabled: read() == true)
    }

    static func enableChromeAccessibility(pid: pid_t) -> Enablement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return ensureEnablement(read: {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value) == .success else { return nil }
            return value as? Bool
        }, write: {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        })
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        // AXWindows omits off-Space Chrome windows even while these exact
        // handles remain live. They are candidates only, never an implicit target.
        let listed = value as? [AXUIElement] ?? []
        let focused = attribute(app, kAXFocusedWindowAttribute)
        let main = attribute(app, kAXMainWindowAttribute)
        return windowCandidates(listed: listed, focused: focused, main: main).filter { windowID(of: $0) != nil }
    }

    static func windowCandidates<T: Equatable>(listed: [T], focused: T?, main: T?) -> [T] {
        var result = listed
        for candidate in [focused, main].compactMap({ $0 }) where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    static func frame(_ target: ComputerUseBackgroundTarget) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.windowID) as? [[CFString: Any]],
              let info = windows.first,
              (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value == target.processID,
              let bounds = info[kCGWindowBounds] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    static func isOnScreen(_ target: ComputerUseBackgroundTarget) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.windowID) as? [[CFString: Any]],
              let info = windows.first else { return false }
        return (info[kCGWindowIsOnscreen] as? Bool) == true
    }

    static func resolve(_ target: ComputerUseBackgroundTarget) -> AXUIElement? {
        guard frame(target) != nil,
              NSRunningApplication(processIdentifier: target.processID)?.bundleIdentifier == target.bundleID else { return nil }
        if let window = target.retainedWindow,
           windowID(of: window) == target.windowID,
           !ComputerUseObservationCapture.axString(window, kAXRoleAttribute).isEmpty {
            return window
        }
        return windows(pid: target.processID).first { windowID(of: $0) == target.windowID }
    }

    static func contains(_ element: AXUIElement, target: ComputerUseBackgroundTarget) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.processID else { return false }
        let window = attribute(element, kAXWindowAttribute) ?? element
        return windowID(of: window) == target.windowID && frame(target) != nil
    }
}

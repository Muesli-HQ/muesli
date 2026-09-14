import AppKit
import ApplicationServices
import Darwin

/// Identity survives snapshots, but never permits adoption of a sibling window.
struct ComputerUseBackgroundTarget: Equatable {
    let processID: pid_t
    let windowID: CGWindowID
    let bundleID: String

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

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
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
        return windows(pid: target.processID).first { windowID(of: $0) == target.windowID }
    }

    static func contains(_ element: AXUIElement, target: ComputerUseBackgroundTarget) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.processID else { return false }
        let window = attribute(element, kAXWindowAttribute) ?? element
        return windowID(of: window) == target.windowID && frame(target) != nil
    }
}

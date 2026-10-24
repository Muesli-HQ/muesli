import AppKit
import ApplicationServices
import Darwin
import IOKit

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
    static var isScreenLocked: Bool {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    private(set) static var lastWindowDiagnostics = ""
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let axHandle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let getWindow: GetWindow? = {
        guard let axHandle, let symbol = dlsym(axHandle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    struct WindowFact {
        let id: CGWindowID
        let frame: CGRect
        let title: String
    }

    static func corroboratedID(frame: CGRect, title: String, windows: [WindowFact]) -> CGWindowID? {
        guard !title.isEmpty else { return nil }
        let matches = windows.filter {
            !$0.title.isEmpty && $0.title == title &&
            abs($0.frame.minX - frame.minX) <= 2 && abs($0.frame.minY - frame.minY) <= 2 &&
            abs($0.frame.width - frame.width) <= 2 && abs($0.frame.height - frame.height) <= 2
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var id: CGWindowID = 0
        if let getWindow, getWindow(element, &id) == .success, id != 0 { return id }
        // The private getter can decline in a signed app even when the AX window
        // is readable. Restore the earlier driver's corroboration, but reject
        // blank titles and duplicate matches (geometry alone is not identity).
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              ComputerUseObservationCapture.axString(element, kAXRoleAttribute) == kAXWindowRole,
              let frame = ComputerUseObservationCapture.rect(element),
              let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[CFString: Any]] else { return nil }
        let facts = infos.compactMap { info -> WindowFact? in
            guard (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer] as? Int) == 0,
                  let number = info[kCGWindowNumber] as? NSNumber,
                  let bounds = info[kCGWindowBounds] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let title = info[kCGWindowName] as? String else { return nil }
            return WindowFact(id: number.uint32Value, frame: cgFrame, title: title)
        }
        return corroboratedID(frame: frame, title: ComputerUseObservationCapture.axString(element, kAXTitleAttribute), windows: facts)
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
        let listStatus = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        // AXWindows omits off-Space Chrome windows even while these exact
        // handles remain live. They are candidates only, never an implicit target.
        let listed = value as? [AXUIElement] ?? []
        let focused = attribute(app, kAXFocusedWindowAttribute)
        let main = attribute(app, kAXMainWindowAttribute)
        let candidates = windowCandidates(listed: listed, focused: focused, main: main)
        var details: [String] = []
        let resolved = candidates.filter { window in
            var rawID: CGWindowID = 0
            let status = getWindow?(window, &rawID)
            let id = windowID(of: window)
            details.append("native=\(rawID)/\(status?.rawValue ?? -1), resolved=\(id ?? 0), role=\(ComputerUseObservationCapture.axString(window, kAXRoleAttribute))")
            return id != nil
        }
        lastWindowDiagnostics = "AXWindows=\(listStatus.rawValue)/\(listed.count), focused=\(focused != nil), main=\(main != nil), getter=\(getWindow != nil), candidates=[\(details.joined(separator: "; "))]"
        return resolved
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
        // Chromium's AXWindow may be an AXGroup with a compositor ID. Only
        // accept an owning window/sheet, corroborated inside the same process.
        func owner(of root: AXUIElement) -> CGWindowID? {
            owningWindowID(start: root, role: {
                ComputerUseObservationCapture.axString($0, kAXRoleAttribute)
            }, parent: { attribute($0, kAXParentAttribute) }, windowID: { windowID(of: $0) }, belongsToProcess: {
                var ownerPID: pid_t = 0
                return AXUIElementGetPid($0, &ownerPID) == .success && ownerPID == target.processID
            })
        }
        let ownerID = owner(of: element) ?? attribute(element, kAXWindowAttribute).flatMap { owner(of: $0) }
        return ownerID == target.windowID && frame(target) != nil
    }

    /// Bounded and cycle-safe; a sheet belongs to its enclosing window when one
    /// is exposed, otherwise its own window ID is the only available identity.
    static func owningWindowID<Element: Equatable>(start: Element, maxDepth: Int = 32,
        role: (Element) -> String, parent: (Element) -> Element?,
        windowID: (Element) -> CGWindowID?, belongsToProcess: (Element) -> Bool) -> CGWindowID? {
        var current: Element? = start
        var visited: [Element] = []
        var sheetID: CGWindowID?
        for _ in 0..<maxDepth {
            guard let element = current else { return sheetID }
            guard !visited.contains(element), belongsToProcess(element) else { return nil }
            visited.append(element)
            switch role(element) {
            case kAXWindowRole: return windowID(element)
            case kAXSheetRole: sheetID = windowID(element)
            default: break
            }
            current = parent(element)
        }
        return nil
    }
}

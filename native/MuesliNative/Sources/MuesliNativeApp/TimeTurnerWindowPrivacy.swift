import ApplicationServices
import Foundation

/// One allowance for AX work across every app, display and revalidation in a sampling cycle.
/// OCR and screenshot acquisition do not spend the allowance.
struct TimeTurnerAXBudget {
    private(set) var remaining: TimeInterval
    let revalidationReserve: TimeInterval
    private let uptime: () -> TimeInterval

    init(interval: TimeInterval, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        remaining = min(2, max(0, interval / 2))
        revalidationReserve = remaining / 2
        self.uptime = uptime
    }

    @MainActor
    mutating func permits(reserving reserve: TimeInterval = 0, _ inspect: (TimeInterval) async -> Bool) async -> Bool {
        let available = remaining - reserve
        guard available > 0, !Task.isCancelled else { return false }
        let start = uptime()
        let deadline = start + min(available, 1)
        let permitted = await inspect(deadline)
        let end = uptime()
        remaining = max(0, remaining - (end - start))
        return permitted && end < deadline && !Task.isCancelled
    }
}

/// ScreenCaptureKit and AX both expose window bounds in global screen coordinates.
/// Only allow pixels from windows whose accessibility trees could be inspected.
enum TimeTurnerWindowPrivacy {
    static func inspectedIndices(processID: pid_t, frames: [CGRect], deadline: TimeInterval, omitUnmatched: Bool) -> IndexSet? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var windowValues: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 65, &windowValues) == .success,
              let windowValues, CFArrayGetCount(windowValues) <= 64,
              let windows = windowValues as? [AXUIElement] else { return nil }
        let attributes = [kAXSubroleAttribute, kAXChildrenAttribute, kAXRoleAttribute] as CFArray
        return inspectedIndices(frames: frames, windows: windows, omitUnmatched: omitUnmatched, frame: { window in
            AXUIElementSetMessagingTimeout(window, 0.15)
            return DictationContextCapture.windowFrame(window)
        }, inspect: { node in
            AXUIElementSetMessagingTimeout(node, 0.15)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, attributes, [], &values) == .success,
                  let values else { return nil }
            return decodeNode(values as NSArray, withinBudget: { ProcessInfo.processInfo.systemUptime < deadline })
        }, withinBudget: { ProcessInfo.processInfo.systemUptime < deadline })
    }

    // A batched AX read can succeed even when an individual attribute failed.
    static func decodeNode(_ values: NSArray, withinBudget: () -> Bool) -> (subrole: String?, children: [AXUIElement])? {
        guard values.count == 3 else { return nil }
        let subrole = values[0] as? String
        if subrole == nil {
            let error = attributeError(values[0] as AnyObject)
            guard error == .attributeUnsupported || error == .noValue else { return nil }
        }
        if let elements = values[1] as? NSArray {
            var children: [AXUIElement] = []
            for element in elements {
                guard withinBudget(), CFGetTypeID(element as AnyObject) == AXUIElementGetTypeID() else { return nil }
                children.append(element as! AXUIElement)
            }
            return (subrole, children)
        }
        guard let error = attributeError(values[1] as AnyObject),
              allowsMissingChildren(after: error, attribute: kAXChildrenAttribute, role: values[2] as? String ?? "") else { return nil }
        return (subrole, [])
    }

    private static func attributeError(_ value: AnyObject) -> AXError? {
        if CFGetTypeID(value) == CFNullGetTypeID() { return .noValue }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var error = AXError.failure
        guard AXValueGetType(axValue) == .axError, AXValueGetValue(axValue, .axError, &error) else { return nil }
        return error
    }

    // Only non-editable leaf controls can safely omit AXChildren. An opaque
    // window, group, text input or unknown role could conceal a secure field.
    static func allowsMissingChildren(after error: AXError, attribute: String, role: @autoclosure () -> String) -> Bool {
        guard attribute == kAXChildrenAttribute, error == .attributeUnsupported || error == .noValue else { return false }
        switch role() {
        case kAXStaticTextRole, kAXImageRole, kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole:
            return true
        default:
            return false
        }
    }

    static func inspectedIndices<Node: Hashable>(frames: [CGRect], windows: [Node], omitUnmatched: Bool,
                                                 frame: (Node) -> CGRect?, inspect: (Node) -> (subrole: String?, children: [Node])?,
                                                 withinBudget: () -> Bool) -> IndexSet? {
        guard !frames.isEmpty else { return nil }
        var bounds: [CGRect] = []
        for window in windows {
            guard withinBudget(), let rect = frame(window) else { return nil }
            bounds.append(rect)
        }
        var pending: [Node] = []
        var indices = IndexSet()
        for (offset, rect) in frames.enumerated() {
            guard withinBudget() else { return nil }
            let matches = bounds.indices.filter { bounds[$0].equalTo(rect) }
            if matches.isEmpty && omitUnmatched { continue }
            guard matches.count == 1, let index = matches.first else { return nil }
            indices.insert(offset)
            pending.append(windows[index])
        }
        guard !indices.isEmpty, Set(pending).count == indices.count else { return nil }
        // Compositor surfaces can move independently of their AX window. Exclude every
        // unmatched surface by ID. Check all AX roots when the mapping is incomplete so
        // a second private window with differing geometry still blocks this app.
        if indices.count != frames.count { pending = windows }
        var seen = Set(pending)
        while let node = pending.popLast() {
            guard withinBudget(), let info = inspect(node),
                  info.subrole != kAXSecureTextFieldSubrole else { return nil }
            for child in info.children {
                guard withinBudget() else { return nil }
                if seen.insert(child).inserted { pending.append(child) }
            }
        }
        return withinBudget() ? indices : nil
    }
}

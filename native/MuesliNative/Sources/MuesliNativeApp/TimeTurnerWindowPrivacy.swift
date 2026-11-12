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
    static func permits(processID: pid_t, frames: [CGRect], deadline: TimeInterval) -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let windows = elements(app, kAXWindowsAttribute, limit: 64) else { return false }
        return permits(frames: frames, windows: windows, frame: { window in
            AXUIElementSetMessagingTimeout(window, 0.15)
            return DictationContextCapture.windowFrame(window)
        }, inspect: { node, limit in
            AXUIElementSetMessagingTimeout(node, 0.15)
            var subrole: CFTypeRef?
            let nodeSubrole: String?
            switch AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &subrole) {
            case .success:
                guard let value = subrole as? String else { return nil }
                nodeSubrole = value
            case .attributeUnsupported, .noValue: nodeSubrole = nil
            default: return nil
            }
            guard let children = elements(node, kAXChildrenAttribute, limit: limit) else { return nil }
            return (nodeSubrole, children)
        }, withinBudget: { ProcessInfo.processInfo.systemUptime < deadline })
    }

    private static func elements(_ element: AXUIElement, _ attribute: String, limit: Int) -> [AXUIElement]? {
        var array: CFArray?
        let status = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, limit + 1, &array)
        switch status {
        case .success:
            guard let array, CFArrayGetCount(array) <= limit,
                  let children = array as? [AXUIElement] else { return nil }
            return children
        default:
            guard allowsMissingChildren(after: status, attribute: attribute, role: DictationContextCapture.axStringValue(element, attribute: kAXRoleAttribute)) else { return nil }
            return []
        }
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

    static func permits<Node: Hashable>(frames: [CGRect], windows: [Node],
                                        frame: (Node) -> CGRect?, inspect: (Node, Int) -> (subrole: String?, children: [Node])?,
                                        withinBudget: () -> Bool, nodeLimit: Int = 512) -> Bool {
        guard !frames.isEmpty, frames.count <= windows.count else { return false }
        var bounds: [CGRect] = []
        for window in windows {
            guard withinBudget(), let rect = frame(window) else { return false }
            bounds.append(rect)
        }
        var pending: [Node] = []
        for rect in frames {
            let matches = bounds.indices.filter { bounds[$0].equalTo(rect) }
            guard matches.count == 1, let index = matches.first else { return false }
            pending.append(windows[index])
        }
        var seen = Set(pending)
        guard seen.count == frames.count, seen.count <= nodeLimit else { return false }
        while let node = pending.popLast() {
            guard withinBudget(), let info = inspect(node, nodeLimit - seen.count),
                  info.subrole != kAXSecureTextFieldSubrole else { return false }
            for child in info.children where seen.insert(child).inserted {
                guard seen.count <= nodeLimit else { return false }
                pending.append(child)
            }
        }
        return withinBudget()
    }
}

import ApplicationServices
import Foundation

/// ScreenCaptureKit and AX both expose window bounds in global screen coordinates.
/// Only allow pixels from windows whose accessibility trees could be inspected.
enum TimeTurnerWindowPrivacy {
    static func permits(processID: pid_t, frames: [CGRect]) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let windows = elements(app, kAXWindowsAttribute, limit: 64) else { return false }
        return permits(frames: frames, windows: windows, frame: { window in
            AXUIElementSetMessagingTimeout(window, 0.15)
            return DictationContextCapture.windowFrame(window)
        }, inspect: { node, limit in
            AXUIElementSetMessagingTimeout(node, 0.15)
            var subrole: CFTypeRef?
            let role: String?
            switch AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &subrole) {
            case .success:
                guard let value = subrole as? String else { return nil }
                role = value
            case .attributeUnsupported, .noValue: role = nil
            default: return nil
            }
            guard let children = elements(node, kAXChildrenAttribute, limit: limit) else { return nil }
            return (role, children)
        }, withinBudget: { ProcessInfo.processInfo.systemUptime < deadline })
    }

    private static func elements(_ element: AXUIElement, _ attribute: String, limit: Int) -> [AXUIElement]? {
        var array: CFArray?
        switch AXUIElementCopyAttributeValues(element, attribute as CFString, 0, limit + 1, &array) {
        case .success:
            guard let array, CFArrayGetCount(array) <= limit,
                  let children = array as? [AXUIElement] else { return nil }
            return children
        case .attributeUnsupported, .noValue: return []
        default: return nil
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

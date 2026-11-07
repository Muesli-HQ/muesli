import ApplicationServices
import CoreGraphics
import Foundation

/// Inline creates its Grid panel before a call. Only an on-screen panel with
/// the call's Leave room control is evidence of a current session.
enum InlineGridCallObservation: Equatable {
    case active(pid_t)
    case absent
    case unavailable
}

enum InlineGridCallCollector {
    static let bundleID = "chat.inline.InlineMac"

    static func isCallWindow(title: String?, bounds: CGRect?, onScreenBounds: [CGRect], labels: [String]) -> Bool {
        guard title == "Grid Call", let bounds, bounds.width > 0, bounds.height > 0,
              labels.contains("Leave room") else { return false }
        return onScreenBounds.contains { rect in
            abs(rect.minX - bounds.minX) < 2 && abs(rect.minY - bounds.minY) < 2
                && abs(rect.width - bounds.width) < 2 && abs(rect.height - bounds.height) < 2
        }
    }

    static func observe(in apps: [RunningAppSnapshot]) -> InlineGridCallObservation {
        let inlineApps = apps.filter { $0.bundleID == bundleID }
        guard !inlineApps.isEmpty else { return .absent }
        guard AXIsProcessTrusted(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return .unavailable }
        var incomplete = false
        for app in inlineApps {
            var rects: [CGRect] = []
            for window in windows where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier {
                guard let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                      let raw = window[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else {
                    incomplete = true
                    continue
                }
                if alpha.doubleValue > 0.5 { rects.append(rect) }
            }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            guard let axWindows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else {
                incomplete = true
                continue
            }
            for window in axWindows {
                guard let title = attribute(window, kAXTitleAttribute) as? String else {
                    incomplete = true
                    continue
                }
                guard title == "Grid Call" else { continue }
                guard let bounds = bounds(of: window) else { incomplete = true; continue }
                let isOnScreen = isCallWindow(title: title, bounds: bounds, onScreenBounds: rects, labels: ["Leave room"])
                guard isOnScreen else { continue }
                if labels(in: window).contains("Leave room") { return .active(app.processIdentifier) }
                // A folded panel or an incomplete AX tree must not end a call.
                incomplete = true
            }
        }
        return incomplete ? .unavailable : .absent
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func bounds(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func labels(in window: AXUIElement) -> [String] {
        var pending = [window]
        var labels: [String] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(1)
        while let element = pending.popLast(), visited < 100, Date() < deadline {
            visited += 1
            if (attribute(element, kAXRoleAttribute) as? String) == kAXButtonRole {
                if let label = attribute(element, kAXDescriptionAttribute) as? String { labels.append(label) }
                if let label = attribute(element, kAXTitleAttribute) as? String { labels.append(label) }
            }
            if labels.contains("Leave room") { break }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children) }
        }
        return labels
    }
}

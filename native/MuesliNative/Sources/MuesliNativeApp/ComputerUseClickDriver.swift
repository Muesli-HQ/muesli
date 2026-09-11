import AppKit
import ApplicationServices
import Foundation

@MainActor
enum ComputerUseClickDriver {
    enum Route: String, Codable, Equatable {
        case axPress = "ax_press"
        case elementCenterSkyLight = "element_center_skylight"
        case windowPointSkyLight = "window_point_skylight"
        case globalHID = "global_hid"
    }

    enum Button: String, Codable, Equatable {
        case left
        case right
    }

    struct Diagnostics: Codable, Equatable {
        let route: Route
        let target: String
        let processID: Int?
        let windowID: Int?
        let x: Int?
        let y: Int?
        let posted: Bool
        let reason: String

        var fields: [String: String] {
            var values = [
                "click_route": route.rawValue,
                "click_target": target,
                "click_posted": posted ? "true" : "false",
                "click_reason": reason,
            ]
            if let processID {
                values["process_id"] = "\(processID)"
            }
            if let windowID {
                values["window_id"] = "\(windowID)"
            }
            if let x, let y {
                values["click_point"] = "\(x),\(y)"
            }
            return values
        }

        var messageSuffix: String {
            var parts = ["route=\(route.rawValue)"]
            if let processID {
                parts.append("pid=\(processID)")
            }
            if let windowID {
                parts.append("window_id=\(windowID)")
            }
            if let x, let y {
                parts.append("point=\(x),\(y)")
            }
            parts.append("posted=\(posted ? "true" : "false")")
            return parts.joined(separator: " ")
        }

        // The bridge into the executor's transaction/verification model lands with
        // Phase 2, when the executor actually routes through this driver. Until
        // then `fields` carries the same diagnostics without the dependency.
    }

    struct RouteDecision: Equatable {
        let route: Route?
        let blockedReason: String?
    }

    struct PointRequest {
        let point: CGPoint
        let label: String?
        let processID: pid_t?
        let windowID: CGWindowID?
        let button: Button
        let clicks: Int
        let allowGlobalHID: Bool
    }

    static var postBackgroundClickForTests: ((PointRequest) -> Bool)?
    static var postGlobalClickForTests: ((PointRequest) -> Bool)?
    static var performAXPressForTests: ((AXUIElement) -> Bool)?

    static func clickElement(
        _ element: AXUIElement,
        label: String,
        processID: pid_t?,
        windowID: CGWindowID?,
        button: Button = .left,
        clicks: Int = 1,
        allowGlobalHID: Bool
    ) -> ComputerUseExecutionResult {
        if let rect = rect(of: element) {
            ComputerUseCursorOverlay.shared.show(at: center(of: rect), label: label)
        }
        if axBool(element, kAXEnabledAttribute) == false {
            return .failed("\(label) is disabled; click would likely be a no-op")
        }

        let actions = actionNames(of: element)
        let canTryAXPress = actions?.contains(kAXPressAction as String) != false && button == .left && max(1, clicks) == 1
        if canTryAXPress {
            let pressed = performAXPressForTests?(element) ?? (AXUIElementPerformAction(element, kAXPressAction as CFString) == .success)
            if pressed {
                let diagnostics = Diagnostics(
                    route: .axPress,
                    target: label,
                    processID: processID.map(Int.init),
                    windowID: windowID.map(Int.init),
                    x: nil,
                    y: nil,
                    posted: true,
                    reason: "element advertised AXPress and accepted it"
                )
                return .executed(
                    "Clicked \(label) [\(diagnostics.messageSuffix)]"
                )
            }
        }

        let actionList = (actions ?? []).isEmpty ? "none" : (actions ?? []).joined(separator: ", ")
        let fallbackReason = canTryAXPress
            ? "AXPress did not change action state or was rejected"
            : "element does not advertise AXPress (actions: \(actionList))"

        guard let rect = rect(of: element) else {
            return .failed("Could not resolve \(label) frame for element-center click.")
        }

        return clickPoint(PointRequest(
            point: center(of: rect),
            label: label,
            processID: processID,
            windowID: windowID,
            button: button,
            clicks: clicks,
            allowGlobalHID: allowGlobalHID
        ), preferredBackgroundRoute: .elementCenterSkyLight, reason: fallbackReason)
    }

    static func clickPoint(
        _ request: PointRequest,
        preferredBackgroundRoute: Route = .windowPointSkyLight,
        reason: String = "screenshot coordinate target"
    ) -> ComputerUseExecutionResult {
        ComputerUseCursorOverlay.shared.show(at: request.point, label: request.label)
        let label = cleanedLabel(request.label)
        if let processID = request.processID {
            guard processID > 0 else {
                return .needsConfirmation("Background click requires nonzero process_id from the latest target snapshot.")
            }
            guard let windowID = request.windowID, windowID > 0 else {
                return .needsConfirmation("Background click requires nonzero window_id from the latest target snapshot.")
            }
            let posted = postBackgroundClickForTests?(request) ?? ComputerUseBackgroundDriver.click(
                at: request.point,
                processID: processID,
                windowID: windowID,
                button: request.button == .right ? .right : .left,
                clickCount: request.clicks,
                useOffscreenActivationPrimer: shouldUseOffscreenActivationPrimer(
                    processID: processID,
                    label: request.label
                )
            )
            let diagnostics = Diagnostics(
                route: preferredBackgroundRoute,
                target: label,
                processID: Int(processID),
                windowID: Int(windowID),
                x: Int(request.point.x.rounded()),
                y: Int(request.point.y.rounded()),
                posted: posted,
                reason: reason
            )
            guard posted else {
                return .failed(
                    "Background click could not be posted to process \(processID) [\(diagnostics.messageSuffix)]"
                )
            }
            return .executed(
                "Clicked \(label) [\(diagnostics.messageSuffix)]"
            )
        }

        guard request.allowGlobalHID else {
            return .needsConfirmation("Coordinate click requires direct app control, or process_id/window_id for Work quietly mode.")
        }

        let posted = postGlobalClickForTests?(request) ?? postGlobalHIDClick(request)
        let diagnostics = Diagnostics(
            route: .globalHID,
            target: label,
            processID: nil,
            windowID: nil,
            x: Int(request.point.x.rounded()),
            y: Int(request.point.y.rounded()),
            posted: posted,
            reason: "direct pointer click"
        )
        guard posted else {
            return .failed(
                "Global click could not be posted [\(diagnostics.messageSuffix)]"
            )
        }
        return .executed(
            "Clicked \(label) [\(diagnostics.messageSuffix)]"
        )
    }

    static func routeDecisionForTests(
        advertisedActions: [String]?,
        axPressAccepted: Bool,
        hasFrame: Bool,
        processID: pid_t?,
        windowID: CGWindowID?,
        allowGlobalHID: Bool
    ) -> RouteDecision {
        if advertisedActions?.contains(kAXPressAction as String) != false, axPressAccepted {
            return RouteDecision(route: .axPress, blockedReason: nil)
        }
        guard hasFrame else {
            return RouteDecision(route: nil, blockedReason: "missing_frame")
        }
        if let processID, processID > 0 {
            guard let windowID, windowID > 0 else {
                return RouteDecision(route: nil, blockedReason: "missing_window_id")
            }
            return RouteDecision(route: .elementCenterSkyLight, blockedReason: nil)
        }
        if allowGlobalHID {
            return RouteDecision(route: .globalHID, blockedReason: nil)
        }
        return RouteDecision(route: nil, blockedReason: "direct_control_required")
    }

    private static func postGlobalHIDClick(_ request: PointRequest) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        CGWarpMouseCursorPosition(request.point)
        let mouseButton: CGMouseButton = request.button == .right ? .right : .left
        let downType: CGEventType = request.button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = request.button == .right ? .rightMouseUp : .leftMouseUp
        let clickCount = max(1, min(request.clicks, 2))
        for clickIndex in 1...clickCount {
            guard let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: request.point,
                mouseButton: mouseButton
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: upType,
                mouseCursorPosition: request.point,
                mouseButton: mouseButton
            ) else {
                return false
            }
            mouseDown.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            mouseUp.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func cleanedLabel(_ label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "point" : trimmed
    }

    private static func shouldUseOffscreenActivationPrimer(processID: pid_t, label: String?) -> Bool {
        guard let bundleID = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
              bundleID == "com.google.Chrome"
        else { return false }
        let normalizedLabel = ComputerUseElementCandidate.normalizedText(label ?? "")
        return normalizedLabel.contains("youtube")
            || normalizedLabel.contains("video")
            || normalizedLabel.contains("media")
            || normalizedLabel.contains("play")
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return value as? Bool
    }

    private static func actionNames(of element: AXUIElement) -> [String]? {
        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(element, &rawActions) == .success else { return nil }
        return (rawActions as? [String]) ?? []
    }

    private static func rect(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}

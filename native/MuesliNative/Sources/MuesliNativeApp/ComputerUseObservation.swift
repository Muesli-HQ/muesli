import AppKit
import ApplicationServices
import Foundation

struct ComputerUseRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }
}

struct ComputerUseElementCandidate: Codable, Equatable {
    let elementID: String
    let role: String
    let title: String
    let label: String
    let value: String
    let help: String
    let enabled: Bool
    let frame: ComputerUseRect?
    let path: String

    enum CodingKeys: String, CodingKey {
        case elementID = "element_id"
        case role
        case title
        case label
        case value
        case help
        case enabled
        case frame
        case path
    }

    var normalizedText: String {
        Self.normalizedText([title, label, value, help].joined(separator: " "))
    }

    static func normalizedText(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ComputerUseObservation: Codable, Equatable {
    let appName: String
    let bundleID: String
    let windowTitle: String
    let windowFrame: ComputerUseRect?
    let elements: [ComputerUseElementCandidate]
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case windowFrame = "window_frame"
        case elements
        case capturedAt = "captured_at"
    }
}

@MainActor
final class ComputerUseElementRegistry {
    private var elements: [String: AXUIElement] = [:]

    func clear() {
        elements.removeAll()
    }

    func register(_ element: AXUIElement, id: String) {
        elements[id] = element
    }

    func element(for id: String) -> AXUIElement? {
        elements[id]
    }

    var registeredIDsForTests: Set<String> {
        Set(elements.keys)
    }
}

@MainActor
enum ComputerUseObservationCapture {
    static func capture(
        registry: ComputerUseElementRegistry,
        maxCandidates: Int = 80,
        maxDepth: Int = 8
    ) -> ComputerUseObservation {
        registry.clear()
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""
        let capturedAt = Date()

        guard AXIsProcessTrusted(), let app else {
            return ComputerUseObservation(
                appName: appName,
                bundleID: bundleID,
                windowTitle: "",
                windowFrame: nil,
                elements: [],
                capturedAt: capturedAt
            )
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = focusedWindow(in: axApp)
        let root = window ?? axApp
        let windowTitle = window.map { axString($0, kAXTitleAttribute) } ?? ""
        let windowFrame = window.flatMap(rect)

        var candidates: [ComputerUseElementCandidate] = []
        var visited = Set<AXUIElement>()
        walk(
            root,
            registry: registry,
            candidates: &candidates,
            visited: &visited,
            path: "0",
            depth: 0,
            maxDepth: maxDepth,
            maxCandidates: maxCandidates
        )

        return ComputerUseObservation(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            windowFrame: windowFrame.map(ComputerUseRect.init),
            elements: candidates,
            capturedAt: capturedAt
        )
    }

    nonisolated static func candidateForTests(
        elementID: String,
        role: String,
        title: String,
        label: String = "",
        value: String = "",
        help: String = "",
        enabled: Bool = true,
        frame: ComputerUseRect? = nil,
        path: String = "0"
    ) -> ComputerUseElementCandidate {
        ComputerUseElementCandidate(
            elementID: elementID,
            role: role,
            title: title,
            label: label,
            value: value,
            help: help,
            enabled: enabled,
            frame: frame,
            path: path
        )
    }

    private static func walk(
        _ element: AXUIElement,
        registry: ComputerUseElementRegistry,
        candidates: inout [ComputerUseElementCandidate],
        visited: inout Set<AXUIElement>,
        path: String,
        depth: Int,
        maxDepth: Int,
        maxCandidates: Int
    ) {
        guard depth <= maxDepth, candidates.count < maxCandidates, !visited.contains(element) else { return }
        visited.insert(element)

        if let candidate = candidate(from: element, id: "e\(candidates.count + 1)", path: path) {
            registry.register(element, id: candidate.elementID)
            candidates.append(candidate)
        }

        let children = childElements(of: element)
        for (index, child) in children.enumerated() where candidates.count < maxCandidates {
            walk(
                child,
                registry: registry,
                candidates: &candidates,
                visited: &visited,
                path: "\(path).\(index)",
                depth: depth + 1,
                maxDepth: maxDepth,
                maxCandidates: maxCandidates
            )
        }
    }

    private static func candidate(from element: AXUIElement, id: String, path: String) -> ComputerUseElementCandidate? {
        let role = axString(element, kAXRoleAttribute)
        let title = axString(element, kAXTitleAttribute)
        let label = axString(element, kAXDescriptionAttribute)
        let value = axString(element, kAXValueAttribute)
        let help = axString(element, kAXHelpAttribute)
        let enabled = axBool(element, kAXEnabledAttribute) ?? true
        let frame = rect(element).map(ComputerUseRect.init)

        let text = ComputerUseElementCandidate.normalizedText([title, label, value, help].joined(separator: " "))
        guard !role.isEmpty || !text.isEmpty else { return nil }

        return ComputerUseElementCandidate(
            elementID: id,
            role: role,
            title: truncate(title, limit: 80),
            label: truncate(label, limit: 80),
            value: truncate(value, limit: 120),
            help: truncate(help, limit: 80),
            enabled: enabled,
            frame: frame,
            path: path
        )
    }

    private static func focusedWindow(in axApp: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let element = value,
              CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let rawChildren = value as? [AXUIElement]
        else { return [] }
        return rawChildren
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func rect(_ element: AXUIElement) -> CGRect? {
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

    private static func truncate(_ value: String, limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit - 1)) + "..." : value
    }
}

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
    let elementIndex: Int
    let role: String
    let title: String
    let label: String
    let value: String
    let help: String
    let enabled: Bool
    let frame: ComputerUseRect?
    let path: String
    let actionNames: [String]
    let processID: Int?

    enum CodingKeys: String, CodingKey {
        case elementID = "element_id"
        case elementIndex = "element_index"
        case role
        case title
        case label
        case value
        case help
        case enabled
        case frame
        case path
        case actionNames = "action_names"
        case processID = "process_id"
    }

    init(
        elementID: String,
        elementIndex: Int,
        role: String,
        title: String,
        label: String,
        value: String,
        help: String,
        enabled: Bool,
        frame: ComputerUseRect?,
        path: String,
        actionNames: [String] = [],
        processID: Int? = nil
    ) {
        self.elementID = elementID
        self.elementIndex = elementIndex
        self.role = role
        self.title = title
        self.label = label
        self.value = value
        self.help = help
        self.enabled = enabled
        self.frame = frame
        self.path = path
        self.actionNames = actionNames
        self.processID = processID
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

struct ComputerUseFocusedElement: Codable, Equatable {
    let role: String
    let title: String
    let label: String
    let value: String
    let frame: ComputerUseRect?
    let processID: Int?

    enum CodingKeys: String, CodingKey {
        case role
        case title
        case label
        case value
        case frame
        case processID = "process_id"
    }

    var normalizedText: String {
        ComputerUseElementCandidate.normalizedText([title, label, value].joined(separator: " "))
    }
}

struct ComputerUseScreenshotObservation: Equatable {
    let screenshotID: String
    let width: Int
    let height: Int
    let windowFrame: ComputerUseRect
    let scaleX: Double
    let scaleY: Double
    let imageDataURL: String?

    enum CodingKeys: String, CodingKey {
        case screenshotID = "screenshot_id"
        case width
        case height
        case windowFrame = "window_frame"
        case scaleX = "scale_x"
        case scaleY = "scale_y"
    }
}

extension ComputerUseScreenshotObservation: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            screenshotID: try container.decode(String.self, forKey: .screenshotID),
            width: try container.decode(Int.self, forKey: .width),
            height: try container.decode(Int.self, forKey: .height),
            windowFrame: try container.decode(ComputerUseRect.self, forKey: .windowFrame),
            scaleX: try container.decode(Double.self, forKey: .scaleX),
            scaleY: try container.decode(Double.self, forKey: .scaleY),
            imageDataURL: nil
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screenshotID, forKey: .screenshotID)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(windowFrame, forKey: .windowFrame)
        try container.encode(scaleX, forKey: .scaleX)
        try container.encode(scaleY, forKey: .scaleY)
    }
}

struct ComputerUseObservation: Codable, Equatable {
    let stateID: String
    let appName: String
    let bundleID: String
    let windowTitle: String
    let windowFrame: ComputerUseRect?
    let screenshot: ComputerUseScreenshotObservation?
    let cursorPosition: ComputerUseRect?
    let focusedElement: ComputerUseFocusedElement?
    let selectedText: String?
    let appInstructions: String?
    let elements: [ComputerUseElementCandidate]
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case stateID = "state_id"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case windowFrame = "window_frame"
        case screenshot
        case cursorPosition = "cursor_position"
        case focusedElement = "focused_element"
        case selectedText = "selected_text"
        case appInstructions = "app_instructions"
        case elements
        case capturedAt = "captured_at"
    }

    init(
        stateID: String = Self.newStateID(),
        appName: String,
        bundleID: String,
        windowTitle: String,
        windowFrame: ComputerUseRect?,
        screenshot: ComputerUseScreenshotObservation?,
        cursorPosition: ComputerUseRect?,
        focusedElement: ComputerUseFocusedElement? = nil,
        selectedText: String? = nil,
        appInstructions: String? = nil,
        elements: [ComputerUseElementCandidate],
        capturedAt: Date
    ) {
        self.stateID = stateID
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.screenshot = screenshot
        self.cursorPosition = cursorPosition
        self.focusedElement = focusedElement
        self.selectedText = selectedText
        self.appInstructions = appInstructions
        self.elements = elements
        self.capturedAt = capturedAt
    }

    static func newStateID() -> String {
        "state-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
    }
}

struct ComputerUseObservationTarget: Codable, Equatable {
    let appName: String?
    let bundleID: String?

    var displayName: String {
        if let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appName
        }
        return bundleID ?? ""
    }
}

@MainActor
final class ComputerUseElementRegistry {
    struct Fingerprint: Equatable {
        let role: String
        let path: String
        let normalizedText: String
        let frame: ComputerUseRect?
        let processID: Int?
    }

    var backgroundTarget: ComputerUseBackgroundTarget?
    private var elements: [String: AXUIElement] = [:]
    private var indexedElements: [Int: AXUIElement] = [:]
    private var elementFingerprintsByID: [String: Fingerprint] = [:]
    private var elementFingerprintsByIndex: [Int: Fingerprint] = [:]
    private var screenshot: ComputerUseScreenshotObservation?

    func clear() {
        backgroundTarget = nil
        elements.removeAll()
        indexedElements.removeAll()
        elementFingerprintsByID.removeAll()
        elementFingerprintsByIndex.removeAll()
        screenshot = nil
    }

    func register(_ element: AXUIElement, candidate: ComputerUseElementCandidate) {
        let id = candidate.elementID
        let index = candidate.elementIndex
        elements[id] = element
        indexedElements[index] = element
        let fingerprint = Fingerprint(candidate)
        elementFingerprintsByID[id] = fingerprint
        elementFingerprintsByIndex[index] = fingerprint
    }

    func element(for id: String) -> AXUIElement? {
        resolve(elements[id], fingerprint: elementFingerprintsByID[id])
    }

    func element(for index: Int) -> AXUIElement? {
        resolve(indexedElements[index], fingerprint: elementFingerprintsByIndex[index])
    }

    func registerScreenshot(_ screenshot: ComputerUseScreenshotObservation?) {
        self.screenshot = screenshot
    }

    func currentScreenshot() -> ComputerUseScreenshotObservation? {
        screenshot
    }

    var registeredIDsForTests: Set<String> {
        Set(elements.keys)
    }

    private func resolve(_ element: AXUIElement?, fingerprint: Fingerprint?) -> AXUIElement? {
        guard let element else { return nil }
        if let backgroundTarget, !ComputerUseWindowIdentity.contains(element, target: backgroundTarget) { return nil }
        guard let fingerprint else { return element }
        if Self.isValid(element) {
            return element
        }
        let matches = elements.values.filter { candidate in
            Self.isValid(candidate) && Self.fingerprint(for: candidate) == fingerprint
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func isValid(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    private static func fingerprint(for element: AXUIElement) -> Fingerprint {
        let role = ComputerUseObservationCapture.axString(element, kAXRoleAttribute)
        let title = ComputerUseObservationCapture.axString(element, kAXTitleAttribute)
        let label = ComputerUseObservationCapture.axString(element, kAXDescriptionAttribute)
        let value = ComputerUseObservationCapture.axString(element, kAXValueAttribute)
        let help = ComputerUseObservationCapture.axString(element, kAXHelpAttribute)
        let text = ComputerUseElementCandidate.normalizedText([title, label, value, help].joined(separator: " "))
        return Fingerprint(
            role: role,
            path: "",
            normalizedText: text,
            frame: ComputerUseObservationCapture.rect(element).map(ComputerUseRect.init),
            processID: ComputerUseObservationCapture.processID(of: element).map(Int.init)
        )
    }
}

extension ComputerUseElementRegistry.Fingerprint {
    init(_ candidate: ComputerUseElementCandidate) {
        role = candidate.role
        path = ""
        normalizedText = candidate.normalizedText
        frame = candidate.frame
        processID = candidate.processID
    }
}

@MainActor
enum ComputerUseObservationCapture {
    static func capture(
        registry: ComputerUseElementRegistry,
        includeScreenshot: Bool = false,
        target: ComputerUseObservationTarget? = nil,
        maxCandidates: Int = 80,
        maxDepth: Int = 8
    ) -> ComputerUseObservation {
        registry.clear()
        let app = runningApplication(for: target) ?? NSWorkspace.shared.frontmostApplication
        if target != nil, let app, !app.isActive {
            app.activate(options: [.activateAllWindows])
        }
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""
        let capturedAt = Date()

        guard AXIsProcessTrusted(), let app else {
            return ComputerUseObservation(
                appName: appName,
                bundleID: bundleID,
                windowTitle: "",
                windowFrame: nil,
                screenshot: nil,
                cursorPosition: cursorPositionObservation(),
                focusedElement: nil,
                selectedText: nil,
                appInstructions: ComputerUseAppInstructionProvider.instructions(for: bundleID, appName: appName),
                elements: [],
                capturedAt: capturedAt
            )
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = focusedWindow(in: axApp)
        let root = window ?? axApp
        let windowTitle = window.map { axString($0, kAXTitleAttribute) } ?? ""
        let windowFrame = window.flatMap(rect)
        let screenshot = includeScreenshot ? captureScreenshot(for: app, fallbackFrame: windowFrame) : nil
        registry.registerScreenshot(screenshot)
        let focusedElementSnapshot = focusedElementSnapshot(requiredPID: app.processIdentifier)
        let focusedElement = focusedElementSnapshot?.observation
        let selectedText = selectedTextObservation(from: focusedElementSnapshot?.element)
        let appInstructions = ComputerUseAppInstructionProvider.instructions(for: bundleID, appName: appName)

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
            screenshot: screenshot,
            cursorPosition: cursorPositionObservation(),
            focusedElement: focusedElement,
            selectedText: selectedText,
            appInstructions: appInstructions,
            elements: candidates,
            capturedAt: capturedAt
        )
    }

    /// No app activation, focused-window substitution, or whole-display capture.
    static func captureBackground(
        registry: ComputerUseElementRegistry,
        includeScreenshot: Bool,
        target: ComputerUseBackgroundTarget?
    ) -> ComputerUseObservation {
        registry.clear()
        let instructions = ComputerUseBackgroundSession.plannerInstructions
        guard AXIsProcessTrusted(), let target, let window = ComputerUseWindowIdentity.resolve(target) else {
            return ComputerUseObservation(
                appName: target?.bundleID ?? "No background window acquired", bundleID: target?.bundleID ?? "",
                windowTitle: "", windowFrame: nil, screenshot: nil, cursorPosition: nil,
                appInstructions: instructions + " No live acquired window. Use launch_app or get_app_state to acquire one.",
                elements: [], capturedAt: Date()
            )
        }
        registry.backgroundTarget = target
        let frame = rect(window)
        var screenshot: ComputerUseScreenshotObservation?
        if includeScreenshot, let frame,
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, target.windowID, [.bestResolution, .boundsIgnoreFraming]) {
            screenshot = screenshotObservation(image: image, frame: frame)
        }
        registry.registerScreenshot(screenshot)
        var candidates: [ComputerUseElementCandidate] = []
        var visited = Set<AXUIElement>()
        walk(window, registry: registry, candidates: &candidates, visited: &visited,
             path: "0", depth: 0, maxDepth: 12, maxCandidates: 160,
             deadline: ProcessInfo.processInfo.systemUptime + 1.0)
        return ComputerUseObservation(
            appName: NSRunningApplication(processIdentifier: target.processID)?.localizedName ?? target.bundleID,
            bundleID: target.bundleID, windowTitle: axString(window, kAXTitleAttribute),
            windowFrame: frame.map(ComputerUseRect.init), screenshot: screenshot, cursorPosition: nil,
            appInstructions: instructions + " Acquired process_id=\(target.processID), window_id=\(target.windowID).",
            elements: candidates, capturedAt: Date()
        )
    }

    nonisolated static func candidateForTests(
        elementID: String,
        elementIndex: Int? = nil,
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
            elementIndex: elementIndex ?? Self.elementIndex(from: elementID),
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
        maxCandidates: Int,
        deadline: TimeInterval? = nil
    ) {
        if let deadline {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            AXUIElementSetMessagingTimeout(element, 0.05)
        }
        guard depth <= maxDepth, candidates.count < maxCandidates, !visited.contains(element) else { return }
        visited.insert(element)

        let nextIndex = candidates.count + 1
        if let candidate = candidate(from: element, id: "e\(nextIndex)", index: nextIndex, path: path) {
            registry.register(element, candidate: candidate)
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
                maxCandidates: maxCandidates,
                deadline: deadline
            )
        }
    }

    private static func candidate(from element: AXUIElement, id: String, index: Int, path: String) -> ComputerUseElementCandidate? {
        let role = axString(element, kAXRoleAttribute)
        let title = axString(element, kAXTitleAttribute)
        let label = axString(element, kAXDescriptionAttribute)
        let value = axString(element, kAXValueAttribute)
        let help = axString(element, kAXHelpAttribute)
        let enabled = axBool(element, kAXEnabledAttribute) ?? true
        let frame = rect(element).map(ComputerUseRect.init)
        let actions = actionNames(of: element)
        let pid = processID(of: element).map(Int.init)

        let text = ComputerUseElementCandidate.normalizedText([title, label, value, help].joined(separator: " "))
        guard !role.isEmpty || !text.isEmpty else { return nil }

        return ComputerUseElementCandidate(
            elementID: id,
            elementIndex: index,
            role: role,
            title: truncate(title, limit: 80),
            label: truncate(label, limit: 80),
            value: truncate(value, limit: 120),
            help: truncate(help, limit: 80),
            enabled: enabled,
            frame: frame,
            path: path,
            actionNames: actions,
            processID: pid
        )
    }

    nonisolated private static func elementIndex(from elementID: String) -> Int {
        let digits = elementID.drop { !$0.isNumber }
        return Int(digits) ?? 0
    }

    private static func focusedWindow(in axApp: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let element = value,
              CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    private static func runningApplication(for target: ComputerUseObservationTarget?) -> NSRunningApplication? {
        guard let target else { return nil }
        if let bundleID = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
            return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        }
        guard let appName = target.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty else {
            return nil
        }
        let canonical = canonicalAppName(appName)
        if let bundleID = ComputerUseExecutor.bundleIdentifierAlias(for: appName),
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { app in
            guard let name = app.localizedName else { return false }
            return canonicalAppName(name) == canonical
        }
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let rawChildren = value as? [AXUIElement]
        else { return [] }
        return rawChildren
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String {
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

    static func rect(_ element: AXUIElement) -> CGRect? {
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

    static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(element, &rawActions) == .success else { return [] }
        return (rawActions as? [String]) ?? []
    }

    private struct FocusedElementSnapshot {
        let element: AXUIElement
        let observation: ComputerUseFocusedElement
    }

    private static func focusedElementSnapshot(requiredPID: pid_t) -> FocusedElementSnapshot? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let rawElement = value,
              CFGetTypeID(rawElement) == AXUIElementGetTypeID()
        else { return nil }

        let element = rawElement as! AXUIElement
        guard processID(of: element) == requiredPID else { return nil }
        let observation = ComputerUseFocusedElement(
            role: axString(element, kAXRoleAttribute),
            title: truncate(axString(element, kAXTitleAttribute), limit: 80),
            label: truncate(axString(element, kAXDescriptionAttribute), limit: 80),
            value: truncate(axString(element, kAXValueAttribute), limit: 160),
            frame: rect(element).map(ComputerUseRect.init),
            processID: processID(of: element).map(Int.init)
        )
        return FocusedElementSnapshot(element: element, observation: observation)
    }

    private static func selectedTextObservation(from focusedElement: AXUIElement?) -> String? {
        guard let focusedElement else { return nil }
        let selected = axString(focusedElement, kAXSelectedTextAttribute)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : truncate(selected, limit: 240)
    }

    private static func cursorPositionObservation() -> ComputerUseRect {
        let point = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        return ComputerUseRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private static func captureScreenshot(
        for app: NSRunningApplication,
        fallbackFrame: CGRect?
    ) -> ComputerUseScreenshotObservation? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let appWindows = windowList.filter { dict in
            guard let ownerPID = dict[kCGWindowOwnerPID] as? Int32, ownerPID == app.processIdentifier else { return false }
            guard let layer = dict[kCGWindowLayer] as? Int, layer == 0 else { return false }
            guard let bounds = cgWindowBounds(dict), bounds.width > 0, bounds.height > 0 else { return false }
            return true
        }
        let appWindow = preferredScreenshotWindow(from: appWindows, fallbackFrame: fallbackFrame)

        if let appWindow,
           let windowID = appWindow[kCGWindowNumber] as? CGWindowID,
           let frame = cgWindowBounds(appWindow) ?? fallbackFrame,
           frame.width > 0,
           frame.height > 0,
           let image = CGWindowListCreateImage(
               .null,
               .optionIncludingWindow,
               windowID,
               [.bestResolution, .boundsIgnoreFraming]
           ),
           !shouldUseDisplayFallbackForScreenshot(width: image.width, height: image.height, frame: frame) {
            return screenshotObservation(image: image, frame: frame)
        }

        guard let displayFrame = displayFrame(containing: fallbackFrame),
              let image = CGWindowListCreateImage(
                  displayFrame,
                  .optionOnScreenOnly,
                  kCGNullWindowID,
                  [.bestResolution]
              ) else { return nil }
        return screenshotObservation(image: image, frame: displayFrame)
    }

    private static func screenshotObservation(image: CGImage, frame: CGRect) -> ComputerUseScreenshotObservation {
        let width = image.width
        let height = image.height
        let scaleX = Double(width) / max(Double(frame.width), 1)
        let scaleY = Double(height) / max(Double(frame.height), 1)
        return ComputerUseScreenshotObservation(
            screenshotID: "s\(Int(Date().timeIntervalSince1970 * 1000))",
            width: width,
            height: height,
            windowFrame: ComputerUseRect(frame),
            scaleX: scaleX,
            scaleY: scaleY,
            imageDataURL: imageDataURL(image)
        )
    }

    nonisolated static func shouldUseDisplayFallbackForScreenshot(width: Int, height: Int, frame: CGRect) -> Bool {
        width < 320 || height < 240 || frame.width < 320 || frame.height < 240
    }

    private static func preferredScreenshotWindow(
        from windows: [[CFString: Any]],
        fallbackFrame: CGRect?
    ) -> [CFString: Any]? {
        guard !windows.isEmpty else { return nil }
        if let fallbackFrame, fallbackFrame.width > 0, fallbackFrame.height > 0 {
            let matching = windows
                .compactMap { window -> ([CFString: Any], CGRect)? in
                    guard let bounds = cgWindowBounds(window) else { return nil }
                    return (window, bounds)
                }
                .filter { _, bounds in bounds.intersects(fallbackFrame) }
                .sorted { lhs, rhs in
                    lhs.1.intersection(fallbackFrame).area > rhs.1.intersection(fallbackFrame).area
                }
            if let usefulMatch = matching.first(where: { !shouldUseDisplayFallbackForScreenshot(width: Int($0.1.width), height: Int($0.1.height), frame: $0.1) }) {
                return usefulMatch.0
            }
        }
        if let usefulWindow = windows.first(where: { window in
            guard let bounds = cgWindowBounds(window) else { return false }
            return !shouldUseDisplayFallbackForScreenshot(width: Int(bounds.width), height: Int(bounds.height), frame: bounds)
        }) {
            return usefulWindow
        }
        return windows.max { lhs, rhs in
            (cgWindowBounds(lhs)?.area ?? 0) < (cgWindowBounds(rhs)?.area ?? 0)
        }
    }

    private static func displayFrame(containing frame: CGRect?) -> CGRect? {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }
        let targetPoint = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGEvent(source: nil)?.location
            ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)
        if let display = displays.first(where: { CGDisplayBounds($0).contains(targetPoint) }) {
            return CGDisplayBounds(display)
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    private static func cgWindowBounds(_ windowInfo: [CFString: Any]) -> CGRect? {
        guard let bounds = windowInfo[kCGWindowBounds] as? [String: Any] else { return nil }
        let x = bounds["X"] as? CGFloat ?? 0
        let y = bounds["Y"] as? CGFloat ?? 0
        let width = bounds["Width"] as? CGFloat ?? 0
        let height = bounds["Height"] as? CGFloat ?? 0
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func imageDataURL(_ image: CGImage) -> String? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.62]) else {
            return nil
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit - 1)) + "..." : value
    }

    private static func canonicalAppName(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                ? Character(scalar)
                : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: #" app$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ComputerUseAppInstructionProvider {
    static func instructions(for bundleID: String, appName: String) -> String? {
        var hints: [String] = []
        if isBrowser(bundleID: bundleID, appName: appName) {
            hints.append("Browser hint: for a new web task, open a fresh tab with command+t, then use navigate_url on the active tab without tab indexes. Use tab listing only when continuing or finding an existing tab. If DOM/page tools fail or return nothing, continue with AX, screenshot, keyboard, and mouse control.")
        }
        if isNativeRichTextApp(bundleID: bundleID, appName: appName) {
            hints.append("Native rich-text hint: focus the editable title/body before insertion, prefer paste_text for multi-word text, and verify the focused value or visible AX text changed before proceeding.")
        }
        return hints.isEmpty ? nil : hints.joined(separator: "\n")
    }

    private static func isBrowser(bundleID: String, appName: String) -> Bool {
        let identifiers = Set([
            "com.google.Chrome",
            "com.apple.Safari",
            "org.mozilla.firefox",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
        ])
        if identifiers.contains(bundleID) {
            return true
        }
        let name = canonical(appName)
        return ["chrome", "google chrome", "safari", "firefox", "arc", "edge", "microsoft edge"].contains(name)
    }

    private static func isNativeRichTextApp(bundleID: String, appName: String) -> Bool {
        let identifiers = Set([
            "com.apple.Notes",
            "com.apple.TextEdit",
            "com.apple.mail",
        ])
        if identifiers.contains(bundleID) {
            return true
        }
        let name = canonical(appName)
        return ["notes", "textedit", "text edit", "mail"].contains(name)
    }

    private static func canonical(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CGRect {
    var area: CGFloat {
        max(width, 0) * max(height, 0)
    }
}

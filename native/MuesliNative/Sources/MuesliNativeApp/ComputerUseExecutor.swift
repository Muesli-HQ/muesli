import AppKit
import ApplicationServices
import Foundation

struct ComputerUseExecutionResult: Equatable {
    enum Status: Equatable {
        case executed
        case needsConfirmation
        case unsupported
        case failed
    }

    let status: Status
    let message: String

    static func executed(_ message: String) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .executed, message: message)
    }

    static func needsConfirmation(_ message: String) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .needsConfirmation, message: message)
    }

    static func unsupported(_ message: String) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .unsupported, message: message)
    }

    static func failed(_ message: String) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .failed, message: message)
    }
}

@MainActor
enum ComputerUseExecutor {
    private static let appAliases: [String: String] = [
        "arc": "company.thebrowser.Browser",
        "calendar": "com.apple.iCal",
        "chrome": "com.google.Chrome",
        "facetime": "com.apple.FaceTime",
        "finder": "com.apple.finder",
        "firefox": "org.mozilla.firefox",
        "google chrome": "com.google.Chrome",
        "mail": "com.apple.mail",
        "messages": "com.apple.MobileSMS",
        "notes": "com.apple.Notes",
        "safari": "com.apple.Safari",
        "settings": "com.apple.systempreferences",
        "slack": "com.tinyspeck.slackmacgap",
        "spotify": "com.spotify.client",
        "system settings": "com.apple.systempreferences",
        "terminal": "com.apple.Terminal",
        "visual studio code": "com.microsoft.VSCode",
        "vs code": "com.microsoft.VSCode",
        "vscode": "com.microsoft.VSCode",
        "zoom": "us.zoom.xos",
    ]

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "equal": 24, "9": 25, "7": 26,
        "-": 27, "minus": 27, "8": 28, "0": 29, "]": 30, "right bracket": 30, "o": 31,
        "u": 32, "[": 33, "left bracket": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "quote": 39, "k": 40, ";": 41, "semicolon": 41, "\\": 42, "backslash": 42,
        ",": 43, "comma": 43, "/": 44, "slash": 44, "n": 45, "m": 46, ".": 47, "period": 47,
        "`": 50, "grave": 50, "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left arrow": 123, "right arrow": 124, "down arrow": 125, "up arrow": 126,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func execute(_ parsed: ParsedComputerUseIntent) async -> ComputerUseExecutionResult {
        guard !parsed.requiresConfirmation else {
            return .needsConfirmation("Confirm required")
        }

        switch parsed.intent {
        case .openApp(let name):
            return await openApp(named: name)
        case .focusApp(let name):
            return await focusApp(named: name)
        case .click(let label):
            return clickElement(labeled: label)
        case .pressKey(let command):
            return pressKey(command)
        case .typeText(let text):
            PasteController.typeText(text)
            return .executed("Typed text")
        case .pasteText(let text):
            PasteController.paste(text: text)
            return .executed("Pasted text")
        case .scroll(let direction, let pages):
            return scroll(direction: direction, pages: pages)
        }
    }

    static func bundleIdentifierAlias(for appName: String) -> String? {
        appAliases[canonicalAppName(appName)]
    }

    static func keyCode(for key: String) -> CGKeyCode? {
        keyCodes[canonicalKeyName(key)]
    }

    private static func openApp(named rawName: String) async -> ComputerUseExecutionResult {
        let name = cleanedName(rawName)
        guard let appURL = applicationURL(for: name) else {
            return .failed("Could not find \(name)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            _ = try await openApplication(at: appURL, configuration: configuration)
            return .executed("Opened \(name)")
        } catch {
            return .failed("Could not open \(name)")
        }
    }

    private static func focusApp(named rawName: String) async -> ComputerUseExecutionResult {
        let name = cleanedName(rawName)
        if let app = runningApplication(named: name) {
            app.activate(options: [.activateAllWindows])
            return .executed("Focused \(name)")
        }
        return await openApp(named: name)
    }

    private static func pressKey(_ command: ComputerUseKeyCommand) -> ComputerUseExecutionResult {
        guard let keyCode = keyCode(for: command.key),
              let source = CGEventSource(stateID: .combinedSessionState)
        else {
            return .unsupported("Unsupported key \(command.key)")
        }

        let flags = cgFlags(for: command.modifiers)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        return .executed("Pressed key")
    }

    private static func scroll(direction: ComputerUseScrollDirection, pages: Double) -> ComputerUseExecutionResult {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("Could not create scroll event")
        }

        let units = Int32(max(1, min(8, pages)) * 8)
        let vertical: Int32
        let horizontal: Int32
        switch direction {
        case .up:
            vertical = units
            horizontal = 0
        case .down:
            vertical = -units
            horizontal = 0
        case .left:
            vertical = 0
            horizontal = units
        case .right:
            vertical = 0
            horizontal = -units
        }

        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
        return .executed("Scrolled \(direction.rawValue)")
    }

    private static func clickElement(labeled rawLabel: String) -> ComputerUseExecutionResult {
        guard AXIsProcessTrusted() else {
            return .failed("Accessibility permission required")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .failed("No frontmost app")
        }

        let label = canonicalLabel(rawLabel)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let root = focusedWindow(in: axApp) ?? axApp
        guard let match = findElement(labeled: label, in: root, maxDepth: 8, visited: []) else {
            return .failed("Could not find \(rawLabel)")
        }

        if AXUIElementPerformAction(match, kAXPressAction as CFString) == .success {
            return .executed("Clicked \(rawLabel)")
        }
        if clickCenter(of: match) {
            return .executed("Clicked \(rawLabel)")
        }
        return .failed("Could not click \(rawLabel)")
    }

    private static func applicationURL(for appName: String) -> URL? {
        let canonical = canonicalAppName(appName)
        if let bundleIdentifier = appAliases[canonical],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
        ]
        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                if applicationNames(for: url).contains(canonical) {
                    return url
                }
            }
        }
        return nil
    }

    private static func applicationNames(for appURL: URL) -> Set<String> {
        var names: Set<String> = [canonicalAppName(appURL.deletingPathExtension().lastPathComponent)]
        if let bundle = Bundle(url: appURL) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String {
                    names.insert(canonicalAppName(value))
                }
            }
        }
        return names
    }

    private static func runningApplication(named appName: String) -> NSRunningApplication? {
        let canonical = canonicalAppName(appName)
        if let bundleIdentifier = appAliases[canonical],
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { app in
            guard let name = app.localizedName else { return false }
            return canonicalAppName(name) == canonical
        }
    }

    private static func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                }
            }
        }
    }

    private static func cgFlags(for modifiers: [ComputerUseKeyModifier]) -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .option:
                flags.insert(.maskAlternate)
            case .control:
                flags.insert(.maskControl)
            case .shift:
                flags.insert(.maskShift)
            case .function:
                flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    private static func focusedWindow(in axApp: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let element = value,
              CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    private static func findElement(
        labeled label: String,
        in element: AXUIElement,
        maxDepth: Int,
        visited: Set<AXUIElement>
    ) -> AXUIElement? {
        guard maxDepth >= 0, !visited.contains(element) else { return nil }
        var visited = visited
        visited.insert(element)

        if elementMatches(element, label: label) {
            return element
        }

        for child in childElements(of: element) {
            if let match = findElement(labeled: label, in: child, maxDepth: maxDepth - 1, visited: visited) {
                return match
            }
        }
        return nil
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let rawChildren = value as? [AXUIElement]
        else { return [] }
        return rawChildren
    }

    private static func elementMatches(_ element: AXUIElement, label: String) -> Bool {
        let candidates = [
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXValueAttribute),
            axString(element, kAXHelpAttribute),
        ]
        return candidates.contains { candidate in
            let normalized = canonicalLabel(candidate)
            return normalized == label || normalized.contains(label)
        }
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func clickCenter(of element: AXUIElement) -> Bool {
        guard let rect = rect(of: element) else { return false }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        return true
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

    private static func cleanedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalAppName(_ value: String) -> String {
        canonicalLabel(value)
            .replacingOccurrences(of: #" app$"#, with: "", options: .regularExpression)
    }

    private static func canonicalKeyName(_ value: String) -> String {
        canonicalLabel(value)
            .replacingOccurrences(of: "arrow key", with: "arrow")
    }

    private static func canonicalLabel(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                ? Character(scalar)
                : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

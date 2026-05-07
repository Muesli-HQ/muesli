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
enum ComputerUseToolExecutor {
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
        "tail scale": "io.tailscale.ipn.macsys",
        "tailscale": "io.tailscale.ipn.macsys",
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

    static func execute(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) async -> ComputerUseExecutionResult {
        if let failure = toolCall.validationFailure() {
            return .unsupported(failure)
        }
        guard !toolCall.requiresConfirmation else {
            return .needsConfirmation("Confirm: \(toolCall.summary)")
        }

        switch toolCall.tool {
        case .listApps:
            return listApps()
        case .launchApp:
            return await openApp(named: toolCall.appName?.isEmpty == false ? toolCall.appName! : toolCall.canonicalBundleID)
        case .listWindows:
            return listWindows(appBundleID: toolCall.canonicalBundleID)
        case .getWindowState:
            if !toolCall.canonicalBundleID.isEmpty || toolCall.appName?.isEmpty == false {
                return await focusApp(named: toolCall.appName?.isEmpty == false ? toolCall.appName! : toolCall.canonicalBundleID)
            }
            return .executed("Captured window state")
        case .moveCursor:
            return moveCursor(toolCall, registry: registry)
        case .click:
            return click(toolCall, registry: registry)
        case .setValue:
            return setValue(toolCall, registry: registry)
        case .drag:
            return drag(toolCall, registry: registry)
        case .pressKey, .hotkey:
            return pressKey(ComputerUseKeyCommand(
                modifiers: toolCall.modifiers ?? [],
                key: toolCall.key ?? ""
            ))
        case .typeText:
            return await enterText(toolCall, registry: registry, mode: .keyboard)
        case .pasteText:
            return await enterText(toolCall, registry: registry, mode: .paste)
        case .scroll:
            return scroll(direction: toolCall.direction ?? .down, pages: toolCall.pages ?? 1)
        case .listBrowserTabs:
            return await ComputerUseBrowserAutomation.listTabs(appBundleID: toolCall.canonicalBundleID)
        case .activateBrowserTab:
            return await ComputerUseBrowserAutomation.activateTab(
                appBundleID: toolCall.canonicalBundleID,
                windowIndex: toolCall.windowIndex ?? 1,
                tabIndex: toolCall.tabIndex ?? 1
            )
        case .navigateURL:
            return await ComputerUseBrowserAutomation.navigate(
                appBundleID: toolCall.canonicalBundleID,
                windowIndex: toolCall.windowIndex,
                tabIndex: toolCall.tabIndex,
                url: toolCall.url ?? ""
            )
        case .pageGetText:
            return await ComputerUseBrowserAutomation.pageText(
                appBundleID: toolCall.canonicalBundleID,
                windowIndex: toolCall.windowIndex,
                tabIndex: toolCall.tabIndex
            )
        case .pageQueryDOM:
            return await ComputerUseBrowserAutomation.queryDOM(
                appBundleID: toolCall.canonicalBundleID,
                windowIndex: toolCall.windowIndex,
                tabIndex: toolCall.tabIndex,
                selector: toolCall.selector ?? "",
                attributes: toolCall.attributes ?? []
            )
        case .finish:
            return .executed(toolCall.reason ?? "Done")
        case .fail:
            return .failed(toolCall.reason ?? "Failed")
        }
    }

    static func bundleIdentifierAlias(for appName: String) -> String? {
        appAliases[canonicalAppName(appName)]
    }

    static func keyCode(for key: String) -> CGKeyCode? {
        keyCodes[canonicalKeyName(key)]
    }

    private static func listApps() -> ComputerUseExecutionResult {
        let apps = NSWorkspace.shared.runningApplications
            .filter { ($0.localizedName?.isEmpty == false) || ($0.bundleIdentifier?.isEmpty == false) }
            .map { app in
                "\(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "unknown"), pid \(app.processIdentifier))\(app.isActive ? " active" : "")"
            }
            .prefix(80)
            .joined(separator: "\n")
        return .executed(apps.isEmpty ? "No running apps" : apps)
    }

    private static func listWindows(appBundleID: String) -> ComputerUseExecutionResult {
        let windows = windowInfos(appBundleID: appBundleID)
        guard !windows.isEmpty else {
            return .executed("No visible windows")
        }
        let text = windows.prefix(80).map { window in
            let frame: String
            if let rect = window.frame {
                frame = " \(Int(rect.x)),\(Int(rect.y)),\(Int(rect.width)),\(Int(rect.height))"
            } else {
                frame = ""
            }
            return "\(window.windowID ?? 0): \(window.appName) - \(window.title)\(frame)"
        }.joined(separator: "\n")
        return .executed(text)
    }

    private static func windowInfos(appBundleID: String) -> [ComputerUseWindowInfo] {
        let appByPID: [pid_t: NSRunningApplication] = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }
        )
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        return windowList.compactMap { window in
            guard let layer = window[kCGWindowLayer] as? Int, layer == 0,
                  let ownerPID = window[kCGWindowOwnerPID] as? pid_t
            else { return nil }
            let app = appByPID[ownerPID]
            let bundleID = app?.bundleIdentifier ?? ""
            if !appBundleID.isEmpty, bundleID != appBundleID {
                return nil
            }
            let title = window[kCGWindowName] as? String ?? ""
            let ownerName = window[kCGWindowOwnerName] as? String ?? app?.localizedName ?? "Unknown"
            let windowID = window[kCGWindowNumber] as? Int
            return ComputerUseWindowInfo(
                windowID: windowID,
                appName: ownerName,
                bundleID: bundleID,
                processID: Int(ownerPID),
                title: title,
                frame: cgWindowBounds(window).map(ComputerUseRect.init),
                isOnScreen: (window[kCGWindowIsOnscreen] as? Bool) ?? true
            )
        }
    }

    private static func openApp(named rawName: String) async -> ComputerUseExecutionResult {
        let name = cleanedName(rawName)
        guard let appURL = applicationURL(for: name) else {
            return .failed("Could not find \(name)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        do {
            let app = try await openApplication(at: appURL, configuration: configuration)
            app.activate(options: [.activateAllWindows])
            _ = try await waitUntilActive(app: app, timeout: 1.5)
            return .executed("Opened \(name)")
        } catch is CancellationError {
            return .failed("Cancelled opening \(name)")
        } catch {
            return .failed("Could not open \(name): \(error.localizedDescription)")
        }
    }

    private static func focusApp(named rawName: String) async -> ComputerUseExecutionResult {
        let name = cleanedName(rawName)
        if let app = runningApplication(named: name) {
            app.activate(options: [.activateAllWindows])
            do {
                _ = try await waitUntilActive(app: app, timeout: 1.5)
            } catch is CancellationError {
                return .failed("Cancelled focusing \(name)")
            } catch {
                return .failed("Could not focus \(name): \(error.localizedDescription)")
            }
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

        let deltas = scrollDeltas(direction: direction, pages: pages)

        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: deltas.vertical,
            wheel2: deltas.horizontal,
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
        return .executed("Scrolled \(direction.rawValue)")
    }

    static func scrollDeltas(direction: ComputerUseScrollDirection, pages: Double) -> (vertical: Int32, horizontal: Int32) {
        let units = Int32(max(1, min(8, pages)) * 8)
        switch direction {
        case .up:
            return (units, 0)
        case .down:
            return (-units, 0)
        case .left:
            return (0, -units)
        case .right:
            return (0, units)
        }
    }

    private static func click(_ toolCall: ComputerUseToolCall, registry: ComputerUseElementRegistry?) -> ComputerUseExecutionResult {
        if let index = toolCall.elementIndex {
            guard let element = registry?.element(for: index) else {
                return .failed("Stale or unknown element_index \(index). Run get_window_state again and use an element from the fresh snapshot.")
            }
            return clickElement(element, fallbackLabel: toolCall.label ?? "e\(index)")
        }
        if let elementID = toolCall.elementID, !elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let element = registry?.element(for: elementID) else {
                return .failed("Stale or unknown element_id \(elementID). Run get_window_state again and use an element from the fresh snapshot.")
            }
            return clickElement(element, fallbackLabel: toolCall.label ?? elementID)
        }
        if toolCall.x != nil, toolCall.y != nil {
            return clickPoint(toolCall, registry: registry)
        }
        return .needsConfirmation("Confirm: unknown click target")
    }

    private static func setValue(_ toolCall: ComputerUseToolCall, registry: ComputerUseElementRegistry?) -> ComputerUseExecutionResult {
        let element: AXUIElement?
        if let index = toolCall.elementIndex {
            guard let resolved = registry?.element(for: index) else {
                return .failed("Stale or unknown element_index \(index). Run get_window_state again and use an element from the fresh snapshot.")
            }
            element = resolved
        } else if let elementID = toolCall.elementID {
            guard let resolved = registry?.element(for: elementID) else {
                return .failed("Stale or unknown element_id \(elementID). Run get_window_state again and use an element from the fresh snapshot.")
            }
            element = resolved
        } else {
            element = nil
        }
        guard let element else {
            return .failed("Stale or unknown element target")
        }
        let value = toolCall.value ?? ""
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if result == .success {
            return .executed("Set value")
        }
        return .unsupported("Element does not support set_value")
    }

    private enum TextEntryMode {
        case keyboard
        case paste

        var toolName: String {
            switch self {
            case .keyboard: "type_text"
            case .paste: "paste_text"
            }
        }

        var completedMessage: String {
            switch self {
            case .keyboard: "Typed text"
            case .paste: "Pasted text"
            }
        }
    }

    private static func enterText(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        mode: TextEntryMode
    ) async -> ComputerUseExecutionResult {
        let targetApp = await prepareTextEntryApp(toolCall)
        if case let .failure(message) = targetApp {
            return .failed(message)
        }
        let app = targetApp.app

        if let elementResult = await focusTextEntryElement(toolCall, registry: registry) {
            if case let .failure(message) = elementResult {
                return .failed(message)
            }
        }

        guard focusedEditableTextTarget(requiredApp: app) != nil else {
            let target = textEntryTargetDescription(app: app, toolCall: toolCall)
            return .failed("No focused editable text target\(target). Click an editable note body, title, text field, or text area before using \(mode.toolName).")
        }

        switch mode {
        case .keyboard:
            PasteController.typeText(toolCall.text ?? "")
            try? await Task.sleep(nanoseconds: 250_000_000)
        case .paste:
            PasteController.paste(text: toolCall.text ?? "")
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return .executed(mode.completedMessage)
    }

    private enum AppPreparationResult {
        case success(NSRunningApplication?)
        case failure(String)

        var app: NSRunningApplication? {
            if case let .success(app) = self { return app }
            return nil
        }
    }

    private enum ElementFocusResult {
        case success
        case failure(String)
    }

    private static func prepareTextEntryApp(_ toolCall: ComputerUseToolCall) async -> AppPreparationResult {
        let target = textEntryAppName(toolCall)
        guard !target.isEmpty else {
            return .success(nil)
        }

        let focusResult = await focusApp(named: target)
        guard focusResult.status == .executed else {
            return .failure(focusResult.message)
        }
        return .success(runningApplication(named: target))
    }

    private static func textEntryAppName(_ toolCall: ComputerUseToolCall) -> String {
        if toolCall.appName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return toolCall.appName ?? ""
        }
        if !toolCall.canonicalBundleID.isEmpty {
            return toolCall.canonicalBundleID
        }
        return ""
    }

    private static func focusTextEntryElement(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) async -> ElementFocusResult? {
        let element: AXUIElement?
        if let index = toolCall.elementIndex, index > 0 {
            guard let resolved = registry?.element(for: index) else {
                return .failure("Stale or unknown element_index \(index). Run get_window_state again and use an element from the fresh snapshot.")
            }
            element = resolved
        } else if let elementID = toolCall.elementID, !elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = registry?.element(for: elementID) else {
                return .failure("Stale or unknown element_id \(elementID). Run get_window_state again and use an element from the fresh snapshot.")
            }
            element = resolved
        } else {
            element = nil
        }
        guard let element else { return nil }

        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        if let rect = rect(of: element) {
            ComputerUseCursorOverlay.shared.show(at: CGPoint(x: rect.midX, y: rect.midY), label: toolCall.label)
        }
        _ = clickCenter(of: element)
        try? await Task.sleep(nanoseconds: 250_000_000)
        return .success
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

    private static func clickElement(_ element: AXUIElement, fallbackLabel: String) -> ComputerUseExecutionResult {
        if let rect = rect(of: element) {
            ComputerUseCursorOverlay.shared.show(
                at: CGPoint(x: rect.midX, y: rect.midY),
                label: fallbackLabel
            )
        }
        if axBool(element, kAXEnabledAttribute) == false {
            return .failed("\(fallbackLabel) is disabled; click would likely be a no-op")
        }

        let advertisedActions = actionNames(of: element)
        if let advertisedActions, !advertisedActions.contains(kAXPressAction) {
            if clickCenter(of: element) {
                return .executed("Clicked \(fallbackLabel) by coordinates; element does not advertise AXPress")
            }
            let actions = advertisedActions.isEmpty ? "none" : advertisedActions.joined(separator: ", ")
            return .unsupported("\(fallbackLabel) does not advertise AXPress (actions: \(actions))")
        }

        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return .executed("Clicked \(fallbackLabel)")
        }
        if clickCenter(of: element) {
            return .executed("Clicked \(fallbackLabel) by coordinates after AXPress failed")
        }
        return .failed("Could not click \(fallbackLabel)")
    }

    private static func clickPoint(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) -> ComputerUseExecutionResult {
        guard let point = screenPoint(for: toolCall, registry: registry) else {
            return .failed("No current screenshot for point click")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("Could not create mouse event")
        }

        ComputerUseCursorOverlay.shared.show(at: point, label: toolCall.label)
        CGWarpMouseCursorPosition(point)
        let button = mouseButton(from: toolCall.button)
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        let clickCount = max(1, min(toolCall.clicks ?? 1, 2))
        for clickIndex in 1...clickCount {
            guard let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: point,
                mouseButton: button
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: upType,
                mouseCursorPosition: point,
                mouseButton: button
            ) else {
                return .failed("Could not create mouse event")
            }
            mouseDown.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            mouseUp.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
        }
        let label = toolCall.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .executed("Clicked \(label?.isEmpty == false ? label! : "point")")
    }

    private static func moveCursor(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) -> ComputerUseExecutionResult {
        guard let point = screenPoint(for: toolCall, registry: registry) else {
            return .failed("No current screenshot for cursor move")
        }
        CGWarpMouseCursorPosition(point)
        ComputerUseCursorOverlay.shared.show(at: point, label: toolCall.label)
        return .executed("Moved cursor to \(Int(point.x.rounded())),\(Int(point.y.rounded()))")
    }

    private static func drag(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) -> ComputerUseExecutionResult {
        guard let start = screenPoint(for: toolCall, registry: registry),
              let end = screenPoint(
                x: toolCall.toX,
                y: toolCall.toY,
                screenshotID: toolCall.screenshotID,
                registry: registry
              )
        else {
            return .failed("No current screenshot for drag")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: start,
                mouseButton: .left
              ),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: end,
                mouseButton: .left
              )
        else {
            return .failed("Could not create drag event")
        }

        ComputerUseCursorOverlay.shared.show(at: start, label: toolCall.label)
        mouseDown.post(tap: .cghidEventTap)
        for step in 1...12 {
            let progress = CGFloat(step) / 12
            let point = CGPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        mouseUp.post(tap: .cghidEventTap)
        ComputerUseCursorOverlay.shared.show(at: end, label: toolCall.label)
        return .executed("Dragged pointer")
    }

    private static func applicationURL(for appName: String) -> URL? {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return url
        }

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
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("."),
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == trimmed }) {
            return app
        }

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

    private static func waitUntilActive(app: NSRunningApplication, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isActive {
                return true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return app.isActive
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

    private static func textEntryTargetDescription(
        app: NSRunningApplication?,
        toolCall: ComputerUseToolCall
    ) -> String {
        let appName = app?.localizedName ?? textEntryAppName(toolCall)
        return appName.isEmpty ? "" : " in \(appName)"
    }

    private static func focusedEditableTextTarget(requiredApp: NSRunningApplication?) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let rawElement = value,
              CFGetTypeID(rawElement) == AXUIElementGetTypeID()
        else { return nil }

        let element = rawElement as! AXUIElement
        if let requiredApp {
            guard processID(of: element) == requiredApp.processIdentifier else {
                return nil
            }
        }
        return isEditableTextElement(element) ? element : nil
    }

    private static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        let editableRoles = Set([
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
        ])
        if editableRoles.contains(role) {
            return true
        }
        if subrole == "AXSearchField" {
            return true
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return role.contains("Text") || role == "AXWebArea" || role == "AXGroup"
        }
        return false
    }

    private static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
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

    private static func cgWindowBounds(_ windowInfo: [CFString: Any]) -> CGRect? {
        guard let bounds = windowInfo[kCGWindowBounds] as? [String: Any] else { return nil }
        let x = bounds["X"] as? CGFloat ?? 0
        let y = bounds["Y"] as? CGFloat ?? 0
        let width = bounds["Width"] as? CGFloat ?? 0
        let height = bounds["Height"] as? CGFloat ?? 0
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func screenPoint(
        for toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) -> CGPoint? {
        screenPoint(
            x: toolCall.x,
            y: toolCall.y,
            screenshotID: toolCall.screenshotID,
            registry: registry
        )
    }

    private static func screenPoint(
        x: Double?,
        y: Double?,
        screenshotID: String?,
        registry: ComputerUseElementRegistry?
    ) -> CGPoint? {
        guard let x, let y, let screenshot = registry?.currentScreenshot() else { return nil }
        if let screenshotID, screenshotID != screenshot.screenshotID {
            return nil
        }
        let window = screenshot.windowFrame
        return CGPoint(
            x: window.x + (x / max(screenshot.scaleX, 0.0001)),
            y: window.y + (y / max(screenshot.scaleY, 0.0001))
        )
    }

    private static func mouseButton(from rawValue: String?) -> CGMouseButton {
        let value = canonicalLabel(rawValue ?? "")
        return value == "right" || value == "secondary" ? .right : .left
    }

    private static func currentCursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
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

@MainActor
enum ComputerUseExecutor {
    static func bundleIdentifierAlias(for appName: String) -> String? {
        ComputerUseToolExecutor.bundleIdentifierAlias(for: appName)
    }

    static func keyCode(for key: String) -> CGKeyCode? {
        ComputerUseToolExecutor.keyCode(for: key)
    }
}

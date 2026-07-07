import AppKit
import ApplicationServices
import Foundation

struct ComputerUseExecutionResult: Equatable {
    enum Status: Equatable {
        case executed
        case needsConfirmation
        case unsupported
        case failed
        case cancelled
    }

    let status: Status
    let message: String
    let diagnostics: [String: String]?
    let transaction: ComputerUseActionTransaction?

    static func executed(
        _ message: String,
        diagnostics: [String: String]? = nil,
        transaction: ComputerUseActionTransaction? = nil
    ) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .executed, message: message, diagnostics: diagnostics, transaction: transaction)
    }

    static func needsConfirmation(
        _ message: String,
        diagnostics: [String: String]? = nil,
        transaction: ComputerUseActionTransaction? = nil
    ) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .needsConfirmation, message: message, diagnostics: diagnostics, transaction: transaction)
    }

    static func unsupported(
        _ message: String,
        diagnostics: [String: String]? = nil,
        transaction: ComputerUseActionTransaction? = nil
    ) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .unsupported, message: message, diagnostics: diagnostics, transaction: transaction)
    }

    static func failed(
        _ message: String,
        diagnostics: [String: String]? = nil,
        transaction: ComputerUseActionTransaction? = nil
    ) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .failed, message: message, diagnostics: diagnostics, transaction: transaction)
    }

    static func cancelled(
        _ message: String = "Cancelled",
        diagnostics: [String: String]? = nil,
        transaction: ComputerUseActionTransaction? = nil
    ) -> ComputerUseExecutionResult {
        ComputerUseExecutionResult(status: .cancelled, message: message, diagnostics: diagnostics, transaction: transaction)
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
        "pageup": 116, "page up": 116, "pagedown": 121, "page down": 121,
        "left arrow": 123, "right arrow": 124, "down arrow": 125, "up arrow": 126,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func execute(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        interactionMode: ComputerUseInteractionMode = .direct
    ) async -> ComputerUseExecutionResult {
        if let failure = toolCall.validationFailure() {
            return .unsupported(failure)
        }
        guard !toolCall.requiresConfirmation else {
            return .needsConfirmation("Confirm: \(toolCall.summary)")
        }

        switch toolCall.tool {
        case .recognizeScreenshotText:
            return .unsupported("recognize_screenshot_text is handled by the planner runtime")
        case .listApps:
            return listApps()
        case .launchApp:
            return await openApp(
                named: toolCall.appName?.isEmpty == false ? toolCall.appName! : toolCall.canonicalBundleID,
                allowActivation: interactionMode == .direct
            )
        case .listWindows:
            return listWindows(appBundleID: toolCall.canonicalBundleID)
        case .getAppState, .getWindowState:
            if !toolCall.canonicalBundleID.isEmpty || toolCall.appName?.isEmpty == false {
                guard interactionMode == .direct else {
                    return .executed("Captured target state without foreground activation request")
                }
                return await focusApp(named: toolCall.appName?.isEmpty == false ? toolCall.appName! : toolCall.canonicalBundleID)
            }
            return .executed("Captured window state")
        case .moveCursor:
            return moveCursor(toolCall, registry: registry, allowCursorWarp: interactionMode == .direct)
        case .click, .clickElement, .clickPoint:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                click(
                    toolCall,
                    registry: registry,
                    allowPointerFallback: interactionMode == .direct,
                    allowBackgroundDispatch: interactionMode == .quiet
                )
            }
        case .focusElement:
            guard interactionMode == .direct else {
                return .needsConfirmation("Moving focus as a standalone step would interrupt the user's current app. In Work quietly mode, use paste_text with the intended process/window/element target so Muesli can route insertion to that target without foregrounding it.")
            }
            return await focusElement(toolCall, registry: registry, allowAppActivation: interactionMode == .direct)
        case .activateFocused:
            return await activateFocused(toolCall, allowAppActivation: interactionMode == .direct)
        case .performSecondaryAction:
            return performSecondaryAction(toolCall, registry: registry)
        case .setValue:
            return setValue(toolCall, registry: registry)
        case .drag:
            guard interactionMode == .direct else {
                return .needsConfirmation("Dragging the pointer requires direct app control.")
            }
            return drag(toolCall, registry: registry)
        case .pressKey, .hotkey:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await pressKey(
                    toolCall,
                    registry: registry,
                    allowBackgroundDispatch: interactionMode == .quiet
                )
            }
        case .typeText:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await enterText(
                    toolCall,
                    registry: registry,
                    mode: .keyboard,
                    allowAppActivation: interactionMode == .direct
                )
            }
        case .pasteText:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await enterText(
                    toolCall,
                    registry: registry,
                    mode: .paste,
                    allowAppActivation: interactionMode == .direct
                )
            }
        case .scroll:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                scroll(
                    toolCall,
                    registry: registry,
                    allowGlobalScroll: interactionMode == .direct,
                    allowBackgroundDispatch: interactionMode == .quiet
                )
            }
        case .listBrowserTabs:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await ComputerUseBrowserAutomation.listTabs(appBundleID: toolCall.canonicalBundleID)
            }
        case .activateBrowserTab:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await ComputerUseBrowserAutomation.activateTab(
                    appBundleID: toolCall.canonicalBundleID,
                    windowIndex: toolCall.windowIndex ?? 1,
                    tabIndex: toolCall.tabIndex ?? 1,
                    allowActivation: interactionMode == .direct,
                    processID: toolCall.processID.map(pid_t.init),
                    windowID: toolCall.windowID.map(CGWindowID.init)
                )
            }
        case .openNewBrowserTab:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await ComputerUseBrowserAutomation.openNewTab(
                    appBundleID: toolCall.canonicalBundleID,
                    allowActivation: interactionMode == .direct,
                    processID: toolCall.processID.map(pid_t.init),
                    windowID: toolCall.windowID.map(CGWindowID.init)
                )
            }
        case .navigateURL:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await ComputerUseBrowserAutomation.navigate(
                    appBundleID: toolCall.canonicalBundleID,
                    windowIndex: toolCall.windowIndex,
                    tabIndex: toolCall.tabIndex,
                    url: toolCall.url ?? "",
                    allowActivation: interactionMode == .direct,
                    processID: toolCall.processID.map(pid_t.init),
                    windowID: toolCall.windowID.map(CGWindowID.init)
                )
            }
        case .navigateActiveBrowserTab:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await ComputerUseBrowserAutomation.navigate(
                    appBundleID: toolCall.canonicalBundleID,
                    windowIndex: nil,
                    tabIndex: nil,
                    url: toolCall.url ?? "",
                    allowActivation: interactionMode == .direct,
                    processID: toolCall.processID.map(pid_t.init),
                    windowID: toolCall.windowID.map(CGWindowID.init)
                )
            }
        case .pageGetText:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await ComputerUseBrowserAutomation.pageText(
                    appBundleID: toolCall.canonicalBundleID,
                    windowIndex: toolCall.windowIndex,
                    tabIndex: toolCall.tabIndex
                )
            }
        case .pageQueryDOM:
            return await withFrontmostPreserved(enabled: interactionMode == .quiet) {
                await ComputerUseBrowserAutomation.queryDOM(
                    appBundleID: toolCall.canonicalBundleID,
                    windowIndex: toolCall.windowIndex,
                    tabIndex: toolCall.tabIndex,
                    selector: toolCall.selector ?? "",
                    attributes: toolCall.attributes ?? []
                )
            }
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
        let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
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

    private static func matchedWindowID(processID: pid_t, frame: CGRect) -> Int? {
        if let axWindow = containingWindowForID(ofProcessID: processID, frame: frame),
           axWindow > 0 {
            return Int(axWindow)
        }
        let matchedWindow = windowInfos(appBundleID: "")
            .filter { $0.processID == Int(processID) }
            .first { info in
                guard let candidateFrame = info.frame else { return false }
                return framesApproximatelyMatch(CGRect(
                    x: candidateFrame.x,
                    y: candidateFrame.y,
                    width: candidateFrame.width,
                    height: candidateFrame.height
                ), frame)
            }
        return matchedWindow?.windowID
    }

    private static func containingWindowForID(ofProcessID processID: pid_t, frame: CGRect) -> CGWindowID? {
        let app = AXUIElementCreateApplication(processID)
        guard let window = windowMatchingFrame(in: app, frame: frame) else { return nil }
        var windowID = CGWindowID(0)
        guard AXWindowIDResolver.getWindowID(window, &windowID), windowID > 0 else {
            return nil
        }
        return windowID
    }

    private static func windowMatchingFrame(in axApp: AXUIElement, frame: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return nil
        }
        return windows.first { window in
            guard let candidateFrame = rect(of: window) else { return false }
            return framesApproximatelyMatch(candidateFrame, frame)
        }
    }

    private static func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        return abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    private static func openApp(
        named rawName: String,
        allowActivation: Bool = true
    ) async -> ComputerUseExecutionResult {
        let name = cleanedName(rawName)
        do {
            if let app = runningApplication(named: name) {
                if allowActivation {
                    app.activate(options: [.activateAllWindows])
                    _ = try await waitUntilActive(app: app, timeout: 1.5)
                    return .executed(
                        "Opened \(name) (already running)",
                        transaction: launchTransaction(path: "running_app_activate", app: app, verified: true)
                    )
                }
                return .executed(
                    "Launched \(name) (already running; left in background)",
                    transaction: launchTransaction(path: "running_app_background", app: app, verified: true)
                )
            }

            guard let appURL = try await applicationURL(for: name) else {
                return .failed("Could not find \(name)")
            }

            let priorFrontmost = NSWorkspace.shared.frontmostApplication
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = allowActivation
            let app = try await openApplication(at: appURL, configuration: configuration)
            if allowActivation {
                app.activate(options: [.activateAllWindows])
                _ = try await waitUntilActive(app: app, timeout: 1.5)
                return .executed(
                    "Opened \(name)",
                    transaction: launchTransaction(path: "launch_services_activate", app: app, verified: true)
                )
            }
            await restoreFrontmostApp(priorFrontmost, ifTargetSelfActivated: app)
            return .executed(
                "Launched \(name) in background",
                transaction: launchTransaction(path: "launch_services_background", app: app, verified: true)
            )
        } catch is CancellationError {
            return .cancelled("Cancelled opening \(name)")
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
                return .cancelled("Cancelled focusing \(name)")
            } catch {
                return .failed("Could not focus \(name): \(error.localizedDescription)")
            }
            return .executed("Focused \(name)")
        }
        return await openApp(named: name, allowActivation: true)
    }

    private static func launchTransaction(
        path: String,
        app: NSRunningApplication,
        verified: Bool
    ) -> ComputerUseActionTransaction {
        ComputerUseActionTransaction(
            path: path,
            posted: true,
            verified: verified,
            effect: verified ? .confirmed : .unknown,
            targetStable: true,
            processID: Int(app.processIdentifier),
            escalationHint: "Use get_window_state before interacting with this app so actions are scoped to the current process/window.",
            warning: verified ? nil : "Launch command was sent, but the running app could not be confirmed."
        )
    }

    private static func pressKey(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        allowBackgroundDispatch: Bool = false
    ) async -> ComputerUseExecutionResult {
        let command = ComputerUseKeyCommand(
            modifiers: toolCall.modifiers ?? [],
            key: toolCall.key ?? ""
        )
        guard let keyCode = keyCode(for: command.key),
              let source = CGEventSource(stateID: .combinedSessionState)
        else {
            return .unsupported("Unsupported key \(command.key)")
        }

        if allowBackgroundDispatch, !(toolCall.processID.map { $0 > 0 } ?? false) {
            return .failed(
                "Quiet key dispatch requires process_id and window_id from the latest target state; key was not posted.",
                transaction: ComputerUseActionTransaction(
                    path: "pid_key_events",
                    posted: false,
                    verified: false,
                    effect: .blocked,
                    targetStable: false,
                    processID: nil,
                    windowID: toolCall.windowID,
                    escalationHint: "Refresh target state and retry press_key with process_id and window_id, or switch Computer Use to direct control.",
                    warning: "Quiet key dispatch was blocked before posting because process_id was missing."
                )
            )
        }

        let resolvedProcessID: pid_t?
        if let suppliedProcessID = toolCall.processID, suppliedProcessID > 0 {
            let expectedProcessID = pid_t(suppliedProcessID)
            if !allowBackgroundDispatch {
                guard let focusedProcessID = currentFocusedProcessID() else {
                    return .failed("Could not validate process_id \(suppliedProcessID) against current keyboard focus. Refresh state before pressing keys.")
                }
                guard focusedProcessID == expectedProcessID else {
                    return .failed("Stale process_id \(suppliedProcessID); focused element pid is \(focusedProcessID). Refresh state before pressing keys.")
                }
            }
            resolvedProcessID = expectedProcessID
        } else if let mismatch = focusedAppHintMismatchMessage(toolCall) {
            return .failed(mismatch)
        } else {
            resolvedProcessID = nil
        }
        if allowBackgroundDispatch,
           let resolvedProcessID,
           let windowID = toolCall.windowID,
           windowID > 0 {
            guard ComputerUseBackgroundDriver.focusWithoutRaise(
                processID: resolvedProcessID,
                windowID: CGWindowID(windowID)
            ) else {
                return .failed(
                    "Could not focus target window \(windowID) without raising it; key was not posted. Refresh state before pressing keys.",
                    transaction: ComputerUseActionTransaction(
                        path: "pid_key_events",
                        posted: false,
                        verified: false,
                        effect: .blocked,
                        targetStable: false,
                        processID: Int(resolvedProcessID),
                        windowID: windowID,
                        escalationHint: "Refresh target state and retry with the current process_id/window_id, or switch Computer Use to direct control.",
                        warning: "Quiet key dispatch was blocked before posting because the target window could not be focused."
                    )
                )
            }
        } else if allowBackgroundDispatch, let resolvedProcessID {
            return .failed(
                "Quiet key dispatch requires window_id with process_id \(resolvedProcessID) so the key is scoped to a specific window.",
                transaction: ComputerUseActionTransaction(
                    path: "pid_key_events",
                    posted: false,
                    verified: false,
                    effect: .blocked,
                    targetStable: false,
                    processID: Int(resolvedProcessID),
                    windowID: toolCall.windowID,
                    escalationHint: "Refresh target state and retry with process_id and window_id from the latest observation.",
                    warning: "Quiet key dispatch was blocked before posting because window_id was missing."
                )
            )
        }
        let flags = cgFlags(for: command.modifiers)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        let attachAuthMessage = !flags.contains(.maskCommand)
        let postedDown = postKeyEvent(keyDown, processID: resolvedProcessID, attachAuthMessage: attachAuthMessage)
        let postedUp = postKeyEvent(keyUp, processID: resolvedProcessID, attachAuthMessage: attachAuthMessage)
        let posted = postedDown && postedUp
        let transaction = ComputerUseActionTransaction(
            path: resolvedProcessID == nil ? "global_key_events" : "pid_key_events",
            posted: posted,
            verified: false,
            effect: posted ? .unverifiable : .blocked,
            targetStable: true,
            processID: resolvedProcessID.map(Int.init),
            windowID: toolCall.windowID,
            escalationHint: posted
                ? "Inspect the post-action screenshot/AX state; if the key had no effect, refresh state and choose another action."
                : "Refresh target state and retry with a valid process_id/window_id or direct-control fallback.",
            warning: posted
                ? "Key events were posted, but this does not prove the app consumed them."
                : "Key events were not fully posted."
        )
        guard posted else {
            return .failed("Could not post key events", transaction: transaction)
        }
        return .executed("Pressed key", transaction: transaction)
    }

    private static func focusElement(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        allowAppActivation: Bool = true
    ) async -> ComputerUseExecutionResult {
        let targetApp = await prepareTextEntryApp(
            toolCall,
            shouldActivateNamedApp: allowAppActivation && (!toolCall.canonicalBundleID.isEmpty || toolCall.appName?.isEmpty == false)
        )
        if case let .failure(message) = targetApp {
            return .failed(message)
        }
        if case .cancelled = targetApp {
            return .cancelled()
        }
        guard let elementResult = elementTarget(toolCall, registry: registry) else {
            return .failed("Focus requires element_index or element_id")
        }
        let element: AXUIElement
        switch elementResult {
        case .failure(let message):
            return .failed(message)
        case .success(let resolved):
            element = resolved
        }
        switch await focusElement(
            element,
            label: toolCall.label ?? elementTargetLabel(toolCall),
            allowClickFallback: allowAppActivation
        ) {
        case .success:
            return .executed("Focused \(elementTargetLabel(toolCall))")
        case .failure(let message):
            return .failed(message)
        case .cancelled:
            return .cancelled()
        }
    }

    private static func activateFocused(
        _ toolCall: ComputerUseToolCall,
        allowAppActivation: Bool = true
    ) async -> ComputerUseExecutionResult {
        let targetApp = await prepareTextEntryApp(
            toolCall,
            shouldActivateNamedApp: allowAppActivation && (!toolCall.canonicalBundleID.isEmpty || toolCall.appName?.isEmpty == false)
        )
        if case let .failure(message) = targetApp {
            return .failed(message)
        }
        if case .cancelled = targetApp {
            return .cancelled()
        }
        guard AXIsProcessTrusted() else {
            return .failed("Accessibility permission required")
        }
        let requiredProcessID = toolCall.processID.map(pid_t.init)
        guard let element = focusedUIElement(requiredApp: targetApp.app, requiredProcessID: requiredProcessID) else {
            let target = toolCall.processID.map { " for pid \($0)" } ?? ""
            return .failed("No focused UI element\(target). Use get_app_state/get_window_state to inspect focus, or move focus with click or press_key tab before activation.")
        }

        let fallbackLabel = focusedElementLabel(element, fallback: toolCall.label)
        let actionContext = [fallbackLabel, toolCall.label, toolCall.reason].compactMap { $0 }.joined(separator: " ")
        if requiresActivateFocusedConfirmation(element: element, label: fallbackLabel, actionContext: actionContext) {
            return .needsConfirmation("Confirm: activate focused \(fallbackLabel)")
        }
        if axBool(element, kAXEnabledAttribute) == false {
            return .failed("\(fallbackLabel) is disabled; focused activation would likely be a no-op")
        }
        if let rect = rect(of: element) {
            ComputerUseCursorOverlay.shared.show(
                at: CGPoint(x: rect.midX, y: rect.midY),
                label: toolCall.label ?? fallbackLabel
            )
        }

        let advertisedActions = actionNames(of: element)
        if advertisedActions?.contains(kAXPressAction as String) != false,
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return .executed(
                "Sent AXPress to focused \(fallbackLabel); inspect the post-action screenshot/state to decide whether the UI changed as intended",
                transaction: ComputerUseActionTransaction(
                    path: "ax_press_focused",
                    route: "ax_press",
                    posted: true,
                    verified: false,
                    effect: .unverifiable,
                    targetStable: true,
                    processID: processID(of: element).map(Int.init),
                    windowID: toolCall.windowID,
                    escalationHint: "Inspect the post-action screenshot/AX state; if nothing changed, choose a click or key route.",
                    warning: "AXPress was accepted, but this does not prove the focused control changed app state."
                )
            )
        }

        guard let keyCode = keyCode(for: "enter"),
              let source = CGEventSource(stateID: .combinedSessionState)
        else {
            let actions = (advertisedActions ?? []).isEmpty ? "none" : (advertisedActions ?? []).joined(separator: ", ")
            return .unsupported("Focused \(fallbackLabel) does not support AXPress and Enter fallback could not be created (actions: \(actions)).")
        }
        let processID: pid_t?
        switch targetProcessID(toolCall: toolCall, app: targetApp.app, element: element) {
        case .success(let resolvedProcessID):
            processID = resolvedProcessID
        case .failure(let message):
            return .failed(message)
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        let postedDown = postKeyEvent(keyDown, processID: processID)
        let postedUp = postKeyEvent(keyUp, processID: processID)
        let posted = postedDown && postedUp
        let transaction = ComputerUseActionTransaction(
            path: processID == nil ? "global_key_events" : "pid_key_events",
            posted: posted,
            verified: false,
            effect: posted ? .unverifiable : .blocked,
            targetStable: true,
            processID: processID.map(Int.init),
            windowID: toolCall.windowID,
            escalationHint: "Inspect the post-action screenshot/AX state to decide whether focused activation succeeded.",
            warning: posted ? "Enter was posted, but this does not prove the focused UI consumed it." : "Enter was not fully posted."
        )
        guard posted else {
            return .failed("Could not post Enter to focused \(fallbackLabel)", transaction: transaction)
        }
        return .executed(
            "Sent Enter to focused \(fallbackLabel); inspect the post-action screenshot/state to decide whether the UI changed as intended",
            transaction: transaction
        )
    }

    private static func scroll(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        allowGlobalScroll: Bool,
        allowBackgroundDispatch: Bool = false
    ) -> ComputerUseExecutionResult {
        let direction = toolCall.direction ?? .down
        let pages = toolCall.pages ?? 1
        if let elementResult = elementTarget(toolCall, registry: registry) {
            switch elementResult {
            case .failure(let message):
                return .failed(message)
            case .success(let element):
                return scrollElement(element, direction: direction, pages: pages, label: toolCall.label)
            }
        }
        guard allowGlobalScroll else {
            if allowBackgroundDispatch,
               let processID = toolCall.processID,
               processID > 0 {
                return scrollInBackground(
                    direction: direction,
                    pages: pages,
                    processID: pid_t(processID),
                    windowID: toolCall.windowID.flatMap { $0 > 0 ? CGWindowID($0) : nil }
                )
            }
            return .needsConfirmation("Scrolling the active view in Work quietly mode requires process_id/window_id from the latest target state.")
        }
        return scroll(direction: direction, pages: pages)
    }

    private static func scrollInBackground(
        direction: ComputerUseScrollDirection,
        pages: Double,
        processID: pid_t,
        windowID: CGWindowID?
    ) -> ComputerUseExecutionResult {
        guard let windowID, windowID > 0 else {
            return .failed(
                "Background scroll requires window_id so the scroll key is scoped to a specific window.",
                transaction: ComputerUseActionTransaction(
                    path: "pid_key_scroll",
                    posted: false,
                    verified: false,
                    effect: .blocked,
                    targetStable: false,
                    processID: Int(processID),
                    windowID: windowID.map(Int.init),
                    escalationHint: "Refresh target state and retry with process_id/window_id from the latest observation.",
                    warning: "Background scroll was blocked before posting because window_id was missing."
                )
            )
        }
        guard ComputerUseBackgroundDriver.focusWithoutRaise(processID: processID, windowID: windowID) else {
            return .failed(
                "Could not focus target window \(windowID) without raising it; scroll was not posted.",
                transaction: ComputerUseActionTransaction(
                    path: "pid_key_scroll",
                    posted: false,
                    verified: false,
                    effect: .blocked,
                    targetStable: false,
                    processID: Int(processID),
                    windowID: Int(windowID),
                    escalationHint: "Refresh target state and retry with the current process_id/window_id, or switch Computer Use to direct control.",
                    warning: "Background scroll was blocked before posting because the target window could not be focused."
                )
            )
        }
        let repeats = max(1, min(8, Int(pages.rounded(.up))))
        let key = backgroundScrollKey(direction: direction, pages: pages)
        for _ in 0..<repeats {
            guard postKey(key, processID: processID) else {
                return .failed(
                    "Could not post background \(key) scroll key to process \(processID).",
                    transaction: ComputerUseActionTransaction(
                        path: "pid_key_scroll",
                        posted: false,
                        verified: false,
                        effect: .blocked,
                        targetStable: true,
                        processID: Int(processID),
                        windowID: Int(windowID),
                        escalationHint: "Refresh target state and retry with a valid process_id/window_id or use direct-control scroll.",
                        warning: "Scroll key was not posted."
                    )
                )
            }
        }
        return .executed(
            "Scrolled target window \(direction.rawValue)",
            transaction: ComputerUseActionTransaction(
                path: "pid_key_scroll",
                posted: true,
                verified: false,
                effect: .unverifiable,
                targetStable: true,
                processID: Int(processID),
                windowID: Int(windowID),
                escalationHint: "Inspect the post-action screenshot/AX state; if the viewport did not move, choose another scroll target or route.",
                warning: "Scroll keys were posted, but this does not prove the viewport consumed them."
            )
        )
    }

    private static func postKey(_ key: String, processID: pid_t) -> Bool {
        guard let keyCode = keyCode(for: key),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        let postedDown = ComputerUseBackgroundDriver.postKeyEvent(down, to: processID)
        let postedUp = ComputerUseBackgroundDriver.postKeyEvent(up, to: processID)
        return postedDown && postedUp
    }

    private static func backgroundScrollKey(direction: ComputerUseScrollDirection, pages: Double) -> String {
        if pages >= 1 {
            switch direction {
            case .up: return "pageup"
            case .down: return "pagedown"
            case .left: return "left"
            case .right: return "right"
            }
        }
        switch direction {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        }
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
        guard let event else {
            return .failed(
                "Could not create scroll event",
                transaction: ComputerUseActionTransaction(
                    path: "global_scroll_wheel",
                    posted: false,
                    verified: false,
                    effect: .blocked,
                    escalationHint: "Refresh target state and retry scroll with an element or pid/window-scoped target.",
                    warning: "Scroll event was not created."
                )
            )
        }
        event.post(tap: .cghidEventTap)
        return .executed(
            "Scrolled \(direction.rawValue)",
            transaction: ComputerUseActionTransaction(
                path: "global_scroll_wheel",
                posted: true,
                verified: false,
                effect: .unverifiable,
                escalationHint: "Inspect the post-action screenshot/AX state; if the viewport did not move, choose another scroll target or route.",
                warning: "Global scroll was posted, but this does not prove the viewport consumed it."
            )
        )
    }

    private static func scrollElement(
        _ element: AXUIElement,
        direction: ComputerUseScrollDirection,
        pages: Double,
        label: String?
    ) -> ComputerUseExecutionResult {
        let action = scrollActionName(direction: direction)
        let advertisedActions = actionNames(of: element) ?? []
        guard advertisedActions.contains(action) else {
            let actions = advertisedActions.isEmpty ? "none" : advertisedActions.joined(separator: ", ")
            return .unsupported("Element does not advertise \(action) for element-scoped scroll (actions: \(actions)).")
        }
        let count = max(1, min(8, Int(pages.rounded(.up))))
        for _ in 0..<count {
            guard AXUIElementPerformAction(element, action as CFString) == .success else {
                return .failed(
                    "Could not perform \(action) on scroll target",
                    transaction: ComputerUseActionTransaction(
                        path: "ax_scroll_action",
                        route: action,
                        posted: false,
                        verified: false,
                        effect: .blocked,
                        escalationHint: "Refresh target state and choose another scrollable element or direct-control scroll.",
                        warning: "AX scroll action was rejected."
                    )
                )
            }
        }
        if let rect = rect(of: element) {
            ComputerUseCursorOverlay.shared.show(at: CGPoint(x: rect.midX, y: rect.midY), label: label)
        }
        return .executed(
            "Scrolled element \(direction.rawValue)",
            transaction: ComputerUseActionTransaction(
                path: "ax_scroll_action",
                route: action,
                posted: true,
                verified: false,
                effect: .unverifiable,
                escalationHint: "Inspect the post-action screenshot/AX state; if the element did not move, choose another scroll target or route.",
                warning: "AX scroll action was accepted, but this does not prove visible content moved."
            )
        )
    }

    private static func scrollActionName(direction: ComputerUseScrollDirection) -> String {
        switch direction {
        case .up:
            return "AXScrollUpByPage"
        case .down:
            return "AXScrollDownByPage"
        case .left:
            return "AXScrollLeftByPage"
        case .right:
            return "AXScrollRightByPage"
        }
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

    private static func click(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        allowPointerFallback: Bool,
        allowBackgroundDispatch: Bool = false
    ) -> ComputerUseExecutionResult {
        if allowBackgroundDispatch {
            guard let processID = toolCall.processID, processID > 0 else {
                return .needsConfirmation("Work quietly click requires nonzero process_id from the latest target snapshot.")
            }
            guard let windowID = toolCall.windowID, windowID > 0 else {
                return .needsConfirmation("Work quietly click requires nonzero window_id from the latest target snapshot.")
            }
        }
        if toolCall.tool != .clickPoint, let elementResult = elementTarget(toolCall, registry: registry) {
            switch elementResult {
            case .failure(let message):
                return .failed(message)
            case .success(let element):
                return clickElement(
                    element,
                    fallbackLabel: toolCall.label ?? elementTargetLabel(toolCall),
                    allowPointerFallback: allowPointerFallback,
                    backgroundProcessID: allowBackgroundDispatch ? toolCall.processID.map(pid_t.init) : nil,
                    backgroundWindowID: allowBackgroundDispatch ? toolCall.windowID.flatMap { $0 > 0 ? CGWindowID($0) : nil } : nil,
                    button: clickButton(from: toolCall.button),
                    clicks: toolCall.clicks ?? 1
                )
            }
        }
        if toolCall.x != nil, toolCall.y != nil {
            if allowBackgroundDispatch {
                return clickPoint(
                    toolCall,
                    registry: registry,
                    backgroundProcessID: pid_t(toolCall.processID ?? 0),
                    backgroundWindowID: toolCall.windowID.flatMap { $0 > 0 ? CGWindowID($0) : nil }
                )
            } else if !allowPointerFallback {
                return .needsConfirmation("Clicking a screen coordinate requires direct app control.")
            }
            return clickPoint(toolCall, registry: registry)
        }
        return .needsConfirmation("Confirm: unknown click target")
    }

    private static func performSecondaryAction(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) -> ComputerUseExecutionResult {
        guard let elementResult = elementTarget(toolCall, registry: registry) else {
            return .failed("Secondary action requires element_index or element_id")
        }
        let element: AXUIElement
        switch elementResult {
        case .failure(let message):
            return .failed(message)
        case .success(let resolved):
            element = resolved
        }
        let actionName = toolCall.actionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !actionName.isEmpty else {
            return .failed("Secondary action requires action_name")
        }
        guard actionName != (kAXPressAction as String) else {
            return .unsupported("Use click for AXPress; secondary action only invokes non-press advertised actions.")
        }
        let advertisedActions = actionNames(of: element) ?? []
        guard advertisedActions.contains(actionName) else {
            let actions = advertisedActions.isEmpty ? "none" : advertisedActions.joined(separator: ", ")
            return .unsupported("Element does not advertise \(actionName) (actions: \(actions)). Run get_app_state again if the target changed.")
        }
        if let rect = rect(of: element) {
            ComputerUseCursorOverlay.shared.show(at: CGPoint(x: rect.midX, y: rect.midY), label: toolCall.label)
        }
        guard AXUIElementPerformAction(element, actionName as CFString) == .success else {
            return .failed("Could not perform \(actionName) on \(elementTargetLabel(toolCall))")
        }
        return .executed("Performed \(actionName) on \(elementTargetLabel(toolCall))")
    }

    private static func setValue(_ toolCall: ComputerUseToolCall, registry: ComputerUseElementRegistry?) -> ComputerUseExecutionResult {
        guard let elementResult = elementTarget(toolCall, registry: registry) else {
            return .failed("Stale or unknown element target")
        }
        let element: AXUIElement
        switch elementResult {
        case .failure(let message):
            return .failed(message)
        case .success(let resolved):
            element = resolved
        }
        let value = toolCall.value ?? ""
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if result == .success {
            return .executed("Set value")
        }
        return .unsupported("Element does not support direct value setting")
    }

    private static func elementTarget(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) -> ElementTargetResult? {
        if let index = toolCall.elementIndex {
            guard index > 0 else { return nil }
            guard let element = registry?.element(for: index) else {
                return .failure("Stale or unknown element_index \(index). Run get_app_state again and use an element from the fresh snapshot.")
            }
            if let mismatch = processMismatchMessage(for: element, toolCall: toolCall) {
                return .failure(mismatch)
            }
            if let mismatch = windowMismatchMessage(for: element, toolCall: toolCall) {
                return .failure(mismatch)
            }
            return .success(element)
        }
        if let elementID = toolCall.elementID?.trimmingCharacters(in: .whitespacesAndNewlines), !elementID.isEmpty {
            guard let element = registry?.element(for: elementID) else {
                return .failure("Stale or unknown element_id \(elementID). Run get_app_state again and use an element from the fresh snapshot.")
            }
            if let mismatch = processMismatchMessage(for: element, toolCall: toolCall) {
                return .failure(mismatch)
            }
            if let mismatch = windowMismatchMessage(for: element, toolCall: toolCall) {
                return .failure(mismatch)
            }
            return .success(element)
        }
        return nil
    }

    private static func processMismatchMessage(for element: AXUIElement, toolCall: ComputerUseToolCall) -> String? {
        guard let processID = toolCall.processID, processID > 0 else { return nil }
        guard let elementProcessID = Self.processID(of: element) else {
            return "Could not validate process_id \(processID) for element target. Refresh state before using this element."
        }
        guard elementProcessID == pid_t(processID) else {
            return "Stale process_id \(processID); element target pid is \(elementProcessID). Refresh state before using this element."
        }
        return nil
    }

    private static func windowMismatchMessage(for element: AXUIElement, toolCall: ComputerUseToolCall) -> String? {
        guard let requestedWindowID = toolCall.windowID, requestedWindowID > 0 else { return nil }
        guard let elementProcessID = Self.processID(of: element) else {
            return "Could not validate window_id \(requestedWindowID) for element target because the element process is unavailable. Refresh state before using this element."
        }
        guard let windowElement = containingWindow(of: element),
              let windowFrame = rect(of: windowElement) else {
            return "Could not validate window_id \(requestedWindowID) for element target because its containing window is unavailable. Refresh state before using this element."
        }
        guard let matchedWindowID = matchedWindowID(processID: elementProcessID, frame: windowFrame) else {
            return "Could not validate window_id \(requestedWindowID) for element target. Refresh state before using this element."
        }
        guard matchedWindowID == requestedWindowID else {
            return "Stale window_id \(requestedWindowID); element target is in window_id \(matchedWindowID). Refresh state before using this element."
        }
        return nil
    }

    private static func elementTargetLabel(_ toolCall: ComputerUseToolCall) -> String {
        if let label = toolCall.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if let index = toolCall.elementIndex {
            return "e\(index)"
        }
        if let elementID = toolCall.elementID?.trimmingCharacters(in: .whitespacesAndNewlines), !elementID.isEmpty {
            return elementID
        }
        return "element"
    }

    private enum TextEntryMode {
        case keyboard
        case paste

        var toolName: String {
            switch self {
            case .keyboard: "keyboard text"
            case .paste: "paste_text"
            }
        }

        var completedMessage: String {
            switch self {
            case .keyboard: "Typed text"
            case .paste: "Pasted text"
            }
        }

        var transactionPath: String {
            switch self {
            case .keyboard: "key_events_text"
            case .paste: "clipboard_paste"
            }
        }
    }

    private static func enterText(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        mode: TextEntryMode,
        allowAppActivation: Bool = true
    ) async -> ComputerUseExecutionResult {
        let targetApp = await prepareTextEntryApp(
            toolCall,
            shouldActivateNamedApp: allowAppActivation && (!toolCall.canonicalBundleID.isEmpty || toolCall.appName?.isEmpty == false)
        )
        if case let .failure(message) = targetApp {
            return .failed(message)
        }
        if case .cancelled = targetApp {
            return .cancelled()
        }
        let app = targetApp.app
        let backgroundTextEntry = !allowAppActivation

        var explicitElement: AXUIElement?
        if let elementResult = elementTarget(toolCall, registry: registry) {
            switch elementResult {
            case .failure(let message):
                return .failed(message)
            case .success(let element):
                explicitElement = element
            }
        }
        if let elementResult = await focusTextEntryElement(
            toolCall,
            registry: registry,
            allowClickFallback: allowAppActivation
        ) {
            if case let .failure(message) = elementResult {
                return .failed(message)
            }
            if case .cancelled = elementResult {
                return .cancelled()
            }
        }

        let requiredFocusedProcessID = toolCall.processID.map(pid_t.init)
        let focusedElement = focusedEditableTextTarget(
            requiredApp: app,
            requiredProcessID: requiredFocusedProcessID
        )
        let targetElement: AXUIElement?
        if let explicitElement {
            switch explicitTextTargetResolution(explicitElementIsEditable: isTextEntryTarget(explicitElement)) {
            case .failure(let message):
                return .failed(message)
            case .success:
                break
            }
            if !backgroundTextEntry {
                guard let focusedElement,
                      elementsAppearSame(explicitElement, focusedElement) else {
                    return .failed("No focused editable text target: focused element no longer matches requested text target. Refresh state before using \(mode.toolName).")
                }
            }
            targetElement = explicitElement
        } else {
            targetElement = focusedElement
        }
        guard let targetElement, isTextEntryTarget(targetElement) else {
            let target = textEntryTargetDescription(app: app, toolCall: toolCall)
            return .failed("No focused editable text target\(target). Use element_index/element_id from the latest get_window_state for the editable field, note body, web editor, or document editing area before using \(mode.toolName).")
        }
        if let mismatch = windowMismatchMessage(for: targetElement, toolCall: toolCall) {
            return .failed(mismatch)
        }

        let processID: pid_t?
        switch targetProcessID(toolCall: toolCall, app: app, element: targetElement) {
        case .success(let resolvedProcessID):
            processID = resolvedProcessID
        case .failure(let message):
            return .failed(message)
        }

        let text = toolCall.text ?? ""
        let valueBeforeAXSelectedText = axString(targetElement, kAXValueAttribute)
        if !shouldPlaceCaretBeforeBackgroundTextEntry(targetElement, backgroundTextEntry: backgroundTextEntry),
           setSelectedText(text, in: targetElement) {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch is CancellationError {
                return .cancelled()
            } catch {
                return .failed(error.localizedDescription)
            }
            if textWriteReadbackConfirms(text, beforeValue: valueBeforeAXSelectedText, in: targetElement) {
                return .executed(
                    "Inserted text via AXSelectedText",
                    transaction: ComputerUseActionTransaction(
                        path: "ax_selected_text",
                        posted: true,
                        verified: true,
                        effect: .confirmed,
                        targetStable: true,
                        processID: processID.map(Int.init),
                        windowID: toolCall.windowID,
                        elementID: toolCall.elementID,
                        elementIndex: toolCall.elementIndex,
                        requestedTextSample: textSample(text),
                        observedTextSample: textSample(text)
                    )
                )
            }
            return .failed(
                "AXSelectedText accepted the write, but AX readback did not confirm insertion. Refresh target state before retrying text entry; retrying blindly may duplicate text if the AX write already landed.",
                transaction: ComputerUseActionTransaction(
                    path: "ax_selected_text",
                    posted: true,
                    verified: false,
                    effect: .unverifiable,
                    targetStable: true,
                    processID: processID.map(Int.init),
                    windowID: toolCall.windowID,
                    elementID: toolCall.elementID,
                    elementIndex: toolCall.elementIndex,
                    requestedTextSample: textSample(text),
                    escalationHint: "Inspect the post-action screenshot/AX state before retrying; retrying blindly may duplicate text if the AX write landed but AX readback lagged.",
                    warning: "AXSelectedText accepted the write, but readback did not prove insertion."
                )
            )
        }

        if let processID,
           backgroundTextEntry,
           let windowID = toolCall.windowID,
           windowID > 0 {
            guard ComputerUseBackgroundDriver.focusWithoutRaise(
                processID: processID,
                windowID: CGWindowID(windowID)
            ) else {
                return .failed(
                    "Could not focus target window \(windowID) without raising it; text was not posted.",
                    transaction: textEntryTransaction(
                        path: mode.transactionPath,
                        posted: false,
                        text: text,
                        toolCall: toolCall,
                        processID: processID,
                        effect: .blocked,
                        targetStable: false,
                        warning: "Quiet text entry was blocked before posting because the target window could not be focused."
                    )
                )
            }
        } else if backgroundTextEntry, let processID {
            return .failed(
                "Quiet text entry requires window_id with process_id \(processID) before fallback typing or paste can be posted.",
                transaction: textEntryTransaction(
                    path: mode.transactionPath,
                    posted: false,
                    text: text,
                    toolCall: toolCall,
                    processID: processID,
                    effect: .blocked,
                    targetStable: false,
                    warning: "Quiet text entry was blocked before posting because window_id was missing."
                )
            )
        }
        if backgroundTextEntry,
           shouldPlaceCaretBeforeBackgroundTextEntry(targetElement, backgroundTextEntry: backgroundTextEntry) {
            guard let processID, processID > 0 else {
                return .failed("Background text entry for web editor surfaces requires process_id from the latest target state.")
            }
            guard let windowID = toolCall.windowID, windowID > 0 else {
                return .failed("Background text entry for web editor surfaces requires window_id from the latest target state.")
            }
            let placed = backgroundClickCenter(
                of: targetElement,
                label: toolCall.label ?? elementTargetLabel(toolCall),
                processID: processID,
                windowID: CGWindowID(windowID)
            )
            guard placed.status == .executed else {
                return placed
            }
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch is CancellationError {
                return .cancelled()
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        switch mode {
        case .keyboard:
            if (!backgroundTextEntry || explicitElement != nil),
               let failure = validateFocusedTextEntryFallbackTarget(targetElement, app: app, mode: mode) {
                return failure
            }
            PasteController.typeText(text, processID: processID)
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch is CancellationError {
                return .cancelled()
            } catch {
                return .failed(error.localizedDescription)
            }
        case .paste:
            if (!backgroundTextEntry || explicitElement != nil),
               let failure = validateFocusedTextEntryFallbackTarget(targetElement, app: app, mode: mode) {
                return failure
            }
            let pasteWasPosted = await PasteController.pasteAndWait(
                text: text,
                processID: processID,
                beforePasteAction: {
                    guard (backgroundTextEntry && explicitElement == nil)
                        || validateFocusedTextEntryFallbackTarget(targetElement, app: app, mode: mode) == nil else {
                        return false
                    }
                    return true
                }
            )
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
            } catch is CancellationError {
                return .cancelled()
            } catch {
                return .failed(error.localizedDescription)
            }
            guard pasteWasPosted else {
                return .failed(
                    "paste_text was not posted: the focused editable target changed or scoped background paste delivery failed. Refresh state and choose the editable field again.",
                    transaction: textEntryTransaction(
                        path: mode.transactionPath,
                        posted: false,
                        text: text,
                        toolCall: toolCall,
                        processID: processID,
                        effect: .blocked
                    )
                )
            }
        }
        return .executed(
            mode.completedMessage,
            transaction: textEntryTransaction(
                path: mode.transactionPath,
                posted: true,
                text: text,
                toolCall: toolCall,
                processID: processID,
                effect: .unverifiable
            )
        )
    }

    private static func textEntryTransaction(
        path: String,
        posted: Bool,
        text: String,
        toolCall: ComputerUseToolCall,
        processID: pid_t?,
        effect: ComputerUseActionEffect,
        targetStable: Bool = true,
        warning: String? = nil
    ) -> ComputerUseActionTransaction {
        ComputerUseActionTransaction(
            path: path,
            posted: posted,
            verified: false,
            effect: effect,
            targetStable: targetStable,
            processID: processID.map(Int.init),
            windowID: toolCall.windowID,
            elementID: toolCall.elementID,
            elementIndex: toolCall.elementIndex,
            requestedTextSample: textSample(text),
            escalationHint: posted
                ? "Inspect the post-action screenshot/AX state; if the text is absent, partial, or duplicated, refocus the editable target and retry paste_text."
                : "Refresh target state and choose the editable field again before retrying text entry.",
            warning: warning ?? (posted
                ? "Text input was posted, but this path cannot prove the web/editor surface consumed it."
                : "Text input was not posted.")
        )
    }

    private static func validateFocusedTextEntryFallbackTarget(
        _ targetElement: AXUIElement,
        app: NSRunningApplication?,
        mode: TextEntryMode
    ) -> ComputerUseExecutionResult? {
        guard let focusedElement = focusedEditableTextTarget(requiredApp: app) else {
            return .failed("No focused editable text target: focused element changed before \(mode.toolName) fallback posted. Refresh state and choose the editable field again.")
        }
        guard elementsAppearSame(targetElement, focusedElement) else {
            return .failed("No focused editable text target: focused element no longer matches requested text target before \(mode.toolName) fallback posted. Refresh state and choose the editable field again.")
        }
        return nil
    }

    private enum AppPreparationResult {
        case success(NSRunningApplication?)
        case failure(String)
        case cancelled

        var app: NSRunningApplication? {
            if case let .success(app) = self { return app }
            return nil
        }
    }

    private enum ElementFocusResult {
        case success
        case failure(String)
        case cancelled
    }

    private enum ElementTargetResult {
        case success(AXUIElement)
        case failure(String)
    }

    private static func prepareTextEntryApp(
        _ toolCall: ComputerUseToolCall,
        shouldActivateNamedApp: Bool
    ) async -> AppPreparationResult {
        if let processID = toolCall.processID,
           let app = runningApplication(processID: pid_t(processID)),
           !shouldActivateNamedApp {
            return .success(app)
        }

        let target = textEntryAppName(toolCall)
        guard !target.isEmpty else {
            if let processID = toolCall.processID {
                return .success(runningApplication(processID: pid_t(processID)))
            }
            return .success(nil)
        }

        if !shouldActivateNamedApp {
            if let app = runningApplication(named: target) {
                return .success(app)
            }
            let launchResult = await openApp(named: target, allowActivation: false)
            if launchResult.status == .cancelled {
                return .cancelled
            }
            guard launchResult.status == .executed else {
                return .failure(launchResult.message)
            }
            return .success(runningApplication(named: target))
        }

        let focusResult = await focusApp(named: target)
        if focusResult.status == .cancelled {
            return .cancelled
        }
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
        registry: ComputerUseElementRegistry?,
        allowClickFallback: Bool
    ) async -> ElementFocusResult? {
        let element: AXUIElement?
        if let index = toolCall.elementIndex, index > 0 {
            guard let resolved = registry?.element(for: index) else {
                return .failure("Stale or unknown element_index \(index). Run get_app_state again and use an element from the fresh snapshot.")
            }
            element = resolved
        } else if let elementID = toolCall.elementID, !elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = registry?.element(for: elementID) else {
                return .failure("Stale or unknown element_id \(elementID). Run get_app_state again and use an element from the fresh snapshot.")
            }
            element = resolved
        } else {
            element = nil
        }
        guard let element else { return nil }

        return await focusElement(element, label: toolCall.label, allowClickFallback: allowClickFallback)
    }

    private static func focusElement(_ element: AXUIElement, label: String?, allowClickFallback: Bool) async -> ElementFocusResult {
        let targetProcessID = processID(of: element)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        if let rect = rect(of: element) {
            ComputerUseCursorOverlay.shared.show(at: CGPoint(x: rect.midX, y: rect.midY), label: label)
        }
        if allowClickFallback, isTextEntryTarget(element) {
            _ = clickCenter(of: element)
        }
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error.localizedDescription)
        }
        guard let targetProcessID else {
            return .failure("Could not validate focused element process after focus attempt.")
        }
        guard let focusedElement = focusedUIElement(requiredApp: nil),
              let focusedProcessID = processID(of: focusedElement) else {
            return .failure("Focus did not move to an accessible element after focus attempt.")
        }
        guard focusedProcessID == targetProcessID else {
            return .failure("Focus moved to process \(focusedProcessID), not intended process \(targetProcessID). Refresh state before typing.")
        }
        guard elementsAppearSame(element, focusedElement) else {
            return .failure("Focus moved within the target process, but not to the intended element. Refresh state before typing.")
        }
        return .success
    }

    private static func clickElement(
        _ element: AXUIElement,
        fallbackLabel: String,
        allowPointerFallback: Bool = true,
        backgroundProcessID: pid_t? = nil,
        backgroundWindowID: CGWindowID? = nil,
        button: ComputerUseClickDriver.Button = .left,
        clicks: Int = 1
    ) -> ComputerUseExecutionResult {
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
            guard backgroundProcessID != nil || allowPointerFallback else {
                let actions = advertisedActions.isEmpty ? "none" : advertisedActions.joined(separator: ", ")
                return .needsConfirmation("\(fallbackLabel) needs an element-center click because it does not advertise AXPress (actions: \(actions)). In Work quietly mode include nonzero process_id/window_id from the latest target snapshot.")
            }
        }

        return ComputerUseClickDriver.clickElement(
            element,
            label: fallbackLabel,
            processID: backgroundProcessID,
            windowID: backgroundWindowID,
            button: button,
            clicks: clicks,
            allowGlobalHID: allowPointerFallback
        )
    }

    private static func backgroundClickCenter(
        of element: AXUIElement,
        label: String,
        processID: pid_t?,
        windowID: CGWindowID?
    ) -> ComputerUseExecutionResult {
        guard let processID, processID > 0 else {
            return .failed("Background element-center click for \(label) requires nonzero process_id from the latest target snapshot.")
        }
        guard let windowID, windowID > 0 else {
            return .failed("Background element-center click for \(label) requires nonzero window_id from the latest target snapshot.")
        }
        guard let rect = rect(of: element) else {
            return .failed("Could not resolve \(label) frame for background element click.")
        }
        return ComputerUseClickDriver.clickPoint(
            ComputerUseClickDriver.PointRequest(
                point: CGPoint(x: rect.midX, y: rect.midY),
                label: label,
                processID: processID,
                windowID: windowID,
                button: .left,
                clicks: 1,
                allowGlobalHID: false
            ),
            preferredBackgroundRoute: .elementCenterSkyLight,
            reason: "caret placement or element-center fallback"
        )
    }

    private static func clickPoint(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        backgroundProcessID: pid_t? = nil,
        backgroundWindowID: CGWindowID? = nil
    ) -> ComputerUseExecutionResult {
        let point: CGPoint
        switch screenPoint(for: toolCall, registry: registry) {
        case .success(let resolvedPoint):
            point = resolvedPoint
        case .failure(let message):
            return .failed(message)
        }
        return ComputerUseClickDriver.clickPoint(ComputerUseClickDriver.PointRequest(
            point: point,
            label: toolCall.label,
            processID: backgroundProcessID,
            windowID: backgroundWindowID,
            button: clickButton(from: toolCall.button),
            clicks: toolCall.clicks ?? 1,
            allowGlobalHID: backgroundProcessID == nil
        ))
    }

    private static func moveCursor(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?,
        allowCursorWarp: Bool
    ) -> ComputerUseExecutionResult {
        let point: CGPoint
        switch screenPoint(for: toolCall, registry: registry) {
        case .success(let resolvedPoint):
            point = resolvedPoint
        case .failure(let message):
            return .failed(message)
        }
        if allowCursorWarp {
            CGWarpMouseCursorPosition(point)
        }
        ComputerUseCursorOverlay.shared.show(at: point, label: toolCall.label)
        if allowCursorWarp {
            return .executed("Moved cursor to \(Int(point.x.rounded())),\(Int(point.y.rounded()))")
        }
        return .executed("Showed target cursor overlay without moving the system cursor")
    }

    private static func drag(
        _ toolCall: ComputerUseToolCall,
        registry: ComputerUseElementRegistry?
    ) -> ComputerUseExecutionResult {
        let start: CGPoint
        let end: CGPoint
        switch screenPoint(for: toolCall, registry: registry) {
        case .success(let resolvedStart):
            start = resolvedStart
        case .failure(let message):
            return .failed(message)
        }
        switch screenPoint(
            x: toolCall.toX,
            y: toolCall.toY,
            screenshotID: toolCall.screenshotID,
            registry: registry
        ) {
        case .success(let resolvedEnd):
            end = resolvedEnd
        case .failure(let message):
            return .failed(message)
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

    private static func applicationURL(for appName: String) async throws -> URL? {
        try Task.checkCancellation()
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

        let lookupTask = Task.detached(priority: .userInitiated) {
            try findApplicationURL(canonicalName: canonical)
        }
        return try await withTaskCancellationHandler {
            try await lookupTask.value
        } onCancel: {
            lookupTask.cancel()
        }
    }

    nonisolated private static func findApplicationURL(canonicalName: String) throws -> URL? {
        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
        ]
        var checkedURLs = 0
        for root in searchRoots {
            try Task.checkCancellation()
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                checkedURLs += 1
                if checkedURLs.isMultiple(of: 25) {
                    try Task.checkCancellation()
                }
                if applicationNames(for: url).contains(canonicalName) {
                    return url
                }
            }
        }
        return nil
    }

    nonisolated private static func applicationNames(for appURL: URL) -> Set<String> {
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

    private static func runningApplication(processID: pid_t) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == processID }
    }

    private static func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws -> NSRunningApplication {
        let continuationBox = OpenApplicationContinuationBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard continuationBox.set(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    if let error {
                        continuationBox.resume(throwing: error)
                    } else if let app {
                        continuationBox.resume(returning: app)
                    } else {
                        continuationBox.resume(throwing: CocoaError(.fileNoSuchFile))
                    }
                }
            }
        } onCancel: {
            continuationBox.cancel()
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

    private static func restoreFrontmostApp(
        _ priorFrontmost: NSRunningApplication?,
        ifTargetSelfActivated target: NSRunningApplication
    ) async {
        guard let priorFrontmost,
              priorFrontmost.processIdentifier != target.processIdentifier,
              !priorFrontmost.isTerminated
        else { return }

        for delay in [80_000_000, 250_000_000, 500_000_000] as [UInt64] {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            if target.isActive {
                priorFrontmost.activate(options: [])
            }
        }
    }

    private static func withFrontmostPreserved(
        enabled: Bool,
        operation: () async -> ComputerUseExecutionResult
    ) async -> ComputerUseExecutionResult {
        guard enabled else {
            return await operation()
        }
        let priorFrontmost = NSWorkspace.shared.frontmostApplication
        let result = await operation()
        await restoreFrontmostAfterPotentialSteal(priorFrontmost)
        return result
    }

    private static func restoreFrontmostAfterPotentialSteal(_ priorFrontmost: NSRunningApplication?) async {
        guard let priorFrontmost,
              !priorFrontmost.isTerminated
        else { return }
        for delay in [0, 80_000_000, 250_000_000] as [UInt64] {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            priorFrontmost.activate(options: [])
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

    private static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        if let directWindow = axElement(element, kAXWindowAttribute) {
            return directWindow
        }
        var current = element
        for _ in 0..<12 {
            if axString(current, kAXRoleAttribute) == (kAXWindowRole as String) {
                return current
            }
            guard let parent = axElement(current, kAXParentAttribute) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
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

    private static func focusedUIElement(requiredApp: NSRunningApplication?, requiredProcessID: pid_t? = nil) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let rawElement = value,
              CFGetTypeID(rawElement) == AXUIElementGetTypeID()
        else { return nil }

        let element = rawElement as! AXUIElement
        if let requiredProcessID {
            guard processID(of: element) == requiredProcessID else {
                return nil
            }
        }
        if let requiredApp {
            guard processID(of: element) == requiredApp.processIdentifier else {
                return nil
            }
        }
        return element
    }

    private static func focusedEditableTextTarget(
        requiredApp: NSRunningApplication?,
        requiredProcessID: pid_t? = nil
    ) -> AXUIElement? {
        guard let element = focusedUIElement(requiredApp: requiredApp, requiredProcessID: requiredProcessID) else { return nil }
        return isTextEntryTarget(element) ? element : nil
    }

    private static func elementsAppearSame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) {
            return true
        }
        guard processID(of: lhs) == processID(of: rhs),
              axString(lhs, kAXRoleAttribute) == axString(rhs, kAXRoleAttribute)
        else { return false }
        switch (rect(of: lhs), rect(of: rhs)) {
        case let (.some(lhsRect), .some(rhsRect)):
            return abs(lhsRect.origin.x - rhsRect.origin.x) < 1
                && abs(lhsRect.origin.y - rhsRect.origin.y) < 1
                && abs(lhsRect.size.width - rhsRect.size.width) < 1
                && abs(lhsRect.size.height - rhsRect.size.height) < 1
        default:
            return false
        }
    }

    private static func isTextEntryTarget(_ element: AXUIElement) -> Bool {
        isEditableTextElement(element) || isWebEditorSurface(element)
    }

    enum ExplicitTextTargetResolution: Equatable {
        case success
        case failure(String)
    }

    static func explicitTextTargetResolutionForTests(explicitElementIsEditable: Bool) -> ExplicitTextTargetResolution {
        explicitTextTargetResolution(explicitElementIsEditable: explicitElementIsEditable)
    }

    private static func explicitTextTargetResolution(explicitElementIsEditable: Bool) -> ExplicitTextTargetResolution {
        guard explicitElementIsEditable else {
            return .failure("No focused editable text target: requested element is not an editable text target. Refresh state and choose an editable field before using text entry.")
        }
        return .success
    }

    private static func shouldPlaceCaretBeforeBackgroundTextEntry(
        _ element: AXUIElement,
        backgroundTextEntry: Bool
    ) -> Bool {
        guard backgroundTextEntry else { return false }
        let role = axString(element, kAXRoleAttribute)
        if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String || role == kAXComboBoxRole as String {
            return false
        }
        return role == "AXWebArea" || role == "AXGroup" || isWebEditorSurface(element)
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

    private static func isWebEditorSurface(_ element: AXUIElement) -> Bool {
        let role = axString(element, kAXRoleAttribute)
        guard role == "AXWebArea" else { return false }
        let combined = [
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXHelpAttribute),
        ].joined(separator: " ").lowercased()
        let editorTerms = [
            "editing area",
            "document editing",
            "google docs",
            "editor",
            "editable",
            "text area",
            "textbox",
        ]
        return editorTerms.contains { combined.contains($0) }
    }

    private static func setSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        guard !text.isEmpty else { return true }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private static func textWriteReadbackConfirms(
        _ text: String,
        beforeValue: String,
        in element: AXUIElement
    ) -> Bool {
        let value = axString(element, kAXValueAttribute)
        let selectedText = axString(element, kAXSelectedTextAttribute)
        if textSample(text).map({ containsNormalizedText(value, sample: $0) || containsNormalizedText(selectedText, sample: $0) }) == true {
            return true
        }
        return !value.isEmpty && value != beforeValue
    }

    private static func textSample(_ text: String) -> String? {
        let tokens = ComputerUseElementCandidate.normalizedText(text)
            .split(separator: " ")
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(16).joined(separator: " ")
    }

    private static func containsNormalizedText(_ haystack: String, sample: String) -> Bool {
        ComputerUseElementCandidate.normalizedText(haystack).contains(sample)
    }

    private static func targetProcessID(
        toolCall: ComputerUseToolCall,
        app: NSRunningApplication?,
        element: AXUIElement?
    ) -> ProcessTargetResolution {
        if let processID = toolCall.processID, processID > 0 {
            let suppliedProcessID = pid_t(processID)
            if let app, app.processIdentifier != suppliedProcessID {
                return .failure("Stale process_id \(processID); current target app pid is \(app.processIdentifier). Refresh state before sending text or key events.")
            }
            if let element,
               let elementProcessID = Self.processID(of: element),
               elementProcessID != suppliedProcessID {
                return .failure("Stale process_id \(processID); target element pid is \(elementProcessID). Refresh state before sending text or key events.")
            }
            if app == nil, element == nil {
                guard let focusedProcessID = currentFocusedProcessID() else {
                    return .failure("Could not validate process_id \(processID). Refresh state before sending text or key events.")
                }
                if focusedProcessID != suppliedProcessID {
                    return .failure("Stale process_id \(processID); focused element pid is \(focusedProcessID). Refresh state before sending text or key events.")
                }
            }
            return .success(suppliedProcessID)
        }
        if let app {
            return .success(app.processIdentifier)
        }
        if let element {
            return .success(processID(of: element))
        }
        return .success(nil)
    }

    private enum ProcessTargetResolution {
        case success(pid_t?)
        case failure(String)
    }

    private static func postKeyEvent(
        _ event: CGEvent?,
        processID: pid_t?,
        attachAuthMessage: Bool = true
    ) -> Bool {
        guard let event else { return false }
        if let processID, processID > 0 {
            return ComputerUseBackgroundDriver.postKeyEvent(
                event,
                to: processID,
                attachAuthMessage: attachAuthMessage
            )
        } else {
            event.post(tap: .cghidEventTap)
            return true
        }
    }

    private static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private static func currentFocusedProcessID() -> pid_t? {
        focusedUIElement(requiredApp: nil).flatMap { processID(of: $0) }
    }

    private static func focusedAppHintMismatchMessage(_ toolCall: ComputerUseToolCall) -> String? {
        let targetName = textEntryAppName(toolCall)
        guard !targetName.isEmpty else { return nil }
        guard let focusedProcessID = currentFocusedProcessID(),
              let focusedApp = runningApplication(processID: focusedProcessID) else {
            return "Could not validate app target against current keyboard focus. Refresh state before pressing keys."
        }
        let expectedBundleID = toolCall.canonicalBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expectedBundleID.isEmpty,
           focusedApp.bundleIdentifier != expectedBundleID {
            return "App target \(expectedBundleID) does not match current keyboard focus \(focusedApp.bundleIdentifier ?? "unknown"). Refresh state before pressing keys."
        }
        if toolCall.canonicalBundleID.isEmpty,
           let appName = toolCall.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty,
           canonicalAppName(focusedApp.localizedName ?? "") != canonicalAppName(appName) {
            return "App target \(appName) does not match current keyboard focus \(focusedApp.localizedName ?? "unknown"). Refresh state before pressing keys."
        }
        return nil
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

    private static func focusedElementLabel(_ element: AXUIElement, fallback: String?) -> String {
        for candidate in [
            fallback,
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXHelpAttribute),
            axString(element, kAXRoleAttribute),
        ] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return boundedActionLabel(trimmed)
            }
        }
        return "element"
    }

    private static func boundedActionLabel(_ label: String) -> String {
        let compact = label
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard compact.count > 120 else { return compact }
        return "\(compact.prefix(117))..."
    }

    private static func isLowInformationActionLabel(_ text: String) -> Bool {
        let canonical = canonicalLabel(text)
        return canonical.isEmpty
            || canonical == "element"
            || canonical == "button"
            || canonical == "axbutton"
            || canonical == "default button"
            || canonical == "axdefaultbutton"
            || canonical == "group"
            || canonical == "axgroup"
            || canonical == "menu item"
            || canonical == "axmenuitem"
            || canonical == "unknown"
            || canonical == "axunknown"
    }

    private static func isRiskyActionLabel(_ text: String) -> Bool {
        let riskyWords: Set<String> = [
            "archive",
            "allow",
            "approve",
            "accept",
            "authorize",
            "buy",
            "cancel",
            "checkout",
            "close",
            "confirm",
            "continue",
            "delete",
            "don",
            "discard",
            "enable",
            "erase",
            "grant",
            "install",
            "ok",
            "overwrite",
            "pay",
            "proceed",
            "purchase",
            "quit",
            "remove",
            "replace",
            "reset",
            "save",
            "send",
            "stop",
            "submit",
            "transfer",
            "unsubscribe",
            "yes",
        ]
        let words = Set(canonicalLabel(text).split(separator: " ").map(String.init))
        return !riskyWords.isDisjoint(with: words)
    }

    private static func requiresActivateFocusedConfirmation(
        element: AXUIElement,
        label: String,
        actionContext: String
    ) -> Bool {
        if isRiskyActionLabel(actionContext) || isLowInformationActionLabel(label) {
            return true
        }
        guard isDefaultDialogAction(element) else { return false }
        return !isClearlySafeActionLabel(label)
    }

    private static func isDefaultDialogAction(_ element: AXUIElement) -> Bool {
        let role = canonicalLabel(axString(element, kAXRoleAttribute))
        let subrole = canonicalLabel(axString(element, kAXSubroleAttribute))
        return role == "axdefaultbutton"
            || subrole == "axdefaultbutton"
            || subrole == "default button"
            || subrole == "axdialog"
    }

    private static func isClearlySafeActionLabel(_ text: String) -> Bool {
        let safeLabels: Set<String> = [
            "back",
            "collapse",
            "copy",
            "expand",
            "find",
            "next",
            "pause",
            "play",
            "previous",
            "search",
            "show",
            "view",
        ]
        let canonical = canonicalLabel(text)
        return safeLabels.contains(canonical)
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
    ) -> ScreenPointResolution {
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
    ) -> ScreenPointResolution {
        guard let x, let y else {
            return .failure("Screenshot coordinate action requires x and y from the latest screenshot")
        }
        guard let screenshot = registry?.currentScreenshot() else {
            return .failure("No current screenshot for coordinate action")
        }
        if let screenshotID, screenshotID != screenshot.screenshotID {
            return .failure("Stale screenshot_id \(screenshotID); latest screenshot is \(screenshot.screenshotID). Use coordinates from the latest state.")
        }
        let window = screenshot.windowFrame
        return .success(CGPoint(
            x: window.x + (x / max(screenshot.scaleX, 0.0001)),
            y: window.y + (y / max(screenshot.scaleY, 0.0001))
        ))
    }

    private enum ScreenPointResolution {
        case success(CGPoint)
        case failure(String)
    }

    private static func clickButton(from rawValue: String?) -> ComputerUseClickDriver.Button {
        let value = canonicalLabel(rawValue ?? "")
        return value == "right" || value == "secondary" ? .right : .left
    }

    private static func currentCursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
    }

    private static func cleanedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func canonicalAppName(_ value: String) -> String {
        canonicalLabel(value)
            .replacingOccurrences(of: #" app$"#, with: "", options: .regularExpression)
    }

    private static func canonicalKeyName(_ value: String) -> String {
        canonicalLabel(value)
            .replacingOccurrences(of: "arrow key", with: "arrow")
    }

    nonisolated private static func canonicalLabel(_ value: String) -> String {
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

private final class OpenApplicationContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSRunningApplication, Error>?
    private var cancelled = false

    func set(_ continuation: CheckedContinuation<NSRunningApplication, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.continuation = continuation
        return true
    }

    func cancel() {
        let continuationToResume: CheckedContinuation<NSRunningApplication, Error>?
        lock.lock()
        cancelled = true
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(throwing: CancellationError())
    }

    func resume(returning app: NSRunningApplication) {
        let continuationToResume: CheckedContinuation<NSRunningApplication, Error>?
        lock.lock()
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(returning: app)
    }

    func resume(throwing error: Error) {
        let continuationToResume: CheckedContinuation<NSRunningApplication, Error>?
        lock.lock()
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(throwing: error)
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

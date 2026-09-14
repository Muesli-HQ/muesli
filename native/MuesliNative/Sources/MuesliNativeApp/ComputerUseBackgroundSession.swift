import AppKit
import ApplicationServices

/// One run owns one window. This executor never calls foreground mutation helpers.
@MainActor
final class ComputerUseBackgroundSession {
    static let plannerInstructions = """
    BACKGROUND MODE: operate only the acquired window. launch_app/get_app_state without a window_id creates a separate Chrome window; other apps require an explicit window_id from list_windows. Never substitute the user's focused window. Browser tools use only the acquired Chrome window; window_index 1 is a logical slot for that window, never the browser's front window. Prefer exact AX element actions and set_value/AX text; raw Chromium keys, modified keys, drag and global cursor movement are unavailable. A dispatched event is not verified success: inspect the next snapshot. If a route is refused, choose another supported route or fail honestly. No shell tool is available.
    """

    private(set) var target: ComputerUseBackgroundTarget?
    private var browserWindowID: Int?
    private var lastEditable: AXUIElement?
    private let focus = ComputerUseBackgroundFocusGuard()
    private var busy = false
    private var attemptedBrowserAcquisition = false
    private var stoppedForFocus = false
    private static var leasedProcesses = Set<pid_t>()

    init(target: ComputerUseBackgroundTarget? = nil) { self.target = target }

    func observe(registry: ComputerUseElementRegistry, screenshot: Bool) -> ComputerUseObservation {
        ComputerUseObservationCapture.captureBackground(registry: registry, includeScreenshot: screenshot, target: target)
    }

    func end() { focus.end(); lastEditable = nil }

    func execute(_ call: ComputerUseToolCall, registry: ComputerUseElementRegistry) async -> ComputerUseExecutionResult {
        guard !Task.isCancelled else { return .cancelled() }
        if let failure = call.validationFailure() { return .unsupported(failure) }
        if call.requiresConfirmation { return .needsConfirmation("Confirm: \(call.summary)") }
        guard !stoppedForFocus else { return .failed("Background run stopped after a focus transition. Start a new run after checking the target.") }
        guard !busy else { return .unsupported("A background action is already in progress") }
        if call.tool == .listApps || call.tool == .listWindows {
            return await ComputerUseToolExecutor.execute(call, registry: registry)
        }
        let requestedBundle = resolvedBundle(call)
        let acquiring = [.launchApp, .getAppState, .getWindowState].contains(call.tool)
        if let target {
            guard target.accepts(processID: call.processID, windowID: call.windowID, bundleID: requestedBundle) else {
                return .unsupported("Action addresses a different process/window than this run owns")
            }
            guard ComputerUseWindowIdentity.resolve(target) != nil else {
                registry.clear()
                return .failed("Acquired window closed or AX is unavailable; no sibling window was substituted")
            }
        } else if !acquiring {
            return .unsupported("No acquired background window. Call launch_app or get_app_state first")
        }
        guard AXIsProcessTrusted() else { return .unsupported("Accessibility permission is required for background CUA") }
        let bundle = target?.bundleID ?? requestedBundle
        guard !bundle.isEmpty else { return .unsupported("Specify the target app to acquire a background window") }
        let pid = target?.processID ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
        if let pid, !Self.leasedProcesses.insert(pid).inserted { return .unsupported("Another background action owns this process") }
        busy = true
        focus.begin(bundleID: bundle)
        defer {
            focus.end()
            busy = false
            if let pid { Self.leasedProcesses.remove(pid) }
        }
        let result: ComputerUseExecutionResult
        if acquiring {
            result = await acquire(call, bundle: bundle)
        } else if let target {
            result = await dispatch(call, registry: registry, target: target)
        } else {
            result = .failed("Background target unavailable")
        }
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return .cancelled() }
        focus.checkWindowFocus()
        if focus.focusChanged {
            stoppedForFocus = true
            return .failed("Focus changed during background action; further actions stopped. App restoration is attempted only without intervening user input; inspect the active window before retrying. Action result: \(result.message). Focus evidence: \(focus.diagnostics.joined(separator: "; "))")
        }
        if !focus.diagnostics.isEmpty {
            return ComputerUseExecutionResult(status: result.status, message: result.message + "\nFocus: " + focus.diagnostics.joined(separator: "; "))
        }
        return result
    }

    private func resolvedBundle(_ call: ComputerUseToolCall) -> String {
        if !call.canonicalBundleID.isEmpty { return call.canonicalBundleID }
        if let name = call.appName, !name.isEmpty {
            return ComputerUseExecutor.bundleIdentifierAlias(for: name) ??
                NSWorkspace.shared.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }?.bundleIdentifier ?? name
        }
        return ""
    }

    private func acquire(_ call: ComputerUseToolCall, bundle: String) async -> ComputerUseExecutionResult {
        if let target { return .executed("Using acquired window \(target.windowID) in process \(target.processID)") }
        // Keep initial acquisition deterministic: launching an arbitrary native app
        // can create/activate windows in app-specific ways. Open it first, then use
        // list_windows and an explicit ID. Chrome gets a new isolated window below.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            return .unsupported("\(bundle) must be running before background acquisition; open it and retry")
        }
        if let pid = call.processID, pid != Int(app.processIdentifier) { return .unsupported("Requested process does not match the app") }
        let readiness = bundle == "com.google.Chrome" ? ComputerUseWindowIdentity.enableChromeAccessibility(pid: app.processIdentifier) : nil
        var windows = ComputerUseWindowIdentity.windows(pid: app.processIdentifier)
        if bundle == "com.google.Chrome" {
            for _ in 0..<4 where windows.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return .cancelled() }
                windows = ComputerUseWindowIdentity.windows(pid: app.processIdentifier)
            }
        }
        if let id = call.windowID {
            guard let windowID = CGWindowID(exactly: id), windowID != 0 else { return .unsupported("Invalid window_id") }
            let candidate = ComputerUseBackgroundTarget(processID: app.processIdentifier, windowID: windowID, bundleID: bundle)
            guard let window = ComputerUseWindowIdentity.resolve(candidate) else { return .failed("Explicit window is unavailable or belongs to another process") }
            // Browser scripts need a independently mapped browser window identity;
            // AX-only operation is still available on an explicit native window.
            target = ComputerUseBackgroundTarget(processID: candidate.processID, windowID: candidate.windowID, bundleID: bundle, retainedWindow: window)
            return .executed("Acquired explicit window \(windowID); browser-script navigation is unavailable for an unmapped window")
        }
        guard bundle == "com.google.Chrome" else { return .unsupported("Use list_windows and get_app_state with an explicit window_id for this app") }
        guard !attemptedBrowserAcquisition else { return .failed("Browser acquisition already failed in this run; inspect the created window before retrying in a new run") }
        attemptedBrowserAcquisition = true
        guard !windows.isEmpty else {
            return .failed("Chrome exposes no AX window handles (list, focused, or main). No window was created. Check Chrome accessibility before retrying. \(readiness?.diagnostic ?? ""). \(ComputerUseWindowIdentity.lastWindowDiagnostics)")
        }
        let before = Set(windows.compactMap { ComputerUseWindowIdentity.windowID(of: $0) })
        let nonce = "Muesli-CUA-" + UUID().uuidString
        do {
            let result = try await ComputerUseBrowserAutomation.runAppleScript("""
            with timeout of 8 seconds
              tell application id "com.google.Chrome"
                set ownedWindow to make new window
                set URL of active tab of ownedWindow to "data:text/html,<title>\(nonce)</title>"
                return id of ownedWindow as text
              end tell
            end timeout
            """)
            guard let scriptID = Int(result.trimmingCharacters(in: .whitespacesAndNewlines)), scriptID > 0 else { return .failed("Browser did not return a window identity") }
            // Observe only the unique new AX window. Never infer identity by title,
            // frontmost state, or the first window returned by the browser.
            for _ in 0..<32 {
                try Task.checkCancellation()
                let added = ComputerUseWindowIdentity.windows(pid: app.processIdentifier).filter {
                    ComputerUseObservationCapture.axString($0, kAXTitleAttribute).contains(nonce)
                }.compactMap { ComputerUseWindowIdentity.windowID(of: $0) }.filter { !before.contains($0) }
                if added.count > 1 { return .failed("Multiple windows appeared during acquisition; refusing ambiguous ownership") }
                if let id = added.first {
                    let candidate = ComputerUseBackgroundTarget(processID: app.processIdentifier, windowID: id, bundleID: bundle)
                    if let window = ComputerUseWindowIdentity.resolve(candidate) {
                        target = ComputerUseBackgroundTarget(processID: candidate.processID, windowID: id, bundleID: bundle, retainedWindow: window)
                        browserWindowID = scriptID
                        return .executed("Acquired separate Chrome window \(id), process \(app.processIdentifier). \(readiness?.diagnostic ?? ""). \(ComputerUseWindowIdentity.lastWindowDiagnostics)")
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            return .failed("New Chrome window has no live AX identity. It was left open; no existing window was adopted")
        } catch is CancellationError { return .cancelled() }
        catch { return .failed("Background acquisition failed: \(error.localizedDescription)") }
    }

    private func dispatch(_ call: ComputerUseToolCall, registry: ComputerUseElementRegistry, target: ComputerUseBackgroundTarget) async -> ComputerUseExecutionResult {
        guard registry.backgroundTarget == target else { return .unsupported("Refresh the acquired window before acting; snapshot identity is stale") }
        switch call.tool {
        case .navigateURL, .navigateActiveBrowserTab, .openNewBrowserTab, .activateBrowserTab, .listBrowserTabs:
            return await browserAction(call, target: target)
        case .click, .clickElement, .clickPoint, .performSecondaryAction, .setValue, .typeText, .pasteText, .scroll:
            return elementOrPointerAction(call, registry: registry, target: target)
        case .pressKey, .hotkey:
            return ComputerUseBackgroundInput.key(call, target: target)
        default:
            return .unsupported("\(call.tool.rawValue) has no acquired-window background route in this increment")
        }
    }

    private func browserAction(_ call: ComputerUseToolCall, target: ComputerUseBackgroundTarget) async -> ComputerUseExecutionResult {
        guard let scriptID = browserWindowID, target.bundleID == "com.google.Chrome", call.windowIndex == nil || call.windowIndex == 1 else {
            return .unsupported("Browser tools require this run's newly acquired Chrome window (logical window_index 1)")
        }
        let body: String
        switch call.tool {
        case .navigateURL, .navigateActiveBrowserTab:
            guard call.tabIndex == nil,
                  let url = ComputerUseToolInvocation.safeHTTPURL(call.url ?? "") else { return .unsupported("Use an HTTP(S) URL in the acquired window's active tab") }
            body = "set URL of active tab of ownedWindow to \"\(ComputerUseBrowserAutomation.appleScriptString(url.absoluteString))\""
        case .openNewBrowserTab:
            body = "tell ownedWindow to make new tab\nset active tab index of ownedWindow to count of tabs of ownedWindow"
        case .activateBrowserTab:
            guard let index = call.tabIndex, index > 0 else { return .unsupported("A positive tab_index is required") }
            body = "if \(index) > count of tabs of ownedWindow then error \"Tab no longer exists\"\nset active tab index of ownedWindow to \(index)"
        case .listBrowserTabs:
            body = "set output to \"\"\nrepeat with t from 1 to count of tabs of ownedWindow\nset output to output & \"1:\" & t & tab & title of tab t of ownedWindow & tab & URL of tab t of ownedWindow & linefeed\nend repeat\nreturn output"
        default: return .unsupported("Unsupported scoped browser action")
        }
        do {
            let output = try await ComputerUseBrowserAutomation.runAppleScript(Self.browserScript(windowID: scriptID, body: body))
            return .executed(call.tool == .listBrowserTabs ? output : "Dispatched action to acquired browser window; verify the next snapshot")
        } catch is CancellationError { return .cancelled() }
        catch { return .failed("Scoped navigation failed: \(error.localizedDescription)") }
    }

    static func browserScript(windowID: Int, body: String) -> String {
        """
        with timeout of 8 seconds
          tell application id "com.google.Chrome"
            set ownedWindow to first window whose id is \(windowID)
            \(body)
          end tell
        end timeout
        """
    }

    private func elementOrPointerAction(_ call: ComputerUseToolCall, registry: ComputerUseElementRegistry, target: ComputerUseBackgroundTarget) -> ComputerUseExecutionResult {
        var element: AXUIElement?
        if let index = call.elementIndex { element = registry.element(for: index) }
        else if let id = call.elementID { element = registry.element(for: id) }
        else if call.tool == .typeText || call.tool == .pasteText { element = lastEditable }
        if call.elementIndex != nil || call.elementID != nil {
            guard element != nil else { return .unsupported("Stale or unknown element; refresh the target snapshot") }
        }
        if let element {
            guard ComputerUseWindowIdentity.contains(element, target: target) else { return .unsupported("Element is not in the acquired window") }
            let role = ComputerUseObservationCapture.axString(element, kAXRoleAttribute)
            let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
            switch call.tool {
            case .setValue, .typeText, .pasteText:
                guard editable else { return .unsupported("An exact editable AX element is required") }
                let replacement = call.tool == .setValue
                let text = replacement ? call.value ?? "" : call.text ?? ""
                let attribute = replacement ? kAXValueAttribute : kAXSelectedTextAttribute
                guard AXUIElementSetAttributeValue(element, attribute as CFString, text as CFString) == .success else {
                    return .unsupported("Target does not support \(attribute); no global typing or paste was attempted")
                }
                lastEditable = element
                if replacement, ComputerUseObservationCapture.axString(element, kAXValueAttribute) != text {
                    return .failed("AXValue write returned success but target readback did not match")
                }
                return .executed(replacement ? "Verified target AXValue; this does not guarantee web input events fired" : "AXSelectedText accepted; verify insertion in the next snapshot")
            case .click, .clickElement, .performSecondaryAction:
                if editable { lastEditable = element }
                let action = call.tool == .performSecondaryAction ? call.actionName ?? kAXShowMenuAction : kAXPressAction
                guard [kAXPressAction, kAXShowMenuAction, kAXConfirmAction].contains(action) else { return .unsupported("Background AX action not supported") }
                if AXUIElementPerformAction(element, action as CFString) == .success { return .executed("Dispatched \(action) on acquired-window element; verify effect") }
                guard call.tool != .performSecondaryAction, let frame = ComputerUseObservationCapture.rect(element) else { return .unsupported("AX action failed and no scoped pointer route is available") }
                return ComputerUseBackgroundInput.click(point: CGPoint(x: frame.midX, y: frame.midY), target: target,
                                                        right: call.button == "right", count: call.clicks ?? 1)
            case .scroll:
                guard let frame = ComputerUseObservationCapture.rect(element) else { return .unsupported("Scroll target has no frame") }
                return ComputerUseBackgroundInput.scroll(point: CGPoint(x: frame.midX, y: frame.midY), target: target,
                                                         direction: call.direction ?? .down, pages: call.pages ?? 1)
            default: break
            }
        }
        guard call.tool == .click || call.tool == .clickPoint || call.tool == .scroll,
              let screenshot = registry.currentScreenshot(), call.screenshotID == screenshot.screenshotID,
              let frame = ComputerUseWindowIdentity.frame(target), ComputerUseRect(frame) == screenshot.windowFrame,
              let x = call.x, let y = call.y, x.isFinite, y.isFinite,
              x >= 0, y >= 0, x < Double(screenshot.width), y < Double(screenshot.height) else {
            return .unsupported("Use an exact element or coordinates from the current acquired-window screenshot")
        }
        let point = CGPoint(x: frame.minX + x / screenshot.scaleX, y: frame.minY + y / screenshot.scaleY)
        if call.tool == .scroll {
            return ComputerUseBackgroundInput.scroll(point: point, target: target, direction: call.direction ?? .down, pages: call.pages ?? 1)
        }
        return ComputerUseBackgroundInput.click(point: point, target: target, right: call.button == "right", count: call.clicks ?? 1)
    }
}

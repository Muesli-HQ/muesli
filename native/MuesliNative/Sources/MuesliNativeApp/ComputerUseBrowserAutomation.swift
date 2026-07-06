import AppKit
import ApplicationServices
import Foundation

enum ComputerUseBrowserAutomation {
    static var runAppleScriptForTests: ((String) throws -> String)?
    static var runBackgroundCommandForTests: ((BackgroundBrowserCommand) async -> ComputerUseExecutionResult)?

    enum BackgroundBrowserCommand: Equatable {
        case openNewTab(processID: Int, windowID: Int?)
        case navigate(url: String, processID: Int, windowID: Int?)
    }

    static func listTabs(appBundleID: String) async -> ComputerUseExecutionResult {
        guard supportsBrowser(appBundleID) else {
            return .unsupported("Browser tools currently support Google Chrome only")
        }
        let script = """
        set output to ""
        tell application id "\(appleScriptString(appBundleID))"
          repeat with w from 1 to count of windows
            set activeIndex to active tab index of window w
            repeat with t from 1 to count of tabs of window w
              set tabTitle to title of tab t of window w
              set tabURL to URL of tab t of window w
              set isActive to (t is activeIndex)
              set output to output & w & tab & t & tab & isActive & tab & tabTitle & tab & tabURL & linefeed
            end repeat
          end repeat
        end tell
        return output
        """
        do {
            let output = try await runAppleScript(script)
            let tabs = parseTabs(output: output, appBundleID: appBundleID)
            guard !tabs.isEmpty else {
                return .executed("No browser tabs")
            }
            return .executed(tabs.map { tab in
                "\(tab.windowIndex):\(tab.tabIndex) \(tab.isActive ? "active " : "")\(tab.title) - \(tab.url)"
            }.joined(separator: "\n"))
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(browserScriptError(error))
        }
    }

    static func activateTab(appBundleID: String, windowIndex: Int, tabIndex: Int, allowActivation: Bool = true) async -> ComputerUseExecutionResult {
        guard supportsBrowser(appBundleID) else {
            return .unsupported("Browser tools currently support Google Chrome only")
        }
        let activationLine = allowActivation ? "  activate\n" : ""
        let windowOrderingLine = allowActivation ? "  set index of window \(max(1, windowIndex)) to 1\n" : ""
        let script = """
        tell application id "\(appleScriptString(appBundleID))"
        \(activationLine)\
          set active tab index of window \(max(1, windowIndex)) to \(max(1, tabIndex))
        \(windowOrderingLine)\
        end tell
        """
        do {
            _ = try await runAppleScript(script)
            return .executed(
                "Activated browser tab \(windowIndex):\(tabIndex)",
                transaction: browserTransaction(
                    path: "browser_applescript_activate_tab",
                    posted: true,
                    effect: .unverifiable,
                    processID: nil,
                    windowID: nil,
                    warning: "AppleScript accepted tab activation, but this does not prove the page is ready."
                )
            )
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(browserScriptError(error))
        }
    }

    static func openNewTab(
        appBundleID: String,
        allowActivation: Bool = true,
        processID: pid_t? = nil,
        windowID: CGWindowID? = nil
    ) async -> ComputerUseExecutionResult {
        guard supportsBrowser(appBundleID) else {
            return .unsupported("Browser tools currently support Google Chrome only")
        }
        if !allowActivation {
            guard let processID, processID > 0 else {
                return .needsConfirmation("Quiet new-tab creation requires process_id and window_id from the latest browser window state. Launch the browser, capture get_window_state, then call open_new_browser_tab with that target.")
            }
            guard let windowID, windowID > 0 else {
                return .needsConfirmation("Quiet new-tab creation requires a nonzero window_id from the latest browser window state. Refresh get_window_state for the browser before opening a tab.")
            }
            if let runBackgroundCommandForTests {
                return await runBackgroundCommandForTests(.openNewTab(processID: Int(processID), windowID: Int(windowID)))
            }
            return await openNewTabInBackground(processID: processID, windowID: windowID)
        }
        let activationLine = allowActivation ? "  activate\n" : ""
        let windowReference = allowActivation ? "front window" : "window 1"
        let emptyWindowAction = allowActivation
            ? "make new window"
            : "return \"No browser window is available for quiet new-tab creation\""
        let windowOrderingLine = allowActivation ? "    set index of front window to 1\n" : ""
        let script = """
        tell application id "\(appleScriptString(appBundleID))"
        \(activationLine)\
          if (count of windows) is 0 then
            \(emptyWindowAction)
          else
        \(windowOrderingLine)\
            tell \(windowReference) to make new tab
            set active tab index of \(windowReference) to (count of tabs of \(windowReference))
          end if
        end tell
        """
        do {
            let output = try await runAppleScript(script)
            if output.contains("No browser window is available") {
                return .needsConfirmation("Opening a new browser window requires direct app control.")
            }
            return .executed(
                "Opened new browser tab",
                transaction: browserTransaction(
                    path: "browser_applescript_new_tab",
                    posted: true,
                    effect: .unverifiable,
                    processID: nil,
                    windowID: nil,
                    warning: "AppleScript accepted new-tab creation, but this does not prove the tab is ready."
                )
            )
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(browserScriptError(error))
        }
    }

    static func navigate(
        appBundleID: String,
        windowIndex: Int?,
        tabIndex: Int?,
        url: String,
        allowActivation: Bool = true,
        processID: pid_t? = nil,
        windowID: CGWindowID? = nil
    ) async -> ComputerUseExecutionResult {
        guard supportsBrowser(appBundleID) else {
            return .unsupported("Browser tools currently support Google Chrome only")
        }
        guard let safeURL = ComputerUseToolInvocation.safeHTTPURL(url) else {
            return .needsConfirmation("Confirm: unsafe navigation URL")
        }
        if !allowActivation {
            guard let processID, processID > 0 else {
                return .needsConfirmation("Quiet browser navigation requires process_id and window_id from the latest browser window state. Launch the browser, capture get_window_state, then route navigation to that target.")
            }
            guard let windowID, windowID > 0 else {
                return .needsConfirmation("Quiet browser navigation requires a nonzero window_id from the latest browser window state. Refresh get_window_state for the browser before navigating.")
            }
            if let runBackgroundCommandForTests {
                return await runBackgroundCommandForTests(.navigate(url: safeURL.absoluteString, processID: Int(processID), windowID: Int(windowID)))
            }
            return await navigateInBackground(url: safeURL.absoluteString, processID: processID, windowID: windowID)
        }
        let script = navigateScript(
            appBundleID: appBundleID,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            url: safeURL.absoluteString,
            allowActivation: allowActivation
        )
        do {
            let output = try await runAppleScript(script)
            if output.contains("No browser window is available") {
                return .needsConfirmation("Opening a browser window requires direct app control.")
            }
            let suffix = output.isEmpty ? "" : " (\(output))"
            return .executed(
                "Navigated to \(safeURL.absoluteString)\(suffix)",
                transaction: browserTransaction(
                    path: "browser_applescript_navigate",
                    posted: true,
                    effect: .unverifiable,
                    processID: nil,
                    windowID: nil,
                    requestedURL: safeURL.absoluteString,
                    warning: "AppleScript accepted navigation, but this does not prove the page loaded or became usable."
                )
            )
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(browserScriptError(error))
        }
    }

    private static func openNewTabInBackground(processID: pid_t, windowID: CGWindowID?) async -> ComputerUseExecutionResult {
        let priorFrontmost = NSWorkspace.shared.frontmostApplication
        if let windowID {
            guard ComputerUseBackgroundDriver.focusWithoutRaise(processID: processID, windowID: windowID) else {
                return .failed(
                    "Could not focus target browser window_id \(windowID) without raising it; quiet new-tab creation was not posted.",
                    transaction: browserTransaction(
                        path: "browser_background_cmd_t",
                        posted: false,
                        effect: .blocked,
                        processID: Int(processID),
                        windowID: Int(windowID),
                        warning: "Target browser window could not be focused without raising, so Cmd-T was not posted."
                    )
                )
            }
        }
        guard postKey("t", modifiers: .maskCommand, processID: processID, attachAuthMessage: false) else {
            return .failed(
                "Could not post background Cmd-T to browser process \(processID).",
                transaction: browserTransaction(
                    path: "browser_background_cmd_t",
                    posted: false,
                    effect: .blocked,
                    processID: Int(processID),
                    windowID: windowID.map(Int.init),
                    warning: "Cmd-T was not posted to the browser process."
                )
            )
        }
        restoreFrontmost(priorFrontmost, targetProcessID: processID)
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .executed(
            "Opened new browser tab in target window",
            transaction: browserTransaction(
                path: "browser_background_cmd_t",
                posted: true,
                effect: .unverifiable,
                processID: Int(processID),
                windowID: windowID.map(Int.init),
                warning: "Cmd-T was posted, but this does not prove the new tab is ready."
            )
        )
    }

    private static func navigateInBackground(url: String, processID: pid_t, windowID: CGWindowID?) async -> ComputerUseExecutionResult {
        let priorFrontmost = NSWorkspace.shared.frontmostApplication
        if let windowID {
            guard ComputerUseBackgroundDriver.focusWithoutRaise(processID: processID, windowID: windowID) else {
                return .failed(
                    "Could not focus target browser window_id \(windowID) without raising it; quiet navigation was not posted.",
                    transaction: browserTransaction(
                        path: "browser_background_cmd_l_paste_enter",
                        posted: false,
                        effect: .blocked,
                        processID: Int(processID),
                        windowID: Int(windowID),
                        requestedURL: url,
                        warning: "Target browser window could not be focused without raising, so navigation keys were not posted."
                    )
                )
            }
        }
        guard postKey("l", modifiers: .maskCommand, processID: processID, attachAuthMessage: false) else {
            return .failed(
                "Could not post background Cmd-L to browser process \(processID).",
                transaction: browserTransaction(
                    path: "browser_background_cmd_l_paste_enter",
                    posted: false,
                    effect: .blocked,
                    processID: Int(processID),
                    windowID: windowID.map(Int.init),
                    requestedURL: url,
                    warning: "Cmd-L was not posted to the browser process."
                )
            )
        }
        restoreFrontmost(priorFrontmost, targetProcessID: processID)
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(error.localizedDescription)
        }
        if let windowID {
            guard ComputerUseBackgroundDriver.focusWithoutRaise(processID: processID, windowID: windowID) else {
                return .failed(
                    "Target browser window_id \(windowID) lost quiet focus before URL paste; navigation was stopped.",
                    transaction: browserTransaction(
                        path: "browser_background_cmd_l_paste_enter",
                        posted: false,
                        effect: .blocked,
                        processID: Int(processID),
                        windowID: Int(windowID),
                        requestedURL: url,
                        warning: "Target browser window could not be refocused without raising before URL paste."
                    )
                )
            }
        }
        PasteController.paste(text: url, processID: processID)
        restoreFrontmost(priorFrontmost, targetProcessID: processID)
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(error.localizedDescription)
        }
        if let windowID {
            guard ComputerUseBackgroundDriver.focusWithoutRaise(processID: processID, windowID: windowID) else {
                return .failed(
                    "Target browser window_id \(windowID) lost quiet focus before Enter; navigation was stopped.",
                    transaction: browserTransaction(
                        path: "browser_background_cmd_l_paste_enter",
                        posted: false,
                        effect: .blocked,
                        processID: Int(processID),
                        windowID: Int(windowID),
                        requestedURL: url,
                        warning: "Target browser window could not be refocused without raising before Enter."
                    )
                )
            }
        }
        guard postKey("enter", processID: processID) else {
            return .failed(
                "Could not post background Enter to browser process \(processID).",
                transaction: browserTransaction(
                    path: "browser_background_cmd_l_paste_enter",
                    posted: false,
                    effect: .blocked,
                    processID: Int(processID),
                    windowID: windowID.map(Int.init),
                    requestedURL: url,
                    warning: "Enter was not posted to the browser process."
                )
            )
        }
        restoreFrontmost(priorFrontmost, targetProcessID: processID)
        do {
            try await Task.sleep(nanoseconds: 700_000_000)
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .executed(
            "Navigated target browser tab to \(url)",
            transaction: browserTransaction(
                path: "browser_background_cmd_l_paste_enter",
                posted: true,
                effect: .unverifiable,
                processID: Int(processID),
                windowID: windowID.map(Int.init),
                requestedURL: url,
                warning: "Navigation keystrokes were posted, but this does not prove the page loaded or became usable."
            )
        )
    }

    private static func browserTransaction(
        path: String,
        posted: Bool,
        effect: ComputerUseActionEffect,
        processID: Int?,
        windowID: Int?,
        requestedURL: String? = nil,
        warning: String
    ) -> ComputerUseActionTransaction {
        ComputerUseActionTransaction(
            path: path,
            posted: posted,
            verified: false,
            effect: effect,
            targetStable: true,
            processID: processID,
            windowID: windowID,
            requestedURL: requestedURL,
            escalationHint: "Use the post-action get_window_state/screenshot to verify the tab URL, page load, and available controls before continuing or finishing.",
            warning: warning
        )
    }

    private static func restoreFrontmost(_ priorFrontmost: NSRunningApplication?, targetProcessID: pid_t) {
        guard let priorFrontmost,
              !priorFrontmost.isTerminated,
              priorFrontmost.processIdentifier != targetProcessID
        else { return }
        priorFrontmost.activate(options: [])
    }

    private static func postKey(
        _ key: String,
        modifiers: CGEventFlags = [],
        processID: pid_t,
        attachAuthMessage: Bool = true
    ) -> Bool {
        guard let keyCode = browserKeyCode(for: key),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = modifiers
        up.flags = modifiers
        let postedDown = ComputerUseBackgroundDriver.postKeyEvent(
            down,
            to: processID,
            attachAuthMessage: attachAuthMessage
        )
        let postedUp = ComputerUseBackgroundDriver.postKeyEvent(
            up,
            to: processID,
            attachAuthMessage: attachAuthMessage
        )
        return postedDown && postedUp
    }

    private static func browserKeyCode(for key: String) -> CGKeyCode? {
        switch key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "t": return 17
        case "l": return 37
        case "enter", "return": return 36
        default: return nil
        }
    }

    static func navigateScript(appBundleID: String, windowIndex: Int?, tabIndex: Int?, url: String, allowActivation: Bool = true) -> String {
        let requestedWindow = max(1, windowIndex ?? 1)
        let requestedTab = max(1, tabIndex ?? 1)
        let hasWindowHint = windowIndex != nil
        let hasTabHint = tabIndex != nil
        let activationLine = allowActivation ? "  activate\n" : ""
        let emptyWindowAction = allowActivation
            ? "make new window"
            : "return \"No browser window is available for quiet navigation\""
        return """
        tell application id "\(appleScriptString(appBundleID))"
        \(activationLine)\
          if (count of windows) is 0 then \(emptyWindowAction)
          set targetWindow to front window
          set usedFallback to false
          if \(appleScriptBool(hasWindowHint)) then
            if \(requestedWindow) <= (count of windows) then
              set targetWindow to window \(requestedWindow)
            else
              set usedFallback to true
            end if
          end if
          set targetTab to active tab of targetWindow
          if \(appleScriptBool(hasTabHint)) then
            if \(requestedTab) <= (count of tabs of targetWindow) then
              set targetTab to tab \(requestedTab) of targetWindow
            else
              set usedFallback to true
            end if
          end if
          set URL of targetTab to "\(appleScriptString(url))"
          if usedFallback then
            return "used active tab fallback"
          end if
          return ""
        end tell
        """
    }

    static func pageText(appBundleID: String, windowIndex: Int?, tabIndex: Int?) async -> ComputerUseExecutionResult {
        await runReadOnlyJavaScript(
            appBundleID: appBundleID,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            javascript: """
            (() => {
              const text = document.body ? document.body.innerText : document.documentElement.innerText;
              return String(text || '').slice(0, 12000);
            })()
            """,
            successPrefix: "Page text"
        )
    }

    static func queryDOM(
        appBundleID: String,
        windowIndex: Int?,
        tabIndex: Int?,
        selector: String,
        attributes: [String]
    ) async -> ComputerUseExecutionResult {
        let selectorJSON = jsonString(selector)
        let selectedAttributes = Array(attributes.prefix(12))
        let attributesJSON = jsonArray(selectedAttributes)
        return await runReadOnlyJavaScript(
            appBundleID: appBundleID,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            javascript: """
            (() => {
              const selector = \(selectorJSON);
              const attrs = \(attributesJSON);
              const nodes = Array.from(document.querySelectorAll(selector)).slice(0, 80);
              return JSON.stringify(nodes.map((node, index) => {
                const out = {
                  index,
                  tag: node.tagName ? node.tagName.toLowerCase() : '',
                  text: (node.innerText || node.textContent || '').trim().slice(0, 500)
                };
                for (const attr of attrs) {
                  out[attr] = node.getAttribute(attr) || '';
                }
                return out;
              }));
            })()
            """,
            successPrefix: "DOM query"
        )
    }

    static func parseTabs(output: String, appBundleID: String) -> [ComputerUseBrowserTabInfo] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 5,
                      let windowIndex = Int(parts[0]),
                      let tabIndex = Int(parts[1])
                else { return nil }
                return ComputerUseBrowserTabInfo(
                    appBundleID: appBundleID,
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    title: parts[3],
                    url: parts[4],
                    isActive: parts[2].lowercased() == "true"
                )
            }
    }

    private static func runReadOnlyJavaScript(
        appBundleID: String,
        windowIndex: Int?,
        tabIndex: Int?,
        javascript: String,
        successPrefix: String
    ) async -> ComputerUseExecutionResult {
        guard supportsBrowser(appBundleID) else {
            return .unsupported("Browser tools currently support Google Chrome only")
        }
        let target = browserTabReference(windowIndex: windowIndex, tabIndex: tabIndex)
        let script = """
        tell application id "\(appleScriptString(appBundleID))"
          execute javascript \(jsonString(javascript)) in \(target)
        end tell
        """
        do {
            let output = try await runAppleScript(script)
            return .executed("\(successPrefix): \(String(output.prefix(12000)))")
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(browserScriptError(error))
        }
    }

    private static func browserTabReference(windowIndex: Int?, tabIndex: Int?) -> String {
        if let windowIndex, let tabIndex {
            return "tab \(max(1, tabIndex)) of window \(max(1, windowIndex))"
        }
        if let windowIndex {
            return "active tab of window \(max(1, windowIndex))"
        }
        return "active tab of front window"
    }

    private static func supportsBrowser(_ appBundleID: String) -> Bool {
        appBundleID == "com.google.Chrome"
    }

    private static func runAppleScript(_ script: String) async throws -> String {
        if let runAppleScriptForTests {
            return try runAppleScriptForTests(script)
        }

        let processBox = AppleScriptProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        process.arguments = ["-e", script]
                        let output = Pipe()
                        let error = Pipe()
                        process.standardOutput = output
                        process.standardError = error
                        guard processBox.set(process) else {
                            throw CancellationError()
                        }
                        try process.run()
                        process.waitUntilExit()

                        let wasCancelled = processBox.clear()
                        if wasCancelled {
                            throw CancellationError()
                        }

                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        let errorData = error.fileHandleForReading.readDataToEndOfFile()
                        if process.terminationStatus != 0 {
                            let message = String(data: errorData, encoding: .utf8) ?? "Apple Events failed"
                            throw NSError(domain: "ComputerUseBrowserAutomation", code: Int(process.terminationStatus), userInfo: [
                                NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines),
                            ])
                        }
                        continuation.resume(returning: (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    } catch {
                        _ = processBox.clear()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    private static func browserScriptError(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("not allowed") || message.localizedCaseInsensitiveContains("javascript") {
            return "Chrome Apple Events JavaScript permission is required for browser page tools"
        }
        return message.isEmpty ? "Browser automation failed" : message
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{0}", with: "")
    }

    private static func appleScriptBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

private final class AppleScriptProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let currentProcess = process
        lock.unlock()
        currentProcess?.terminate()
    }

    @discardableResult
    func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasCancelled = cancelled
        process = nil
        return wasCancelled
    }
}

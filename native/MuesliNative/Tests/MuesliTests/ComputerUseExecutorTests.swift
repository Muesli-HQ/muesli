import CoreGraphics
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use executor", .serialized)
struct ComputerUseExecutorTests {
    @Test("maps common app aliases to bundle identifiers")
    @MainActor
    func commonAppAliases() {
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "Google Chrome") == "com.google.Chrome")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "chrome") == "com.google.Chrome")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "VS Code") == "com.microsoft.VSCode")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "tail scale") == "io.tailscale.ipn.macsys")
        #expect(ComputerUseExecutor.bundleIdentifierAlias(for: "Tailscale") == "io.tailscale.ipn.macsys")
    }

    @Test("maps spoken key names to virtual key codes")
    @MainActor
    func spokenKeyNames() {
        #expect(ComputerUseExecutor.keyCode(for: "l") == 37)
        #expect(ComputerUseExecutor.keyCode(for: "enter") == 36)
        #expect(ComputerUseExecutor.keyCode(for: "left arrow") == 123)
    }

    @Test("maps scroll directions to CG wheel deltas")
    @MainActor
    func scrollDirectionDeltas() {
        #expect(ComputerUseToolExecutor.scrollDeltas(direction: .up, pages: 1).vertical > 0)
        #expect(ComputerUseToolExecutor.scrollDeltas(direction: .down, pages: 1).vertical < 0)
        #expect(ComputerUseToolExecutor.scrollDeltas(direction: .left, pages: 1).horizontal < 0)
        #expect(ComputerUseToolExecutor.scrollDeltas(direction: .right, pages: 1).horizontal > 0)
    }

    @Test("explicit text targets must be editable")
    @MainActor
    func explicitTextTargetsMustBeEditable() {
        #expect(ComputerUseToolExecutor.explicitTextTargetResolutionForTests(explicitElementIsEditable: true) == .success)
        let result = ComputerUseToolExecutor.explicitTextTargetResolutionForTests(explicitElementIsEditable: false)
        guard case .failure(let message) = result else {
            Issue.record("expected explicit non-editable target to fail")
            return
        }
        #expect(message.contains("requested element is not an editable text target"))
        #expect(message.contains("Refresh state"))
    }

    @Test("element click fails stale snapshot instead of falling through")
    @MainActor
    func elementClickFailsStaleSnapshot() async {
        let registry = ComputerUseElementRegistry()
        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(tool: .click, elementIndex: 9, label: "Search"),
            registry: registry
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("Stale or unknown element_index 9"))
    }

    @Test("secondary action rejects stale snapshot")
    @MainActor
    func secondaryActionRejectsStaleSnapshot() async {
        let registry = ComputerUseElementRegistry()
        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(tool: .performSecondaryAction, elementIndex: 9, actionName: "AXShowMenu", label: "More"),
            registry: registry
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("Stale or unknown element_index 9"))
    }

    @Test("element scroll rejects stale snapshot")
    @MainActor
    func elementScrollRejectsStaleSnapshot() async {
        let registry = ComputerUseElementRegistry()
        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(tool: .scroll, elementIndex: 9, direction: .down),
            registry: registry
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("Stale or unknown element_index 9"))
    }

    @Test("coordinate action rejects stale screenshot id")
    @MainActor
    func coordinateActionRejectsStaleScreenshotID() async {
        let registry = ComputerUseElementRegistry()
        registry.registerScreenshot(ComputerUseScreenshotObservation(
            screenshotID: "latest-shot",
            width: 100,
            height: 80,
            windowFrame: ComputerUseRect(x: 10, y: 20, width: 100, height: 80),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: nil
        ))

        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(tool: .moveCursor, screenshotID: "old-shot", x: 12, y: 24),
            registry: registry
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("Stale screenshot_id old-shot"))
        #expect(result.message.contains("latest screenshot is latest-shot"))
    }

    @Test("parses browser tab Apple Events output")
    func parsesBrowserTabs() {
        let tabs = ComputerUseBrowserAutomation.parseTabs(
            output: "1\t1\ttrue\tHacker News\thttps://news.ycombinator.com/\n1\t2\tfalse\tYouTube\thttps://youtube.com/\n",
            appBundleID: "com.google.Chrome"
        )

        #expect(tabs.count == 2)
        #expect(tabs[0].windowIndex == 1)
        #expect(tabs[0].tabIndex == 1)
        #expect(tabs[0].isActive)
        #expect(tabs[1].title == "YouTube")
    }

    @Test("lists browser tabs with mocked Apple Events adapter")
    func listsBrowserTabs() async {
        ComputerUseBrowserAutomation.runAppleScriptForTests = { script in
            #expect(script.contains("application id \"com.google.Chrome\""))
            return "1\t1\ttrue\tHacker News\thttps://news.ycombinator.com/\n"
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let result = await ComputerUseBrowserAutomation.listTabs(appBundleID: "com.google.Chrome")

        #expect(result.status == .executed)
        #expect(result.message.contains("Hacker News"))
    }

    @Test("activates browser tab with mocked Apple Events adapter")
    func activatesBrowserTab() async {
        ComputerUseBrowserAutomation.runAppleScriptForTests = { script in
            #expect(script.contains("active tab index of window 2 to 3"))
            return ""
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let result = await ComputerUseBrowserAutomation.activateTab(appBundleID: "com.google.Chrome", windowIndex: 2, tabIndex: 3)

        #expect(result.status == .executed)
    }

    @Test("quiet browser tab activation requires direct control")
    func quietBrowserTabActivationRequiresDirectControl() async {
        ComputerUseBrowserAutomation.runAppleScriptForTests = { _ in
            Issue.record("Quiet browser tab activation should not use unscoped AppleScript mutation")
            return ""
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let result = await ComputerUseBrowserAutomation.activateTab(
            appBundleID: "com.google.Chrome",
            windowIndex: 2,
            tabIndex: 3,
            allowActivation: false
        )

        #expect(result.status == .needsConfirmation)
        #expect(result.message.contains("not window_id scoped"))
    }

    @Test("browser automation preserves cancellation")
    func browserAutomationPreservesCancellation() async {
        ComputerUseBrowserAutomation.runAppleScriptForTests = { _ in
            throw CancellationError()
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let result = await ComputerUseBrowserAutomation.listTabs(appBundleID: "com.google.Chrome")

        #expect(result.status == .cancelled)
    }

    @Test("navigates safe URLs and rejects unsafe URLs")
    func navigatesSafeURLsAndRejectsUnsafeURLs() async {
        var capturedScript = ""
        ComputerUseBrowserAutomation.runAppleScriptForTests = { script in
            capturedScript = script
            return ""
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let safe = await ComputerUseBrowserAutomation.navigate(
            appBundleID: "com.google.Chrome",
            windowIndex: 1,
            tabIndex: 1,
            url: "https://www.google.com/search?q=hello&hl=en"
        )
        let unsafe = await ComputerUseBrowserAutomation.navigate(
            appBundleID: "com.google.Chrome",
            windowIndex: nil,
            tabIndex: nil,
            url: "javascript:alert(1)"
        )

        #expect(safe.status == .executed)
        #expect(safe.transaction?.path == "browser_applescript_navigate")
        #expect(safe.transaction?.posted == true)
        #expect(safe.transaction?.verified == false)
        #expect(safe.transaction?.effect == .unverifiable)
        #expect(safe.transaction?.requestedURL == "https://www.google.com/search?q=hello&hl=en")
        #expect(capturedScript.contains("https://www.google.com/search?q=hello&hl=en"))
        #expect(unsafe.status == .needsConfirmation)
    }

    @Test("quiet browser navigation requires process id")
    func quietBrowserNavigationRequiresProcessID() async {
        ComputerUseBrowserAutomation.runAppleScriptForTests = { _ in
            Issue.record("Quiet browser navigation should not use AppleScript mutation")
            return ""
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let result = await ComputerUseBrowserAutomation.navigate(
            appBundleID: "com.google.Chrome",
            windowIndex: 1,
            tabIndex: 1,
            url: "https://docs.new",
            allowActivation: false
        )

        #expect(result.status == .needsConfirmation)
    }

    @Test("quiet browser navigation routes to target process")
    func quietBrowserNavigationRoutesToTargetProcess() async {
        var capturedCommand: ComputerUseBrowserAutomation.BackgroundBrowserCommand?
        ComputerUseBrowserAutomation.runBackgroundCommandForTests = { command in
            capturedCommand = command
            return .executed("background routed")
        }
        defer { ComputerUseBrowserAutomation.runBackgroundCommandForTests = nil }

        let result = await ComputerUseBrowserAutomation.navigate(
            appBundleID: "com.google.Chrome",
            windowIndex: nil,
            tabIndex: nil,
            url: "https://docs.new",
            allowActivation: false,
            processID: 1234,
            windowID: 88
        )

        #expect(result.status == .executed)
        #expect(capturedCommand == .navigate(url: "https://docs.new", processID: 1234, windowID: 88))
    }

    @Test("quiet browser navigation fails before posting when target window cannot be focused")
    func quietBrowserNavigationFailsBeforePostingWhenTargetWindowCannotBeFocused() async {
        ComputerUseBackgroundDriver.focusWithoutRaiseForTests = { _, _ in false }
        defer { ComputerUseBackgroundDriver.focusWithoutRaiseForTests = nil }

        let result = await ComputerUseBrowserAutomation.navigate(
            appBundleID: "com.google.Chrome",
            windowIndex: nil,
            tabIndex: nil,
            url: "https://docs.new",
            allowActivation: false,
            processID: 1234,
            windowID: 88
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("quiet navigation was not posted"))
        #expect(result.transaction?.posted == false)
        #expect(result.transaction?.effect == .blocked)
    }

    @Test("quiet focus rejects mismatched window owner before posting")
    func quietFocusRejectsMismatchedWindowOwnerBeforePosting() {
        var focusWasAttempted = false
        ComputerUseBackgroundDriver.windowOwnerPIDForTests = { _ in 9999 }
        ComputerUseBackgroundDriver.focusWithoutRaiseForTests = { _, _ in
            focusWasAttempted = true
            return true
        }
        defer {
            ComputerUseBackgroundDriver.windowOwnerPIDForTests = nil
            ComputerUseBackgroundDriver.focusWithoutRaiseForTests = nil
        }

        let result = ComputerUseBackgroundDriver.focusWithoutRaise(processID: 1234, windowID: 88)

        #expect(result == false)
        #expect(focusWasAttempted == false)
    }

    @Test("quiet press key fails before posting when target window cannot be focused")
    @MainActor
    func quietPressKeyFailsBeforePostingWhenTargetWindowCannotBeFocused() async {
        ComputerUseBackgroundDriver.focusWithoutRaiseForTests = { _, _ in false }
        defer { ComputerUseBackgroundDriver.focusWithoutRaiseForTests = nil }

        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(
                tool: .pressKey,
                processID: 1234,
                windowID: 88,
                key: "enter"
            ),
            registry: nil,
            interactionMode: .quiet
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("key was not posted"))
        #expect(result.transaction?.posted == false)
        #expect(result.transaction?.effect == .blocked)
    }

    @Test("quiet press key without process id fails before posting")
    @MainActor
    func quietPressKeyWithoutProcessIDFailsBeforePosting() async {
        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(
                tool: .pressKey,
                windowID: 88,
                key: "enter"
            ),
            registry: nil,
            interactionMode: .quiet
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("requires process_id and window_id"))
        #expect(result.transaction?.posted == false)
        #expect(result.transaction?.effect == .blocked)
    }

    @Test("quiet scroll fails before posting when target window cannot be focused")
    @MainActor
    func quietScrollFailsBeforePostingWhenTargetWindowCannotBeFocused() async {
        ComputerUseBackgroundDriver.focusWithoutRaiseForTests = { _, _ in false }
        defer { ComputerUseBackgroundDriver.focusWithoutRaiseForTests = nil }

        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(
                tool: .scroll,
                processID: 1234,
                windowID: 88,
                direction: .down,
                pages: 1
            ),
            registry: nil,
            interactionMode: .quiet
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("scroll was not posted"))
        #expect(result.transaction?.posted == false)
        #expect(result.transaction?.effect == .blocked)
    }

    @Test("navigate URL validates tab hints before targeting")
    func navigateURLValidatesTabHintsBeforeTargeting() {
        let script = ComputerUseBrowserAutomation.navigateScript(
            appBundleID: "com.google.Chrome",
            windowIndex: 1,
            tabIndex: 16,
            url: "https://www.youtube.com/results?search_query=Drake+latest+song"
        )

        #expect(script.contains("set targetTab to active tab of targetWindow"))
        #expect(script.contains("if 16 <= (count of tabs of targetWindow) then"))
        #expect(script.contains("set targetTab to tab 16 of targetWindow"))
        #expect(!script.contains("tab 16 of window 1"))
        #expect(script.contains("used active tab fallback"))
    }

    @Test("opens new browser tab with mocked Apple Events adapter")
    func opensNewBrowserTab() async {
        var capturedScript = ""
        ComputerUseBrowserAutomation.runAppleScriptForTests = { script in
            capturedScript = script
            return ""
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let result = await ComputerUseBrowserAutomation.openNewTab(appBundleID: "com.google.Chrome")

        #expect(result.status == .executed)
        #expect(capturedScript.contains("make new tab"))
        #expect(capturedScript.contains("active tab index of front window"))
    }

    @Test("quiet new browser tab requires process id")
    func quietNewBrowserTabRequiresProcessID() async {
        ComputerUseBrowserAutomation.runAppleScriptForTests = { _ in
            Issue.record("Quiet new-tab creation should not use AppleScript mutation")
            return ""
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let result = await ComputerUseBrowserAutomation.openNewTab(
            appBundleID: "com.google.Chrome",
            allowActivation: false
        )

        #expect(result.status == .needsConfirmation)
    }

    @Test("quiet new browser tab routes to target process")
    func quietNewBrowserTabRoutesToTargetProcess() async {
        var capturedCommand: ComputerUseBrowserAutomation.BackgroundBrowserCommand?
        ComputerUseBrowserAutomation.runBackgroundCommandForTests = { command in
            capturedCommand = command
            return .executed("background routed")
        }
        defer { ComputerUseBrowserAutomation.runBackgroundCommandForTests = nil }

        let result = await ComputerUseBrowserAutomation.openNewTab(
            appBundleID: "com.google.Chrome",
            allowActivation: false,
            processID: 1234,
            windowID: 88
        )

        #expect(result.status == .executed)
        #expect(capturedCommand == .openNewTab(processID: 1234, windowID: 88))
    }

    @Test("quiet coordinate click without process id requires direct control")
    @MainActor
    func quietCoordinateClickWithoutProcessIDRequiresDirectControl() async {
        let registry = ComputerUseElementRegistry()
        registry.registerScreenshot(ComputerUseScreenshotObservation(
            screenshotID: "latest-shot",
            width: 100,
            height: 80,
            windowFrame: ComputerUseRect(x: 10, y: 20, width: 100, height: 80),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: nil
        ))

        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(tool: .clickPoint, screenshotID: "latest-shot", x: 20, y: 30),
            registry: registry,
            interactionMode: .quiet
        )

        #expect(result.status == .needsConfirmation)
    }

    @Test("quiet coordinate click without window id requires target window")
    @MainActor
    func quietCoordinateClickWithoutWindowIDRequiresTargetWindow() async {
        let registry = ComputerUseElementRegistry()
        registry.registerScreenshot(ComputerUseScreenshotObservation(
            screenshotID: "latest-shot",
            width: 100,
            height: 80,
            windowFrame: ComputerUseRect(x: 10, y: 20, width: 100, height: 80),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: nil
        ))

        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(tool: .clickPoint, processID: 1234, screenshotID: "latest-shot", label: "Docs editor", x: 20, y: 30),
            registry: registry,
            interactionMode: .quiet
        )

        #expect(result.status == .needsConfirmation)
        #expect(result.message.contains("window_id"))
    }

    @Test("quiet coordinate click fails before posting when target window cannot be focused")
    @MainActor
    func quietCoordinateClickFailsBeforePostingWhenTargetWindowCannotBeFocused() async {
        let registry = ComputerUseElementRegistry()
        registry.registerScreenshot(ComputerUseScreenshotObservation(
            screenshotID: "latest-shot",
            width: 100,
            height: 80,
            windowFrame: ComputerUseRect(x: 10, y: 20, width: 100, height: 80),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: nil
        ))
        ComputerUseBackgroundDriver.focusWithoutRaiseForTests = { _, _ in false }
        defer { ComputerUseBackgroundDriver.focusWithoutRaiseForTests = nil }

        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(
                tool: .clickPoint,
                processID: 1234,
                windowID: 88,
                screenshotID: "latest-shot",
                label: "Docs editor",
                x: 20,
                y: 30
            ),
            registry: registry,
            interactionMode: .quiet
        )

        #expect(result.status == .failed)
        #expect(result.message.contains("Background click could not be posted"))
        #expect(result.transaction?.posted == false)
        #expect(result.transaction?.effect == .blocked)
    }

    @Test("quiet YouTube result click uses window scoped route diagnostics")
    @MainActor
    func quietYouTubeResultClickUsesWindowScopedRouteDiagnostics() async {
        let registry = ComputerUseElementRegistry()
        registry.registerScreenshot(ComputerUseScreenshotObservation(
            screenshotID: "youtube-results",
            width: 400,
            height: 300,
            windowFrame: ComputerUseRect(x: 100, y: 200, width: 400, height: 300),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: nil
        ))
        var capturedRequest: ComputerUseClickDriver.PointRequest?
        ComputerUseClickDriver.postBackgroundClickForTests = { request in
            capturedRequest = request
            return true
        }
        defer { ComputerUseClickDriver.postBackgroundClickForTests = nil }

        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(
                tool: .clickPoint,
                processID: 4321,
                windowID: 88,
                screenshotID: "youtube-results",
                label: "YouTube search result",
                x: 40,
                y: 50
            ),
            registry: registry,
            interactionMode: .quiet
        )

        #expect(result.status == .executed)
        #expect(result.diagnostics?["click_route"] == "window_point_skylight")
        #expect(result.diagnostics?["process_id"] == "4321")
        #expect(result.diagnostics?["window_id"] == "88")
        #expect(result.transaction?.path == "window_point_skylight")
        #expect(result.transaction?.route == "window_point_skylight")
        #expect(result.transaction?.posted == true)
        #expect(result.transaction?.verified == false)
        #expect(result.transaction?.effect == .unverifiable)
        #expect(result.transaction?.processID == 4321)
        #expect(result.transaction?.windowID == 88)
        #expect(capturedRequest?.point == CGPoint(x: 140, y: 250))
    }

    @Test("generic web button click prefers screenshot route when AX is ambiguous")
    @MainActor
    func genericWebButtonClickPrefersScreenshotRouteWhenAXIsAmbiguous() async {
        let decision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: [],
            axPressAccepted: false,
            hasFrame: true,
            processID: 4321,
            windowID: 88,
            allowGlobalHID: false
        )

        #expect(decision.route == .elementCenterSkyLight)
        #expect(decision.blockedReason == nil)
    }

    @Test("Docs and Sheets editor clicks require scoped quiet target")
    @MainActor
    func docsAndSheetsEditorClicksRequireScopedQuietTarget() {
        let docsDecision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: nil,
            axPressAccepted: false,
            hasFrame: true,
            processID: 4321,
            windowID: nil,
            allowGlobalHID: false
        )
        let sheetsDecision = ComputerUseClickDriver.routeDecisionForTests(
            advertisedActions: nil,
            axPressAccepted: false,
            hasFrame: true,
            processID: nil,
            windowID: 88,
            allowGlobalHID: false
        )

        #expect(docsDecision.route == nil)
        #expect(docsDecision.blockedReason == "missing_window_id")
        #expect(sheetsDecision.route == nil)
        #expect(sheetsDecision.blockedReason == "direct_control_required")
    }

    @Test("quiet standalone focus requires direct control")
    @MainActor
    func quietStandaloneFocusRequiresDirectControl() async {
        let result = await ComputerUseToolExecutor.execute(
            ComputerUseToolCall(tool: .focusElement, elementIndex: 1, label: "Document content"),
            registry: ComputerUseElementRegistry(),
            interactionMode: .quiet
        )

        #expect(result.status == .needsConfirmation)
        #expect(result.message.contains("standalone step would interrupt"))
        #expect(result.message.contains("paste_text"))
    }

    @Test("page text and DOM query use read-only JavaScript")
    func pageTextAndDOMQueryUseReadOnlyJavaScript() async {
        var scripts: [String] = []
        ComputerUseBrowserAutomation.runAppleScriptForTests = { script in
            scripts.append(script)
            return "result"
        }
        defer { ComputerUseBrowserAutomation.runAppleScriptForTests = nil }

        let text = await ComputerUseBrowserAutomation.pageText(appBundleID: "com.google.Chrome", windowIndex: 1, tabIndex: 1)
        let dom = await ComputerUseBrowserAutomation.queryDOM(
            appBundleID: "com.google.Chrome",
            windowIndex: 1,
            tabIndex: 1,
            selector: "a.storylink",
            attributes: ["href"]
        )

        #expect(text.status == .executed)
        #expect(dom.status == .executed)
        #expect(scripts.allSatisfy { $0.contains("execute javascript") })
        #expect(scripts[1].contains("querySelectorAll"))
    }
}

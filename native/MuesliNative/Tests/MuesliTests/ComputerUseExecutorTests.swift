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
        #expect(capturedScript.contains("https://www.google.com/search?q=hello&hl=en"))
        #expect(unsafe.status == .needsConfirmation)
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

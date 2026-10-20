import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use background boundaries", .serialized)
@MainActor
struct ComputerUseBackgroundTests {
    @Test("Command activity survives suspension and releases on success, failure and cancellation")
    func commandActivityLifetime() async {
        enum Failure: Error { case expected }
        for outcome in 0...2 {
            let token = NSObject()
            var active = false
            var releases = 0
            do {
                try await ComputerUseReferenceRuntime.withCommandActivity(begin: {
                    active = true
                    return token
                }, end: { released in
                    #expect(released === token)
                    active = false
                    releases += 1
                }) {
                    #expect(active)
                    await Task.yield() // Model/network suspension must retain the assertion.
                    #expect(active)
                    if outcome == 1 { throw Failure.expected }
                    if outcome == 2 { throw CancellationError() }
                }
                #expect(outcome == 0)
            } catch is CancellationError {
                #expect(outcome == 2)
            } catch {
                #expect(outcome == 1)
            }
            #expect(!active)
            #expect(releases == 1)
        }
    }

    @Test("Observation feedback distinguishes unchanged reads from new scope and mutations")
    func observationProgressFeedback() {
        var progress = ComputerUseReferenceRuntime.ObservationProgress()
        func snapshot(_ token: String, tab: String = "tab1", value: String = "") -> [String: Any] {
            ["result": ["structuredContent": [
                "status": "ok", "mode": "snapshot", "target_id": "target1", "tab_id": tab,
                "outline": value, "refs": [], "content_refs": [],
                "snapshot": ["id": token, "scope": "query", "complete": true,
                             "omitted": ["offscreen": 12]]
            ]]]
        }
        let args: [String: Any] = ["query": "arbitrary missing item"]
        let first = progress.guidance(tool: "get_browser_state", arguments: args, response: snapshot("p1"))
        #expect(first?.contains("does not establish absence") == true)
        #expect(first?.contains("unchanged evidence") == false)
        let repeated = progress.guidance(tool: "get_browser_state", arguments: args, response: snapshot("p2"))
        #expect(repeated?.contains("unchanged evidence") == true)
        let changed = progress.guidance(tool: "get_browser_state", arguments: args, response: snapshot("p3", value: "new content"))
        #expect(changed?.contains("unchanged evidence") == false)
        let otherTab = progress.guidance(tool: "get_browser_state", arguments: args, response: snapshot("p4", tab: "tab2"))
        #expect(otherTab?.contains("Several reads") == false)
        #expect(progress.guidance(tool: "browser_pointer", arguments: ["action": "scroll"], response: [:]) == nil)
        let afterScroll = progress.guidance(tool: "get_browser_state", arguments: args, response: snapshot("p5", tab: "tab2"))
        #expect(afterScroll?.contains("unchanged evidence") == false)
        #expect(progress.guidance(tool: "get_browser_state", arguments: args,
            response: ["result": ["isError": true]]) == nil)
        let afterError = progress.guidance(tool: "get_browser_state", arguments: args, response: snapshot("p6", tab: "tab2"))
        #expect(afterError?.contains("unchanged evidence") == false)
    }

    @Test("Retired observations preserve facts but discard pagination capabilities")
    func retiredPaginationCapabilities() {
        let response: [String: Any] = ["result": ["structuredContent": [
            "status": "ok", "mode": "snapshot", "outline": "- article an established fact",
            "snapshot": ["id": "old-snapshot", "continuation": "obsolete-cursor", "complete": false],
            "continuation": "legacy-cursor", "target_id": "target1", "tab_id": "tab1"
        ]]]
        let summary = ComputerUseReferenceRuntime.snapshotHistorySummary(from: response) ?? ""
        #expect(summary.contains("an established fact"))
        #expect(summary.contains("target1"))
        #expect(!summary.contains("obsolete-cursor"))
        #expect(!summary.contains("legacy-cursor"))
        #expect(!summary.contains("old-snapshot"))
    }

    @Test("Persistent reference host isolates command ownership and rejects stale release")
    func referenceCommandOwnership() throws {
        let driver = ComputerUseReferenceDriver()
        let first = try driver.claimCommand()
        #expect(throws: (any Error).self) { try driver.claimCommand() }
        driver.releaseCommand(UUID())
        #expect(throws: (any Error).self) { try driver.claimCommand() }
        driver.releaseCommand(first)
        let second = try driver.claimCommand()
        #expect(first != second)
        driver.releaseCommand(first)
        #expect(throws: (any Error).self) { try driver.claimCommand() }
        driver.releaseCommand(second)
    }

    @Test("Reference task session overrides model session aliases without changing targets")
    func referenceTaskSessionIsolation() {
        let scoped = ComputerUseReferenceDriver.scopedArguments(
            ["session": "previous-task", "_session_id": "forged", "pid": 12, "window_id": 34], session: "current-task")
        #expect(scoped["session"] as? String == "current-task")
        #expect(scoped["_session_id"] == nil)
        #expect(scoped["pid"] as? Int == 12)
        #expect(scoped["window_id"] as? Int == 34)
    }

    @Test("Reference comparison rejects foreground delivery before dispatch")
    func referenceBackgroundDelivery() {
        #expect(ComputerUseReferenceRuntime.permitsBackgroundDelivery([:]))
        #expect(ComputerUseReferenceRuntime.permitsBackgroundDelivery(["scope": "window", "target": ["kind": "window", "pid": 123, "window_id": 456]]))
        #expect(!ComputerUseReferenceRuntime.permitsBackgroundDelivery(["scope": "desktop"]))
        #expect(!ComputerUseReferenceRuntime.permitsBackgroundDelivery(["target": ["kind": "desktop"]]))
        #expect(ComputerUseReferenceRuntime.allowedTools.contains("move_cursor"))
        #expect(ComputerUseReferenceRuntime.permitsBackgroundDelivery(["delivery_mode": "background"]))
        #expect(!ComputerUseReferenceRuntime.permitsBackgroundDelivery(["delivery_mode": "foreground"]))
        #expect(!ComputerUseReferenceRuntime.permitsBackgroundDelivery(["delivery_mode": true]))
    }

    @Test("Locked sessions stop before calling the model or acquiring a window")
    func lockedSessionPreflight() async {
        var config = AppConfig()
        config.computerUseBackgroundMode = true
        let runtime = ComputerUsePlannerRuntime(config: config, plan: { _ in
            Issue.record("Planner must not be called while locked")
            return ComputerUsePlannerResponse(toolCall: .init(tool: .finish, reason: "unexpected"))
        }, isScreenLocked: { true })
        let result = await runtime.run(command: "Draft without posting")
        #expect(result.status == .failed)
        #expect(result.message.contains("unlocked Mac"))
    }

    @Test("Background writing cannot bypass the scoped executor")
    func writingUsesBackgroundBoundary() async {
        var config = AppConfig()
        config.enableComputerUsePlanner = true
        config.computerUseBackgroundMode = true
        let runtime = ComputerUsePlannerRuntime(config: config, maxSteps: 1,
            prepareEdit: { _, _ in
                Issue.record("Background edits must not use the foreground writing path")
                throw CancellationError()
            }, plan: { _ in
                ComputerUsePlannerResponse(toolCall: .init(tool: .editText,
                    elementID: "missing", instruction: "Rewrite this", scope: "field"))
            }, isScreenLocked: { false })
        let result = await runtime.run(command: "Rewrite the acquired field")
        #expect(result.status == .failed)
        #expect(result.traceEvents.contains { $0.kind == "tool_result" && $0.body.contains("No acquired background window") })
    }

    @Test("Corroboration refuses blank titles and same-frame sibling ambiguity")
    func exactCorroboration() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let facts = [ComputerUseWindowIdentity.WindowFact(id: 1, frame: frame, title: "owned"),
                     ComputerUseWindowIdentity.WindowFact(id: 2, frame: frame, title: "user")]
        #expect(ComputerUseWindowIdentity.corroboratedID(frame: frame, title: "owned", windows: facts) == 1)
        #expect(ComputerUseWindowIdentity.corroboratedID(frame: frame, title: "", windows: facts) == nil)
        #expect(ComputerUseWindowIdentity.corroboratedID(frame: frame, title: "missing", windows: facts) == nil)
        #expect(ComputerUseWindowIdentity.corroboratedID(frame: frame, title: "owned", windows: facts + [.init(id: 3, frame: frame, title: "owned")]) == nil)
    }

    @Test("Chrome setter error does not discard successful enablement readback")
    func enablementReadback() {
        var flag = false
        let applied = ComputerUseWindowIdentity.ensureEnablement(read: { flag }, write: {
            flag = true
            return .notImplemented
        })
        #expect(applied.enabled)
        #expect(applied.status == .notImplemented)
        let rejected = ComputerUseWindowIdentity.ensureEnablement(read: { false }, write: { .cannotComplete })
        #expect(!rejected.enabled)
        let already = ComputerUseWindowIdentity.ensureEnablement(read: { true }, write: {
            Issue.record("Do not rewrite an enabled attribute")
            return .success
        })
        #expect(already.enabled && !already.requested)
    }

    @Test("Off-Space windows remain candidates when AXWindows is empty")
    func offSpaceCandidates() {
        #expect(ComputerUseWindowIdentity.windowCandidates(listed: [Int](), focused: 30365, main: 30365) == [30365])
        #expect(ComputerUseWindowIdentity.windowCandidates(listed: [1, 2], focused: 2, main: 3) == [1, 2, 3])
        #expect(ComputerUseWindowIdentity.windowCandidates(listed: [Int](), focused: nil, main: nil).isEmpty)
        let owned = ComputerUseBackgroundTarget(processID: 42, windowID: 30365, bundleID: "fixture")
        #expect(!owned.accepts(processID: 42, windowID: 1, bundleID: "fixture"))
    }

    @Test("User working in another app cannot be classified as a target-window focus steal")
    func unrelatedWindowChanges() {
        #expect(!ComputerUseBackgroundFocusGuard.isUnexpectedWindowChange(prior: 1, current: 2, targetWasFrontmost: false, userActed: false))
        #expect(!ComputerUseBackgroundFocusGuard.isUnexpectedWindowChange(prior: 1, current: 2, targetWasFrontmost: true, userActed: true))
        #expect(ComputerUseBackgroundFocusGuard.isUnexpectedWindowChange(prior: 1, current: 2, targetWasFrontmost: true, userActed: false))
        #expect(!ComputerUseBackgroundFocusGuard.isUnexpectedWindowChange(prior: 1, current: nil, targetWasFrontmost: true, userActed: false))
    }

    @Test("Missing background target never captures the user's window")
    func noTargetObservation() {
        let registry = ComputerUseElementRegistry()
        let state = ComputerUseObservationCapture.captureBackground(registry: registry, includeScreenshot: true, target: nil)
        #expect(state.elements.isEmpty)
        #expect(state.screenshot == nil)
        #expect(state.focusedElement == nil)
        #expect(state.selectedText == nil)
        #expect(state.cursorPosition == nil)
        #expect(registry.currentScreenshot() == nil)
        #expect(registry.backgroundTarget == nil)
    }

    @Test("Unacquired runs refuse actions rather than invoke foreground helpers")
    func noTargetMutation() async {
        let session = ComputerUseBackgroundSession()
        for call in [
            ComputerUseToolCall(tool: .clickElement, elementIndex: 1),
            ComputerUseToolCall(tool: .typeText, text: "should never type"),
            ComputerUseToolCall(tool: .pressKey, key: "return"),
            ComputerUseToolCall(tool: .navigateActiveBrowserTab, url: "https://example.com")
        ] {
            let result = await session.execute(call, registry: ComputerUseElementRegistry())
            #expect(result.status == .unsupported)
        }
        #expect(session.target == nil)
    }

    @Test("Lost window invalidates its snapshot and cannot redirect keyboard input")
    func lostWindow() async {
        let target = ComputerUseBackgroundTarget(processID: -1, windowID: 0, bundleID: "missing.fixture")
        let session = ComputerUseBackgroundSession(target: target)
        let registry = ComputerUseElementRegistry()
        registry.backgroundTarget = target
        let result = await session.execute(ComputerUseToolCall(tool: .pressKey, key: "return"), registry: registry)
        #expect(result.status == .failed)
        #expect(registry.backgroundTarget == nil)
        #expect(session.target == target)
    }

    @Test("A sibling window or process cannot override the acquired identity")
    func targetIsolation() {
        let target = ComputerUseBackgroundTarget(processID: 42, windowID: 9, bundleID: "fixture")
        #expect(target.accepts(processID: nil, windowID: nil, bundleID: ""))
        #expect(target.accepts(processID: 42, windowID: 9, bundleID: "fixture"))
        #expect(!target.accepts(processID: 42, windowID: 10, bundleID: "fixture"))
        #expect(!target.accepts(processID: 43, windowID: 9, bundleID: "fixture"))
        #expect(!target.accepts(processID: 42, windowID: 9, bundleID: "other"))
    }

    @Test("Pointer conversion fails outside the acquired window, including nonfinite values")
    func pointerBounds() {
        let frame = CGRect(x: -400, y: 100, width: 300, height: 200)
        #expect(ComputerUseBackgroundInput.localPoint(CGPoint(x: -350, y: 120), frame: frame) == CGPoint(x: 50, y: 20))
        #expect(ComputerUseBackgroundInput.localPoint(CGPoint(x: 0, y: 120), frame: frame) == nil)
        #expect(ComputerUseBackgroundInput.localPoint(CGPoint(x: Double.nan, y: 120), frame: frame) == nil)
    }

    @Test("Focus recovery does not fight intervening user input or unrelated app activation")
    func focusPolicy() {
        #expect(ComputerUseBackgroundFocusGuard.shouldRestore(activatedBundle: "target", targetBundle: "target", priorPID: 1, activatedPID: 2, userActed: false))
        #expect(!ComputerUseBackgroundFocusGuard.shouldRestore(activatedBundle: "target", targetBundle: "target", priorPID: 1, activatedPID: 2, userActed: true))
        #expect(!ComputerUseBackgroundFocusGuard.shouldRestore(activatedBundle: "other", targetBundle: "target", priorPID: 1, activatedPID: 2, userActed: false))
        #expect(!ComputerUseBackgroundFocusGuard.shouldRestore(activatedBundle: "target", targetBundle: "target", priorPID: 2, activatedPID: 2, userActed: false))
    }

    @Test("Cancellation after synthetic down still delivers its scoped up")
    func balancedCancellation() async throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        let down = try #require(CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true))
        let up = try #require(CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false))
        let task = Task { @MainActor in
            var delivered: [CGEventType] = []
            let posted = ComputerUseBackgroundInput.postPair(down, up, pid: 42) { event, pid in
                #expect(pid == 42)
                delivered.append(event.type)
                if event.type == .keyDown { withUnsafeCurrentTask { $0?.cancel() } }
            }
            #expect(posted)
            #expect(delivered == [.keyDown, .keyUp])
            #expect(!ComputerUseBackgroundInput.postPair(down, up, pid: 42) { _, _ in Issue.record("Post after cancellation") })
        }
        await task.value
    }

    @Test("Background preference survives persistence and old configs retain foreground default")
    func configRoundTrip() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(!old.computerUseBackgroundMode)
        var config = old
        config.computerUseBackgroundMode = true
        let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.computerUseBackgroundMode)
    }

    @Test("Production runtime wires background observation when the setting is enabled")
    func runtimeWiring() async {
        var config = AppConfig()
        config.computerUseBackgroundMode = true
        let runtime = ComputerUsePlannerRuntime(config: config, plan: { request in
            #expect(request.observation.screenshot == nil)
            #expect(request.observation.elements.isEmpty)
            #expect(request.observation.appInstructions?.contains("BACKGROUND MODE") == true)
            return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "Fixture observation complete"))
        }, isScreenLocked: { false })
        let result = await runtime.run(command: "Observe the empty background fixture")
        #expect(result.status == .done)
    }
}

extension ComputerUseBackgroundTests {
    @Test("Strict reference background catalog excludes self-activating shortcut routes")
    func referenceShortcutBoundary() {
        let excluded = ["hotkey", "press_key", "invoke_menu", "browser_prepare"]
        let available = ["browser_navigate", "browser_type", "set_value", "move_cursor"]
        let catalog: [[String: Any]] = (excluded + available).map {
            ["name": $0, "inputSchema": ["type": "object"]]
        }
        let names = Set(ComputerUseReferenceRuntime.definitions(from: catalog)
            .compactMap { $0["name"] as? String })
        for name in excluded {
            #expect(!names.contains(name))
            // execute validates against these definitions before driver.call;
            // a hallucinated or stale shortcut must not reach the driver.
            #expect(!ComputerUseReferenceRuntime.allowedTools.contains(name))
        }
        for name in available { #expect(names.contains(name)) }
    }

    @Test("Reference schemas preserve upstream targeting and exclude administration")
    func referenceSchemas() throws {
        let schema: [String: Any] = ["type": "object", "required": ["pid", "window_id"],
                                    "properties": ["pid": ["type": "integer"], "window_id": ["type": "integer"]]]
        let catalog: [[String: Any]] = [
            ["name": "get_window_state", "inputSchema": schema],
            ["name": "kill_app", "inputSchema": schema]
        ]
        let definitions = ComputerUseReferenceRuntime.definitions(from: catalog)
        #expect(definitions.compactMap { $0["name"] as? String } == ["get_window_state", "finish", "fail"])
        let forwarded = try #require(definitions.first?["parameters"] as? [String: Any])
        #expect(NSDictionary(dictionary: forwarded).isEqual(to: schema))
    }

    @Test("Reference history retires old page refs but preserves all mutation outcomes and identity")
    func referenceSnapshotHistory() {
        let summary = ComputerUseReferenceRuntime.snapshotHistorySummary(from: ["result": ["structuredContent": [
            "status": "ok", "mode": "snapshot", "target_id": "target-1", "tab_id": "tab-1",
            "page": ["url": "https://example.com/post/1"], "refs": [["ref": "p1:1"]], "outline": "old page"
        ]]])
        #expect(summary?.contains("target-1") == true)
        #expect(summary?.contains("p1:1") == false)
        #expect(summary?.contains("retired") == true)
        #expect(summary?.contains("old page") == true)
        typealias Entry = ComputerUseReferenceRuntime.HistoryEntry
        let history = ComputerUseReferenceRuntime.plannerHistory(prefix: "original instruction", entries: [
            Entry(call: "read 1", observation: "old refs", staleSnapshot: summary),
            Entry(call: "submit reply", observation: "outcome uncertain: do not submit again", staleSnapshot: nil),
            Entry(call: "read 2", observation: "recent refs", staleSnapshot: summary),
            Entry(call: "read 3", observation: "fresh refs", staleSnapshot: summary)
        ])
        #expect(!history.contains("old refs"))
        #expect(history.contains("recent refs") && history.contains("fresh refs"))
        #expect(history.contains("outcome uncertain: do not submit again"))
        #expect(history.contains("original instruction") && history.contains("target-1"))
        #expect(ComputerUseReferenceRuntime.snapshotHistorySummary(from: ["result": ["isError": true]]) == nil)
    }

    @Test("Reference history retires superseded tab inventories while retaining window identity")
    func referenceBindingHistory() {
        let summary = ComputerUseReferenceRuntime.snapshotHistorySummary(from: ["result": ["structuredContent": [
            "status": "ok", "mode": "bind", "target_id": "old-binding", "pid": 42,
            "binding_quality": "exact", "tabs": [["tab_id": "obsolete-tab", "url": "https://example.com"]]
        ]]])
        #expect(summary?.contains("old-binding") == true)
        #expect(summary?.contains("exact") == true)
        #expect(summary?.contains("obsolete-tab") == false)
        #expect(summary?.contains("retired_tab_count") == true)
    }

    @Test("Reference observations keep target image bytes out of text history")
    func referenceObservation() {
        let windows = ComputerUseReferenceRuntime.observation(from: ["result": [
            "content": [["type": "text", "text": "Found 1 window(s)."]],
            "structuredContent": ["windows": [["pid": 1252, "window_id": 42]]]
        ]])
        #expect(windows.text.contains("Found 1 window(s)."))
        #expect(windows.text.contains("\"window_id\":42"))
        let response: [String: Any] = ["result": ["content": [
            ["type": "text", "text": "Exact target window 42"],
            ["type": "image", "mimeType": "image/png", "data": "aGVsbG8="]
        ]]]
        let observed = ComputerUseReferenceRuntime.observation(from: response)
        #expect(observed.text == "Exact target window 42")
        #expect(observed.image == "data:image/png;base64,aGVsbG8=")
        let failure = ComputerUseReferenceRuntime.observation(from: ["result": ["content": [["type": "text", "text": "Permission denied"]], "isError": true]])
        #expect(failure.image == nil)
        #expect(failure.text == "Permission denied")
    }
}

extension ComputerUseBackgroundTests {
    @Test("Disconnected background browser calls cannot reach the transport or launch setup")
    func manualChromeConnectionBoundary() async throws {
        let driver = ComputerUseReferenceDriver()
        for name in ["browser_prepare", "get_browser_state", "browser_navigate", "browser_click"] {
            let result = try await driver.callInBackground(name: name, arguments: ["delivery_mode": "foreground"])
            #expect((result["result"] as? [String: Any])?["isError"] as? Bool == true)
            #expect(ComputerUseReferenceRuntime.observation(from: result).text.contains("Settings > Permissions"))
            #expect(driver.processID == nil)
            #expect(driver.chromeAccess == .notConnected)
        }
    }
}

extension ComputerUseBackgroundTests {
    @Test("Chrome reconnect status follows driver refusal codes, not untrusted page text")
    func chromeReconnectRefusals() {
        for code in ["browser_requires_setup", "browser_consent_required", "browser_consent_revoked", "browser_reconnect_exhausted"] {
            #expect(ComputerUseReferenceDriver.requiresChromeReconnect(["result": ["structuredContent": ["refusal": ["code": code]]]]))
        }
        #expect(!ComputerUseReferenceDriver.requiresChromeReconnect(["result": ["structuredContent": ["refusal": ["code": "browser_ref_stale"]]]]))
        #expect(!ComputerUseReferenceDriver.requiresChromeReconnect(["result": ["content": [["type": "text", "text": "browser_consent_required"]]]]))
    }
}

extension ComputerUseBackgroundTests {
    @Test("Chrome Connect waits only for a missing endpoint and preserves other failures")
    func chromePreparationStates() {
        #expect(ComputerUseReferenceDriver.chromePreparationOutcome(["result": ["structuredContent": ["refusal": ["code": "browser_consent_required"]]]]) == .waitingForApproval)
        #expect(ComputerUseReferenceDriver.chromePreparationOutcome(["result": ["structuredContent": ["refusal": ["code": "background_unavailable", "message": "Cannot attach safely"]]]]) == .failed("Cannot attach safely"))
        #expect(ComputerUseReferenceDriver.chromePreparationOutcome(["result": ["structuredContent": ["refusal": ["code": "browser_requires_setup", "message": "Enable debugging"]]]]) == .waitingForDebugging)
        #expect(ComputerUseReferenceDriver.chromePreparationOutcome(["result": ["structuredContent": ["refusal": ["code": "browser_wrong_target_refused", "message": "No exact window"]]]]) == .failed("No exact window"))
        #expect(ComputerUseReferenceDriver.chromePreparationOutcome(["result": ["structuredContent": ["prepared": true]]]) == .connected)
        #expect(ComputerUseReferenceDriver.chromePreparationOutcome(["result": ["structuredContent": ["prepared": false]]]) != .connected)
    }
}

extension ComputerUseBackgroundTests {
    @Test("Chrome status requires affirmative live-socket evidence")
    func chromeSocketStatus() {
        #expect(ComputerUseReferenceDriver.chromeConnectionIsLive(["result": ["structuredContent": ["connected": true]]]))
        #expect(!ComputerUseReferenceDriver.chromeConnectionIsLive(["result": ["structuredContent": ["connected": false]]]))
        #expect(!ComputerUseReferenceDriver.chromeConnectionIsLive(["result": ["isError": true, "structuredContent": ["connected": true]]]))
        #expect(!ComputerUseReferenceDriver.chromeConnectionIsLive(["result": ["content": [["type": "text", "text": "Connected"]]]]))
        #expect(!ComputerUseReferenceRuntime.allowedTools.contains("browser_connection_status"))
    }
}

extension ComputerUseBackgroundTests {
    @Test("Chrome disconnect events cannot invalidate a newer connection")
    func chromeDisconnectEventIdentity() {
        #expect(ComputerUseReferenceDriver.isChromeDisconnectEvent(["session": "current", "connected": false], session: "current"))
        #expect(!ComputerUseReferenceDriver.isChromeDisconnectEvent(["session": "previous", "connected": false], session: "current"))
        #expect(!ComputerUseReferenceDriver.isChromeDisconnectEvent(["session": "current", "connected": true], session: "current"))
        #expect(!ComputerUseReferenceDriver.isChromeDisconnectEvent(["connected": false], session: nil))
    }
    @Test("Reference token budget accounts for model, schemas, images and Unicode")
    func referenceTokenBudget() {
        typealias Budget = ComputerUseReferenceRuntime.ContextBudget
        let local = Budget(model: ComputerUseLocalPlanner.models[0].id)
        let hosted = Budget(model: "gpt-6-sol")
        let unknown = Budget(model: "unknown")
        #expect(local.inputTokens < hosted.inputTokens)
        #expect(unknown.inputTokens < local.inputTokens)
        #expect(Budget(model: "gpt-6-sol", contextWindowTokens: 4096).inputTokens < local.inputTokens)
        #expect(Budget.tokens("你好世界") > Budget.tokens("abcd"))
        let text = hosted.historyAllowance(instructions: "system", tools: [], hasImage: false)
        #expect(hosted.historyAllowance(instructions: "system", tools: [], hasImage: true) == text - 8192)
        #expect(hosted.historyAllowance(instructions: "system", tools: [["schema": String(repeating: "x", count: 3000)]], hasImage: false) < text)
    }

    @Test("Reference compaction fits complete observations without dropping action evidence")
    func referenceBudgetedHistory() throws {
        typealias Runtime = ComputerUseReferenceRuntime
        let large = String(repeating: "snapshot data ", count: 2000)
        let entries = [
            Runtime.HistoryEntry(call: "read 1", observation: large, staleSnapshot: "Earlier identity and facts"),
            Runtime.HistoryEntry(call: "submit", observation: "outcome uncertain; NEVER repeat", staleSnapshot: nil),
            Runtime.HistoryEntry(call: "read 2", observation: large, staleSnapshot: "Verified account and destination")
        ]
        let history = try #require(Runtime.budgetedHistory(prefix: "USER: original task", entries: entries, tokens: 500))
        #expect(Runtime.ContextBudget.tokens(history) <= 500)
        #expect(history.contains("original task"))
        #expect(history.contains("Earlier identity and facts"))
        #expect(history.contains("outcome uncertain; NEVER repeat"))
        #expect(history.contains("Verified account and destination"))
        #expect(Runtime.budgetedHistory(prefix: "original", entries: entries, tokens: 1) == nil)
    }

    @Test("Reference compaction deduplicates facts while preserving distinct evidence")
    func referenceRepeatedFacts() throws {
        typealias Runtime = ComputerUseReferenceRuntime
        func entry(_ fact: String) -> Runtime.HistoryEntry {
            let response: [String: Any] = ["structuredContent": ["status": "ok", "mode": "snapshot", "outline": fact]]
            return .init(call: "read", observation: String(repeating: "full ", count: 3000),
                         staleSnapshot: Runtime.snapshotHistorySummary(from: response))
        }
        let history = try #require(Runtime.budgetedHistory(prefix: "task", entries: [entry("same fact"), entry("same fact"), entry("same fact\nunique fact")], tokens: 1000))
        #expect(history.contains("same fact") && history.contains("unique fact"))
        #expect(history.contains("facts_identical_to_history_entry"))
    }

    @Test("Infrastructure failures preserve uncertain side effects without claiming success")
    func referenceIncompleteOutcome() {
        typealias Runtime = ComputerUseReferenceRuntime
        for reason in ["context exhausted", "verification timed out", "planner unavailable", "step limit"] {
            let (status, message) = Runtime.terminalOutcome(.failed, message: reason, attemptedMutation: true)
            #expect(status == .incomplete)
            #expect(message.contains(reason) && message.contains("Do not repeat"))
            #expect(NotchOutcome.computerUse(status) == .incomplete)
        }
        #expect(Runtime.terminalOutcome(.failed, message: "no action", attemptedMutation: false).0 == .failed)
        #expect(Runtime.terminalOutcome(.done, message: "Verified reply", attemptedMutation: true).0 == .done)
        let cancelled = Runtime.terminalOutcome(.cancelled, message: "Stopped", attemptedMutation: true)
        #expect(cancelled.0 == .cancelled && cancelled.1.contains("may already"))
    }

    @Test("Saved reference history fits the planner budget without executing tools",
          .enabled(if: ProcessInfo.processInfo.environment["MUESLI_REFERENCE_HISTORY_REPLAY_ROOT"] != nil))
    func referenceSavedHistoryReplay() throws {
        typealias Runtime = ComputerUseReferenceRuntime
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MUESLI_REFERENCE_HISTORY_REPLAY_ROOT"]))
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tools.json"))) as? [String: Any]
        let tools = Runtime.definitions(from: try #require((catalog?["result"] as? [String: Any])?["tools"] as? [[String: Any]]))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("call-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var entries: [Runtime.HistoryEntry] = []
        let budget = Runtime.ContextBudget(model: "gpt-6-sol")
        var largest = 0
        var progress = Runtime.ObservationProgress()
        var guidanceCount = 0
        for file in files {
            let call = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let name = try #require(call["tool"] as? String)
            guard Runtime.allowedTools.contains(name) else { continue }
            let response = try #require(call["response"] as? [String: Any])
            let observed = Runtime.observation(from: response)
            let arguments = try JSONSerialization.data(withJSONObject: call["arguments"] ?? [:], options: [.sortedKeys])
            let guidance = progress.guidance(tool: name, arguments: call["arguments"] as? [String: Any] ?? [:], response: response)
            if guidance != nil { guidanceCount += 1 }
            entries.append(.init(call: name + " " + String(decoding: arguments, as: UTF8.self),
                                 observation: observed.text + (guidance.map { "\nRuntime observation guidance: " + $0 } ?? ""),
                                 staleSnapshot: Runtime.snapshotHistorySummary(from: response)))
            let allowance = budget.historyAllowance(instructions: Runtime.instructions, tools: tools, hasImage: observed.image != nil)
            let candidate = Runtime.budgetedHistory(prefix: String(repeating: "original command ", count: 100), entries: entries, tokens: allowance)
            // Avoid dumping private saved page observations in a failed assertion.
            try #require(candidate != nil, "Saved history exceeded its allowance at entry \(entries.count)")
            let history = candidate ?? ""
            largest = max(largest, Runtime.ContextBudget.tokens(history))
        }
        #expect(!entries.isEmpty)
        print("Reference replay: \(entries.count) calls; \(guidanceCount) observation guidance messages; peak estimated history \(largest) tokens; input budget \(budget.inputTokens)")
    }

}

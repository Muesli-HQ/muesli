import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use background boundaries", .serialized)
@MainActor
struct ComputerUseBackgroundTests {
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
        let excluded = ["hotkey", "press_key", "invoke_menu"]
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

import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use background boundaries", .serialized)
@MainActor
struct ComputerUseBackgroundTests {
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
        })
        let result = await runtime.run(command: "Observe the empty background fixture")
        #expect(result.status == .done)
    }
}

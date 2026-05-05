import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use planner response")
struct ComputerUsePlannerResponseTests {
    @Test("decodes valid top-level tool call")
    func decodesValidToolCall() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"open_app","app_name":"Google Chrome"}"#)

        #expect(response.toolCall.tool == .openApp)
        #expect(response.toolCall.appName == "Google Chrome")
    }

    @Test("decodes wrapped tool call")
    func decodesWrappedToolCall() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool_call":{"tool":"press_key","modifiers":["command"],"key":"l"}}"#
        )

        #expect(response.toolCall.tool == .pressKey)
        #expect(response.toolCall.modifiers == [.command])
        #expect(response.toolCall.key == "l")
    }

    @Test("decodes coordinate tool calls")
    func decodesCoordinateToolCalls() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"click_point","screenshot_id":"s1","x":120,"y":240,"label":"Search"}"#
        )

        #expect(response.toolCall.tool == .clickPoint)
        #expect(response.toolCall.screenshotID == "s1")
        #expect(response.toolCall.x == 120)
        #expect(response.toolCall.y == 240)
    }

    @Test("malformed JSON fails safely")
    func malformedJSONFailsSafely() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(from: "open chrome")
        }
    }

    @Test("unknown tool names fail safely")
    func unknownToolFailsSafely() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"run_shell","command":"open Chrome"}"#)
        }
    }

    @Test("extra fields do not bypass required argument validation")
    func extraFieldsDoNotBypassValidation() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"open_app","text":"Google Chrome"}"#)
        }
    }

    @Test("risky tool calls require confirmation")
    func riskyToolCallsRequireConfirmation() throws {
        let click = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"click_element","element_id":"e2","label":"Send"}"#)
        let key = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"press_key","modifiers":["command"],"key":"q"}"#)

        #expect(click.toolCall.requiresConfirmation)
        #expect(key.toolCall.requiresConfirmation)
    }
}

@Suite("Computer Use observation shaping")
struct ComputerUseObservationTests {
    @Test("candidate labels normalize")
    func labelsNormalize() {
        let candidate = ComputerUseObservationCapture.candidateForTests(
            elementID: "e1",
            role: "AXButton",
            title: "Search Field!",
            label: "Main Search"
        )

        #expect(candidate.normalizedText == "search field main search")
    }

    @Test("disabled elements are preserved")
    func disabledElementsArePreserved() {
        let candidate = ComputerUseObservationCapture.candidateForTests(
            elementID: "e1",
            role: "AXButton",
            title: "Submit",
            enabled: false,
            frame: ComputerUseRect(x: 1, y: 2, width: 3, height: 4)
        )

        #expect(candidate.enabled == false)
        #expect(candidate.frame == ComputerUseRect(x: 1, y: 2, width: 3, height: 4))
    }
}

@Suite("Computer Use trace formatting")
struct ComputerUseTraceFormatterTests {
    @Test("hides redundant lifecycle statuses")
    func hidesRedundantLifecycleStatuses() {
        let planning = ComputerUseTraceEvent(kind: "planning", title: "Planning", body: "Step 1", status: "planning", step: 1)
        let result = ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Clicked", status: "executed", step: 1)

        #expect(ComputerUseTraceFormatter.displayStatus(for: planning) == nil)
        #expect(ComputerUseTraceFormatter.displayStatus(for: result) == "executed")
    }
}

@Suite("Computer Use planner runtime")
struct ComputerUsePlannerRuntimeTests {
    @Test("finishes after finish tool")
    @MainActor
    func finishesAfterFinishTool() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done")) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open chrome")

        #expect(result.status == .done)
        #expect(result.message == "done")
        #expect(result.traceEvents.contains { $0.kind == "model_output" })
        #expect(result.traceEvents.contains { $0.kind == "finish" })
    }

    @Test("default runtime uses a high safety step cap")
    @MainActor
    func defaultRuntimeUsesHighSafetyStepCap() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _ in Self.observation() },
            plan: { request in
                #expect(request.maxSteps == 100)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "do a longer workflow")

        #expect(result.status == .done)
        #expect(result.traceEvents.contains { $0.body.contains("Step 1 of 100") })
    }

    @Test("stops at max step count")
    @MainActor
    func stopsAtMaxStepCount() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            maxSteps: 2,
            observe: { _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .observe)) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "look around")

        #expect(result.status == .failed)
        #expect(result.message == "CUA reached its step limit")
    }

    @Test("stops after one repeated no-op tool call")
    @MainActor
    func stopsRepeatedNoOpToolCalls() async {
        var executionCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _ in Self.observation() },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                    tool: .clickElement,
                    elementID: "e1",
                    label: "Address and search bar"
                ))
            },
            execute: { _, _ in
                executionCount += 1
                return .executed("Clicked")
            }
        )

        let result = await runtime.run(command: "search in chrome")

        #expect(result.status == .failed)
        #expect(result.message.contains("one retry of click Address and search bar"))
        #expect(executionCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Repeated action stopped" })
    }

    @Test("stops on confirmation-required action")
    @MainActor
    func stopsOnConfirmationRequiredAction() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _ in Self.observation() },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                    tool: .clickElement,
                    elementID: "e1",
                    label: "Send"
                ))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "send it")

        #expect(result.status == .needsConfirmation)
        #expect(result.message == "Confirm: click Send")
    }

    @Test("fails when planner is unavailable")
    @MainActor
    func failsWhenPlannerUnavailable() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _ in Self.observation() },
            plan: { _ in throw ComputerUsePlannerError.notAuthenticated },
            execute: { _, _ in .failed("unexpected") }
        )

        let result = await runtime.run(command: "open Google Chrome")

        #expect(result.status == .failed)
        #expect(result.message == ComputerUsePlannerError.notAuthenticated.localizedDescription)
        #expect(!result.traceEvents.contains { $0.kind == "fallback" })
        #expect(!result.traceEvents.contains { $0.title == "Rule parser" })
    }

    @Test("does not override planner app choice with parser fallback")
    @MainActor
    func doesNotOverridePlannerAppChoiceWithParserFallback() async {
        var executedTools: [ComputerUseToolCall] = []
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _ in Self.observation() },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .openApp, appName: "Google Chrome"))
                }
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { toolCall, _ in
                executedTools.append(toolCall)
                return .executed("Opened Google Chrome")
            }
        )

        let result = await runtime.run(command: "open the tail scale app")

        #expect(result.status == .done)
        #expect(result.message == "done")
        #expect(executedTools.map(\.tool) == [.openApp])
        #expect(executedTools.first?.appName == "Google Chrome")
        #expect(!result.traceEvents.contains { $0.kind == "fallback" })
        #expect(!result.traceEvents.contains { $0.title == "Planner app mismatch" })
    }

    @Test("fails when planner mode is disabled")
    @MainActor
    func failsWhenPlannerModeDisabled() async {
        var config = AppConfig()
        config.enableComputerUsePlanner = false
        let runtime = ComputerUsePlannerRuntime(
            config: config,
            observe: { _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish)) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open Google Chrome")

        #expect(result.status == .failed)
        #expect(result.message == "CUA planner is disabled.")
        #expect(!result.traceEvents.contains { $0.kind == "fallback" })
    }

    @Test("rejects non-schema planner output")
    @MainActor
    func rejectsNonSchemaPlannerOutput() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _ in Self.observation() },
            plan: { _ in
                _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"open_app","text":"Google Chrome"}"#)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "something unsupported by parser")

        #expect(result.status == .failed)
    }

    @Test("observes screen before coordinate action")
    @MainActor
    func observesScreenBeforeCoordinateAction() async {
        var planCount = 0
        var includeScreenshotValues: [Bool] = []
        var executedTool: ComputerUseToolName?
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, includeScreenshot in
                includeScreenshotValues.append(includeScreenshot)
                return Self.observation(screenshot: includeScreenshot ? Self.screenshot() : nil)
            },
            plan: { request in
                planCount += 1
                if request.observation.screenshot == nil {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .observeScreen))
                }
                if planCount == 2 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .clickPoint,
                        screenshotID: "s1",
                        label: "Search",
                        x: 40,
                        y: 50
                    ))
                }
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { toolCall, _ in
                executedTool = toolCall.tool
                return .executed("Clicked point")
            }
        )

        let result = await runtime.run(command: "click the search field")

        #expect(result.status == .done)
        #expect(includeScreenshotValues == [false, true, true])
        #expect(executedTool == .clickPoint)
        #expect(result.traceEvents.contains { $0.body.contains("screenshot s1") })
    }

    private static func observation(screenshot: ComputerUseScreenshotObservation? = nil) -> ComputerUseObservation {
        ComputerUseObservation(
            appName: "Test",
            bundleID: "com.example.Test",
            windowTitle: "Window",
            windowFrame: nil,
            screenshot: screenshot,
            cursorPosition: ComputerUseRect(x: 10, y: 20, width: 1, height: 1),
            elements: [
                ComputerUseObservationCapture.candidateForTests(
                    elementID: "e1",
                    role: "AXButton",
                    title: "Send"
                ),
            ],
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func screenshot() -> ComputerUseScreenshotObservation {
        ComputerUseScreenshotObservation(
            screenshotID: "s1",
            width: 100,
            height: 80,
            windowFrame: ComputerUseRect(x: 0, y: 0, width: 100, height: 80),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: "data:image/jpeg;base64,"
        )
    }
}

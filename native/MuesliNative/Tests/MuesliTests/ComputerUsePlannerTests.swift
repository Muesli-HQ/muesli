import Foundation
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

@Suite("Computer Use planner runtime")
struct ComputerUsePlannerRuntimeTests {
    @Test("finishes after finish tool")
    @MainActor
    func finishesAfterFinishTool() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done")) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open chrome")

        #expect(result.status == .done)
        #expect(result.message == "done")
    }

    @Test("stops at max step count")
    @MainActor
    func stopsAtMaxStepCount() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            maxSteps: 2,
            observe: { _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .observe)) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "look around")

        #expect(result.status == .failed)
        #expect(result.message == "CUA reached its step limit")
    }

    @Test("stops on confirmation-required action")
    @MainActor
    func stopsOnConfirmationRequiredAction() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _ in Self.observation() },
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

    @Test("falls back to parser when planner is unavailable")
    @MainActor
    func fallsBackToParserWhenPlannerUnavailable() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _ in Self.observation() },
            plan: { _ in throw ComputerUsePlannerError.notAuthenticated },
            execute: { _, _ in .failed("unexpected") },
            executeParsed: { _ in .executed("Opened google chrome") }
        )

        let result = await runtime.run(command: "open Google Chrome")

        #expect(result.status == .done)
        #expect(result.message == "Done: open google chrome")
    }

    @Test("rejects non-schema planner output")
    @MainActor
    func rejectsNonSchemaPlannerOutput() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _ in Self.observation() },
            plan: { _ in
                _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"open_app","text":"Google Chrome"}"#)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "something unsupported by parser")

        #expect(result.status == .failed)
    }

    private static func observation() -> ComputerUseObservation {
        ComputerUseObservation(
            appName: "Test",
            bundleID: "com.example.Test",
            windowTitle: "Window",
            windowFrame: nil,
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
}

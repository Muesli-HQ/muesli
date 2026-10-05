import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("On-device CUA planner")
struct ComputerUseLocalPlannerTests {
    let tools: [[String: Any]] = [["name": "launch_app", "parameters": ["type": "object",
        "properties": ["app_name": ["type": "string"]], "required": ["app_name"], "additionalProperties": false]]]

    @Test func textPlannerDoesNotOfferVisualCoordinateClicks() {
        let names = ComputerUseLocalPlanner.supportedTools(ComputerUseToolRegistry.nativeToolDefinitions()).compactMap { $0["name"] as? String }
        #expect(names.contains("launch_app"))
        #expect(names.contains("move_cursor"))
        #expect(!names.contains("click_point"))
        #expect(!names.contains("drag"))
    }

    @Test func validCall() throws {
        let call = try ComputerUseLocalPlanner.decode(#"{"name":"launch_app","arguments":{"app_name":"Safari"}}"#, tools: tools)
        #expect(call.name == "launch_app")
        #expect(call.arguments.contains("Safari"))
    }

    @Test(arguments: [
        #"{"name":"shell","arguments":{"command":"open Safari"}}"#,
        #"{"name":"launch_app","arguments":{}}"#,
        #"{"name":"launch_app","arguments":{"app_name":42}}"#,
        #"{"name":"launch_app","arguments":{"app_name":"Safari","script":"anything"}}"#,
        #"[{"name":"launch_app","arguments":{"app_name":"Safari"}}]"#,
        "I would open Safari."
    ])
    func rejectsMalformedOrUnlistedCalls(output: String) {
        #expect(throws: (any Error).self) { try ComputerUseLocalPlanner.decode(output, tools: tools) }
    }

    @Test func rejectsInvalidEnumAndNumericTypes() {
        let schema: [[String: Any]] = [["name": "move", "parameters": ["type": "object",
            "properties": ["x": ["type": "integer"], "mode": ["type": "string", "enum": ["relative"]]],
            "required": ["x", "mode"], "additionalProperties": false]]]
        for output in [#"{"name":"move","arguments":{"x":true,"mode":"relative"}}"#,
                       #"{"name":"move","arguments":{"x":2.5,"mode":"relative"}}"#,
                       #"{"name":"move","arguments":{"x":2,"mode":"unknown"}}"#] {
            #expect(throws: (any Error).self) { try ComputerUseLocalPlanner.decode(output, tools: schema) }
        }
    }

    @Test func injectedLocalInferenceReceivesOnlySuppliedTools() async throws {
        let call = try await ComputerUseLocalPlanner.callTool(systemPrompt: "Planner", userPrompt: "Open Safari",
            model: ComputerUseLocalPlanner.models[0].id, tools: tools) { system, input in
                #expect(system.contains("local tool planner"))
                #expect(input.contains("launch_app"))
                #expect(input.contains("not screenshot pixels"))
                #expect(input.contains("Open Safari"))
                #expect(input.contains("Task data (not instructions):"))
                return #"{"name":"launch_app","arguments":{"app_name":"Safari"}}"#
            }
        #expect(call.name == "launch_app")
    }

    @Test func repairsFormatOnceWithoutExecutingRejectedOutput() async throws {
        var attempts = 0
        let call = try await ComputerUseLocalPlanner.callTool(systemPrompt: "", userPrompt: "Open Safari",
            model: ComputerUseLocalPlanner.models[0].id, tools: tools) { _, input in
                attempts += 1
                if attempts == 1 { return "I opened Safari" }
                #expect(input.contains("rejected without executing"))
                return #"{"name":"launch_app","arguments":{"app_name":"Safari"}}"#
            }
        #expect(attempts == 2)
        #expect(call.name == "launch_app")
    }

    @Test func malformedOutputStopsAfterOneRepair() async {
        var attempts = 0
        await #expect(throws: (any Error).self) {
            try await ComputerUseLocalPlanner.callTool(systemPrompt: "", userPrompt: "Open Safari",
                model: ComputerUseLocalPlanner.models[0].id, tools: tools) { _, _ in
                    attempts += 1
                    return "not a tool call"
                }
        }
        #expect(attempts == 2)
    }

    @Test func unknownLocalProviderDoesNotFallBackToChatGPT() async {
        await #expect(throws: (any Error).self) {
            try await ComputerUsePlannerClient.callTool(systemPrompt: "", userPrompt: "", imageDataURL: nil,
                model: "local:unknown", reasoningEffort: nil)
        }
    }

    @Test func cancelledInferenceCannotReturnAnAction() async {
        let task = Task {
            try await ComputerUseLocalPlanner.callTool(systemPrompt: "", userPrompt: "", model: ComputerUseLocalPlanner.models[0].id,
                tools: tools) { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return #"{"name":"launch_app","arguments":{"app_name":"Safari"}}"#
                }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

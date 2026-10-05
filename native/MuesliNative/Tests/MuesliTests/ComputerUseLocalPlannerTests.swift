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

    @Test func localWritingRejectsHostedBackends() throws {
        var config = AppConfig()
        for backend in LLMBackendOption.all {
            config.quilBackend = backend.backend
            #expect(throws: (any Error).self) { try WritingService.validatePolicy(config: config, localOnly: true) }
        }
        config.quilBackend = TranscriptCleanupBackendOption.gemma4LiteRT.backend
        try WritingService.validatePolicy(config: config, localOnly: true)
    }

    @Test func editTextContractPreservesScopeAndInstruction() throws {
        let raw = #"{"tool":"edit_text","element_id":"e2","scope":"selection","instruction":"Make this shorter"}"#
        let call = try JSONDecoder().decode(ComputerUseToolCall.self, from: Data(raw.utf8)).normalizedPlannerOutput()
        #expect(call.validationFailure() == nil)
        #expect(call.scope == "selection")
        #expect(call.instruction == "Make this shorter")
        #expect(call.isMutating)
        #expect(ComputerUseToolCall(tool: .editText, elementID: "e2", instruction: "Shorten").validationFailure() != nil)
        #expect(ComputerUseToolCall(tool: .editText, instruction: "Shorten", scope: "field").validationFailure() != nil)
        #expect(ComputerUseLocalPlanner.supportedTools(ComputerUseToolRegistry.nativeToolDefinitions()).contains { $0["name"] as? String == "edit_text" })
    }

    @Test @MainActor func writingUsesCapturedTextAndChecksAgainBeforeApply() async throws {
        var current = true
        var writes: [String] = []
        let target = ComputerUseTextEditing.Target(text: "Original", isCurrent: { current }, write: {
            writes.append($0); return .executed("verified")
        })
        let prepared = try await ComputerUseTextEditing.prepare(target: target, instruction: "Shorten") { text, instruction in
            #expect(text == "Original")
            #expect(instruction == "Shorten")
            return "Short"
        }
        #expect(writes.isEmpty)
        current = false
        #expect(prepared.apply().status == .failed)
        #expect(writes.isEmpty)
    }

    @Test @MainActor func writingRejectsTargetChangeDuringGeneration() async {
        var current = true
        var writes = 0
        let target = ComputerUseTextEditing.Target(text: "Before", isCurrent: { current }, write: { _ in writes += 1; return .executed("written") })
        await #expect(throws: QuilTransformationError.selectionChanged) {
            try await ComputerUseTextEditing.prepare(target: target, instruction: "Rewrite") { _, _ in
                current = false
                return "After"
            }
        }
        #expect(writes == 0)
    }

    @Test @MainActor func writingCancellationCannotApplyLateOutput() async {
        var writes = 0
        let task = Task { @MainActor in
            let target = ComputerUseTextEditing.Target(text: "Before", isCurrent: { true }, write: { _ in writes += 1; return .executed("written") })
            return try await ComputerUseTextEditing.prepare(target: target, instruction: "Rewrite") { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "After"
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(writes == 0)
    }

    @Test @MainActor func writingAppliesValidatedOutputAndPropagatesReadbackFailure() async throws {
        var written = ""
        let target = ComputerUseTextEditing.Target(text: "", isCurrent: { true }, write: {
            written = $0; return .failed("Write accepted but readback differs")
        })
        let edit = try await ComputerUseTextEditing.prepare(target: target, instruction: "Write a greeting") { _, _ in "Hello" }
        #expect(edit.apply().status == .failed)
        #expect(written == "Hello")
    }

    @Test @MainActor func writingThinkingDoesNotConsumeExecutionBudget() async {
        var clock: TimeInterval = 0
        var planned = 0
        var writes = 0
        let runtime = ComputerUsePlannerRuntime(config: AppConfig(), timeoutSeconds: 5, now: { clock },
            prepareEdit: { _, _ in
                clock += 100
                return PreparedComputerUseTextEdit { writes += 1; clock += 1; return .executed("Text updated") }
            }, observe: { _, _, _ in ComputerUsePlannerRuntimeTests.observation() },
            plan: { _ in
                planned += 1
                return ComputerUsePlannerResponse(toolCall: planned == 1
                    ? ComputerUseToolCall(tool: .editText, elementID: "e1", instruction: "Rewrite", scope: "field")
                    : ComputerUseToolCall(tool: .finish, reason: "Done"))
            }, execute: { _, _ in Issue.record("Writing must use prepared execution"); return .failed("unexpected") })
        let result = await runtime.run(command: "Rewrite this")
        #expect(result.status == .done)
        #expect(writes == 1)
    }
}

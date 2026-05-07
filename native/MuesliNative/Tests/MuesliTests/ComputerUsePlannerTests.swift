import Foundation
import CoreGraphics
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use tool registry")
struct ComputerUseToolRegistryTests {
    @Test("emits schemas and descriptions for every tool")
    func emitsSchemasAndDescriptions() {
        #expect(ComputerUseToolRegistry.definitions.count == ComputerUseToolName.allCases.count)
        for definition in ComputerUseToolRegistry.definitions {
            #expect(!definition.description.isEmpty)
            #expect(definition.schema.type == "object")
            #expect(definition.schema.additionalProperties == false)
            #expect(definition.schema.required.contains("tool"))
            #expect(definition.schema.properties["tool"]?.enumValues == [definition.name.rawValue])
        }
        let docs = ComputerUseToolRegistry.promptDocumentation()
        #expect(docs.contains("Tool: get_window_state"))
        #expect(docs.contains("Tool: page_query_dom"))
    }

    @Test("emits native tool definitions")
    func emitsNativeToolDefinitions() {
        let tools = ComputerUseToolRegistry.nativeToolDefinitions()

        #expect(tools.count == ComputerUseToolName.allCases.count)
        #expect(JSONSerialization.isValidJSONObject(tools))
        let launch = tools.first { ($0["name"] as? String) == "launch_app" }
        #expect(launch?["type"] as? String == "function")
        let parameters = launch?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        #expect(properties?["tool"] == nil)
        #expect(properties?["app_name"] != nil)

        let hotkey = tools.first { ($0["name"] as? String) == "hotkey" }
        let hotkeyParameters = hotkey?["parameters"] as? [String: Any]
        let hotkeyProperties = hotkeyParameters?["properties"] as? [String: Any]
        let modifiers = hotkeyProperties?["modifiers"] as? [String: Any]
        let modifierItems = modifiers?["items"] as? [String: Any]
        #expect(modifierItems?["enum"] as? [String] == ComputerUseKeyModifier.allCases.map(\.rawValue))
    }

    @Test("planner guidance treats browser page tools as optional")
    func plannerGuidanceTreatsBrowserPageToolsAsOptional() {
        let instructions = ComputerUsePlannerClient.instructions

        #expect(instructions.contains("native tool call"))
        #expect(instructions.contains("Browser page tools are optional shortcuts"))
        #expect(instructions.contains("Chrome Apple Events JavaScript permission"))
        #expect(instructions.contains("AX/screenshot fallback"))
        #expect(instructions.contains("Do not use fail only because a browser DOM/page tool failed"))
        #expect(instructions.contains("Do not call get_window_state repeatedly"))
        #expect(instructions.contains("do not loop on observation"))
        #expect(instructions.contains("After hotkey command+t, call navigate_url without tab_index"))
        #expect(instructions.contains("prefer paste_text for multi-word text"))
    }
}

@Suite("Computer Use observation capture")
struct ComputerUseObservationCaptureTests {
    @Test("uses display fallback for shallow window screenshots")
    func usesDisplayFallbackForShallowWindowScreenshots() {
        #expect(ComputerUseObservationCapture.shouldUseDisplayFallbackForScreenshot(
            width: 2940,
            height: 82,
            frame: CGRect(x: 0, y: 0, width: 1470, height: 41)
        ))
        #expect(!ComputerUseObservationCapture.shouldUseDisplayFallbackForScreenshot(
            width: 2940,
            height: 1800,
            frame: CGRect(x: 0, y: 0, width: 1470, height: 900)
        ))
    }
}

@Suite("Computer Use planner response")
struct ComputerUsePlannerResponseTests {
    @Test("decodes valid top-level tool call")
    func decodesValidToolCall() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"launch_app","app_name":"Google Chrome"}"#)

        #expect(response.toolCall.tool == .launchApp)
        #expect(response.toolCall.appName == "Google Chrome")
    }

    @Test("decodes wrapped tool call")
    func decodesWrappedToolCall() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool_call":{"tool":"hotkey","modifiers":["command"],"key":"l"}}"#
        )

        #expect(response.toolCall.tool == .hotkey)
        #expect(response.toolCall.modifiers == [.command])
        #expect(response.toolCall.key == "l")
    }

    @Test("decodes modifier aliases")
    func decodesModifierAliases() throws {
        let response = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "hotkey",
            arguments: #"{"modifiers":["cmd","ctrl","alt","fn"],"key":"t"}"#
        )

        #expect(response.toolCall.modifiers == [.command, .control, .option, .function])
        #expect(response.toolCall.key == "t")
    }

    @Test("decodes coordinate tool calls")
    func decodesCoordinateToolCalls() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"click","screenshot_id":"s1","x":120,"y":240,"label":"Search"}"#
        )

        #expect(response.toolCall.tool == .click)
        #expect(response.toolCall.screenshotID == "s1")
        #expect(response.toolCall.x == 120)
        #expect(response.toolCall.y == 240)
        #expect(!response.toolCall.requiresConfirmation)
    }

    @Test("coordinate clicks require screenshot id")
    func coordinateClicksRequireScreenshotID() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"click","x":120,"y":240,"label":"Search"}"#
            )
        }
    }

    @Test("click rejects mixed element and coordinate addressing")
    func clickRejectsMixedElementAndCoordinateAddressing() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"click","element_index":9,"screenshot_id":"s1","x":120,"y":240,"label":"Search"}"#
            )
        }
    }

    @Test("click rejects invalid element index")
    func clickRejectsInvalidElementIndex() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"click","element_index":0,"label":"Search"}"#
            )
        }
    }

    @Test("decodes move cursor tool calls")
    func decodesMoveCursorToolCalls() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"move_cursor","screenshot_id":"s1","x":120,"y":240,"label":"Search"}"#
        )

        #expect(response.toolCall.tool == .moveCursor)
        #expect(response.toolCall.screenshotID == "s1")
        #expect(response.toolCall.summary == "move cursor to 120,240")
    }

    @Test("decodes native tool call arguments")
    func decodesNativeToolCallArguments() throws {
        let response = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "launch_app",
            arguments: #"{"app_name":"Google Chrome"}"#
        )

        #expect(response.toolCall.tool == .launchApp)
        #expect(response.toolCall.appName == "Google Chrome")
        #expect(response.rawModelOutput?.contains(#""tool":"launch_app""#) == true)
    }

    @Test("decodes app scoped type text tool calls")
    func decodesAppScopedTypeTextToolCalls() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"type_text","app_bundle_id":"com.apple.Notes","element_index":12,"text":"this has been created using computer use","label":"note body"}"#
        )

        #expect(response.toolCall.tool == .typeText)
        #expect(response.toolCall.canonicalBundleID == "com.apple.Notes")
        #expect(response.toolCall.elementIndex == 12)
        #expect(response.toolCall.summary == "type this has been created using computer use")
    }

    @Test("decodes paste text tool calls")
    func decodesPasteTextToolCalls() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"paste_text","app_name":"Notes","text":"this has been created using computer use"}"#
        )

        #expect(response.toolCall.tool == .pasteText)
        #expect(response.toolCall.appName == "Notes")
        #expect(response.toolCall.summary == "paste this has been created using computer use")
    }

    @Test("text entry accepts zero element index as absent target")
    func textEntryAcceptsZeroElementIndexAsAbsentTarget() throws {
        let response = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "paste_text",
            arguments: #"{"label":"note title","app_bundle_id":"com.apple.Notes","text":"hello","element_id":"","element_index":0,"app_name":"Notes"}"#
        )

        #expect(response.toolCall.tool == .pasteText)
        #expect(response.toolCall.elementIndex == 0)
        #expect(response.toolCall.canonicalBundleID == "com.apple.Notes")
    }

    @Test("native tool call rejects unsupported fields")
    func nativeToolCallRejectsUnsupportedFields() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeNativeToolCall(
                name: "finish",
                arguments: #"{"reason":"done","url":"https://example.com"}"#
            )
        }
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

    @Test("missing required fields fail safely")
    func missingRequiredFieldsFailSafely() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"launch_app","text":"Google Chrome"}"#)
        }
    }

    @Test("extra schema-bypass fields fail safely")
    func extraFieldsFailSafely() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"finish","reason":"done","url":"https://example.com"}"#)
        }
    }

    @Test("unsafe URLs fail validation")
    func unsafeURLsFailValidation() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"navigate_url","app_bundle_id":"com.google.Chrome","url":"javascript:alert(1)"}"#)
        }
    }

    @Test("safe URLs allow query parameters")
    func safeURLsAllowQueryParameters() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"navigate_url","app_bundle_id":"com.google.Chrome","url":"https://www.google.com/search?q=hello&hl=en"}"#
        )

        #expect(response.toolCall.url == "https://www.google.com/search?q=hello&hl=en")
    }

    @Test("risky tool calls require confirmation")
    func riskyToolCallsRequireConfirmation() throws {
        let click = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"click","element_id":"e2","label":"Send"}"#)
        let unlabeledPoint = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"click","screenshot_id":"s1","x":120,"y":240}"#)
        let key = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"hotkey","modifiers":["command"],"key":"q"}"#)

        #expect(click.toolCall.requiresConfirmation)
        #expect(unlabeledPoint.toolCall.requiresConfirmation)
        #expect(key.toolCall.requiresConfirmation)
    }
}

@Suite("Computer Use planner model")
struct ComputerUsePlannerModelTests {
    @Test("uses dedicated CUA model instead of shared ChatGPT model")
    func usesDedicatedCUAModel() {
        var config = AppConfig()
        config.chatGPTModel = "gpt-5.4-mini"

        #expect(ComputerUsePlannerClient.plannerModel(for: config) == ComputerUsePlannerClient.defaultModel)

        config.computerUsePlannerModel = "gpt-5.4"

        #expect(ComputerUsePlannerClient.plannerModel(for: config) == "gpt-5.4")
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
        #expect(candidate.elementIndex == 1)
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

@Suite("Computer Use request encoding")
struct ComputerUsePlannerRequestTests {
    @Test("persists screenshot metadata without image data")
    func persistsScreenshotMetadataWithoutImageData() throws {
        let request = ComputerUsePlannerRequest(
            command: "click search",
            step: 1,
            maxSteps: 100,
            latestWindowState: ComputerUseWindowState(observation: ComputerUsePlannerRuntimeTests.observation(screenshot: ComputerUsePlannerRuntimeTests.screenshot())),
            priorOutcomes: []
        )
        let data = try JSONEncoder().encode(request)
        let text = String(data: data, encoding: .utf8) ?? ""

        #expect(text.contains("screenshot_id"))
        #expect(text.contains("s1"))
        #expect(!text.contains("data:image"))
        #expect(text.contains(ComputerUseToolRegistry.catalogVersion))
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
            observe: { _, _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done")) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open chrome")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "done")
        #expect(result.traceEvents.contains { $0.kind == "model_output" })
        #expect(result.traceEvents.contains { $0.kind == "finish" })
    }

    @Test("fail tool produces failed runtime result")
    @MainActor
    func failToolProducesFailedResult() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "blocked")) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "do impossible thing")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message == "blocked")
    }

    @Test("default runtime uses a high safety step cap")
    @MainActor
    func defaultRuntimeUsesHighSafetyStepCap() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { request in
                #expect(request.maxSteps == 100)
                #expect(request.toolCatalogVersion == ComputerUseToolRegistry.catalogVersion)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "do a longer workflow")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.traceEvents.contains { $0.body.contains("Step 1 of 100") })
    }

    @Test("stops at max step count")
    @MainActor
    func stopsAtMaxStepCount() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            maxSteps: 2,
            observe: { _, _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .getWindowState)) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "look around")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message == "CUA reached its step limit")
    }

    @Test("stops after one repeated no-op tool call")
    @MainActor
    func stopsRepeatedNoOpToolCalls() async {
        var executionCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation(screenshot: Self.screenshot()) },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                    tool: .click,
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

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("one retry of click Address and search bar"))
        #expect(executionCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Repeated action stopped" })
    }

    @Test("stops repeated get window state loops")
    @MainActor
    func stopsRepeatedGetWindowStateLoops() async {
        var executionCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "YouTube",
                    screenshot: ComputerUseScreenshotObservation(
                        screenshotID: "s\(executionCount)",
                        width: 2940,
                        height: 1800,
                        windowFrame: ComputerUseRect(x: 0, y: 0, width: 1470, height: 900),
                        scaleX: 2,
                        scaleY: 2,
                        imageDataURL: "data:image/jpeg;base64,abc"
                    )
                )
            },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                    tool: .getWindowState,
                    appBundleID: "com.google.Chrome"
                ))
            },
            execute: { _, _ in
                executionCount += 1
                return .executed("Observed")
            }
        )

        let result = await runtime.run(command: "use the visible page")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("one retry of get window state"))
        #expect(executionCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Repeated action stopped" })
    }

    @Test("stops on confirmation-required action")
    @MainActor
    func stopsOnConfirmationRequiredAction() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                    tool: .click,
                    elementID: "e1",
                    label: "Send"
                ))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "send it")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.needsConfirmation)
        #expect(result.message == "Confirm: click Send")
    }

    @Test("fails when planner is unavailable")
    @MainActor
    func failsWhenPlannerUnavailable() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in throw ComputerUsePlannerError.notAuthenticated },
            execute: { _, _ in .failed("unexpected") }
        )

        let result = await runtime.run(command: "open Google Chrome")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
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
            observe: { _, _, _ in Self.observation() },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .launchApp, appName: "Google Chrome"))
                }
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { toolCall, _ in
                executedTools.append(toolCall)
                return .executed("Opened Google Chrome")
            }
        )

        let result = await runtime.run(command: "open the tail scale app")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "done")
        #expect(executedTools.map(\.tool) == [.launchApp])
        #expect(executedTools.first?.appName == "Google Chrome")
        #expect(!result.traceEvents.contains { $0.kind == "fallback" })
        #expect(!result.traceEvents.contains { $0.title == "Planner app mismatch" })
    }

    @Test("refreshes launched app state instead of frontmost fallback")
    @MainActor
    func refreshesLaunchedAppStateInsteadOfFrontmostFallback() async {
        var observedTargets: [ComputerUseObservationTarget?] = []
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, target in
                observedTargets.append(target)
                if target?.appName == "Notes" {
                    return Self.observation(
                        appName: "Notes",
                        bundleID: "com.apple.Notes",
                        windowTitle: "Notes",
                        screenshot: Self.screenshot()
                    )
                }
                return Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "YouTube",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.step == 1 {
                    #expect(request.latestWindowState.bundleID == "com.google.Chrome")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .launchApp, appName: "Notes"))
                }
                #expect(request.latestWindowState.bundleID == "com.apple.Notes")
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("Opened Notes") }
        )

        let result = await runtime.run(command: "open notes")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(observedTargets.count == 2)
        #expect(observedTargets[0] == nil)
        #expect(observedTargets[1]?.appName == "Notes")
    }

    @Test("fails when planner mode is disabled")
    @MainActor
    func failsWhenPlannerModeDisabled() async {
        var config = AppConfig()
        config.enableComputerUsePlanner = false
        let runtime = ComputerUsePlannerRuntime(
            config: config,
            observe: { _, _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish)) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open Google Chrome")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message == "CUA planner is disabled.")
        #expect(!result.traceEvents.contains { $0.kind == "fallback" })
    }

    @Test("rejects non-schema planner output")
    @MainActor
    func rejectsNonSchemaPlannerOutput() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in
                _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"launch_app","text":"Google Chrome"}"#)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "something unsupported by parser")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
    }

    @Test("initial and mutating observations include screenshots")
    @MainActor
    func initialAndMutatingObservationsIncludeScreenshots() async {
        var includeScreenshotValues: [Bool] = []
        var executedTool: ComputerUseToolName?
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, includeScreenshot, _ in
                includeScreenshotValues.append(includeScreenshot)
                return Self.observation(screenshot: includeScreenshot ? Self.screenshot() : nil)
            },
            plan: { request in
                if request.step == 1 {
                    #expect(request.latestWindowState.screenshot?.screenshotID == "s1")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .click, elementID: "e1", label: "Search"))
                }
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { toolCall, _ in
                executedTool = toolCall.tool
                return .executed("Clicked")
            }
        )

        let result = await runtime.run(command: "click the search field")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(includeScreenshotValues == [true, true])
        #expect(executedTool == .click)
        #expect(result.traceEvents.contains { $0.body.contains("screenshot s1") })
    }

    @Test("browser page permission failures continue with screen fallback")
    @MainActor
    func browserPagePermissionFailuresContinueWithScreenFallback() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                return Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "YouTube",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pageGetText,
                        appBundleID: "com.google.Chrome"
                    ))
                }
                #expect(request.priorOutcomes.last?.tool == .pageGetText)
                #expect(request.priorOutcomes.last?.status == "failed")
                #expect(request.priorOutcomes.last?.message.contains("Continue with get_window_state plus AX/screenshot tools") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "used screen fallback"))
            },
            execute: { toolCall, _ in
                #expect(toolCall.tool == .pageGetText)
                return .failed("Chrome Apple Events JavaScript permission is required for browser page tools")
            }
        )

        let result = await runtime.run(command: "use YouTube")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "used screen fallback")
        #expect(observeCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Screen fallback" })
    }

    @Test("type text focus failures continue with focus fallback")
    @MainActor
    func typeTextFocusFailuresContinueWithFocusFallback() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                return Self.observation(
                    appName: "Notes",
                    bundleID: "com.apple.Notes",
                    windowTitle: "All iCloud",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .typeText,
                        text: "this was created using computer use"
                    ))
                }
                #expect(request.priorOutcomes.last?.tool == .typeText)
                #expect(request.priorOutcomes.last?.status == "failed")
                #expect(request.priorOutcomes.last?.message.contains("focus an editable target") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "focused fallback available"))
            },
            execute: { toolCall, _ in
                #expect(toolCall.tool == .typeText)
                return .failed("No focused editable text target. Click an editable note body, title, text field, or text area before using type_text.")
            }
        )

        let result = await runtime.run(command: "write a note")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "focused fallback available")
        #expect(observeCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Screen fallback" })
    }

    @Test("paste text focus failures continue with focus fallback")
    @MainActor
    func pasteTextFocusFailuresContinueWithFocusFallback() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                return Self.observation(
                    appName: "Notes",
                    bundleID: "com.apple.Notes",
                    windowTitle: "All iCloud",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: "this was created using computer use"
                    ))
                }
                #expect(request.priorOutcomes.last?.tool == .pasteText)
                #expect(request.priorOutcomes.last?.status == "failed")
                #expect(request.priorOutcomes.last?.message.contains("Prefer paste_text for Apple Notes") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "focused fallback available"))
            },
            execute: { toolCall, _ in
                #expect(toolCall.tool == .pasteText)
                return .failed("No focused editable text target. Click an editable note body, title, text field, or text area before using paste_text.")
            }
        )

        let result = await runtime.run(command: "write a note")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "focused fallback available")
        #expect(observeCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Screen fallback" })
    }

    @Test("emits specific floating status labels")
    @MainActor
    func emitsSpecificFloatingStatusLabels() async {
        var statuses: [String] = []
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            onStatus: { status in statuses.append(status) },
            observe: { _, _, _ in Self.observation(screenshot: Self.screenshot()) },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .launchApp, appName: "Google Chrome"))
                }
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("Opened Google Chrome") }
        )

        let result = await runtime.run(command: "open chrome")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(statuses.contains("Observing screen"))
        #expect(statuses.contains("Planning step 1"))
        #expect(statuses.contains("Opening Google Chrome"))
        #expect(statuses.contains("Opened Google Chrome"))
        #expect(statuses.contains("Planning step 2"))
        #expect(statuses.contains("Done"))
    }

    @Test("retries transient planner request failures once")
    @MainActor
    func retriesTransientPlannerRequestFailuresOnce() async {
        var planCalls = 0
        var statuses: [String] = []
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            onStatus: { status in statuses.append(status) },
            observe: { _, _, _ in Self.observation(screenshot: Self.screenshot()) },
            plan: { _ in
                planCalls += 1
                if planCalls == 1 {
                    throw ComputerUsePlannerError.requestFailed("The network connection was lost.")
                }
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open chrome")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(planCalls == 2)
        #expect(statuses.contains("Retrying planner"))
        #expect(result.traceEvents.contains { $0.title == "Planner retry" })
    }

    @Test("does not retry planner cancellation")
    @MainActor
    func doesNotRetryPlannerCancellation() async {
        var planCalls = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation(screenshot: Self.screenshot()) },
            plan: { _ in
                planCalls += 1
                throw CancellationError()
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open chrome")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(planCalls == 1)
        #expect(!result.traceEvents.contains { $0.title == "Planner retry" })
    }

    static func observation(
        appName: String = "Test",
        bundleID: String = "com.example.Test",
        windowTitle: String = "Window",
        screenshot: ComputerUseScreenshotObservation? = nil
    ) -> ComputerUseObservation {
        ComputerUseObservation(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
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

    static func screenshot() -> ComputerUseScreenshotObservation {
        ComputerUseScreenshotObservation(
            screenshotID: "s1",
            width: 100,
            height: 80,
            windowFrame: ComputerUseRect(x: 0, y: 0, width: 100, height: 80),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: "data:image/jpeg;base64,abc"
        )
    }
}

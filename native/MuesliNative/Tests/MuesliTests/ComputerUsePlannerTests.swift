import Foundation
import CoreGraphics
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use tool registry")
struct ComputerUseToolRegistryTests {
    @Test("emits schemas and descriptions for every tool")
    func emitsSchemasAndDescriptions() {
        let hiddenImplementationTools: Set<ComputerUseToolName> = [
            .moveCursor,
            .clickElement,
            .clickPoint,
            .focusElement,
            .activateFocused,
            .performSecondaryAction,
            .setValue,
            .typeText,
            .hotkey,
            .drag,
            .listBrowserTabs,
            .activateBrowserTab,
            .navigateURL,
            .pageGetText,
            .pageQueryDOM,
        ]
        #expect(ComputerUseToolRegistry.definitions.count == ComputerUseToolName.allCases.count - hiddenImplementationTools.count)
        #expect(ComputerUseToolRegistry.definition(for: .click) != nil)
        for hidden in hiddenImplementationTools {
            #expect(ComputerUseToolRegistry.definition(for: hidden) == nil)
        }
        for definition in ComputerUseToolRegistry.definitions {
            #expect(!definition.description.isEmpty)
            #expect(definition.schema.type == "object")
            #expect(definition.schema.additionalProperties == false)
            #expect(definition.schema.required.contains("tool"))
            #expect(definition.schema.properties["tool"]?.enumValues == [definition.name.rawValue])
            #expect(!definition.executionContract.rawValue.isEmpty)
        }
        let docs = ComputerUseToolRegistry.promptDocumentation()
        #expect(docs.contains("Tool: get_app_state"))
        #expect(docs.contains("Tool: get_window_state"))
        #expect(docs.contains("Tool: recognize_screenshot_text"))
        #expect(docs.contains("Tool: click\n"))
        #expect(docs.contains("Do not choose AXPress versus point routes yourself"))
        #expect(docs.contains("Tool: paste_text"))
        #expect(docs.contains("Tool: open_new_browser_tab"))
        #expect(docs.contains("Tool: navigate_active_browser_tab"))
        for hidden in hiddenImplementationTools {
            #expect(!docs.contains("Tool: \(hidden.rawValue)"))
        }
        #expect(docs.contains("Execution contract:"))
        #expect(docs.contains("app_scoped_background_capable"))
        #expect(docs.contains("Orientation only"))
    }

    @Test("emits native tool definitions")
    func emitsNativeToolDefinitions() {
        let tools = ComputerUseToolRegistry.nativeToolDefinitions()

        #expect(tools.count == ComputerUseToolRegistry.definitions.count)
        #expect(JSONSerialization.isValidJSONObject(tools))
        #expect(tools.contains { ($0["name"] as? String) == "click" })
        #expect(!tools.contains { ($0["name"] as? String) == "click_element" })
        #expect(!tools.contains { ($0["name"] as? String) == "click_point" })
        #expect(!tools.contains { ($0["name"] as? String) == "type_text" })
        #expect(!tools.contains { ($0["name"] as? String) == "hotkey" })
        let launch = tools.first { ($0["name"] as? String) == "launch_app" }
        #expect(launch?["type"] as? String == "function")
        #expect((launch?["description"] as? String)?.contains("Execution contract: background_capable") == true)
        let parameters = launch?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        #expect(properties?["tool"] == nil)
        #expect(properties?["app_name"] != nil)

        let pressKey = tools.first { ($0["name"] as? String) == "press_key" }
        let pressKeyParameters = pressKey?["parameters"] as? [String: Any]
        let pressKeyProperties = pressKeyParameters?["properties"] as? [String: Any]
        let modifiers = pressKeyProperties?["modifiers"] as? [String: Any]
        let modifierItems = modifiers?["items"] as? [String: Any]
        #expect(modifierItems?["enum"] as? [String] == ComputerUseKeyModifier.allCases.map(\.rawValue))
    }

    @Test("planner guidance describes reduced model-facing action surface")
    func plannerGuidanceDescribesReducedModelFacingActionSurface() {
        let instructions = ComputerUsePlannerClient.instructions

        #expect(instructions.contains("native tool call"))
        #expect(instructions.contains("Look -> Act -> Verify"))
        #expect(instructions.contains("The screenshot is the source of truth"))
        #expect(instructions.contains("Use the click tool for all click-like intent"))
        #expect(instructions.contains("Prefer element-indexed click addressing"))
        #expect(instructions.contains("screenshot-coordinate click addressing"))
        #expect(instructions.contains("AX candidates, focused_element, and OCR are hints"))
        #expect(instructions.contains("Use recognize_screenshot_text"))
        #expect(instructions.contains("OCR is optional and model-directed"))
        #expect(instructions.contains("Do not use fail only because a browser helper failed"))
        #expect(instructions.contains("Scoped tools accept target identity"))
        #expect(instructions.contains("safety_limit_seconds"))
        #expect(instructions.contains("user-visible auto-stop safety limit"))
        #expect(instructions.contains("Every tool description includes an execution_contract"))
        #expect(instructions.contains("Browser tools marked app_scoped_background_capable"))
        #expect(instructions.contains("process_id/window_id"))
        #expect(instructions.contains("Keyboard focus is state"))
        #expect(instructions.contains("press_key is ambient"))
        #expect(instructions.contains("That schema is invalid"))
        #expect(instructions.contains("Use it for Google Docs"))
        #expect(instructions.contains("Do not call get_app_state/get_window_state repeatedly"))
        #expect(instructions.contains("list_windows, get_app_state, and get_window_state are orientation tools"))
        #expect(instructions.contains("do not fall into repeated AX focus cycles"))
        #expect(instructions.contains("After open_new_browser_tab, call navigate_active_browser_tab"))
        #expect(instructions.contains("use paste_text as the single text-entry intent"))
        #expect(instructions.contains("Use finish only when the user's command is complete and successful"))
        for hidden in ["click_element", "click_point", "type_text", "focus_element", "activate_focused", "page_query_dom", "list_browser_tabs"] {
            #expect(!instructions.contains(hidden))
        }
    }

    @Test("planner guidance includes selected app control mode")
    func plannerGuidanceIncludesSelectedAppControlMode() {
        var quietConfig = AppConfig()
        quietConfig.computerUseInteractionMode = .quiet
        let quietInstructions = ComputerUsePlannerClient.instructions(for: quietConfig)
        #expect(quietInstructions.contains("Current app-control preference: Work quietly"))
        #expect(quietInstructions.contains("Keep the user's current app usable and active"))
        #expect(quietInstructions.contains("pid/window-routed input"))
        #expect(quietInstructions.contains("Avoid foreground_required tools"))

        var directConfig = AppConfig()
        directConfig.computerUseInteractionMode = .direct
        let directInstructions = ComputerUsePlannerClient.instructions(for: directConfig)
        #expect(directInstructions.contains("Current app-control preference: Bring apps forward"))
        #expect(directInstructions.contains("bring target apps forward"))
    }

    @Test("reduced action tool schemas expose their target contract")
    func reducedActionToolSchemasExposeTheirTargetContract() {
        let tools = ComputerUseToolRegistry.nativeToolDefinitions()

        for name in ["click", "paste_text"] {
            let tool = tools.first { ($0["name"] as? String) == name }
            let parameters = tool?["parameters"] as? [String: Any]
            let properties = parameters?["properties"] as? [String: Any]

            #expect(properties?["process_id"] != nil)
            #expect(properties?["window_id"] != nil)
        }

        let getWindowState = tools.first { ($0["name"] as? String) == "get_window_state" }
        let getWindowStateParameters = getWindowState?["parameters"] as? [String: Any]
        let getWindowStateProperties = getWindowStateParameters?["properties"] as? [String: Any]
        #expect(getWindowStateProperties?["process_id"] != nil)
        #expect(getWindowStateProperties?["window_id"] != nil)

        let pressKey = tools.first { ($0["name"] as? String) == "press_key" }
        let pressKeyParameters = pressKey?["parameters"] as? [String: Any]
        let pressKeyProperties = pressKeyParameters?["properties"] as? [String: Any]
        #expect((pressKey?["description"] as? String)?.contains("pid/window-routed") == true)
        #expect((pressKey?["description"] as? String)?.contains("never accepts element_index or element_id") == true)
        #expect(pressKeyProperties?["process_id"] != nil)
        #expect(pressKeyProperties?["window_id"] != nil)
        #expect(pressKeyProperties?["element_index"] == nil)
        #expect(pressKeyProperties?["element_id"] == nil)

        let click = tools.first { ($0["name"] as? String) == "click" }
        #expect((click?["description"] as? String)?.contains("Muesli's driver selects and reports the concrete route") == true)

        let pasteText = tools.first { ($0["name"] as? String) == "paste_text" }
        #expect((pasteText?["description"] as? String)?.contains("driver chooses the safest available text route") == true)
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
            from: #"{"tool_call":{"tool":"press_key","modifiers":["command"],"key":"l"}}"#
        )

        #expect(response.toolCall.tool == .pressKey)
        #expect(response.toolCall.modifiers == [.command])
        #expect(response.toolCall.key == "l")
    }

    @Test("decodes modifier aliases")
    func decodesModifierAliases() throws {
        let response = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "press_key",
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

    @Test("rejects hidden split click implementation routes")
    func rejectsHiddenSplitClickImplementationRoutes() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeNativeToolCall(
                name: "click_element",
                arguments: #"{"element_index":12,"label":"Tweet composer"}"#
            )
        }
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeNativeToolCall(
                name: "click_point",
                arguments: #"{"screenshot_id":"s1","x":120,"y":240,"label":"fallback target"}"#
            )
        }
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

    @Test("coordinate click ignores placeholder element target")
    func coordinateClickIgnoresPlaceholderElementTarget() throws {
        let response = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "click",
            arguments: #"{"button":"left","y":871,"clicks":1,"x":1050,"screenshot_id":"s1778148270271","element_index":0,"label":"reply text field on X post","element_id":""}"#
        )

        #expect(response.toolCall.tool == .click)
        #expect(response.toolCall.elementIndex == nil)
        #expect(response.toolCall.elementID == nil)
        #expect(response.toolCall.x == 1050)
        #expect(response.toolCall.y == 871)
        #expect(response.toolCall.screenshotID == "s1778148270271")
        #expect(response.toolCall.summary == "click reply text field on X post at 1050,871")
    }

    @Test("element click ignores placeholder coordinates without screenshot")
    func elementClickIgnoresPlaceholderCoordinatesWithoutScreenshot() throws {
        let response = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "click",
            arguments: #"{"button":"left","clicks":1,"label":"New tab","y":0,"x":0,"element_id":"e46","element_index":46,"screenshot_id":""}"#
        )

        #expect(response.toolCall.tool == .click)
        #expect(response.toolCall.elementIndex == 46)
        #expect(response.toolCall.elementID == "e46")
        #expect(response.toolCall.x == nil)
        #expect(response.toolCall.y == nil)
        #expect(response.toolCall.screenshotID == nil)
        #expect(response.toolCall.summary == "click element e46")
    }

    @Test("click rejects invalid element index")
    func clickRejectsInvalidElementIndex() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"click","element_index":0,"label":"Search"}"#
            )
        }
    }

    @Test("rejects hidden visual feedback tool calls")
    func rejectsHiddenVisualFeedbackToolCalls() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"move_cursor","screenshot_id":"s1","x":120,"y":240,"label":"Search"}"#
            )
        }
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

    @Test("decodes app scoped paste text tool calls")
    func decodesAppScopedPasteTextToolCalls() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"paste_text","app_bundle_id":"com.apple.Notes","element_index":12,"text":"this has been created using computer use","label":"note body"}"#
        )

        #expect(response.toolCall.tool == .pasteText)
        #expect(response.toolCall.canonicalBundleID == "com.apple.Notes")
        #expect(response.toolCall.elementIndex == 12)
        #expect(response.toolCall.summary == "paste this has been created using computer use")
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

    @Test("decodes get app state compatibility alias")
    func decodesGetAppStateCompatibilityAlias() throws {
        let appState = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"get_app_state","app_bundle_id":"com.google.Chrome"}"#
        )
        let windowState = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"get_window_state","app_bundle_id":"com.google.Chrome"}"#
        )

        #expect(appState.toolCall.tool == .getAppState)
        #expect(windowState.toolCall.tool == .getWindowState)
        #expect(appState.toolCall.canonicalBundleID == windowState.toolCall.canonicalBundleID)
    }

    @Test("rejects hidden focus activation and secondary routes but decodes element scroll")
    func rejectsHiddenFocusActivationAndSecondaryRoutesButDecodesElementScroll() throws {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"focus_element","process_id":123,"element_id":"e4","label":"Search"}"#
            )
        }
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"activate_focused","process_id":123,"label":"Play"}"#
            )
        }
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeJSON(
                from: #"{"tool":"perform_secondary_action","element_index":3,"action_name":"AXShowMenu","label":"More"}"#
            )
        }
        let scroll = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"scroll","element_id":"e7","direction":"down","pages":1}"#
        )

        #expect(scroll.toolCall.tool == .scroll)
        #expect(scroll.toolCall.elementID == "e7")
    }

    @Test("decodes browser intent tools")
    func decodesBrowserIntentTools() throws {
        let newTab = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "open_new_browser_tab",
            arguments: #"{"app_bundle_id":"com.google.Chrome","process_id":1234,"window_id":88}"#
        )
        let navigate = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "navigate_active_browser_tab",
            arguments: #"{"app_bundle_id":"com.google.Chrome","url":"https://twitter.com/compose/tweet","process_id":1234,"window_id":88}"#
        )
        let pressKey = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "press_key",
            arguments: #"{"app_name":"Google Chrome","app_bundle_id":"com.google.Chrome","key":"enter","modifiers":[],"process_id":1234,"window_id":88}"#
        )

        #expect(newTab.toolCall.tool == .openNewBrowserTab)
        #expect(newTab.toolCall.processID == 1234)
        #expect(newTab.toolCall.windowID == 88)
        #expect(navigate.toolCall.tool == .navigateActiveBrowserTab)
        #expect(navigate.toolCall.url == "https://twitter.com/compose/tweet")
        #expect(navigate.toolCall.processID == 1234)
        #expect(navigate.toolCall.windowID == 88)
        #expect(pressKey.toolCall.tool == .pressKey)
        #expect(pressKey.toolCall.processID == 1234)
        #expect(pressKey.toolCall.windowID == 88)
    }

    @Test("native tool call rejects unsupported fields")
    func nativeToolCallRejectsUnsupportedFields() {
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeNativeToolCall(
                name: "finish",
                arguments: #"{"reason":"done","url":"https://example.com"}"#
            )
        }
        #expect(throws: Error.self) {
            _ = try ComputerUsePlannerResponse.decodeNativeToolCall(
                name: "press_key",
                arguments: #"{"key":"enter","element_id":"e9"}"#
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
            _ = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"navigate_active_browser_tab","app_bundle_id":"com.google.Chrome","url":"javascript:alert(1)"}"#)
        }
    }

    @Test("safe URLs allow query parameters")
    func safeURLsAllowQueryParameters() throws {
        let response = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"navigate_active_browser_tab","app_bundle_id":"com.google.Chrome","url":"https://www.google.com/search?q=hello&hl=en"}"#
        )
        let semicolonResponse = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"navigate_active_browser_tab","app_bundle_id":"com.google.Chrome","url":"https://example.com/path;param=value?x=1;y=2"}"#
        )

        #expect(response.toolCall.url == "https://www.google.com/search?q=hello&hl=en")
        #expect(semicolonResponse.toolCall.url == "https://example.com/path;param=value?x=1;y=2")
    }

    @Test("risky tool calls require confirmation")
    func riskyToolCallsRequireConfirmation() throws {
        let click = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"click","element_id":"e2","label":"Send"}"#)
        let unlabeledPoint = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"click","screenshot_id":"s1","x":120,"y":240}"#)
        let key = try ComputerUsePlannerResponse.decodeJSON(from: #"{"tool":"press_key","modifiers":["command"],"key":"q"}"#)

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
            safetyLimitSeconds: 120,
            latestWindowState: ComputerUseWindowState(
                observation: ComputerUsePlannerRuntimeTests.observation(screenshot: ComputerUsePlannerRuntimeTests.screenshot()),
                screenshotOCRText: "Visible OCR text"
            ),
            priorOutcomes: []
        )
        let data = try JSONEncoder().encode(request)
        let text = String(data: data, encoding: .utf8) ?? ""

        #expect(text.contains("screenshot_id"))
        #expect(text.contains("s1"))
        #expect(text.contains("screenshot_ocr_text"))
        #expect(text.contains("Visible OCR text"))
        #expect(text.contains("safety_limit_seconds"))
        #expect(text.contains("observation_context"))
        #expect(text.contains("target_window_state"))
        #expect(text.contains("usable_for_actions"))
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

    @Test("formats final CUA status buckets")
    func formatsFinalStatusBuckets() {
        #expect(ComputerUseTraceFormatter.displayFinalStatus("done") == "done")
        #expect(ComputerUseTraceFormatter.displayFinalStatus("timedout") == "safety_limit")
        #expect(ComputerUseTraceFormatter.displayFinalStatus("fail") == "failed")
        #expect(ComputerUseTraceFormatter.displayFinalStatus("no_progress") == "no_progress")
    }
}

@Suite("Computer Use planner runtime")
struct ComputerUsePlannerRuntimeTests {
    @Test("finishes after finish tool")
    @MainActor
    func finishesAfterFinishTool() async {
        var config = AppConfig()
        config.computerUseTimeoutSeconds = 300
        let runtime = ComputerUsePlannerRuntime(
            config: config,
            observe: { _, _, _ in Self.observation() },
            plan: { request in
                #expect(request.safetyLimitSeconds == 300)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
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

    @Test("safety limit produces auto-stopped runtime result")
    @MainActor
    func safetyLimitProducesAutoStoppedRuntimeResult() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            timeoutSeconds: -1,
            observe: { _, _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done")) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "do something")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.timedOut)
        #expect(result.message.contains("Stopped after safety limit"))
        #expect(result.traceEvents.contains { $0.kind == "timed_out" && $0.title == "Safety limit" && $0.status == "timed_out" })
    }

    @Test("cancelled executor result produces cancelled runtime result")
    @MainActor
    func cancelledExecutorResultProducesCancelledRuntimeResult() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .launchApp, appName: "Google Chrome")) },
            execute: { _, _ in .cancelled("Cancelled opening Google Chrome") }
        )

        let result = await runtime.run(command: "open chrome")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.cancelled)
        #expect(result.message == "CUA cancelled")
        #expect(result.traceEvents.contains { $0.kind == "cancelled" })
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
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listApps)) },
            execute: { _, _ in .executed("Apps") }
        )

        let result = await runtime.run(command: "look around")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message == "CUA reached its step limit")
    }

    @Test("read-only orientation loop sends planner repair without choosing an action")
    @MainActor
    func readOnlyOrientationLoopSendsPlannerRepairWithoutChoosingAction() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            maxSteps: 10,
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 40712,
                    windowID: 93801,
                    windowTitle: "Home / X",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.priorOutcomes.last?.status == "read_only_loop" {
                    let message = request.priorOutcomes.last?.message ?? ""
                    #expect(message.contains("No concrete action has been taken"))
                    #expect(message.contains("Choose one concrete action now"))
                    #expect(message.contains("finish/fail"))
                    #expect(request.availableTools?.contains(.click) == true)
                    #expect(request.availableTools?.contains(.pasteText) == true)
                    #expect(request.availableTools?.contains(.launchApp) == true)
                    #expect(request.availableTools?.contains(.finish) == true)
                    #expect(request.availableTools?.contains(.fail) == true)
                    #expect(request.availableTools?.contains(.getWindowState) == false)
                    #expect(request.availableTools?.contains(.listWindows) == false)
                    #expect(request.toolCatalog.contains("Tool: click"))
                    #expect(!request.toolCatalog.contains("Tool: get_window_state"))
                    #expect(!request.toolCatalog.contains("Tool: list_windows"))
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "handled repair"))
                }
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listWindows, appBundleID: "com.google.Chrome"))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .getWindowState, appBundleID: "com.google.Chrome", processID: 40712, windowID: 93801))
                case 3:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listBrowserTabs, appBundleID: "com.google.Chrome"))
                default:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .getWindowState, appBundleID: "com.google.Chrome", processID: 40712, windowID: 93801))
                }
            },
            execute: { toolCall, _ in
                switch toolCall.tool {
                case .listWindows:
                    return .executed("93801: Google Chrome - Home / X")
                case .listBrowserTabs:
                    return .executed("No browser tabs")
                default:
                    return .executed("Captured target state")
                }
            }
        )

        let result = await runtime.run(command: "post a tweet")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "handled repair")
        #expect(result.traceEvents.contains { $0.kind == "planner_repair" && $0.title == "Action required" })
    }

    @Test("list-only orientation loop restricts next turn to action tools")
    @MainActor
    func listOnlyOrientationLoopRestrictsNextTurnToActionTools() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            maxSteps: 10,
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 40712,
                    windowID: 93801,
                    windowTitle: "Home / X",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.priorOutcomes.last?.status == "read_only_loop" {
                    #expect(request.availableTools?.contains(.click) == true)
                    #expect(request.availableTools?.contains(.launchApp) == true)
                    #expect(request.availableTools?.contains(.listWindows) == false)
                    #expect(request.availableTools?.contains(.listBrowserTabs) == false)
                    #expect(!request.toolCatalog.contains("Tool: list_windows"))
                    #expect(!request.toolCatalog.contains("Tool: list_browser_tabs"))
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "handled list-only repair"))
                }
                if request.step.isMultiple(of: 2) {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listBrowserTabs, appBundleID: "com.google.Chrome"))
                }
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listWindows, appBundleID: "com.google.Chrome"))
            },
            execute: { toolCall, _ in
                switch toolCall.tool {
                case .listWindows:
                    return .executed("93801: Google Chrome - Home / X")
                case .listBrowserTabs:
                    return .executed("No browser tabs")
                default:
                    Issue.record("unexpected execution of \(toolCall.tool)")
                    return .executed("unexpected")
                }
            }
        )

        let result = await runtime.run(command: "post a tweet")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "handled list-only repair")
        #expect(result.traceEvents.contains { $0.kind == "planner_repair" && $0.title == "Action required" })
    }

    @Test("masked tools are rejected before execution")
    @MainActor
    func maskedToolsAreRejectedBeforeExecution() async {
        var actionRepairSeen = false
        var maskedToolExecuted = false
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            maxSteps: 12,
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 40712,
                    windowID: 93801,
                    windowTitle: "Home / X",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.priorOutcomes.last?.status == "invalid_schema" {
                    let message = request.priorOutcomes.last?.message ?? ""
                    #expect(message.contains("get_window_state is not available in this planner turn"))
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "recovered"))
                }
                if request.priorOutcomes.last?.status == "read_only_loop" {
                    actionRepairSeen = true
                    #expect(request.availableTools?.contains(.getWindowState) == false)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .getWindowState, appBundleID: "com.google.Chrome", processID: 40712, windowID: 93801))
                }
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listWindows, appBundleID: "com.google.Chrome"))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .getWindowState, appBundleID: "com.google.Chrome", processID: 40712, windowID: 93801))
                case 3:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listBrowserTabs, appBundleID: "com.google.Chrome"))
                default:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .getWindowState, appBundleID: "com.google.Chrome", processID: 40712, windowID: 93801))
                }
            },
            execute: { toolCall, _ in
                if actionRepairSeen, toolCall.tool == .getWindowState {
                    maskedToolExecuted = true
                }
                switch toolCall.tool {
                case .listWindows:
                    return .executed("93801: Google Chrome - Home / X")
                case .listBrowserTabs:
                    return .executed("No browser tabs")
                default:
                    return .executed("Captured target state")
                }
            }
        )

        let result = await runtime.run(command: "post a tweet")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "recovered")
        #expect(maskedToolExecuted == false)
        #expect(result.traceEvents.contains { $0.kind == "planner_repair" && $0.title == "Planner schema repair" })
    }

    @Test("ignored read-only orientation repair rejects masked tool")
    @MainActor
    func ignoredReadOnlyOrientationRepairRejectsMaskedTool() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            maxSteps: 20,
            timeoutSeconds: 300,
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 40712,
                    windowID: 93801,
                    windowTitle: "Home / X",
                    screenshot: Self.screenshot()
                )
            },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .listWindows, appBundleID: "com.google.Chrome"))
            },
            execute: { _, _ in .executed("93801: Google Chrome - Home / X") }
        )

        let result = await runtime.run(command: "post a tweet")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("list_windows is not available in this planner turn"))
        #expect(result.traceEvents.contains { $0.kind == "planner_repair" && $0.title == "Action required" })
        #expect(result.traceEvents.contains { $0.kind == "failed" && $0.title == "Planner failed" })
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

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.noProgress)
        #expect(result.message.contains("repeated click Address and search bar after two unchanged attempts"))
        #expect(executionCount == 2)
        #expect(result.traceEvents.contains { $0.title == "No progress" && $0.status == "no_progress" })
    }

    @Test("repeated get window state gives planner feedback before stopping")
    @MainActor
    func repeatedGetWindowStateGivesPlannerFeedbackBeforeStopping() async {
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
            plan: { request in
                if request.step == 2 {
                    #expect(request.priorOutcomes.last?.message.contains("State is unchanged after get window state") == true)
                    #expect(request.priorOutcomes.last?.message.contains("choose a concrete action now") == true)
                }
                if request.step <= 2 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .getWindowState,
                        appBundleID: "com.google.Chrome"
                    ))
                }
                #expect(request.priorOutcomes.last?.message.contains("do not call get_app_state/get_window_state again") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in
                executionCount += 1
                return .executed("Observed")
            }
        )

        let result = await runtime.run(command: "use the visible page")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(executionCount == 2)
        #expect(!result.traceEvents.contains { $0.title == "No progress" })
    }

    @Test("stops observation-only loops after larger budget")
    @MainActor
    func stopsObservationOnlyLoopsAfterLargerBudget() async {
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

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.noProgress)
        #expect(result.message.contains("repeated get window state after 4 unchanged observations"))
        #expect(executionCount == 4)
        #expect(result.traceEvents.contains { $0.title == "No progress" && $0.status == "no_progress" })
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

    @Test("get window state preserves process and window target")
    @MainActor
    func getWindowStatePreservesProcessAndWindowTarget() async {
        var observedTargets: [ComputerUseObservationTarget?] = []
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, target in
                observedTargets.append(target)
                return Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: target?.windowID == 88 ? "Target" : "Initial",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .getWindowState,
                        appBundleID: "com.google.Chrome",
                        processID: 1234,
                        windowID: 88
                    ))
                }
                #expect(request.latestWindowState.windowTitle == "Target")
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("Got window state") }
        )

        let result = await runtime.run(command: "inspect target window")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(observedTargets.count == 2)
        #expect(observedTargets[1]?.bundleID == "com.google.Chrome")
        #expect(observedTargets[1]?.processID == 1234)
        #expect(observedTargets[1]?.windowID == 88)
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

    @Test("window state carries observation state ids")
    @MainActor
    func windowStateCarriesObservationStateIDs() {
        let observation = Self.observation(stateID: "state-test-1", screenshot: Self.screenshot())
        let state = ComputerUseWindowState(observation: observation)

        #expect(state.stateID == "state-test-1")
        #expect(state.observation.stateID == "state-test-1")
    }

    @Test("mutating action records verification state ids")
    @MainActor
    func mutatingActionRecordsVerificationStateIDs() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(stateID: "state-before", windowTitle: "Before", screenshot: Self.screenshot())
                }
                return Self.observation(stateID: "state-after", windowTitle: "After", screenshot: Self.screenshot())
            },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .click, elementID: "e1", label: "Search"))
                }
                let outcome = request.priorOutcomes.last
                #expect(outcome?.verificationStatus == .changed)
                #expect(outcome?.beforeStateID == "state-before")
                #expect(outcome?.afterStateID == "state-after")
                #expect(outcome?.stateDelta?.summary.contains("Observed UI state changed") == true)
                #expect(outcome?.transaction?.path == "window_point_skylight")
                #expect(outcome?.transaction?.posted == true)
                #expect(outcome?.transaction?.verified == false)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in
                .executed(
                    "Clicked",
                    transaction: ComputerUseActionTransaction(
                        path: "window_point_skylight",
                        route: "window_point_skylight",
                        posted: true,
                        verified: false,
                        effect: .unverifiable,
                        targetStable: true,
                        processID: 123,
                        windowID: 456
                    )
                )
            }
        )

        let result = await runtime.run(command: "click search")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
    }

    @Test("first unchanged action is planner feedback")
    @MainActor
    func firstUnchangedActionIsPlannerFeedback() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(screenshot: Self.screenshot(id: "before"))
                }
                return Self.observation(screenshot: Self.screenshot(id: "after"))
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "before"))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .pasteText, text: "hello"))
                case 3:
                    let outcome = request.priorOutcomes.last
                    #expect(outcome?.verificationStatus == .unchanged)
                    #expect(outcome?.message.contains("Inspect the latest screenshot") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "after"))
                default:
                    #expect(request.latestWindowState.screenshotOCRText == "hello")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { screenshot in
                screenshot?.screenshotID == "before" ? "" : "hello"
            }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
    }

    @Test("unconfirmed AXSelectedText write is recoverable feedback")
    @MainActor
    func unconfirmedAXSelectedTextWriteIsRecoverableFeedback() async {
        var observeCount = 0
        var planSteps: [Int] = []
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(stateID: "state-before", screenshot: Self.screenshot(id: "before"))
                }
                return Self.observation(
                    stateID: "state-after",
                    screenshot: Self.screenshot(id: "after"),
                    focusedValue: "hello from computer use"
                )
            },
            plan: { request in
                planSteps.append(request.step)
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .pasteText, text: "hello from computer use"))
                }
                let outcome = request.priorOutcomes.last
                #expect(outcome?.status == "failed")
                #expect(outcome?.transaction?.path == "ax_selected_text")
                #expect(outcome?.transaction?.posted == true)
                #expect(outcome?.transaction?.verified == false)
                #expect(outcome?.message.contains("Do not immediately repeat") == true)
                #expect(request.latestWindowState.observation.focusedElement?.value == "hello from computer use")
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in
                .failed(
                    "AXSelectedText accepted the write, but AX readback did not confirm insertion. Refresh target state before retrying text entry; retrying blindly may duplicate text if the AX write already landed.",
                    transaction: ComputerUseActionTransaction(
                        path: "ax_selected_text",
                        posted: true,
                        verified: false,
                        effect: .unverifiable,
                        targetStable: true,
                        requestedTextSample: "hello from computer use",
                        escalationHint: "Inspect the post-action screenshot/AX state before retrying; retrying blindly may duplicate text if the AX write landed but AX readback lagged.",
                        warning: "AXSelectedText accepted the write, but readback did not prove insertion."
                    )
                )
            }
        )

        let result = await runtime.run(command: "write hello from computer use")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(planSteps == [1, 2])
        #expect(observeCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Text write unverified" })
    }

    @Test("text action verifies requested text before finish")
    @MainActor
    func textActionVerifiesRequestedTextBeforeFinish() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(screenshot: Self.screenshot())
                }
                return Self.observation(
                    screenshot: Self.screenshot(),
                    focusedValue: "hello from computer use"
                )
            },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .pasteText, text: "hello from computer use"))
                }
                let outcome = request.priorOutcomes.last
                #expect(outcome?.verificationStatus == .changed)
                #expect(outcome?.message.contains("Observed requested text") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("Pasted text") }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
    }

    @Test("duplicate unverified writes require distinct text evidence")
    @MainActor
    func duplicateUnverifiedWritesRequireDistinctTextEvidence() async {
        let requestedText = "repeat phrase"
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                return Self.observation(
                    stateID: "state-\(observeCount)",
                    screenshot: Self.screenshot(id: "after")
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: requestedText
                    ))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .typeText,
                        text: requestedText
                    ))
                case 3:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .recognizeScreenshotText,
                        screenshotID: "after"
                    ))
                case 4:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .finish,
                        reason: "done"
                    ))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .fail,
                        reason: "Unexpected step."
                    ))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { _ in "\(requestedText) \(requestedText)" }
        )

        let result = await runtime.run(command: "write the same phrase twice")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
    }

    @Test("pre-existing focused text blocks unverified finish")
    @MainActor
    func preExistingFocusedTextBlocksUnverifiedFinish() async {
        let requestedText = "hello from computer use"
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(
                    screenshot: Self.screenshot(),
                    focusedValue: requestedText
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: requestedText
                    ))
                case 2:
                    let outcome = request.priorOutcomes.last
                    #expect(outcome?.verificationStatus == .unchanged)
                    #expect(outcome?.message.contains("AX did not expose newly confirmed requested text") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { _ in requestedText }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Finish blocked because text write evidence is unverified"))
        #expect(result.traceEvents.contains { $0.title == "Text write unverified" })
    }

    @Test("post-only OCR can verify text absent from pre-action visible evidence")
    @MainActor
    func postOnlyOCRCanVerifyTextAbsentFromPreActionVisibleEvidence() async {
        let requestedText = "hello from computer use"
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(screenshot: Self.screenshot(id: "before"))
                }
                return Self.observation(screenshot: Self.screenshot(id: "after"))
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: requestedText
                    ))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "after"))
                case 3:
                    #expect(request.latestWindowState.screenshotOCRText == requestedText)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { _ in requestedText }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "done")
    }

    @Test("duplicate text samples require independent evidence")
    @MainActor
    func duplicateTextSamplesRequireIndependentEvidence() async {
        let sharedPrefix = "computer use is useful and exciting because it can help people move faster with context today"
        let firstText = "\(sharedPrefix) first detail"
        let secondText = "\(sharedPrefix) second detail"
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(screenshot: Self.screenshot(id: "before"))
                }
                return Self.observation(screenshot: Self.screenshot(id: "after"))
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .pasteText, text: firstText))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .pasteText, text: secondText))
                case 3:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "after"))
                case 4:
                    #expect(request.latestWindowState.screenshotOCRText == sharedPrefix)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { _ in sharedPrefix }
        )

        let result = await runtime.run(command: "write duplicate prefix twice")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Finish blocked because text write evidence is unverified"))
        #expect(result.message.contains("from step 2"))
    }

    @Test("quiet mode marks non-frontmost target window as usable")
    @MainActor
    func quietModeMarksNonFrontmostTargetWindowAsUsable() async {
        var config = AppConfig()
        config.computerUseInteractionMode = .quiet
        let runtime = ComputerUsePlannerRuntime(
            config: config,
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 999_999,
                    windowID: 55,
                    windowTitle: "",
                    screenshot: Self.screenshot()
                )
            },
            plan: { request in
                #expect(request.observationContext.controlMode == .quiet)
                #expect(request.observationContext.targetWindowState.windowID == 55)
                #expect(request.observationContext.targetWindowState.isFrontmost == false)
                #expect(request.observationContext.targetWindowState.hasScreenshot == true)
                #expect(request.observationContext.targetWindowState.hasAXCandidates == true)
                #expect(request.observationContext.targetWindowState.usableForActions == true)
                #expect(request.observationContext.keyboardFocusState.relationToTarget == "user_frontmost_or_unknown")
                #expect(request.observationContext.notes.contains { $0.contains("Work quietly preserves the user's active app") })
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "context clear"))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "open twitter")
        let observationPayload = result.traceEvents.first { $0.kind == "observation" }?.debugPayload ?? ""

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(observationPayload.contains(#""context""#))
        #expect(observationPayload.contains(#""usable_for_actions":true"#))
        #expect(result.traceEvents.first { $0.kind == "observation" }?.body.contains("target window_id 55") == true)
    }

    @Test("OCR delta can verify text even when unrelated AX text existed before")
    @MainActor
    func ocrDeltaCanVerifyTextWhenUnrelatedAXTextExistedBefore() async {
        let requestedText = "hello from computer use"
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(
                        screenshot: Self.screenshot(id: "before"),
                        elementValue: requestedText
                    )
                }
                return Self.observation(
                    screenshot: Self.screenshot(id: "after"),
                    elementValue: requestedText
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "before"))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: requestedText
                    ))
                case 3:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "after"))
                default:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { screenshot in
                screenshot?.screenshotID == "before" ? "" : requestedText
            }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "done")
    }

    @Test("post-only OCR uncertainty blocks unverified finish")
    @MainActor
    func postOnlyOCRUncertaintyBlocksUnverifiedFinish() async {
        let requestedText = "hello from computer use"
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(
                    screenshot: Self.screenshot(id: "after"),
                    elementValue: requestedText
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: requestedText
                    ))
                case 2:
                    #expect(request.priorOutcomes.last?.verificationStatus == .unchanged)
                    #expect(request.priorOutcomes.last?.message.contains("AX did not expose newly confirmed requested text") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "after"))
                case 3:
                    #expect(request.latestWindowState.screenshotOCRText == requestedText)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { _ in requestedText }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Finish blocked because text write evidence is unverified"))
        #expect(result.traceEvents.contains { $0.title == "Text write unverified" })
    }

    @Test("unrelated element text blocks unverified finish")
    @MainActor
    func unrelatedElementTextBlocksUnverifiedFinish() async {
        let requestedText = "hello from computer use"
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(screenshot: Self.screenshot())
                }
                return Self.observation(
                    screenshot: Self.screenshot(),
                    elementValue: requestedText
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: requestedText
                    ))
                case 2:
                    let outcome = request.priorOutcomes.last
                    #expect(outcome?.verificationStatus == .unknown)
                    #expect(outcome?.message.contains("AX did not expose newly confirmed requested text") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Pasted text") }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Finish blocked because text write evidence is unverified"))
        #expect(result.traceEvents.contains { $0.title == "Text write unverified" })
    }

    @Test("later verified text write does not hide earlier pending write")
    @MainActor
    func laterVerifiedTextWriteDoesNotHideEarlierPendingWrite() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount < 3 {
                    return Self.observation(
                        stateID: "state-\(observeCount)",
                        windowTitle: "Window \(observeCount)",
                        screenshot: Self.screenshot()
                    )
                }
                return Self.observation(
                    stateID: "state-\(observeCount)",
                    windowTitle: "Window \(observeCount)",
                    screenshot: Self.screenshot(),
                    focusedValue: "second computer use text"
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: "first computer use text"
                    ))
                case 2:
                    #expect(request.priorOutcomes.last?.verificationStatus == .unknown)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .pasteText,
                        text: "second computer use text"
                    ))
                case 3:
                    #expect(request.priorOutcomes.last?.verificationStatus == .changed)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Pasted text") }
        )

        let result = await runtime.run(command: "write two snippets")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Finish blocked because text write evidence is unverified"))
        #expect(result.message.contains("step 1"))
    }

    @Test("target mismatch blocks current-window mutation")
    @MainActor
    func targetMismatchBlocksCurrentWindowMutation() async {
        var executeCalls = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(
                    windowTitle: "Fallback",
                    screenshot: Self.screenshot(),
                    targetMismatch: ComputerUseTargetMismatch(
                        requestedWindowID: 111,
                        actualWindowID: 222,
                        message: "Requested window_id 111 could not be matched; this state fell back to focused window_id 222."
                    )
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    #expect(request.latestWindowState.targetMismatch?.requestedWindowID == 111)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .click,
                        screenshotID: "s1",
                        x: 10,
                        y: 10
                    ))
                case 2:
                    #expect(request.priorOutcomes.last?.status == "target_mismatch")
                    #expect(request.priorOutcomes.last?.message.contains("Cannot run click") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Need matched window."))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in
                executeCalls += 1
                return .executed("Clicked")
            }
        )

        let result = await runtime.run(command: "click target")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message == "Need matched window.")
        #expect(executeCalls == 0)
    }

    @Test("target mismatch blocks app scoped browser mutation")
    @MainActor
    func targetMismatchBlocksAppScopedBrowserMutation() async {
        var executeCalls = 0
        var observeCalls = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCalls += 1
                return Self.observation(
                    appName: "Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "Fallback",
                    screenshot: Self.screenshot(),
                    targetMismatch: observeCalls == 1
                        ? ComputerUseTargetMismatch(
                            requestedWindowID: 111,
                            actualWindowID: 222,
                            message: "Requested window_id 111 could not be matched; this state fell back to focused window_id 222."
                        )
                        : nil
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    #expect(request.latestWindowState.targetMismatch?.requestedWindowID == 111)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .navigateActiveBrowserTab,
                        appBundleID: "com.google.Chrome",
                        url: "https://example.com"
                    ))
                case 2:
                    #expect(request.priorOutcomes.last?.tool == .navigateActiveBrowserTab)
                    #expect(request.priorOutcomes.last?.status == "target_mismatch")
                    #expect(request.priorOutcomes.last?.message.contains("Cannot run navigate_active_browser_tab") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Need matched window."))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in
                executeCalls += 1
                return .executed("Navigated")
            }
        )

        let result = await runtime.run(command: "open example")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message == "Need matched window.")
        #expect(executeCalls == 0)
    }

    @Test("target mismatch blocks finish")
    @MainActor
    func targetMismatchBlocksFinish() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(
                    windowTitle: "Fallback",
                    screenshot: Self.screenshot(),
                    targetMismatch: ComputerUseTargetMismatch(
                        requestedWindowID: 111,
                        actualWindowID: 222,
                        message: "Requested window_id 111 could not be matched; this state fell back to focused window_id 222."
                    )
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                case 2:
                    #expect(request.priorOutcomes.last?.status == "target_mismatch")
                    #expect(request.priorOutcomes.last?.message.contains("Cannot run finish") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Need matched window."))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "finish target")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message == "Need matched window.")
    }

    @Test("text action blocks finish when screenshot was not OCR verified")
    @MainActor
    func textActionBlocksFinishWhenScreenshotWasNotOCRVerified() async {
        let requestedText = """
        Computer Use as the Future of Human-Computer Interaction

        Computer use is becoming the future of human-computer interaction because people are moving beyond simple clicks and typed commands.
        """
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(stateID: "state-before", windowTitle: "Untitled", screenshot: Self.screenshot(id: "before"))
                }
                return Self.observation(stateID: "state-after", windowTitle: "Untitled", screenshot: Self.screenshot(id: "after"))
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "before"))
                case 2:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .pasteText, text: requestedText))
                case 3:
                    let outcome = request.priorOutcomes.last
                    #expect(outcome?.verificationStatus == .unchanged)
                    #expect(outcome?.message.contains("AX did not expose newly confirmed requested text") == true)
                    #expect(outcome?.message.contains("Inspect the latest screenshot") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Pasted text") },
            recognizeScreenshotText: { screenshot in
                screenshot?.screenshotID == "before" ? "" : requestedText
            }
        )

        let result = await runtime.run(command: "write about computer use")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Finish blocked because text write evidence is unverified"))
    }

    @Test("runtime exposes screenshot OCR text after OCR tool")
    @MainActor
    func runtimeExposesScreenshotOCRTextAfterOCRTool() async {
        var ocrCalls = 0
        let privateOCRText = "Sheet contains pasted task text"
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(screenshot: Self.screenshot())
            },
            plan: { request in
                if request.step == 1 {
                    #expect(request.latestWindowState.screenshotOCRText == nil)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "s1"))
                }
                #expect(request.latestWindowState.screenshotOCRText == privateOCRText)
                #expect(request.priorOutcomes.last?.message.contains(privateOCRText) == false)
                #expect(request.priorOutcomes.last?.message.contains("Text withheld from trace history") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("unexpected") },
            recognizeScreenshotText: { _ in
                ocrCalls += 1
                return privateOCRText
            }
        )

        let result = await runtime.run(command: "inspect sheet")
        let traceBodies = result.traceEvents.map(\.body).joined(separator: "\n")
        let traceDebugPayloads = result.traceEvents.compactMap(\.debugPayload).joined(separator: "\n")
        let secondPlanningPayload = result.traceEvents
            .filter { $0.kind == "planning" }
            .dropFirst()
            .first?
            .debugPayload ?? ""

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(ocrCalls == 1)
        #expect(traceBodies.contains(privateOCRText) == false)
        #expect(traceBodies.contains("Text withheld from trace history") == true)
        #expect(traceDebugPayloads.contains(privateOCRText) == false)
        #expect(secondPlanningPayload.contains("screenshot_ocr_text") == false)
        #expect(secondPlanningPayload.contains("screenshot_ocr_metadata_by_id") == true)
        #expect(secondPlanningPayload.contains("character_count") == true)
        #expect(secondPlanningPayload.contains("normalized_sha256") == true)
        #expect(secondPlanningPayload.contains("Text withheld from trace history") == true)
    }

    @Test("OCR tool failures are recoverable planner feedback")
    @MainActor
    func ocrToolFailuresAreRecoverablePlannerFeedback() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(screenshot: Self.screenshot(id: "fresh"))
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .recognizeScreenshotText, screenshotID: "stale"))
                case 2:
                    #expect(request.priorOutcomes.last?.tool == .recognizeScreenshotText)
                    #expect(request.priorOutcomes.last?.status == "failed")
                    #expect(request.priorOutcomes.last?.message.contains("Stale screenshot_id stale") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .getWindowState))
                default:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "recovered"))
                }
            },
            execute: { _, _ in .executed("Captured window state") }
        )

        let result = await runtime.run(command: "read screen")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "recovered")
    }

    @Test("runtime leaves screenshot OCR empty by default")
    @MainActor
    func runtimeLeavesScreenshotOCREmptyByDefault() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(screenshot: Self.screenshot())
            },
            plan: { request in
                #expect(request.latestWindowState.screenshotOCRText == nil)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "inspect sheet")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
    }

    @Test("text action UI change without requested text blocks unverified finish")
    @MainActor
    func textActionUIChangeWithoutRequestedTextBlocksUnverifiedFinish() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                if observeCount == 1 {
                    return Self.observation(stateID: "state-before", windowTitle: "Before", screenshot: Self.screenshot())
                }
                return Self.observation(stateID: "state-after", windowTitle: "After", screenshot: Self.screenshot())
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .typeText, text: "hello from computer use"))
                case 2:
                    let outcome = request.priorOutcomes.last
                    #expect(outcome?.verificationStatus == .unknown)
                    #expect(outcome?.message.contains("AX did not expose newly confirmed requested text") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Typed text") }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Finish blocked because text write evidence is unverified"))
        #expect(result.traceEvents.contains { $0.title == "Text write unverified" })
    }

    @Test("changed action clears previous unchanged action counts")
    @MainActor
    func changedActionClearsPreviousUnchangedActionCounts() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                let title = observeCount <= 2 ? "Before" : "After"
                return Self.observation(windowTitle: title, screenshot: Self.screenshot())
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .click, elementID: "e1", label: "Action A"))
                case 2:
                    #expect(request.priorOutcomes.last?.verificationStatus == .unchanged)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .click, elementID: "e2", label: "Action B"))
                case 3:
                    #expect(request.priorOutcomes.last?.verificationStatus == .changed)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .click, elementID: "e1", label: "Action A"))
                default:
                    #expect(request.priorOutcomes.last?.verificationStatus == .unchanged)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
                }
            },
            execute: { _, _ in .executed("Clicked") }
        )

        let result = await runtime.run(command: "try alternate actions")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(observeCount == 4)
    }

    @Test("unchanged click feedback includes route and asks for different strategy")
    @MainActor
    func unchangedClickFeedbackIncludesRouteAndDifferentStrategy() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                return Self.observation(
                    stateID: "state-\(observeCount)",
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 4321,
                    windowID: 88,
                    windowTitle: "YouTube",
                    screenshot: Self.screenshot(id: "shot-\(observeCount)")
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .clickPoint,
                        processID: 4321,
                        windowID: 88,
                        screenshotID: "shot-1",
                        label: "YouTube search result",
                        x: 20,
                        y: 20
                    ))
                case 2:
                    let outcome = request.priorOutcomes.last
                    #expect(outcome?.verificationStatus == .unchanged)
                    #expect(outcome?.message.contains("window_point_skylight") == true)
                    #expect(outcome?.message.contains("use click with a different visible target or addressing mode") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "route feedback observed"))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in
                .executed("Clicked YouTube search result [route=window_point_skylight pid=4321 window_id=88 point=120,220 posted=true]", diagnostics: [
                    "click_route": "window_point_skylight",
                    "process_id": "4321",
                    "window_id": "88",
                ])
            }
        )

        let result = await runtime.run(command: "play a YouTube result")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "route feedback observed")
    }

    @Test("screenshot unavailable state gives concrete fallback instead of blind observe loop")
    @MainActor
    func screenshotUnavailableStateGivesConcreteFallbackInsteadOfBlindObserveLoop() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 4321,
                    windowID: 88,
                    windowTitle: "",
                    screenshot: nil,
                    appInstructions: "Visual screenshot unavailable: Screen Recording permission is not granted to Muesli. Do not repeat get_window_state waiting for a screenshot; use available AX/browser tools if sufficient, or fail with a clear Screen Recording permission reason when visual interaction is required."
                )
            },
            plan: { request in
                switch request.step {
                case 1:
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .getWindowState,
                        appBundleID: "com.google.Chrome",
                        processID: 4321,
                        windowID: 88
                    ))
                case 2:
                    let outcome = request.priorOutcomes.last
                    #expect(outcome?.message.contains("Visual screenshot is unavailable") == true)
                    #expect(outcome?.message.contains("screenshot-coordinate click cannot be planned") == true)
                    #expect(outcome?.message.contains("Screen Recording") == true)
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Screen Recording permission is required for visual YouTube clicking."))
                default:
                    Issue.record("unexpected planner step \(request.step)")
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .fail, reason: "Unexpected step."))
                }
            },
            execute: { _, _ in .executed("Captured target state without foreground activation request") }
        )

        let result = await runtime.run(command: "play a YouTube video")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("Screen Recording permission is required"))
        #expect(result.traceEvents.contains { $0.kind == "observation" && $0.body.contains("screenshot unavailable") })
    }

    @Test("finish with incomplete language becomes failed")
    @MainActor
    func finishWithIncompleteLanguageBecomesFailed() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "Couldn’t complete the task."))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "do something")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("attempted to finish with an incomplete or blocked result"))
    }

    @Test("finish failure heuristic avoids success false positives")
    @MainActor
    func finishFailureHeuristicAvoidsSuccessFalsePositives() async {
        var finishReasons = [
            "Granted the camera permission.",
            "The modal did not have a cancel button so I pressed Escape instead; task is complete.",
        ]
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                    tool: .finish,
                    reason: finishReasons.removeFirst()
                ))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let permissionResult = await runtime.run(command: "grant permission")
        let didNotResult = await runtime.run(command: "dismiss modal")

        #expect(permissionResult.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(didNotResult.status == ComputerUsePlannerRuntimeResult.Status.done)
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
                #expect(request.priorOutcomes.last?.message.contains("Continue with get_window_state and visual screenshot actions") == true)
                #expect(request.priorOutcomes.last?.message.contains("use click on reliable AX candidates or visible screenshot targets") == true)
                #expect(request.priorOutcomes.last?.message.contains("avoid repeated focus cycles") == true)
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

    @Test("stale element window id refreshes state instead of failing task")
    @MainActor
    func staleElementWindowIDRefreshesStateInsteadOfFailingTask() async {
        var observeCount = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                observeCount += 1
                return Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    processID: 40712,
                    windowID: 93784,
                    windowTitle: "YouTube",
                    screenshot: Self.screenshot(),
                    elementValue: "Twitter/X tab labeled pHequals7"
                )
            },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(
                        tool: .clickElement,
                        appBundleID: "com.google.Chrome",
                        processID: 40712,
                        windowID: 93784,
                        elementID: "e1",
                        elementIndex: 1,
                        label: "Twitter/X tab labeled pHequals7"
                    ))
                }
                #expect(request.priorOutcomes.last?.tool == .clickElement)
                #expect(request.priorOutcomes.last?.status == "failed")
                #expect(request.priorOutcomes.last?.message.contains("identity as stale") == true)
                #expect(request.priorOutcomes.last?.message.contains("Do not reuse the stale") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "refreshed and retried"))
            },
            execute: { toolCall, _ in
                #expect(toolCall.tool == .clickElement)
                return .failed("Stale window_id 93784; element target is in window_id 93801. Refresh state before using this element.")
            }
        )

        let result = await runtime.run(command: "switch Twitter profile")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(result.message == "refreshed and retried")
        #expect(observeCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Screen fallback" })
    }

    @Test("runtime trace stores compact debug payloads")
    @MainActor
    func runtimeTraceStoresCompactDebugPayloads() async {
        var ocrCalls = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in
                Self.observation(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "YouTube",
                    screenshot: Self.screenshot(),
                    elementValue: "Video result"
                )
            },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("unexpected") },
            recognizeScreenshotText: { _ in
                ocrCalls += 1
                return "Video result OCR"
            }
        )

        let result = await runtime.run(command: "play a video")
        let planningPayload = result.traceEvents.first { $0.kind == "planning" }?.debugPayload
        let observationPayload = result.traceEvents.first { $0.kind == "observation" }?.debugPayload

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(planningPayload?.contains(#""latest_window_state""#) == true)
        #expect(planningPayload?.contains("Video result OCR") == false)
        #expect(ocrCalls == 0)
        #expect(observationPayload?.contains(#""elements""#) == true)
        #expect(observationPayload?.contains("Video result") == true)
    }

    @Test("invalid tool call is repaired through planner feedback")
    @MainActor
    func invalidToolCallIsRepairedThroughPlannerFeedback() async {
        var planCalls = 0
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation(screenshot: Self.screenshot()) },
            plan: { request in
                planCalls += 1
                if planCalls == 1 {
                    throw ComputerUsePlannerError.invalidToolCall(
                        name: "click_point",
                        arguments: #"{"x":0,"y":0}"#,
                        message: "click_point requires screenshot_id"
                    )
                }
                #expect(request.priorOutcomes.last?.status == "invalid_schema")
                #expect(request.priorOutcomes.last?.message.contains("Choose exactly one valid tool") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "click something")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
        #expect(planCalls == 2)
        #expect(result.traceEvents.contains { $0.title == "Planner schema repair" })
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
                #expect(request.priorOutcomes.last?.message.contains("fresh screenshot/state") == true)
                #expect(request.priorOutcomes.last?.message.contains("use click to place the caret") == true)
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
                #expect(request.priorOutcomes.last?.message.contains("fresh screenshot/state") == true)
                #expect(request.priorOutcomes.last?.message.contains("same failed target") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "focused fallback available"))
            },
            execute: { toolCall, _ in
                #expect(toolCall.tool == .pasteText)
                return .failed("Focus moved within the target process, but not to the intended element. Refresh state before typing.")
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

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.cancelled)
        #expect(result.message == "CUA cancelled")
        #expect(planCalls == 1)
        #expect(!result.traceEvents.contains { $0.title == "Planner retry" })
    }

    static func observation(
        stateID: String = ComputerUseObservation.newStateID(),
        appName: String = "Test",
        bundleID: String = "com.example.Test",
        processID: Int? = nil,
        windowID: Int? = nil,
        windowTitle: String = "Window",
        screenshot: ComputerUseScreenshotObservation? = nil,
        focusedValue: String = "",
        elementValue: String = "",
        appInstructions: String? = nil,
        targetMismatch: ComputerUseTargetMismatch? = nil
    ) -> ComputerUseObservation {
        ComputerUseObservation(
            stateID: stateID,
            appName: appName,
            bundleID: bundleID,
            processID: processID,
            windowID: windowID,
            windowTitle: windowTitle,
            windowFrame: nil,
            screenshot: screenshot,
            cursorPosition: ComputerUseRect(x: 10, y: 20, width: 1, height: 1),
            focusedElement: focusedValue.isEmpty ? nil : ComputerUseFocusedElement(
                role: "AXTextArea",
                title: "",
                label: "",
                value: focusedValue,
                frame: nil,
                processID: nil
            ),
            appInstructions: appInstructions,
            targetMismatch: targetMismatch,
            elements: [
                ComputerUseObservationCapture.candidateForTests(
                    elementID: "e1",
                    role: "AXButton",
                    title: "Send",
                    value: elementValue
                ),
            ],
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    static func screenshot(id: String = "s1") -> ComputerUseScreenshotObservation {
        ComputerUseScreenshotObservation(
            screenshotID: id,
            width: 100,
            height: 80,
            windowFrame: ComputerUseRect(x: 0, y: 0, width: 100, height: 80),
            scaleX: 1,
            scaleY: 1,
            imageDataURL: "data:image/jpeg;base64,abc"
        )
    }
}

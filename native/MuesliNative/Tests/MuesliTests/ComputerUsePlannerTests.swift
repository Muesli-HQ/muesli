import Foundation
import CoreGraphics
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use tool registry")
struct ComputerUseToolRegistryTests {
    @Test("emits schemas and descriptions for every tool")
    func emitsSchemasAndDescriptions() {
        #expect(ComputerUseToolRegistry.definitions.count == ComputerUseToolName.allCases.count - 1)
        #expect(ComputerUseToolRegistry.definition(for: .click) == nil)
        for definition in ComputerUseToolRegistry.definitions {
            #expect(!definition.description.isEmpty)
            #expect(definition.schema.type == "object")
            #expect(definition.schema.additionalProperties == false)
            #expect(definition.schema.required.contains("tool"))
            #expect(definition.schema.properties["tool"]?.enumValues == [definition.name.rawValue])
        }
        let docs = ComputerUseToolRegistry.promptDocumentation()
        #expect(docs.contains("Tool: get_app_state"))
        #expect(docs.contains("Tool: get_window_state"))
        #expect(docs.contains("Tool: click_element"))
        #expect(docs.contains("Tool: click_point"))
        #expect(!docs.contains("Tool: click\n"))
        #expect(docs.contains("Tool: perform_secondary_action"))
        #expect(docs.contains("Tool: open_new_browser_tab"))
        #expect(docs.contains("Tool: navigate_active_browser_tab"))
        #expect(docs.contains("Tool: page_query_dom"))
    }

    @Test("emits native tool definitions")
    func emitsNativeToolDefinitions() {
        let tools = ComputerUseToolRegistry.nativeToolDefinitions()

        #expect(tools.count == ComputerUseToolRegistry.definitions.count)
        #expect(JSONSerialization.isValidJSONObject(tools))
        #expect(!tools.contains { ($0["name"] as? String) == "click" })
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
        #expect(instructions.contains("Browser DOM/page tools are optional accelerators"))
        #expect(instructions.contains("Chrome Apple Events JavaScript permission"))
        #expect(instructions.contains("AX/screenshot fallback"))
        #expect(instructions.contains("Do not use fail only because a browser DOM/page tool failed"))
        #expect(instructions.contains("Do not call get_app_state/get_window_state repeatedly"))
        #expect(instructions.contains("do not loop on observation"))
        #expect(instructions.contains("After open_new_browser_tab, call navigate_active_browser_tab"))
        #expect(instructions.contains("prefer paste_text for multi-word text"))
        #expect(instructions.contains("Use finish only when the user's command is complete and successful"))
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

    @Test("decodes split click tools")
    func decodesSplitClickTools() throws {
        let element = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "click_element",
            arguments: #"{"element_index":12,"label":"Tweet composer"}"#
        )
        let point = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "click_point",
            arguments: #"{"screenshot_id":"s1","x":120,"y":240,"label":"fallback target"}"#
        )

        #expect(element.toolCall.tool == .clickElement)
        #expect(element.toolCall.elementIndex == 12)
        #expect(element.toolCall.x == nil)
        #expect(point.toolCall.tool == .clickPoint)
        #expect(point.toolCall.screenshotID == "s1")
        #expect(point.toolCall.elementIndex == nil)
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

    @Test("decodes secondary action and element scroll")
    func decodesSecondaryActionAndElementScroll() throws {
        let secondary = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"perform_secondary_action","element_index":3,"action_name":"AXShowMenu","label":"More"}"#
        )
        let scroll = try ComputerUsePlannerResponse.decodeJSON(
            from: #"{"tool":"scroll","element_id":"e7","direction":"down","pages":1}"#
        )

        #expect(secondary.toolCall.tool == .performSecondaryAction)
        #expect(secondary.toolCall.actionName == "AXShowMenu")
        #expect(scroll.toolCall.tool == .scroll)
        #expect(scroll.toolCall.elementID == "e7")
    }

    @Test("decodes browser intent tools")
    func decodesBrowserIntentTools() throws {
        let newTab = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "open_new_browser_tab",
            arguments: #"{"app_bundle_id":"com.google.Chrome"}"#
        )
        let navigate = try ComputerUsePlannerResponse.decodeNativeToolCall(
            name: "navigate_active_browser_tab",
            arguments: #"{"app_bundle_id":"com.google.Chrome","url":"https://twitter.com/compose/tweet"}"#
        )

        #expect(newTab.toolCall.tool == .openNewBrowserTab)
        #expect(navigate.toolCall.tool == .navigateActiveBrowserTab)
        #expect(navigate.toolCall.url == "https://twitter.com/compose/tweet")
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

    @Test("formats final CUA status buckets")
    func formatsFinalStatusBuckets() {
        #expect(ComputerUseTraceFormatter.displayFinalStatus("done") == "done")
        #expect(ComputerUseTraceFormatter.displayFinalStatus("timedout") == "timed_out")
        #expect(ComputerUseTraceFormatter.displayFinalStatus("fail") == "failed")
    }
}

@Suite("Computer Use speech feedback")
struct ComputerUseSpeechFeedbackTests {
    private actor SpeechDrainProbe {
        private var calls: [String] = []
        private var activeCount = 0
        private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
        private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var activeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func record(_ text: String) async {
            let index = calls.count
            calls.append(text)
            activeCount += 1
            resumeWaiters()

            if index < 2 {
                await withCheckedContinuation { continuation in
                    releaseContinuations[index] = continuation
                }
            }

            activeCount -= 1
            resumeWaiters()
        }

        func waitForCallCount(_ count: Int) async {
            guard calls.count < count else { return }
            await withCheckedContinuation { continuation in
                callWaiters.append((count, continuation))
            }
        }

        func waitForActiveCount(_ count: Int) async {
            guard activeCount != count else { return }
            await withCheckedContinuation { continuation in
                activeWaiters.append((count, continuation))
            }
        }

        func releaseCall(at index: Int) {
            releaseContinuations.removeValue(forKey: index)?.resume()
        }

        func recordedCalls() -> [String] {
            calls
        }

        private func resumeWaiters() {
            let readyCallWaiters = callWaiters.filter { calls.count >= $0.0 }
            callWaiters.removeAll { calls.count >= $0.0 }
            readyCallWaiters.forEach { $0.1.resume() }

            let readyActiveWaiters = activeWaiters.filter { activeCount == $0.0 }
            activeWaiters.removeAll { activeCount == $0.0 }
            readyActiveWaiters.forEach { $0.1.resume() }
        }
    }

    @Test("older configs decode with CUA TTS defaults")
    func olderConfigsDecodeWithCUATTSDefaults() throws {
        let data = #"{"enable_computer_use_planner":true}"#.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.enableComputerUseVoiceFeedback)
        #expect(config.computerUseTTSModel == ComputerUseTTSModelOption.micro.rawValue)
        #expect(config.computerUseTTSVoice == ComputerUseTTSVoiceOption.bella.rawValue)
        #expect(config.computerUseTTSSpeed == 1.75)
    }

    @Test("CUA TTS settings encode and decode")
    func cuaTTSSettingsEncodeAndDecode() throws {
        var config = AppConfig()
        config.enableComputerUseVoiceFeedback = false
        config.computerUseTTSModel = ComputerUseTTSModelOption.mini.rawValue
        config.computerUseTTSVoice = ComputerUseTTSVoiceOption.hugo.rawValue
        config.computerUseTTSSpeed = 1.25

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(!decoded.enableComputerUseVoiceFeedback)
        #expect(decoded.computerUseTTSModel == ComputerUseTTSModelOption.mini.rawValue)
        #expect(decoded.computerUseTTSVoice == ComputerUseTTSVoiceOption.hugo.rawValue)
        #expect(decoded.computerUseTTSSpeed == 1.25)
    }

    @Test("status speech suppresses intermediate updates and keeps decision states")
    func statusSpeechPolicy() {
        #expect(ComputerUseSpeechPolicy.commandHeardSpeech(for: "Open Chrome") == "Got it.")
        #expect(ComputerUseSpeechPolicy.commandHeardSpeech(for: "   ") == nil)
        #expect(ComputerUseSpeechPolicy.speech(forStatus: "Planning step 1") == nil)
        #expect(ComputerUseSpeechPolicy.speech(forStatus: "Observing screen") == nil)
        #expect(ComputerUseSpeechPolicy.speech(forStatus: "Screen fallback") == nil)
        #expect(ComputerUseSpeechPolicy.speech(forStatus: "Opening Google Chrome") == nil)
        #expect(ComputerUseSpeechPolicy.speech(forStatus: "Typing") == nil)
        #expect(ComputerUseSpeechPolicy.speech(forStatus: "Confirm") == "I need confirmation before continuing.")
        #expect(ComputerUseSpeechPolicy.speech(forStatus: "Failed") == "CUA failed.")
    }

    @Test("final result speech covers all runtime statuses")
    func finalResultSpeechPolicy() {
        #expect(ComputerUseSpeechPolicy.finalSpeech(for: .init(status: .done, message: "Done")) == "Done.")
        #expect(ComputerUseSpeechPolicy.finalSpeech(for: .init(status: .timedOut, message: "CUA timed out")) == "CUA timed out.")
        #expect(ComputerUseSpeechPolicy.finalSpeech(for: .init(status: .failed, message: "blocked")) == "CUA failed. blocked")
        #expect(ComputerUseSpeechPolicy.finalSpeech(for: .init(status: .needsConfirmation, message: "Confirm: send tweet")) == "I need confirmation. Confirm: send tweet")
        #expect(ComputerUseSpeechPolicy.finalSpeech(for: .init(status: .cancelled, message: "CUA cancelled")) == "CUA cancelled.")
    }

    @Test("speech controller drops duplicate statuses and swallows playback failures")
    @MainActor
    func speechControllerDropsDuplicatesAndSwallowsFailures() async throws {
        var spoken: [String] = []
        let controller = ComputerUseSpeechController { text, _ in
            spoken.append(text)
            throw NSError(domain: "SpeechTest", code: 1)
        }
        let config = AppConfig()

        controller.speakStatus("Confirm", config: config)
        controller.speakStatus("Confirm", config: config)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spoken == ["I need confirmation before continuing."])
    }

    @Test("speech controller respects sound and CUA voice toggles")
    @MainActor
    func speechControllerRespectsConfigToggles() async throws {
        var spoken: [String] = []
        let controller = ComputerUseSpeechController { text, _ in
            spoken.append(text)
        }
        var config = AppConfig()

        config.soundEnabled = false
        controller.speakStatus("Confirm", config: config)
        config.soundEnabled = true
        config.enableComputerUseVoiceFeedback = false
        controller.speakStatus("Failed", config: config)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spoken.isEmpty)
    }

    @Test("muted idle status clears duplicate state without speaking")
    @MainActor
    func mutedIdleStatusClearsDuplicateStateWithoutSpeaking() async throws {
        var spoken: [String] = []
        let controller = ComputerUseSpeechController { text, _ in
            spoken.append(text)
        }
        var config = AppConfig()

        controller.speakStatus("Confirm", config: config)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(spoken == ["I need confirmation before continuing."])

        config.soundEnabled = false
        controller.speakStatus("Confirm", config: config)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(spoken == ["I need confirmation before continuing."])

        config.soundEnabled = true
        controller.speakStatus("Confirm", config: config)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(spoken == [
            "I need confirmation before continuing.",
            "I need confirmation before continuing.",
        ])
    }

    @Test("cancelled drain task cannot clear a newer drain task")
    @MainActor
    func cancelledDrainTaskDoesNotClearNewerDrainTask() async throws {
        let probe = SpeechDrainProbe()
        let controller = ComputerUseSpeechController { text, _ in
            await probe.record(text)
        }
        let config = AppConfig()

        controller.speakStatus("Confirm", config: config)
        await probe.waitForCallCount(1)

        controller.stop()
        controller.speakStatus("Failed", config: config)
        await probe.waitForCallCount(2)

        await probe.releaseCall(at: 0)
        await probe.waitForActiveCount(1)

        controller.speakFinalResult(.init(status: .done, message: "Done"), config: config)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await probe.recordedCalls() == [
            "I need confirmation before continuing.",
            "CUA failed.",
        ])

        await probe.releaseCall(at: 1)
        await probe.waitForCallCount(3)
        #expect(await probe.recordedCalls() == [
            "I need confirmation before continuing.",
            "CUA failed.",
            "Done.",
        ])
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

    @Test("timeout produces timed out runtime result")
    @MainActor
    func timeoutProducesTimedOutResult() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            timeoutSeconds: -1,
            observe: { _, _, _ in Self.observation() },
            plan: { _ in ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done")) },
            execute: { _, _ in .executed("unexpected") }
        )

        let result = await runtime.run(command: "do something")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.timedOut)
        #expect(result.message == "CUA timed out")
        #expect(result.traceEvents.contains { $0.kind == "timed_out" && $0.status == "timed_out" })
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
        #expect(result.message.contains("repeated click Address and search bar after two unchanged attempts"))
        #expect(executionCount == 2)
        #expect(result.traceEvents.contains { $0.title == "Repeated action stopped" })
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
        #expect(!result.traceEvents.contains { $0.title == "Repeated action stopped" })
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

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.failed)
        #expect(result.message.contains("repeated get window state after 4 unchanged observations"))
        #expect(executionCount == 4)
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
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("Clicked") }
        )

        let result = await runtime.run(command: "click search")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
    }

    @Test("first unchanged action is planner feedback")
    @MainActor
    func firstUnchangedActionIsPlannerFeedback() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation(screenshot: Self.screenshot()) },
            plan: { request in
                if request.step == 1 {
                    return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .pasteText, text: "hello"))
                }
                let outcome = request.priorOutcomes.last
                #expect(outcome?.verificationStatus == .unchanged)
                #expect(outcome?.message.contains("no focused value, selected text, or visible AX text change was observed") == true)
                return ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "done"))
            },
            execute: { _, _ in .executed("Pasted text") }
        )

        let result = await runtime.run(command: "write hello")

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.done)
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

    @Test("finish with incomplete language becomes failed")
    @MainActor
    func finishWithIncompleteLanguageBecomesFailed() async {
        let runtime = ComputerUsePlannerRuntime(
            config: AppConfig(),
            observe: { _, _, _ in Self.observation() },
            plan: { _ in
                ComputerUsePlannerResponse(toolCall: ComputerUseToolCall(tool: .finish, reason: "Could not complete the task."))
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
                #expect(request.priorOutcomes.last?.message.contains("Continue with get_app_state plus AX/screenshot tools") == true)
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

        #expect(result.status == ComputerUsePlannerRuntimeResult.Status.cancelled)
        #expect(result.message == "CUA cancelled")
        #expect(planCalls == 1)
        #expect(!result.traceEvents.contains { $0.title == "Planner retry" })
    }

    static func observation(
        stateID: String = ComputerUseObservation.newStateID(),
        appName: String = "Test",
        bundleID: String = "com.example.Test",
        windowTitle: String = "Window",
        screenshot: ComputerUseScreenshotObservation? = nil
    ) -> ComputerUseObservation {
        ComputerUseObservation(
            stateID: stateID,
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

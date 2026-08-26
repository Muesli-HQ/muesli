import Foundation

enum ComputerUsePlannerError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidResponse(String)
    case invalidToolCall(name: String, arguments: String, message: String)
    case backendFailed(statusCode: Int, message: String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Connect ChatGPT to use model-driven computer use."
        case .invalidResponse(let message):
            return "CUA planner returned an invalid tool call. \(message)"
        case .invalidToolCall(let name, let arguments, let message):
            return "CUA planner returned an invalid tool call. \(message) Raw native tool call: \(name) \(String(arguments.prefix(800)))"
        case .backendFailed(let statusCode, let message):
            return "CUA planner failed with status \(statusCode). \(message)"
        case .requestFailed(let message):
            return "CUA planner could not be reached. \(message)"
        }
    }
}

enum ComputerUsePlannerClient {
    static let defaultModel = "gpt-5.6-sol"

    static var instructions: String {
        """
    You are Muesli's computer-use planner. You do not execute actions. You must choose exactly one native tool call from the provided tool list.

    Rules:
    - Only use element_index or element_id values present in latest_window_state. Element references expire after each new get_app_state/get_window_state or refreshed state.
    - Never invent AppleScript, shell commands, code, URLs, or tools.
    - For app launch/navigation, use launch_app with the requested app name or app bundle id. Do not substitute another app because it is frontmost, visible, or present in examples.
    - After launch_app, Muesli will refresh the requested app's state automatically. If the next state is not the requested app, call get_app_state for that app before using fail.
    - Prefer get_app_state when the current state is insufficient or appears to be for the wrong app. get_window_state is a compatibility alias.
    - Prefer click_element/set_value over coordinate clicks when a matching element exists.
    - For coordinate click/drag, use screenshot pixel coordinates from the current screenshot, not global screen coordinates.
    - Include screenshot_id from latest_window_state when using screenshot-coordinate tools.
    - Use click_element for AX candidates and click_point for screenshot coordinates. Never use legacy click unless it appears in an old prior trace.
    - For new or separate browser tasks, prefer open_new_browser_tab and then navigate_active_browser_tab. Use list_browser_tabs and activate_browser_tab only when the user asks to continue, find, or reuse an existing tab.
    - Browser DOM/page tools are optional accelerators. Use page_get_text/page_query_dom when useful, but do not depend on them as the control path.
    - If page_get_text, page_query_dom, or list_browser_tabs fails, is blocked by Chrome Apple Events JavaScript permission, returns insufficient content, or returns no tabs, immediately continue with get_app_state plus AX/screenshot actions such as click_element/click_point, paste_text/type_text, press_key/hotkey, and scroll.
    - For text entry, prefer app-scoped calls: include app_name/app_bundle_id, and include element_index/element_id when an editable target is visible in the latest state.
    - type_text sends literal keyboard input after Muesli activates the requested app and verifies a focused editable target. Use it for normal typing into focused text fields.
    - For Apple Notes and native rich-text editors, first focus the editable note body/title, then prefer paste_text for multi-word text. Use type_text only for short direct key-event text entry when paste_text is inappropriate.
    - Do not use fail only because a browser DOM/page tool failed. Use fail only after trying the available AX/screenshot fallback path or when the requested task is unsafe or truly unsupported.
    - After get_app_state returns a fresh state, act on the visible AX/screenshot evidence. Do not call get_app_state/get_window_state repeatedly unless a tool result indicates the app/window changed or a previous action needs verification.
    - Every mutating action result includes verification. If the prior outcome says no relevant UI change was observed, choose a different strategy such as a different target, different text primitive, keyboard navigation, or get_app_state before retrying.
    - If browser page tools are blocked, use the screenshot and AX candidates to click_element/click_point, type, press keys, or scroll; do not loop on observation waiting for DOM access to appear.
    - navigate_url and navigate_active_browser_tab may only use http or https URLs. Never output javascript:, file:, data:, shell text, or arbitrary code.
    - For navigate_url, include window_index/tab_index only when they came from a recent list_browser_tabs result. After open_new_browser_tab, call navigate_active_browser_tab.
    - max_steps is a high safety ceiling, not a target. Use as few steps as needed.
    - Use finish only when the user's command is complete and successful. If the task could not be completed, is blocked, is unsafe, or needs missing permission/confirmation, use fail(reason); never put blocked or incomplete language in finish.
    - Risky actions are locally blocked by Muesli; do not try to bypass confirmation.
    """
    }

    static func planNextTool(
        request: ComputerUsePlannerRequest,
        config: AppConfig
    ) async throws -> ComputerUsePlannerResponse {
        do {
            return try await callChatGPTResponses(
                systemPrompt: instructions,
                userPrompt: requestPrompt(for: request),
                imageDataURL: request.latestWindowState.screenshot?.imageDataURL,
                model: plannerModel(for: config)
            )
        } catch ChatGPTAuthError.notAuthenticated {
            throw ComputerUsePlannerError.notAuthenticated
        } catch let error as ComputerUsePlannerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ComputerUsePlannerError.requestFailed(error.localizedDescription)
        }
    }

    static func plannerModel(for config: AppConfig) -> String {
        let trimmed = config.computerUsePlannerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private static func requestPrompt(for request: ComputerUsePlannerRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func callChatGPTResponses(
        systemPrompt: String,
        userPrompt: String,
        imageDataURL: String?,
        model: String
    ) async throws -> ComputerUsePlannerResponse {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let body = requestBody(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            imageDataURL: imageDataURL,
            model: model
        )

        let urlRequest = try ChatGPTResponsesTransport.makeRequest(
            body: body,
            token: token,
            accountId: accountId
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let message = extractErrorMessage(from: errorData)
                ?? String(data: errorData, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpStatus)
            throw ComputerUsePlannerError.backendFailed(statusCode: httpStatus, message: String(message.prefix(800)))
        }

        var fullText = ""
        var parsedNativeToolCall: (name: String, arguments: String)?
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                fullText = outputText
            }
            if let type = json["type"] as? String, type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
            }
            if let toolCall = nativeToolCall(in: json) {
                parsedNativeToolCall = toolCall
            }
        }

        if let nativeToolCall = parsedNativeToolCall {
            do {
                return try ComputerUsePlannerResponse.decodeNativeToolCall(
                    name: nativeToolCall.name,
                    arguments: nativeToolCall.arguments
                )
            } catch {
                throw ComputerUsePlannerError.invalidToolCall(
                    name: nativeToolCall.name,
                    arguments: nativeToolCall.arguments,
                    message: error.localizedDescription
                )
            }
        }

        let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw ComputerUsePlannerError.invalidResponse(
            trimmedText.isEmpty
                ? "The model did not return a native tool call."
                : "The model returned text instead of a native tool call: \(String(trimmedText.prefix(800)))"
        )
    }

    static func requestBody(
        systemPrompt: String,
        userPrompt: String,
        imageDataURL: String?,
        model: String
    ) -> [String: Any] {
        var content: [[String: Any]] = [
            ["type": "input_text", "text": userPrompt],
        ]
        if let imageDataURL {
            content.append(["type": "input_image", "image_url": imageDataURL])
        }
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": systemPrompt,
            "tools": ComputerUseToolRegistry.nativeToolDefinitions(),
            "tool_choice": "required",
            "parallel_tool_calls": false,
            "input": [
                [
                    "role": "user",
                    "content": content,
                ] as [String: Any],
            ],
        ]
        if let effort = SummaryModelPreset.reasoningEffort(for: model) {
            body["reasoning"] = ["effort": effort]
        }
        return body
    }

    private static func nativeToolCall(in value: Any, depth: Int = 0) -> (name: String, arguments: String)? {
        guard depth <= 16 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String, type == "function_call",
               let name = dictionary["name"] as? String {
                return (name, argumentsString(from: dictionary["arguments"]))
            }
            if let function = dictionary["function"] as? [String: Any],
               let name = function["name"] as? String {
                return (name, argumentsString(from: function["arguments"]))
            }
            for child in dictionary.values {
                if let toolCall = nativeToolCall(in: child, depth: depth + 1) {
                    return toolCall
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let toolCall = nativeToolCall(in: child, depth: depth + 1) {
                    return toolCall
                }
            }
        }
        return nil
    }

    private static func argumentsString(from value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let value,
           JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
            return String(describing: error)
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }
        return nil
    }
}

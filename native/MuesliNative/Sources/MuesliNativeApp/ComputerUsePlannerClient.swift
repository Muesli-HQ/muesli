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
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    static let defaultModel = "gpt-5.5"

    static var instructions: String {
        """
    You are Muesli's computer-use planner. You do not execute actions. You must choose exactly one native tool call from the provided tool list.

    Rules:
    - Follow Look -> Act -> Verify. Read latest_window_state, choose one concrete action, then use the next observation and receipt to decide what to do.
    - available_tools is authoritative for this turn. Never emit legacy or unavailable tools even if planner_history mentions them.
    - planner_history is the compact action chain. It records prior model calls, primitive results, and observation receipts. The latest state and attached screenshot remain the current source of truth.
    - Only use element_index or element_id values from latest_window_state. They expire after every refreshed observation.
    - Use click for all click intent. Address a clear AX target by element_index/element_id, or a visual target by screenshot_id plus screenshot x/y. Muesli chooses AX, point, or other delivery routes.
    - Use paste_text for text-entry intent. Include the current app and element target when available; Muesli chooses the insertion route.
    - Use update_muesli_settings for supported Muesli configuration changes. Do not open or click through Muesli Settings for these operations. Boolean setters accept true and false. A Computer Use disable applies to future shortcut activations after this command finishes.
      Examples (native tool arguments only):
      - Change the transcription model to Parakeet: {"operation":"set_transcription_model","model":"parakeet"}
      - Enable AI cleanup: {"operation":"set_ai_cleanup","enabled":true}
      - Disable Computer Use after this command: {"operation":"set_computer_use_enabled","enabled":false}
      - Set the Computer Use safety limit for future commands: {"operation":"set_computer_use_safety_limit","seconds":300}
      - Add a dictionary correction: {"operation":"add_dictionary_word","word":"musli","replacement":"Muesli"}
      - Remove a dictionary entry: {"operation":"remove_dictionary_word","word":"musli"}
      - Pause media during dictation: {"operation":"set_pause_media_during_dictation","enabled":true}
      - Mute system audio during dictation: {"operation":"set_mute_system_audio_during_dictation","enabled":true}
      - Hide the floating indicator: {"operation":"set_floating_indicator_enabled","enabled":false}
      - Move the floating indicator: {"operation":"set_floating_indicator_position","position":"Bottom Center"}
      - Disable sound effects: {"operation":"set_sound_effects","enabled":false}
      - Use dark mode: {"operation":"set_theme","theme":"dark"}
      - Do not open the dashboard on launch: {"operation":"set_open_dashboard_on_launch","enabled":false}
    - A transaction receipt describes primitive delivery only. posted means an input was sent; effect reports the observed low-level state change. Neither means the user's semantic task is complete.
    - The harness does not judge whether your strategy is good. Inspect the latest screenshot/AX state and decide whether to continue, finish, or fail.
    - Never invent AppleScript, shell commands, code, URLs, element IDs, screenshot IDs, or tools.
    - max_steps is a high safety ceiling, not a target. Use as few steps as needed.
    - finish and fail are typed terminal decisions. Use finish only for a completed task and fail for blocked, partial, unsupported, unsafe, or incomplete work. The tool choice, not wording heuristics over reason, determines runtime status.
    - Risky actions are locally blocked by Muesli; do not try to bypass confirmation.
    """
    }

    static func planNextTool(
        request: ComputerUsePlannerRequest,
        config: AppConfig
    ) async throws -> ComputerUsePlannerResponse {
        do {
            return try await callWHAM(
                systemPrompt: instructions,
                userPrompt: requestPrompt(for: request),
                imageDataURL: request.latestWindowState.screenshot?.imageDataURL,
                availableTools: request.availableTools,
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

    private static func callWHAM(
        systemPrompt: String,
        userPrompt: String,
        imageDataURL: String?,
        availableTools: [ComputerUseToolName],
        model: String
    ) async throws -> ComputerUsePlannerResponse {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        var content: [[String: Any]] = [
            ["type": "input_text", "text": userPrompt],
        ]
        if let imageDataURL {
            content.append(["type": "input_image", "image_url": imageDataURL])
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": systemPrompt,
            "tools": ComputerUseToolRegistry.nativeToolDefinitions(allowedTools: Set(availableTools)),
            "tool_choice": "required",
            "parallel_tool_calls": false,
            "input": [
                [
                    "role": "user",
                    "content": content,
                ] as [String: Any],
            ],
        ]

        var urlRequest = URLRequest(url: whamURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            urlRequest.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

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
                let response = try ComputerUsePlannerResponse.decodeNativeToolCall(
                    name: nativeToolCall.name,
                    arguments: nativeToolCall.arguments
                )
                if let failure = response.toolAvailabilityFailure(availableTools: availableTools) {
                    throw ComputerUsePlannerError.invalidToolCall(
                        name: nativeToolCall.name,
                        arguments: nativeToolCall.arguments,
                        message: failure
                    )
                }
                return response
            } catch let error as ComputerUsePlannerError {
                throw error
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

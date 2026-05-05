import Foundation

enum ComputerUsePlannerError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidResponse(String)
    case backendFailed(statusCode: Int, message: String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Connect ChatGPT to use model-driven computer use."
        case .invalidResponse(let message):
            return "CUA planner returned an invalid tool call. \(message)"
        case .backendFailed(let statusCode, let message):
            return "CUA planner failed with status \(statusCode). \(message)"
        case .requestFailed(let message):
            return "CUA planner could not be reached. \(message)"
        }
    }
}

enum ComputerUsePlannerClient {
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let defaultModel = "gpt-5.4-mini"

    private static let instructions = """
    You are Muesli's computer-use planner. You do not execute actions. You choose exactly one tool call.

    Return exactly one JSON object and no markdown. Use one of these tools:
    {"tool":"observe"}
    {"tool":"observe_screen"}
    {"tool":"open_app","app_name":"<requested app name>"}
    {"tool":"focus_app","app_name":"<requested app name>"}
    {"tool":"click_element","element_id":"e12","label":"Search"}
    {"tool":"click_point","screenshot_id":"s123","x":120,"y":240,"label":"Search"}
    {"tool":"move_cursor","screenshot_id":"s123","x":120,"y":240}
    {"tool":"drag","screenshot_id":"s123","x":120,"y":240,"to_x":360,"to_y":240,"label":"slider"}
    {"tool":"press_key","modifiers":["command"],"key":"l"}
    {"tool":"type_text","text":"hello"}
    {"tool":"paste_text","text":"hello"}
    {"tool":"scroll","direction":"down","pages":1}
    {"tool":"finish","reason":"done"}

    Rules:
    - Only use element_id values present in the observation.
    - Never invent AppleScript, shell commands, code, URLs, or tools.
    - For open_app/focus_app, app_name must be the app requested by the user command.
    - Do not substitute another app because it is frontmost, visible, or present in examples.
    - Prefer open_app/focus_app for app navigation.
    - Prefer click_element over click_point when a matching element_id is available.
    - Use observe_screen when AX candidates are insufficient and visual coordinates are needed.
    - For click_point/move_cursor/drag, use screenshot pixel coordinates from the current screenshot, not global screen coordinates.
    - Include screenshot_id from the current observation when using screenshot-coordinate tools.
    - Use observe if the current observation is insufficient.
    - max_steps is a high safety ceiling, not a target. Use as few steps as needed.
    - Use finish when the user's command is complete or no further safe action is needed.
    - Risky actions are locally blocked by Muesli; do not try to bypass confirmation.
    """

    static func planNextTool(
        request: ComputerUsePlannerRequest,
        config: AppConfig
    ) async throws -> ComputerUsePlannerResponse {
        do {
            let text = try await callWHAM(
                systemPrompt: instructions,
                userPrompt: requestPrompt(for: request),
                imageDataURL: request.observation.screenshot?.imageDataURL,
                model: config.chatGPTModel.isEmpty ? defaultModel : config.chatGPTModel
            )
            do {
                return try ComputerUsePlannerResponse.decodeJSON(from: text)
            } catch {
                throw ComputerUsePlannerError.invalidResponse(error.localizedDescription)
            }
        } catch ChatGPTAuthError.notAuthenticated {
            throw ComputerUsePlannerError.notAuthenticated
        } catch let error as ComputerUsePlannerError {
            throw error
        } catch {
            throw ComputerUsePlannerError.requestFailed(error.localizedDescription)
        }
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
        model: String
    ) async throws -> String {
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
        }

        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
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

import Foundation

enum ChatGPTResponsesError: LocalizedError {
    case backendFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .backendFailed(let statusCode, let message):
            return "ChatGPT failed with status \(statusCode). \(message)"
        }
    }
}

enum ChatGPTResponsesClient {
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!

    static func respond(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        logCategory: String
    ) async throws -> String {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": systemPrompt,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": userPrompt],
                    ],
                ] as [String: Any],
            ],
        ]

        var request = URLRequest(url: whamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let message = extractErrorMessage(from: errorData)
                ?? String(data: errorData, encoding: .utf8)
                ?? "(unknown)"
            fputs("[\(logCategory)] ChatGPT WHAM: HTTP \(httpStatus): \(String(message.prefix(500)))\n", stderr)
            throw ChatGPTResponsesError.backendFailed(statusCode: httpStatus, message: message)
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard
                let data = jsonString.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let type = json["type"] as? String,
               type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
                continue
            }

            if let outputText = extractOutputText(from: json), !outputText.isEmpty {
                fullText = outputText
            }
        }

        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        fputs("[\(logCategory)] ChatGPT WHAM: collected \(trimmed.count) chars\n", stderr)
        return trimmed
    }

    static func extractOutputText(from payload: [String: Any]) -> String? {
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }
        if let response = payload["response"] as? [String: Any],
           let responseText = extractOutputText(from: response) {
            return responseText
        }
        if let outputText = extractText(fromOutput: payload["output"]) {
            return outputText
        }
        if let contentText = extractText(fromContent: payload["content"]) {
            return contentText
        }
        return nil
    }

    private static func extractText(fromOutput output: Any?) -> String? {
        guard let output else { return nil }
        if let outputText = output as? String, !outputText.isEmpty {
            return outputText
        }
        if let item = output as? [String: Any] {
            return extractText(fromContent: item["content"]) ?? (item["text"] as? String)
        }
        if let items = output as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                if let text = extractText(fromContent: item["content"]) {
                    return text
                }
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                return nil
            }
            let joined = parts.joined(separator: "")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractText(fromContent content: Any?) -> String? {
        guard let content else { return nil }
        if let text = content as? String, !text.isEmpty {
            return text
        }
        if let item = content as? [String: Any] {
            if let text = item["text"] as? String, !text.isEmpty {
                return text
            }
            if let text = item["content"] as? String, !text.isEmpty {
                return text
            }
            if let nested = item["text"] as? [String: Any],
               let value = nested["value"] as? String,
               !value.isEmpty {
                return value
            }
        }
        if let items = content as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                if let text = item["content"] as? String, !text.isEmpty {
                    return text
                }
                if let nested = item["text"] as? [String: Any],
                   let value = nested["value"] as? String,
                   !value.isEmpty {
                    return value
                }
                return nil
            }
            let joined = parts.joined(separator: "")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

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

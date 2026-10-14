import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("ChatGPT Responses transport")
struct ChatGPTResponsesTransportTests {
    @Test("Quill token limits are omitted from Codex requests but retained for WHAM")
    func quillTokenLimitRespectsTransport() throws {
        let body = ChatGPTResponsesClient.requestBody(
            systemPrompt: "Rewrite the selected text",
            userPrompt: "Make this concise",
            model: "gpt-5.6-sol",
            maxOutputTokens: QuilModelPolicy.remoteMaximumOutputTokens
        )
        for backend in ["codex", "wham"] {
            let request = try ChatGPTResponsesTransport.makeRequest(
                body: body,
                token: "test-token",
                accountId: "test-account",
                environment: [ChatGPTResponsesTransport.environmentKey: backend]
            )
            let data = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if backend == "codex" {
                #expect(json["max_output_tokens"] == nil)
            } else {
                #expect(json["max_output_tokens"] as? Int == QuilModelPolicy.remoteMaximumOutputTokens)
            }
            #expect(json["instructions"] as? String == "Rewrite the selected text")
            #expect(json["stream"] as? Bool == true)
        }
    }

    @Test("builds Codex Responses requests with honest Muesli identity")
    func buildsCodexRequest() throws {
        let sessionID = UUID(uuidString: "8AF070D8-956D-4706-9FF8-8140CE7F6B2D")!
        let request = try ChatGPTResponsesTransport.makeRequest(
            body: ["model": "gpt-5.6-sol", "stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.2.3",
            sessionID: sessionID,
            environment: [:]
        )

        #expect(request.url == URL(string: "https://chatgpt.com/backend-api/codex/responses"))
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 120)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
        #expect(request.value(forHTTPHeaderField: "originator") == "muesli")
        #expect(request.value(forHTTPHeaderField: "version") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Muesli/1.2.3")
        #expect(request.value(forHTTPHeaderField: "session_id") == sessionID.uuidString.lowercased())
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-5.6-sol")
        #expect(json["stream"] as? Bool == true)
    }

    @Test("omits empty account IDs without dropping Codex identity headers")
    func omitsEmptyAccountID() throws {
        let request = try ChatGPTResponsesTransport.makeRequest(
            body: ["stream": true],
            token: "access-token",
            accountId: "",
            appVersion: "2.0.0",
            sessionID: UUID(uuidString: "194AC4DC-E234-4153-BA13-A1D48323303F")!,
            environment: [:]
        )

        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "originator") == "muesli")
        #expect(request.value(forHTTPHeaderField: "version") == nil)
    }

    @Test("creates a fresh session ID for every request")
    func createsFreshSessionIDs() throws {
        let first = try ChatGPTResponsesTransport.makeRequest(
            body: ["stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.0.0",
            environment: [:]
        )
        let second = try ChatGPTResponsesTransport.makeRequest(
            body: ["stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.0.0",
            environment: [:]
        )

        let firstSessionID = try #require(first.value(forHTTPHeaderField: "session_id"))
        let secondSessionID = try #require(second.value(forHTTPHeaderField: "session_id"))
        #expect(UUID(uuidString: firstSessionID) != nil)
        #expect(UUID(uuidString: secondSessionID) != nil)
        #expect(firstSessionID != secondSessionID)
    }

    @Test("uses Codex by default and only selects WHAM for the explicit override")
    func selectsBackendFromEnvironment() {
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [:]) == .codex)
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [
            ChatGPTResponsesTransport.environmentKey: "codex",
        ]) == .codex)
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [
            ChatGPTResponsesTransport.environmentKey: "unknown",
        ]) == .codex)
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [
            ChatGPTResponsesTransport.environmentKey: " WHAM ",
        ]) == .wham)
    }

    @Test("builds the legacy WHAM request only for the emergency override")
    func buildsWhamOverrideRequest() throws {
        let request = try ChatGPTResponsesTransport.makeRequest(
            body: ["model": "gpt-5.4", "stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.2.3",
            sessionID: UUID(uuidString: "6482D44E-BE26-4B98-B0B7-B5D5281C713B")!,
            environment: [ChatGPTResponsesTransport.environmentKey: "wham"]
        )

        #expect(request.url == URL(string: "https://chatgpt.com/backend-api/wham/responses"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
        #expect(request.value(forHTTPHeaderField: "originator") == nil)
        #expect(request.value(forHTTPHeaderField: "version") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(request.value(forHTTPHeaderField: "session_id") == nil)
    }

    @Test("prefers the declared final assistant answer over commentary and joined convenience text")
    func extractsFinalAssistantPhase() {
        let answer = #"{"status":"answered","markdown":"Friday [[S1]]"}"#
        let output: [[String: Any]] = [
            ["type": "reasoning", "role": "assistant", "phase": "final_answer", "content": [["text": "PRIVATE_REASONING"]]],
            ["type": "message", "role": "assistant", "phase": "commentary", "content": [["text": "Let me check the meeting."]]],
            ["type": "message", "role": "assistant", "phase": "partial_answer", "content": [["text": "Partial draft"]]],
            ["type": "message", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": answer]]],
            ["type": "message", "role": "user", "phase": "final_answer", "content": [["text": "Not an assistant answer"]]]
        ]
        #expect(ChatGPTResponsesClient.extractOutputText(from: ["output": output, "output_text": "Let me check the meeting." + answer]) == answer)
        #expect(ChatGPTResponsesClient.extractOutputText(from: ["response": ["output": output], "output_text": "Joined commentary"]) == answer)
        var deltas = ""
        var final = ""
        ChatGPTResponsesClient.applyStreamPayload(["type": "response.output_text.delta", "delta": "Let me check the meeting."], deltaText: &deltas, finalText: &final)
        ChatGPTResponsesClient.applyStreamPayload(["type": "response.output_text.delta", "delta": answer], deltaText: &deltas, finalText: &final)
        ChatGPTResponsesClient.applyStreamPayload(["type": "response.completed", "response": ["output": output]], deltaText: &deltas, finalText: &final)
        #expect(ChatGPTResponsesClient.accumulatedOutputText(deltaText: deltas, finalText: final) == answer)
    }

    @Test("keeps legacy unphased output while excluding reasoning")
    func retainsLegacyUnphasedOutput() {
        let output: [[String: Any]] = [
            ["type": "reasoning", "content": [["text": "PRIVATE_REASONING"]]],
            ["type": "message", "role": "assistant", "content": [["text": "Part one "]]],
            ["type": "message", "role": "assistant", "content": [["text": "part two"]]]
        ]
        #expect(ChatGPTResponsesClient.extractOutputText(from: ["output": output]) == "Part one part two")
        #expect(ChatGPTResponsesClient.extractOutputText(from: ["output_text": "Legacy reply"]) == "Legacy reply")
        #expect(ChatGPTResponsesClient.extractOutputText(from: ["output": ["type": "message", "role": "assistant", "phase": "final_answer", "content": [["text": "Final"]]]]) == "Final")
    }


    @Test("native tool requests register strict schemas and preserve replay items")
    func nativeToolRequestSchemaAndReplay() throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "openai"
        let replay: [[String: Any]] = [
            ["role": "user", "content": "Find the decision"],
            ["type": "reasoning", "id": "r1", "encrypted_content": "encrypted-replay", "summary": []],
            ["type": "function_call", "id": "fc1", "call_id": "call1", "name": "search_meeting_sources", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "call1", "output": "source packet"]
        ]
        let tools: [[String: Any]] = [["type": "function", "name": "search_meeting_sources", "strict": true,
            "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"], "additionalProperties": false]]]
        let request = MeetingNativeToolRequest(base: .init(system: "Meeting instructions", user: "unused", config: config),
            inputItems: try JSONSerialization.data(withJSONObject: replay), tools: try JSONSerialization.data(withJSONObject: tools), allowTools: true)
        let body = try MeetingNativeToolTransport.requestBody(request, stream: true)
        #expect(body["store"] as? Bool == false)
        #expect(body["parallel_tool_calls"] as? Bool == false)
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input[1]["encrypted_content"] as? String == "encrypted-replay")
        #expect(input[3]["call_id"] as? String == "call1")
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["status", "markdown"])
        #expect(schema["additionalProperties"] as? Bool == false)
        let finalRequest = MeetingNativeToolRequest(base: request.base, inputItems: request.inputItems, tools: request.tools, allowTools: false)
        #expect(try MeetingNativeToolTransport.requestBody(finalRequest, stream: false)["tool_choice"] as? String == "none")
    }

    @Test("native tool responses preserve encrypted reasoning and provider call IDs")
    func nativeToolResponsePreservesOutput() throws {
        let output: [[String: Any]] = [
            ["type": "reasoning", "id": "r1", "encrypted_content": "opaque", "summary": [["type": "summary_text", "text": "Searching"]]],
            ["type": "function_call", "id": "fc1", "call_id": "call1", "name": "read_meeting_source", "arguments": #"{"source":"S1"}"#]
        ]
        let response = try MeetingNativeToolTransport.parseResponse(["status": "completed", "output": output])
        #expect(response.calls.count == 1)
        #expect(response.calls.first?.id == "call1")
        #expect(response.calls.first?.name == "read_meeting_source")
        #expect(response.text.isEmpty)
        let preserved = try #require(JSONSerialization.jsonObject(with: response.outputItems) as? [[String: Any]])
        #expect(preserved[0]["encrypted_content"] as? String == "opaque")
        #expect(preserved[1]["id"] as? String == "fc1")
    }

    @Test("native tool parsing rejects incomplete and malformed terminal output")
    func nativeToolResponseRejectsIncomplete() throws {
        for payload in [
            ["status": "incomplete", "output": [["type": "message", "content": [["text": "Partial"]]]]],
            ["status": "failed", "output": []],
            ["status": "completed", "output": [["type": "function_call", "name": "search_meeting_sources", "arguments": "{}"]]],
            ["status": "completed", "output": [["type": "function_call", "call_id": "c", "name": "search_meeting_sources", "arguments": [:]]]],
            ["status": "completed", "output": []]
        ] as [[String: Any]] {
            #expect(throws: (any Error).self) { try MeetingNativeToolTransport.parseResponse(payload) }
        }
        #expect(throws: (any Error).self) { try MeetingNativeToolTransport.parseResponse(Data("not JSON".utf8)) }
    }


    @Test("Codex native SSE replays completed items when terminal output is omitted")
    func nativeStreamAccumulatesCompletedItems() throws {
        var accumulator = MeetingNativeResponseAccumulator()
        let function: [String: Any] = ["type": "function_call", "id": "fc1", "call_id": "call1", "name": "browse_meeting_sources", "arguments": "{}"]
        #expect(try accumulator.apply(["type": "response.output_item.done", "output_index": 1, "item": function]) == nil)
        #expect(try accumulator.apply(["type": "response.output_item.done", "output_index": 0, "item": ["type": "reasoning", "id": "r1", "encrypted_content": "opaque", "summary": []]]) == nil)
        // Repeated item completion must not duplicate the call or reasoning.
        #expect(try accumulator.apply(["type": "response.output_item.done", "output_index": 1, "item": function]) == nil)
        let completed = try accumulator.apply(["type": "response.completed", "response": ["id": "resp1"]])
        let result = try #require(completed)
        #expect(result.calls.count == 1)
        #expect(result.calls.first?.id == "call1")
        let items = try #require(JSONSerialization.jsonObject(with: result.outputItems) as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items.first?["encrypted_content"] as? String == "opaque")
    }

    @Test("native SSE never executes partial call deltas or failed terminal events")
    func nativeStreamRejectsPartialCalls() throws {
        var accumulator = MeetingNativeResponseAccumulator()
        #expect(try accumulator.apply(["type": "response.function_call_arguments.delta", "item_id": "fc1", "delta": "{}"] ) == nil)
        #expect(throws: (any Error).self) {
            try accumulator.apply(["type": "response.completed", "response": ["id": "resp1"]])
        }
        for event in ["response.incomplete", "response.failed", "error"] {
            #expect(throws: (any Error).self) { try accumulator.apply(["type": event]) }
        }
    }


    @Test("OpenRouter GPT and o-series use native tools; other families retain fallback")
    func openRouterNativeCapability() {
        let client = MeetingTextGenerationClient()
        var config = AppConfig()
        config.meetingSummaryBackend = "openrouter"
        for model in ["openai/gpt-5.4", "openai/gpt-5-mini", "openai/o1", "openai/o3-mini", "openai/o4-mini:free"] {
            config.openRouterModel = model
            #expect(client.supportsNativeTools(config: config))
        }
        for model in ["openrouter/free", "anthropic/claude-sonnet-4", "google/gemini-2.5-pro", "openai/o10", "custom/gpt-5"] {
            config.openRouterModel = model
            #expect(!client.supportsNativeTools(config: config))
        }
    }

    @Test("OpenRouter native requests retain routing ID and existing authentication headers")
    func openRouterNativeRequest() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "openrouter"
        config.openRouterModel = "openai/gpt-5.4"
        config.meetingSummaryReasoningEffort = .medium
        let client = MeetingTextGenerationClient(credentialResolver: { _ in "test-key" }, load: { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") != nil)
            let requestData = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
            #expect(body["model"] as? String == "openai/gpt-5.4")
            #expect(body["messages"] == nil)
            #expect(body["tool_choice"] as? String == "auto")
            #expect(body["reasoning"] as? [String: String] != nil)
            #expect((body["max_output_tokens"] as? Int ?? 0) >= 32_768)
            let payload: [String: Any] = ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": #"{"status":"insufficient_evidence","markdown":"No evidence"}"#]]]]]
            return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let response = try await client.generateNative(.init(base: .init(system: "Meeting instructions", user: "", config: config), inputItems: Data("[]".utf8), tools: Data("[]".utf8), allowTools: true))
        #expect(response.text.contains("insufficient_evidence"))
    }


    @Test("native SSE retains completed tool calls when terminal output is explicitly empty")
    func nativeStreamEmptyTerminalRetainsToolCall() throws {
        var accumulator = MeetingNativeResponseAccumulator()
        _ = try accumulator.apply(["type": "response.output_item.done", "output_index": 0, "item": ["type": "function_call", "id": "fc1", "call_id": "call1", "name": "read_full_meeting", "arguments": #"{"meeting_id":42,"page":0}"#]])
        let completed = try accumulator.apply(["type": "response.completed", "response": ["id": "resp1", "status": "completed", "output": []]])
        let response = try #require(completed)
        #expect(response.calls.count == 1)
        #expect(response.calls.first?.id == "call1")
        #expect(response.calls.first?.name == "read_full_meeting")
    }

    @Test("native SSE retains final JSON when terminal output is explicitly empty")
    func nativeStreamEmptyTerminalRetainsFinalAnswer() throws {
        var accumulator = MeetingNativeResponseAccumulator()
        let answer = #"{"status":"conversation","markdown":"Here is a shorter version."}"#
        _ = try accumulator.apply(["type": "response.output_item.done", "output_index": 0, "item": ["type": "message", "id": "m1", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": answer]]]])
        let completed = try accumulator.apply(["type": "response.completed", "response": ["id": "resp1", "status": "completed", "output": []]])
        let response = try #require(completed)
        #expect(response.calls.isEmpty)
        #expect(response.text == answer)
    }

    @Test("native terminal snapshots merge by identity without duplicating calls or losing reasoning")
    func nativeStreamMergesPartialTerminalSnapshot() throws {
        var accumulator = MeetingNativeResponseAccumulator()
        let call: [String: Any] = ["type": "function_call", "id": "fc1", "call_id": "call1", "name": "browse_meeting_sources", "arguments": "{}"]
        _ = try accumulator.apply(["type": "response.output_item.done", "output_index": 0, "item": ["type": "reasoning", "id": "r1", "encrypted_content": "opaque", "summary": []]])
        _ = try accumulator.apply(["type": "response.output_item.done", "output_index": 1, "item": call])
        let completed = try accumulator.apply(["type": "response.completed", "response": ["status": "completed", "output": [call, ["type": "reasoning", "id": "r1", "summary": []]]]])
        let response = try #require(completed)
        let items = try #require(JSONSerialization.jsonObject(with: response.outputItems) as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items[0]["id"] as? String == "r1")
        #expect(items[0]["encrypted_content"] as? String == "opaque")
        #expect(items[1]["call_id"] as? String == "call1")
        #expect(response.calls.count == 1)
    }

    @Test("native transport distinguishes empty, incomplete and malformed responses safely")
    func nativeTransportSafeFailureCategories() throws {
        do {
            _ = try MeetingNativeToolTransport.parseResponse(["status": "completed", "output": []])
            Issue.record("Expected empty output rejection")
        } catch MeetingNativeToolTransportError.emptyOutput {} catch { Issue.record("Incorrect error category") }
        var accumulator = MeetingNativeResponseAccumulator()
        _ = try accumulator.apply(["type": "response.output_item.done", "item": ["type": "message", "role": "assistant", "content": [["text": "Partial private text"]]]])
        do {
            _ = try accumulator.apply(["type": "response.completed", "response": ["status": "incomplete", "output": []]])
            Issue.record("Expected incomplete rejection")
        } catch MeetingNativeToolTransportError.incompleteResponse {} catch { Issue.record("Incorrect error category") }
        do {
            _ = try MeetingNativeToolTransport.parseResponse(["status": "completed", "output": [["type": "function_call", "name": "tool", "arguments": "private arguments"]]])
            Issue.record("Expected malformed call rejection")
        } catch MeetingNativeToolTransportError.malformedToolCall {} catch { Issue.record("Incorrect error category") }
        #expect(!MeetingNativeToolTransportError.incompleteResponse.localizedDescription.contains("Partial private text"))
    }

}

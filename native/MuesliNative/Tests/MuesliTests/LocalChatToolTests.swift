import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Local endpoint native tools")
struct LocalChatToolTests {
    private func config(_ backend: String = "ollama") -> AppConfig {
        var c = AppConfig(); c.meetingSummaryBackend = backend
        c.ollamaURL = "http://localhost:11434/proxy"; c.ollamaModel = "synthetic-model"
        c.lmStudioURL = "http://localhost:1234/proxy/v1"; c.lmStudioModel = "synthetic-model"
        c.customLLMURL = "http://localhost:8080/proxy/v1/chat/completions?tenant=example"
        c.customLLMModel = "synthetic-model"; c.customLLMFormat = CustomLLMFormat.openAI.rawValue
        return c
    }
    private func response(_ request: URLRequest, _ object: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func request(_ config: AppConfig, items: [[String: Any]], tools: Bool = true) throws -> MeetingNativeToolRequest {
        .init(base: .init(system: "Return JSON with status and markdown.", user: "", config: config), inputItems: try JSONSerialization.data(withJSONObject: items),
            tools: try JSONSerialization.data(withJSONObject: MeetingChatNativeHarness.documentTools(vision: false)), allowTools: tools)
    }
    private var initial: [[String: Any]] { [["role": "user", "content": [["type": "input_text", "text": "Read the attached synthetic original."]]]] }

    @Test func ollamaMetadataSelectsToolsAndPinsEffectiveContextWithoutModelNameHeuristics() async throws {
        let c = config()
        let caps = try await LocalChatToolTransport.detect(config: c, credential: "", load: { req in
            #expect(req.url?.path == "/proxy/api/show")
            let body = try #require(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
            #expect(body["model"] as? String == "synthetic-model")
            return try response(req, ["capabilities": ["completion", "tools"], "parameters": "temperature 0.7\nnum_ctx 16384", "model_info": ["unknown.context_length": 32768]])
        }, cache: LocalChatProbeCache())
        #expect(caps.nativeTools && caps.contextTokens == 16384)
        let body = try LocalChatToolTransport.body(request(c, items: initial), capabilities: caps)
        #expect((body["tools"] as? [Any])?.count == 3)
        #expect((body["options"] as? [String: Int])?["num_ctx"] == 16384)
        #expect(body["format"] == nil)
    }

    @Test func lmStudioMatchesLoadedInstanceAndUsesItsActualWindow() async throws {
        let c = config("lmstudio")
        let caps = try await LocalChatToolTransport.detect(config: c, credential: "", load: { req in
            #expect(req.url?.path == "/proxy/api/v1/models")
            #expect(req.httpMethod == "GET" && req.httpBody == nil)
            return try response(req, ["models": [["key": "checkpoint-name", "max_context_length": 131072,
                "capabilities": ["trained_for_tool_use": true],
                "loaded_instances": [["id": "synthetic-model", "config": ["context_length": 6144]], ["id": "another-instance", "config": ["context_length": 32768]]]]]])
        }, cache: LocalChatProbeCache())
        #expect(caps.nativeTools && caps.contextTokens == 6144)
        var client = MeetingTextGenerationClient(); client.localChatCapabilities = caps
        #expect(client.supportsNativeTools(config: c)); #expect(client.chatContextTokens(config: c) == 6144)
        var switched = c; switched.lmStudioModel = "another-instance"
        #expect(!client.supportsNativeTools(config: switched))
        switched = c; switched.lmStudioURL = "http://localhost:5555"
        #expect(!client.supportsNativeTools(config: switched))
    }

    @Test func explicitUnsupportedMetadataRetainsCompatibilityWithoutProbing() async throws {
        for backend in ["ollama", "lmstudio"] {
            let c = config(backend)
            let caps = try await LocalChatToolTransport.detect(config: c, credential: "", load: { req in
                #expect(req.url?.path.hasSuffix(backend == "ollama" ? "/api/show" : "/api/v1/models") == true)
                return try response(req, backend == "ollama" ? ["capabilities": ["completion"]] : ["models": [["key": "synthetic-model", "capabilities": ["trained_for_tool_use": false]]]])
            }, cache: LocalChatProbeCache())
            #expect(!caps.nativeTools)
        }
    }

    @Test func customDetectionUsesOnlySyntheticNativeCallsAndCachesByCredential() async throws {
        let fixture = LocalToolFixture(wire: .openAI, metadata: nil)
        var client = MeetingTextGenerationClient(); client.localChatProbeCache = LocalChatProbeCache()
        client.credentialResolver = { _ in "synthetic-secret" }; client.load = { try await fixture.load($0) }
        var c = config("custom_llm")
        c.customLLMHeaders = [.init(name: "X-Muesli-Test", value: "synthetic-value")]
        let prepared = try await client.preparedForChat(config: c)
        #expect(prepared.supportsNativeTools(config: c))
        _ = try await client.preparedForChat(config: c)
        #expect(await fixture.probes == 1)
        #expect(await fixture.metadataRequests == 2)
        #expect(await fixture.requests.allSatisfy { $0.url?.query == "tenant=example" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-secret" && $0.value(forHTTPHeaderField: "X-Muesli-Test") == "synthetic-value" })
        client.credentialResolver = { _ in "replacement-secret" }
        _ = try await client.preparedForChat(config: c)
        #expect(await fixture.probes == 2)
    }

    @Test func syntheticProbeCacheExpiresWithoutRetainingCredentials() async {
        let cache = LocalChatProbeCache(); let start = Date(timeIntervalSince1970: 1_000)
        await cache.save(true, key: "positive-digest", now: start)
        await cache.save(false, key: "negative-digest", now: start)
        #expect(await cache.value("positive-digest", now: start.addingTimeInterval(31)) == true)
        #expect(await cache.value("negative-digest", now: start.addingTimeInterval(31)) == nil)
        #expect(await cache.value("positive-digest", now: start.addingTimeInterval(301)) == nil)
    }

    @Test func metadataAuthenticationAndTransientFailuresDoNotDowngradeToCompatibility() async throws {
        for status in [401, 403, 429, 500] {
            await #expect(throws: MeetingTextGenerationError.self) {
                _ = try await LocalChatToolTransport.detect(config: config("custom_llm"), credential: "", load: { req in
                    try response(req, ["error": "synthetic"], status: status)
                }, cache: LocalChatProbeCache())
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await LocalChatToolTransport.detect(config: config(), credential: "", load: { _ in throw CancellationError() }, cache: LocalChatProbeCache())
        }
    }

    @Test func ignoredProbeAndExplicitUnsupportedToolsUseCompatibility() async throws {
        for reject in [false, true] {
            let c = config("custom_llm")
            let caps = try await LocalChatToolTransport.detect(config: c, credential: "", load: { req in
                if req.httpMethod == "GET" { return try response(req, ["data": [["id": "synthetic-model"]]]) }
                if reject { return try response(req, ["error": ["message": "tools are not supported"]], status: 400) }
                return try response(req, ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "{\"tool\":\"muesli_capability_probe\"}"]]]])
            }, cache: LocalChatProbeCache())
            #expect(!caps.nativeTools)
        }
    }

    @Test func nativeIDsAndOpaqueContextReplayAcrossBothProtocols() throws {
        for wire in [LocalChatCapabilities.Wire.ollama, .openAI] {
            let c = config(wire == .ollama ? "ollama" : "lmstudio")
            let arguments: Any = wire == .ollama ? ["document_id": "doc"] : "{\"document_id\":\"doc\"}" as Any
            let calls: [[String: Any]] = ["first", "second"].map { ["type": "function", "id": $0, "function": ["name": "inspect_document", "arguments": arguments]] }
            let message: [String: Any] = ["role": "assistant", "content": "", "thinking": "opaque synthetic context", "tool_calls": calls]
            let payload: [String: Any] = wire == .ollama ? ["done": true, "message": message] : ["choices": [["finish_reason": "tool_calls", "message": message]]]
            let parsed = try LocalChatToolTransport.parse(JSONSerialization.data(withJSONObject: payload), wire: wire)
            #expect(parsed.calls.map(\.id) == ["first", "second"])
            #expect(parsed.text.isEmpty)
            let output = try #require(JSONSerialization.jsonObject(with: parsed.outputItems) as? [[String: Any]])
            let items = initial + output + parsed.calls.map { ["type": "function_call_output", "call_id": $0.id, "output": "synthetic result \($0.id)"] }
            let caps = LocalChatCapabilities(wire: wire, provider: c.meetingSummaryBackend, model: "synthetic-model", endpoint: try LocalChatToolTransport.endpoint(c), nativeTools: true, contextTokens: nil, template: URLRequest(url: try LocalChatToolTransport.endpoint(c)), configuration: c)
            let body = try LocalChatToolTransport.body(request(c, items: items, tools: false), capabilities: caps)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages[2]["thinking"] as? String == "opaque synthetic context")
            #expect(messages[3][wire == .ollama ? "tool_name" : "tool_call_id"] as? String == (wire == .ollama ? "inspect_document" : "first"))
            #expect(body["tools"] == nil)
            if wire == .openAI { #expect(body["tool_choice"] as? String == "none") }
            #expect(throws: MeetingChatHarnessError.self) { try LocalChatToolTransport.body(request(c, items: initial + output), capabilities: caps) }
        }
    }

    @Test func ollamaMissingIDsAreAssignedOnceAndInvalidOutputsAreRejected() throws {
        let call: [String: Any] = ["function": ["name": "inspect_document", "arguments": ["document_id": "doc"]]]
        let parsed = try LocalChatToolTransport.parse(JSONSerialization.data(withJSONObject: ["done": true, "message": ["role": "assistant", "tool_calls": [call]]]), wire: .ollama)
        #expect(!parsed.calls[0].id.isEmpty)
        let output = try #require(JSONSerialization.jsonObject(with: parsed.outputItems) as? [[String: Any]])
        #expect(output[0]["call_ids"] as? [String] == [parsed.calls[0].id])
        for message in [
            ["role": "assistant", "tool_calls": [["id": "same", "function": ["name": "inspect_document", "arguments": "{}"]], ["id": "same", "function": ["name": "inspect_document", "arguments": "{}"]]]],
            ["role": "assistant", "tool_calls": [["id": "id", "function": ["name": "inspect_document", "arguments": "[]"]]]],
            ["role": "assistant", "tool_calls": [["id": "id", "function": ["name": "inspect_document", "arguments": String(repeating: "x", count: 20_000)]]]]
        ] as [[String: Any]] {
            #expect(throws: (any Error).self) { try LocalChatToolTransport.parse(JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "tool_calls", "message": message]]]), wire: .openAI) }
        }
        #expect(throws: MeetingNativeToolTransportError.self) { try LocalChatToolTransport.parse(JSONSerialization.data(withJSONObject: ["done": true, "done_reason": "length", "message": ["role": "assistant", "content": "partial"]]), wire: .ollama) }
        #expect(throws: MeetingNativeToolTransportError.self) { try LocalChatToolTransport.parse(JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["role": "assistant", "content": "partial"]]]]), wire: .openAI) }
    }

    @Test @MainActor func allLocalAdaptersUseScopedNativeDocumentLoopWithoutCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-tools-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.md"); try Data("Verification phrase: silver badger.".utf8).write(to: url)
        let files = try ChatFileReader.references(urls: [url], existing: [])
        for backend in ["ollama", "lmstudio", "custom_llm"] {
            let fixture = LocalToolFixture(wire: backend == "ollama" ? .ollama : .openAI, metadata: true)
            var client = MeetingTextGenerationClient(); client.load = { try await fixture.load($0) }
            client.credentialResolver = { _ in "" }; client.localChatProbeCache = LocalChatProbeCache()
            let reader = ChatDocumentTools(files: files, supportsVision: false)
            let evidence = MeetingChatEvidence(scope: .init(selection: .meetings([])), passages: [], dependencies: [], coverage: .init(eligibleMeetingCount: 0, evidenceMeetingCount: 0, isPartialRecap: false))
            let (answer, _) = try await MeetingChatClient.run(question: "Read the synthetic file.", evidence: evidence, history: [], config: config(backend), sessionID: UUID(), generator: client, execute: { call, current in
                guard case .document(let document) = call else { Issue.record("Escaped document scope"); return .init(evidence: current) }
                return .init(evidence: current, documentOutput: try await reader.execute(document).output)
            }, activity: { _, _ in }, attachments: .init(context: try ChatDocumentTools.manifest(files), documents: files))
            #expect(answer.markdown == "silver badger")
            #expect(await fixture.nativeCalls == 2)
            #expect(await fixture.sawToolResult)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["synthetic.md"])
    }

    @Test func nativeFailuresAndFinalOnlyCallsNeverDowngrade() async throws {
        let c = config(); var client = MeetingTextGenerationClient()
        client.localChatCapabilities = .init(wire: .ollama, provider: c.meetingSummaryBackend, model: "synthetic-model", endpoint: try LocalChatToolTransport.endpoint(c), nativeTools: true, contextTokens: nil, template: URLRequest(url: try LocalChatToolTransport.endpoint(c)), configuration: c)
        client.load = { req in try response(req, ["error": "tools unavailable"], status: 500) }
        await #expect(throws: MeetingTextGenerationError.self) { try await client.generateNative(request(c, items: initial)) }
        client.load = { req in try response(req, ["done": true, "message": ["role": "assistant", "tool_calls": [["function": ["name": "inspect_document", "arguments": [:]]]]]]) }
        await #expect(throws: MeetingChatHarnessError.self) { try await client.generateNative(request(c, items: initial, tools: false)) }
        var switched = c; switched.ollamaURL = "http://localhost:4444"
        #expect(!client.supportsNativeTools(config: switched))
        switched = config("custom_llm"); switched.customLLMFormat = CustomLLMFormat.anthropic.rawValue
        #expect(!LocalChatToolTransport.supportsProvider(switched))
    }
}

private actor LocalToolFixture {
    let wire: LocalChatCapabilities.Wire
    let metadata: Bool?
    private(set) var probes = 0
    private(set) var metadataRequests = 0
    private(set) var nativeCalls = 0
    private(set) var sawToolResult = false
    private(set) var requests: [URLRequest] = []
    init(wire: LocalChatCapabilities.Wire, metadata: Bool?) { self.wire = wire; self.metadata = metadata }
    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var object: [String: Any]
        if request.httpMethod == "GET" || request.url!.path.hasSuffix("/api/show") {
            metadataRequests += 1
            if wire == .ollama { object = ["capabilities": metadata == true ? ["completion", "tools"] : ["completion"], "parameters": "num_ctx 32768"] }
            else { object = [request.url!.path.contains("/api/v1/") ? "models" : "data": [["id": "synthetic-model", "key": "synthetic-model", "capabilities": metadata.map { ["trained_for_tool_use": $0] } ?? [:]]]] }
        } else {
            let messages = body["messages"] as? [[String: Any]] ?? []
            let tools = body["tools"] as? [[String: Any]] ?? []
            var message: [String: Any] = ["role": "assistant", "content": ""]
            if (tools.first?["function"] as? [String: Any])?["name"] as? String == "muesli_capability_probe" {
                probes += 1
                let fn = tools[0]["function"] as! [String: Any]; let schema = fn["parameters"] as! [String: Any]
                let props = schema["properties"] as! [String: [String: Any]]; let token = (props["token"]!["enum"] as! [String])[0]
                message["tool_calls"] = [["id": "probe-id", "type": "function", "function": ["name": "muesli_capability_probe", "arguments": wire == .ollama ? ["token": token] as Any : "{\"token\":\"\(token)\"}"]]]
            } else {
                nativeCalls += 1
                #expect(!tools.isEmpty)
                if nativeCalls == 1 {
                    let user = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
                    let range = try #require(user.range(of: "[a-f0-9]{64}", options: .regularExpression))
                    let id = String(user[range]); let args: [String: Any] = ["document_id": id, "page": 1, "offset": 0, "end_page": NSNull()]
                    message["tool_calls"] = [["id": "read-id", "type": "function", "function": ["name": "read_document", "arguments": wire == .ollama ? args as Any : String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]]
                } else {
                    sawToolResult = messages.contains { $0["role"] as? String == "tool" && ($0["content"] as? String)?.contains("silver badger") == true }
                    message["content"] = #"{"status":"conversation","markdown":"silver badger"}"#
                }
            }
            object = wire == .ollama ? ["done": true, "done_reason": "stop", "message": message] : ["choices": [["finish_reason": message["tool_calls"] == nil ? "stop" : "tool_calls", "message": message]]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

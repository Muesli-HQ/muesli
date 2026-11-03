import Foundation
import MuesliCore
import MLXLMCommon

extension Gemma4LiteRTModel {
    var nativeChatModelID: String { GemmaNativeAudioModels.descriptor(for: self).repoID }
}

struct GemmaChatCapabilities: Sendable, Equatable {
    let model: Gemma4LiteRTModel
    let contextTokens: Int
    let nativeTools: Bool

    /// Called off the main actor, once per captured request. Never infer support
    /// from a model name alone or probe files from a view's availability closure.
    static func detect(modelID: String, directory: URL? = nil) throws -> Self {
        guard let model = Gemma4LiteRTModel.generalPurpose.first(where: { $0.nativeChatModelID == modelID }) else { throw GemmaMeetingChatError.unsupportedModel }
        let root = directory ?? GemmaNativeAudioModels.directory(for: model)
        guard directory != nil || GemmaNativeAudioModels.isAvailable(model) else { throw GemmaMeetingChatError.modelMissing }
        func object(_ name: String) throws -> [String: Any] {
            let url = root.appendingPathComponent(name)
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32_768,
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw GemmaMeetingChatError.unsupportedModel }
            return value
        }
        let config = try object("config.json"); let tokens = try object("tokenizer_config.json")
        guard let text = config["text_config"] as? [String: Any],
              config["model_type"] as? String == "gemma4",
              text["model_type"] as? String == "gemma4_text",
              let maximum = text["max_position_embeddings"] as? Int, maximum > 0, maximum <= 1_048_576 else { throw GemmaMeetingChatError.unsupportedModel }
        let supports = tokens["stc_token"] as? String == "<|tool_call>" && tokens["etc_token"] as? String == "<tool_call|>"
            && tokens["str_token"] as? String == "<|tool_response>" && tokens["etr_token"] as? String == "<tool_response|>"
        return .init(model: model, contextTokens: maximum, nativeTools: supports)
    }
}

enum GemmaMeetingChatError: Error, LocalizedError {
    case modelMissing, unsupportedModel, macOSRequired, timedOut
    var errorDescription: String? {
        switch self {
        case .modelMissing: "Download the Gemma 4 model selected for Chat from Models first."
        case .unsupportedModel: "This Gemma checkpoint does not support the native chat runtime. Select a downloaded general-purpose Gemma 4 model."
        case .macOSRequired: "On-device Gemma chat requires macOS 15 or later."
        case .timedOut: "On-device Gemma took too long to respond. Please retry."
        }
    }
}

/// Native Gemma declaration/call/response framing. The answer harness retains
/// call ownership and IDs; the model receives its trained protocol, not JSON
/// tool requests embedded in a user prompt. No transcript/tool payload is saved.
enum GemmaChatCodec {
    static func quoted(_ text: String) -> String {
        // Quoted files can contain literal model protocol tokens. Neutralize the
        // delimiters before tokenization without changing the control frames.
        text.replacingOccurrences(of: "<eos>", with: "<\u{200B}eos>")
            .replacingOccurrences(of: "<bos>", with: "<\u{200B}bos>")
            .replacingOccurrences(of: "<|", with: "<\u{200B}|")
            .replacingOccurrences(of: "|>", with: "|\u{200B}>")
            .replacingOccurrences(of: "<turn|>", with: "<\u{200B}turn|\u{200B}>")
    }
    static func schemas(_ data: Data, forPrompt: Bool = true) throws -> [[String: Any]] {
        guard data.count <= 32_768, let input = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MeetingChatHarnessError.toolProtocol }
        return try input.map { tool in
            guard let name = tool["name"] as? String,
                  name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil,
                  let parameters = tool["parameters"] as? [String: Any] else { throw MeetingChatHarnessError.toolProtocol }
            return ["type": "function", "function": ["name": name, "description": tool["description"] as? String ?? "", "parameters": forPrompt ? nullableSchema(parameters) : parameters]]
        }
    }
    private static func nullableSchema(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            for (key, item) in object { object[key] = nullableSchema(item) }
            if let types = object["type"] as? [String], types.contains("null"), let type = types.first(where: { $0 != "null" }) {
                object["type"] = type; object["nullable"] = true
            }
            return object
        }
        if let array = value as? [Any] { return array.map(nullableSchema) }
        return value
    }
    static func prompt(_ request: MeetingNativeToolRequest) throws -> String {
        guard request.base.images.isEmpty, request.inputItems.count <= ChatFileReader.maximumRequestBytes,
              let input = try JSONSerialization.jsonObject(with: request.inputItems) as? [[String: Any]] else { throw ChatFileError.unsupportedProvider }
        let tools = request.allowTools ? try schemas(request.tools) : []
        var prompt: String
        if tools.isEmpty { prompt = "<bos><|turn>system\n" + quoted(request.base.system) + "<turn|>\n" }
        else {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]), as: UTF8.self)
            let framed = try GemmaToolCalling.prompt(system: quoted(request.base.system), user: "", toolsJSON: json)
            guard let end = framed.range(of: "<|turn>user\n", options: .backwards) else { throw MeetingChatHarnessError.toolProtocol }
            prompt = String(framed[..<end.lowerBound])
        }
        var names: [String: String] = [:]; var waiting = Set<String>(); var modelTurn = false
        for item in input {
            switch item["type"] as? String {
            case "function_call":
                guard let id = item["call_id"] as? String, names[id] == nil,
                      let name = item["name"] as? String,
                      name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil,
                      let arguments = item["arguments"] as? String,
                      let values = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { throw MeetingChatHarnessError.toolProtocol }
                if !modelTurn { prompt += "<|turn>model\n"; modelTurn = true }
                names[id] = name; waiting.insert(id)
                prompt += "<|tool_call>call:" + name + "{" + values.keys.sorted().map { $0 + ":" + GemmaToolCalling.argument(safeValue(values[$0]!)) }.joined(separator: ",") + "}<tool_call|>"
            case "function_call_output":
                guard let id = item["call_id"] as? String, let name = names[id], waiting.remove(id) != nil,
                      let output = item["output"] as? String else { throw MeetingChatHarnessError.toolProtocol }
                prompt += "<|tool_response>response:" + name + "{value:" + GemmaToolCalling.argument(quoted(output)) + "}<tool_response|>"
            case "reasoning": throw MeetingChatHarnessError.toolProtocol // Opaque cloud state cannot enter a local attempt.
            default:
                guard waiting.isEmpty, item["role"] as? String == "user", let blocks = item["content"] as? [[String: Any]],
                      blocks.allSatisfy({ $0["type"] as? String == "input_text" }) else { throw MeetingChatHarnessError.toolProtocol }
                if modelTurn { prompt += "<turn|>\n" }
                prompt += "<|turn>user\n" + quoted(blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")) + "<turn|>\n"
                modelTurn = false
            }
        }
        guard waiting.isEmpty else { throw MeetingChatHarnessError.toolProtocol }
        if !modelTurn { prompt += "<|turn>model\n" }
        return prompt
    }
    private static func safeValue(_ value: Any) -> Any {
        if let text = value as? String { return quoted(text) }
        if let map = value as? [String: Any] { return map.mapValues(safeValue) }
        if let array = value as? [Any] { return array.map(safeValue) }
        return value
    }
    /// Equivalent to the hosted native JSON answer schema, alongside native tool
    /// frames. In particular, document-only answers cannot claim meeting evidence.
    static func grammar(_ request: MeetingNativeToolRequest) throws -> String {
        let valid = Set(["conversation", "answered", "insufficient_evidence"])
        guard !request.allowedAnswerStatuses.isEmpty, Set(request.allowedAnswerStatuses).isSubset(of: valid) else { throw MeetingChatHarnessError.toolProtocol }
        func literal(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        let statuses = try request.allowedAnswerStatuses.map { try literal("\"" + $0 + "\"") }.joined(separator: " | ")
        let final = try "final ::= " + literal("{\"status\":") + " (" + statuses + ") " + literal(",\"markdown\":") + " jsonstr " + literal("}")
        let string = #"jsonstr ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\"""#
        if !request.allowTools {
            return "root ::= final\n" + final + "\n" + string
        }
        let tools = try schemas(request.tools)
        if tools.isEmpty { return "root ::= final\n" + final + "\n" + string }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: tools), as: UTF8.self)
        let native = try GemmaToolGrammar.make(toolsJSON: json)
        return native.replacingOccurrences(of: "root ::=", with: "root ::= final |") + "\n" + final + "\n" + string
    }

    static func response(text: String, calls: [ToolCall], allowTools: Bool) throws -> MeetingNativeToolResponse {
        guard text.utf8.count <= 64_000, calls.count <= MeetingChatNativeHarness.maximumToolCalls,
              allowTools || calls.isEmpty else { throw MeetingChatHarnessError.toolProtocol }
        var output: [[String: Any]] = []; var normalized: [MeetingNativeToolCall] = []
        for call in calls {
            let id = call.id ?? UUID().uuidString
            let arguments = String(decoding: try JSONEncoder().encode(call.function.arguments), as: UTF8.self)
            guard arguments.utf8.count <= 4_096 else { throw MeetingChatHarnessError.toolProtocol }
            normalized.append(.init(id: id, name: call.function.name, arguments: arguments))
            output.append(["type": "function_call", "call_id": id, "name": call.function.name, "arguments": arguments])
        }
        return .init(outputItems: try JSONSerialization.data(withJSONObject: output), calls: normalized, text: text)
    }
}

import Foundation
import CoreFoundation

/// Swift rendering of the pinned Gemma 4 function-declaration format. No template engine.
enum GemmaToolCalling {
    static let quote = "<|\"|>"
    static func argument(_ value: Any) -> String {
        if let value = value as? String { return quote + value + quote }
        if value is NSNull { return "null" }
        if let value = value as? [String: Any] { return "{" + value.keys.sorted().map { argument($0) + ":" + argument(value[$0]!) }.joined(separator: ",") + "}" }
        if let value = value as? [Any] { return "[" + value.map(argument).joined(separator: ",") + "]" }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return value.stringValue
        }
        return "null"
    }
    static func properties(_ properties: [String: Any]) -> String {
        properties.keys.sorted().map { key in
            let value = properties[key] as? [String: Any] ?? [:]
            let type = (value["type"] as? String ?? "").uppercased()
            var fields: [String] = []
            if let description = value["description"] as? String, !description.isEmpty { fields.append("description:" + argument(description)) }
            if type == "STRING", let choices = value["enum"] as? [Any], !choices.isEmpty { fields.append("enum:" + argument(choices)) }
            if type == "ARRAY", let items = value["items"] as? [String: Any], !items.isEmpty {
                fields.append("items:{" + items.keys.sorted().compactMap { key -> String? in
                    guard let item = items[key], !(item is NSNull) else { return nil }
                    if key == "properties" { return "properties:{" + self.properties(item as? [String: Any] ?? [:]) + "}" }
                    if key == "type", let type = item as? String { return "type:" + argument(type.uppercased()) }
                    return key + ":" + argument(item)
                }.joined(separator: ",") + "}")
            }
            if value["nullable"] as? Bool == true { fields.append("nullable:true") }
            if type == "OBJECT" {
                let nested = value["properties"] as? [String: Any] ?? value.filter { !["description", "type", "properties", "required", "nullable"].contains($0.key) }
                fields.append("properties:{" + self.properties(nested) + "}")
                if let required = value["required"] as? [String], !required.isEmpty { fields.append("required:" + argument(required)) }
            }
            fields.append("type:" + argument(type))
            return key + ":{" + fields.joined(separator: ",") + "}"
        }.joined(separator: ",")
    }
    static func prompt(system: String, user: String, toolsJSON: String) throws -> String {
        let tools = try tools(toolsJSON)
        let declarations = try tools.map { tool -> String in
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else { throw invalid() }
            var body = "declaration:" + name + "{description:" + argument(function["description"] as? String ?? "")
            if let parameters = function["parameters"] as? [String: Any], !parameters.isEmpty {
                var fields: [String] = []
                if let props = parameters["properties"] as? [String: Any], !props.isEmpty { fields.append("properties:{" + properties(props) + "}") }
                if let required = parameters["required"] as? [String], !required.isEmpty { fields.append("required:" + argument(required)) }
                if let type = parameters["type"] as? String { fields.append("type:" + argument(type.uppercased())) }
                body += ",parameters:{" + fields.joined(separator: ",") + "}"
            }
            return "<|tool>" + body + "}<tool|>"
        }.joined()
        return "<bos><|turn>system\n" + system.trimmingCharacters(in: .whitespacesAndNewlines) + declarations
            + "<turn|>\n<|turn>user\n" + user.trimmingCharacters(in: .whitespacesAndNewlines) + "<turn|>\n<|turn>model\n"
    }
    static func tools(_ json: String) throws -> [[String: Any]] {
        guard let tools = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]], !tools.isEmpty else { throw invalid() }
        return tools
    }
    static func invalid() -> ComputerUsePlannerError { .invalidResponse("Invalid or incomplete native Gemma tool call. Nothing was executed.") }
    static func response(_ raw: String) throws -> String {
        var parser = GemmaToolValueParser(raw)
        try parser.consume("<|tool_call>call:")
        let name = try parser.identifier()
        let arguments = try parser.object()
        try parser.consume("<tool_call|>")
        guard parser.isAtEnd else { throw invalid() }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": [["type": "function", "function": ["name": name, "arguments": arguments]]]], options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Constrain the native Gemma dialect, including tool names and argument schemas.
/// The existing planner validates the normalized result again before execution.
struct GemmaToolGrammar {
    private var rules: [String] = [
        #"str ::= "<|\"|>" ([^<] | "<" [^|] | "<|" [^\"] | "<|\"" [^|] | "<|\"|" [^>])* "<|\"|>""#,
        #"number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?"#,
        #"integer ::= "-"? ("0" | [1-9] [0-9]*)"#
    ]
    private var next = 0
    private static func literal(_ value: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private mutating func rule(_ body: String) -> String {
        let name = "r\(next)"; next += 1
        rules.append(name + " ::= " + body)
        return name
    }
    private mutating func schema(_ value: [String: Any], depth: Int = 0) throws -> String {
        guard depth < 20 else { throw GemmaToolCalling.invalid() }
        if let options = value["anyOf"] as? [[String: Any]] {
            let branches = try options.map { option -> String in
                var merged = value
                merged.removeValue(forKey: "anyOf")
                for (key, item) in option { merged[key] = item }
                merged["required"] = Array(Set((value["required"] as? [String] ?? []) + (option["required"] as? [String] ?? []))).sorted()
                return try schema(merged, depth: depth + 1)
            }
            return rule(branches.joined(separator: " | "))
        }
        if let choices = value["enum"] as? [String], !choices.isEmpty {
            return rule(try choices.map { try Self.literal(GemmaToolCalling.argument($0)) }.joined(separator: " | "))
        }
        switch value["type"] as? String ?? (value["required"] != nil ? "object" : "") {
        case "string": return "str"
        case "boolean": return #"("true" | "false")"#
        case "integer": return "integer"
        case "number": return "number"
        case "array":
            guard let items = value["items"] as? [String: Any] else { throw GemmaToolCalling.invalid() }
            let item = try schema(items, depth: depth + 1)
            let minimum = value["minItems"] as? Int ?? 0
            if let maximum = value["maxItems"] as? Int {
                guard minimum >= 0, maximum >= minimum, maximum <= 100 else { throw GemmaToolCalling.invalid() }
                let variants = try (minimum...maximum).map { count in
                    try Self.literal("[") + " " + Array(repeating: item, count: count).joined(separator: " " + Self.literal(",") + " ") + " " + Self.literal("]")
                }
                return rule(variants.joined(separator: " | "))
            }
            guard minimum >= 0, minimum <= 100 else { throw GemmaToolCalling.invalid() }
            if minimum > 0 {
                return rule(try Self.literal("[") + " " + Array(repeating: item, count: minimum).joined(separator: " " + Self.literal(",") + " ") + #" ("," "# + item + #")* "]""#)
            }
            return rule(#""[" ("# + item + #" ("," "# + item + #")*)? "]""#)
        case "object":
            let properties = value["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(value["required"] as? [String] ?? [])
            guard required.isSubset(of: Set(properties.keys)) else { throw GemmaToolCalling.invalid() }
            // Two states per field preserve comma placement when optional fields are absent.
            var empty = try Self.literal("")
            var nonempty = try Self.literal("")
            for key in properties.keys.sorted().reversed() {
                let field = try Self.literal(key + ":") + " " + (try schema(properties[key]!, depth: depth + 1))
                let oldEmpty = empty, oldNonempty = nonempty
                empty = rule(field + " " + oldNonempty + (required.contains(key) ? "" : " | " + oldEmpty))
                nonempty = rule(try Self.literal(",") + " " + field + " " + oldNonempty + (required.contains(key) ? "" : " | " + oldNonempty))
            }
            return rule(try Self.literal("{") + " " + empty + " " + Self.literal("}"))
        default: throw GemmaToolCalling.invalid()
        }
    }
    static func make(toolsJSON: String) throws -> String {
        var builder = Self()
        var choices: [String] = []
        for tool in try GemmaToolCalling.tools(toolsJSON) {
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String,
                  name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                  let parameters = function["parameters"] as? [String: Any] else { throw GemmaToolCalling.invalid() }
            choices.append(try literal("<|tool_call>call:" + name) + " " + (try builder.schema(parameters)) + " " + literal("<tool_call|>"))
        }
        builder.rules.append("root ::= " + choices.joined(separator: " | "))
        return builder.rules.joined(separator: "\n")
    }
}

/// Strict native-dialect parser: preserve scalar types; never coerce a quoted value
/// to a number/bool based on schema, or silently discard malformed fields.
private struct GemmaToolValueParser {
    private var rest: Substring
    init(_ raw: String) { rest = raw[...] }
    var isAtEnd: Bool { rest.isEmpty }
    mutating func consume(_ literal: String) throws {
        guard rest.hasPrefix(literal) else { throw GemmaToolCalling.invalid() }
        rest = rest.dropFirst(literal.count)
    }
    mutating func identifier() throws -> String {
        let name = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        guard let first = name.first, first.isLetter || first == "_" else { throw GemmaToolCalling.invalid() }
        rest = rest.dropFirst(name.count)
        return String(name)
    }
    mutating func object(depth: Int = 0) throws -> [String: Any] {
        guard depth < 20 else { throw GemmaToolCalling.invalid() }
        try consume("{")
        var result: [String: Any] = [:]
        if rest.hasPrefix("}") { try consume("}"); return result }
        while true {
            let key = try identifier()
            guard result[key] == nil else { throw GemmaToolCalling.invalid() }
            try consume(":")
            result[key] = try value(depth: depth + 1)
            if rest.hasPrefix("}") { try consume("}"); return result }
            try consume(",")
        }
    }
    private mutating func value(depth: Int) throws -> Any {
        guard depth < 20 else { throw GemmaToolCalling.invalid() }
        if rest.hasPrefix(GemmaToolCalling.quote) {
            try consume(GemmaToolCalling.quote)
            guard let end = rest.range(of: GemmaToolCalling.quote) else { throw GemmaToolCalling.invalid() }
            let result = String(rest[..<end.lowerBound]); rest = rest[end.upperBound...]
            return result
        }
        if rest.hasPrefix("{") { return try object(depth: depth) }
        if rest.hasPrefix("[") {
            try consume("[")
            var result: [Any] = []
            if rest.hasPrefix("]") { try consume("]"); return result }
            while true {
                result.append(try value(depth: depth + 1))
                if rest.hasPrefix("]") { try consume("]"); return result }
                try consume(",")
            }
        }
        let literal = rest.prefix { $0 != "," && $0 != "}" && $0 != "]" }
        guard !literal.isEmpty else { throw GemmaToolCalling.invalid() }
        let result = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed])
        guard result is NSNumber || result is NSNull else { throw GemmaToolCalling.invalid() }
        rest = rest.dropFirst(literal.count)
        return result
    }
}

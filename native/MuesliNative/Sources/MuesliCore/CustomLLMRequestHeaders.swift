import Foundation

public struct CustomLLMRequestHeader: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var value: String

    public init(id: String = UUID().uuidString, name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case value
    }
}

public enum CustomLLMRequestHeaderError: LocalizedError, Equatable {
    case tooManyHeaders(maximum: Int)
    case missingName
    case invalidName(String)
    case reservedName(String)
    case duplicateName(String)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case let .tooManyHeaders(maximum):
            return "Custom LLM supports at most \(maximum) additional headers."
        case .missingName:
            return "Enter a name for each Custom LLM header."
        case let .invalidName(name):
            return "\(name) is not a valid HTTP header name."
        case let .reservedName(name):
            return "\(name) is managed by Muesli and cannot be overridden."
        case let .duplicateName(name):
            return "\(name) is configured more than once."
        case let .invalidValue(name):
            return "\(name) contains an invalid header value."
        }
    }
}

public enum CustomLLMRequestHeaders {
    public static let maximumCount = 20

    private static let reservedNames: Set<String> = [
        "authorization",
        "connection",
        "content-length",
        "content-type",
        "host",
        "proxy-authorization",
        "te",
        "transfer-encoding",
        "upgrade",
        "x-api-key",
        "anthropic-version",
    ]

    public static func apply(_ headers: [CustomLLMRequestHeader], to request: inout URLRequest) throws {
        for (name, value) in try validated(headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    public static func validated(_ headers: [CustomLLMRequestHeader]) throws -> [String: String] {
        let configured = headers.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.value.isEmpty
        }
        guard configured.count <= maximumCount else {
            throw CustomLLMRequestHeaderError.tooManyHeaders(maximum: maximumCount)
        }

        var result: [String: String] = [:]
        var normalizedNames = Set<String>()
        for header in configured {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw CustomLLMRequestHeaderError.missingName
            }
            guard isValidHeaderName(name) else {
                throw CustomLLMRequestHeaderError.invalidName(name)
            }

            let normalizedName = name.lowercased()
            guard !reservedNames.contains(normalizedName) else {
                throw CustomLLMRequestHeaderError.reservedName(name)
            }
            guard normalizedNames.insert(normalizedName).inserted else {
                throw CustomLLMRequestHeaderError.duplicateName(name)
            }
            let containsInvalidControl = header.value.unicodeScalars.contains {
                ($0.value < 32 && $0.value != 9) || $0.value == 127
            }
            guard !containsInvalidControl else {
                throw CustomLLMRequestHeaderError.invalidValue(name)
            }
            result[name] = header.value
        }
        return result
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        let punctuation = Set("!#$%&'*+-.^_`|~".unicodeScalars.map(\.value))
        return !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || punctuation.contains(value)
        }
    }
}

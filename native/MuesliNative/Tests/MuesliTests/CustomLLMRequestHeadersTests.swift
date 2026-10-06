import Foundation
import Testing
import MuesliCore

@Suite("Custom LLM request headers")
struct CustomLLMRequestHeadersTests {
    @Test("valid headers are applied to a request")
    func appliesHeaders() throws {
        let url = try #require(URL(string: "https://example.com"))
        var request = URLRequest(url: url)
        try CustomLLMRequestHeaders.apply([
            CustomLLMRequestHeader(name: "source", value: "muesli"),
            CustomLLMRequestHeader(name: "org-id", value: "2"),
        ], to: &request)

        #expect(request.value(forHTTPHeaderField: "source") == "muesli")
        #expect(request.value(forHTTPHeaderField: "org-id") == "2")
    }

    @Test("empty placeholder rows are ignored")
    func ignoresEmptyRows() throws {
        let headers = try CustomLLMRequestHeaders.validated([CustomLLMRequestHeader()])
        #expect(headers.isEmpty)
    }

    @Test("reserved headers cannot be overridden", arguments: [
        "Authorization", "Content-Type", "Host", "x-api-key", "anthropic-version",
    ])
    func rejectsReservedHeaders(name: String) {
        #expect(throws: CustomLLMRequestHeaderError.reservedName(name)) {
            try CustomLLMRequestHeaders.validated([
                CustomLLMRequestHeader(name: name, value: "value"),
            ])
        }
    }

    @Test("invalid header names are rejected")
    func rejectsInvalidName() {
        #expect(throws: CustomLLMRequestHeaderError.invalidName("bad header")) {
            try CustomLLMRequestHeaders.validated([
                CustomLLMRequestHeader(name: "bad header", value: "value"),
            ])
        }
    }

    @Test("duplicate names are rejected case-insensitively")
    func rejectsDuplicateNames() {
        #expect(throws: CustomLLMRequestHeaderError.duplicateName("SOURCE")) {
            try CustomLLMRequestHeaders.validated([
                CustomLLMRequestHeader(name: "source", value: "one"),
                CustomLLMRequestHeader(name: "SOURCE", value: "two"),
            ])
        }
    }

    @Test("invalid control characters in values are rejected", arguments: [
        "safe\r\ninjected: true",
        "value\u{0001}",
        "value\u{000B}",
        "value\u{000C}",
        "value\u{007F}",
    ])
    func rejectsHeaderInjection(value: String) {
        #expect(throws: CustomLLMRequestHeaderError.invalidValue("source")) {
            try CustomLLMRequestHeaders.validated([
                CustomLLMRequestHeader(name: "source", value: value),
            ])
        }
    }

    @Test("headers decode without persisted UI identifiers")
    func decodesWithoutID() throws {
        let data = Data(#"{"name":"source","value":"muesli"}"#.utf8)
        let header = try JSONDecoder().decode(CustomLLMRequestHeader.self, from: data)
        #expect(!header.id.isEmpty)
        #expect(header.name == "source")
        #expect(header.value == "muesli")

        let encoded = try JSONEncoder().encode(header)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["id"] == nil)
        #expect(json["name"] as? String == "source")
    }

    @Test("header count is bounded")
    func rejectsTooManyHeaders() {
        let headers = (0...CustomLLMRequestHeaders.maximumCount).map {
            CustomLLMRequestHeader(name: "x-header-\($0)", value: "value")
        }
        #expect(throws: CustomLLMRequestHeaderError.tooManyHeaders(maximum: CustomLLMRequestHeaders.maximumCount)) {
            try CustomLLMRequestHeaders.validated(headers)
        }
    }
}

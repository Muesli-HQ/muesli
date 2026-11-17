import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Telemetry privacy")
struct TelemetryPrivacyTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "muesli-telemetry-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func batch(_ payloads: [[String: String]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payloads.map { ["type": "synthetic", "payload": $0] })
    }

    @Test func numericWordBatchPreservedOnlyInOriginalConsentGeneration() throws {
        try withDefaults { defaults in
            let gate = TelemetryPrivacyGate(defaults: defaults, configured: true)
            let data = try JSONSerialization.data(withJSONObject: [[
                "type": "dictation.words_baseline", "floatValue": 42000,
                "payload": gate.parameters
            ] as [String: Any]])
            let clean = try #require(gate.filter(data))
            let rows = try #require(JSONSerialization.jsonObject(with: clean) as? [[String: Any]])
            #expect(rows.first?["floatValue"] as? Int == 42000)
            #expect(!String(decoding: clean, as: UTF8.self).contains(TelemetryPrivacyGate.localMarker))
            gate.setDisabled(true)
            gate.setDisabled(false)
            #expect(gate.filter(data) == nil)
        }
    }

    @Test func defaultOffAndMarkerNeverLeavesTransport() throws {
        try withDefaults { defaults throws in
            let gate = TelemetryPrivacyGate(defaults: defaults, configured: true)
            #expect(!gate.isDisabled)
            let clean = try #require(gate.filter(batch([gate.parameters])))
            #expect(!String(decoding: clean, as: UTF8.self).contains(TelemetryPrivacyGate.localMarker))
            #expect(gate.filter(try batch([[:]])) != nil) // pre-upgrade backlog
        }
    }

    @Test func disablesImmediatelyAndPersistsAcrossLaunches() throws {
        try withDefaults { defaults throws in
            let gate = TelemetryPrivacyGate(defaults: defaults, configured: true)
            let before = try batch([gate.parameters])
            gate.setDisabled(true)
            #expect(gate.filter(before) == nil)
            #expect(gate.filter(try batch([gate.parameters])) == nil)
            let relaunched = TelemetryPrivacyGate(defaults: defaults, configured: true)
            #expect(relaunched.isDisabled)
            #expect(relaunched.filter(before) == nil)
        }
    }

    @Test func reenablingNeverReplaysSuppressedOrOldEvents() throws {
        try withDefaults { defaults throws in
            let gate = TelemetryPrivacyGate(defaults: defaults, configured: true)
            let initialToken = try #require(gate.bestEffortConsentToken)
            let before = gate.parameters
            gate.setDisabled(true)
            #expect(gate.bestEffortConsentToken == nil)
            let during = gate.parameters
            gate.setDisabled(false)
            let newToken = try #require(gate.bestEffortConsentToken)
            #expect(newToken != initialToken)
            #expect(gate.filter(try batch([before, during, [:]])) == nil)
            let mixed = try #require(gate.filter(batch([before, during, gate.parameters])))
            let signals = try #require(JSONSerialization.jsonObject(with: mixed) as? [[String: Any]])
            #expect(signals.count == 1)
            let relaunched = TelemetryPrivacyGate(defaults: defaults, configured: true)
            #expect(!relaunched.isDisabled)
            #expect(relaunched.filter(try batch([before, during, [:]])) == nil)
            #expect(relaunched.filter(try batch([relaunched.parameters])) != nil)
        }
    }

    @Test func optedOutActivityCannotLeakThroughSDKCumulativeMetrics() throws {
        try withDefaults { defaults throws in
            let gate = TelemetryPrivacyGate(defaults: defaults, configured: true)
            gate.setDisabled(true)
            gate.setDisabled(false)
            var payload = gate.parameters
            payload["TelemetryDeck.Retention.totalSessionsCount"] = "123"
            payload["TelemetryDeck.Acquisition.firstSessionDate"] = "2026-01-01"
            payload["muesli.channel"] = "dev"
            let clean = try #require(gate.filter(batch([payload])))
            let text = String(decoding: clean, as: UTF8.self)
            #expect(!text.contains("Retention"))
            #expect(!text.contains("firstSessionDate"))
            #expect(text.contains("muesli.channel"))
        }
    }

    @Test func failsClosedForUnconfiguredBuildsAndMalformedBatches() throws {
        try withDefaults { defaults throws in
            let gate = TelemetryPrivacyGate(defaults: defaults, configured: false)
            #expect(gate.bestEffortConsentToken == nil)
            gate.setDisabled(false)
            #expect(gate.filter(try batch([gate.parameters])) == nil)
            let enabled = TelemetryPrivacyGate(defaults: defaults, configured: true)
            #expect(enabled.filter(nil) == nil)
            #expect(enabled.filter(Data("bad json".utf8)) == nil)
            #expect(enabled.filter(Data("[{\"payload\":{\"unexpected\":3}}]".utf8)) == nil)
        }
    }

    @Test func consentedTransportStripsLocalMarker() async throws {
        let name = "muesli-telemetry-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = TelemetryPrivacyGate(defaults: defaults, configured: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryEchoProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://invalid.example/v2/")!)
        request.httpMethod = "POST"
        request.httpBody = try batch([gate.parameters.merging(["safe": "value"]) { _, new in new }])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let task = gate.send(request, session: session) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
            if task == nil { continuation.resume(throwing: URLError(.cancelled)) }
        }
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("safe"))
        #expect(!text.contains(TelemetryPrivacyGate.localMarker))
    }

    @Test func dedicatedSDKSessionDropsWithoutNetwork() async throws {
        // Test bundles are deliberately unconfigured. Exercise URLProtocol itself,
        // including Foundation's conversion from httpBody to httpBodyStream.
        #expect(!TelemetryRuntimeConfiguration.current().isEnabled)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryPrivacyProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://invalid.example/v2/")!)
        request.httpMethod = "POST"
        request.httpBody = try batch([["synthetic": "true"]])
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.isEmpty)
    }

    @Test func disablingDoesNotStartTransport() throws {
        try withDefaults { defaults throws in
            let gate = TelemetryPrivacyGate(defaults: defaults, configured: true)
            var request = URLRequest(url: URL(string: "https://invalid.example")!)
            request.httpBody = try batch([gate.parameters])
            gate.setDisabled(true)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            #expect(gate.send(request, session: session) { _, _, _ in
                Issue.record("Suppressed requests must never enter URLSession")
            } == nil)
        }
    }
}

/// Echoes synthetic requests entirely in-process; never opens a socket.
private final class TelemetryEchoProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Chatwoot call detection origins")
struct ChatwootCallDetectionOriginTests {
    @Test func canonicalizesCustomOriginsWithoutLosingPortOrScheme() {
        let pairs = [
            ("https://chatwoot.selfhosted.com/support/app?token=synthetic#call", "https://chatwoot.selfhosted.com:443"),
            ("HTTPS://CHATWOOT.SELFHOSTED.COM:8443/base/app", "https://chatwoot.selfhosted.com:8443"),
            ("http://localhost:8080/base", "http://localhost:8080"),
            ("http://localhost/base", "http://localhost:80"),
            ("https://127.0.0.1:8443/base", "https://127.0.0.1:8443"),
            ("http://0.0.0.0/base", "http://0.0.0.0:80"),
            ("https://255.255.255.255/base", "https://255.255.255.255:443"),
            ("https://0xservice.example.test/base", "https://0xservice.example.test:443"),
            ("https://[::1]:8443/base", "https://[::1]:8443")
        ]
        for (input, expected) in pairs {
            #expect(ChatwootCallDetectionOrigin.canonical(input) == expected)
        }
    }

    @Test func rejectsCredentialsMalformedAuthorityAndSchemes() {
        for input in ["https://user@chatwoot.selfhosted.com", "https://user:secret@chatwoot.selfhosted.com",
                      "https://chatwoot.selfhosted.com:0", "https://chatwoot.selfhosted.com:65536",
                      "https://chatwoot.selfhosted.com:bad", "https://chatwoot.selfhosted.com:",
                      "https://", "file:///app", "javascript:call()", "https://a.test/ bad",
                      "https://a.test/\\path", "https://a.test/%ZZ", "https://a.test/%", "https://a.test/%1",
                      "https://%61.test/", "https://a.test/\npath", "https://a.test./app",
                      "https://0x7f000001/", "https://0177.0.0.1/", "https://2130706433/",
                      "https://127.1/", "https://127.0.1/", "https://0x7f.0.0.1/",
                      "https://127.0.0.01/", "https://127.0.0.256/", "https://0x/",
                      "https://example.123/"] {
            #expect(ChatwootCallDetectionOrigin.canonical(input) == nil, "\(input)")
        }
    }

    @Test func pathQueryAndFragmentCannotChangeGeneratedOrigin() {
        // Seeded generation with an independent literal origin oracle; no Swift PBT dependency.
        var seed: UInt64 = 0xc411_d0c
        for _ in 0..<512 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let port = 1 + seed % 65535
            let host = "node-\(seed % 100000).example.test"
            let scheme = seed & 1 == 0 ? "https" : "http"
            let expected = "\(scheme)://\(host):\(port)"
            let suffix = "/base/\(seed)/%E2%98%83?synthetic=\(seed)#route-\(seed)"
            #expect(ChatwootCallDetectionOrigin.canonical(expected + suffix) == expected)
        }
    }

    @Test func generatedCredentialAuthoritiesAreAlwaysRejected() {
        var seed: UInt64 = 0xbad_a017
        for _ in 0..<512 {
            seed = seed &* 2862933555777941757 &+ 3037000493
            let user = String(seed, radix: 16)
            let scheme = seed & 1 == 0 ? "https" : "http"
            #expect(ChatwootCallDetectionOrigin.canonical("\(scheme)://\(user)@node-\(seed).test:8443/base") == nil)
        }
    }

    @Test func defaultPortsAreEquivalentButSuffixSpoofsAreDistinct() {
        #expect(ChatwootCallDetectionOrigin.canonical("https://a.test") == "https://a.test:443")
        #expect(ChatwootCallDetectionOrigin.canonical("https://a.test:443/base") == "https://a.test:443")
        #expect(ChatwootCallDetectionOrigin.canonical("https://a.test.evil.test/base") == "https://a.test.evil.test:443")
        #expect(ChatwootCallDetectionOrigin.canonical("https://a.test/" + String(repeating: "x", count: 8192)) == nil)
    }
}

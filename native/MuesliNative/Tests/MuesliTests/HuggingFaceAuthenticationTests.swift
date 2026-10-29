import Foundation
import Testing
import MuesliCore

@Suite("Hugging Face authentication")
struct HuggingFaceAuthenticationTests {
    @Test("Environment credentials precede local sign-in and newlines are refused")
    func environment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(HuggingFaceAuthentication.token(environment: ["HF_TOKEN":"hf_fixture"], homeDirectory: home) == "hf_fixture")
        #expect(HuggingFaceAuthentication.token(environment: ["HF_TOKEN":"hf_fixture\nInjected: value"], homeDirectory: home) == nil)
    }

    @Test("A GUI app can reuse the standard hf auth login credential file without an environment")
    func cachedSignIn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".cache/huggingface/token")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hf_fixture\n".utf8).write(to: file)
        #expect(HuggingFaceAuthentication.token(environment: [:], homeDirectory: home) == "hf_fixture")
        #expect(HuggingFaceAuthentication.token(environment: ["HF_TOKEN":"hf_override"], homeDirectory: home) == "hf_override")
        #expect(HuggingFaceAuthentication.token(environment: ["HF_TOKEN_PATH":home.appendingPathComponent("missing").path], homeDirectory: home) == nil)
    }

    @Test("Tokens are scoped to the exact HTTPS Hugging Face authority")
    func trustedHost() {
        for url in ["http://huggingface.co/a", "https://huggingface.co.evil.test/a", "https://cdn-lfs.hf.co/a", "https://user@huggingface.co/a", "https://huggingface.co:8080/a"] {
            #expect(!HuggingFaceAuthentication.isTrusted(URL(string: url)))
        }
        #expect(HuggingFaceAuthentication.isTrusted(URL(string: "https://huggingface.co/Muesli-HQ/medasr-coreml/resolve/pin/model")))
    }

    @Test("Redirects strip bearer credentials from CDN requests while preserving resumable ranges")
    func redirect() throws {
        let origin = try #require(URL(string: "https://huggingface.co/model/resolve/main/file"))
        var request = URLRequest(url: try #require(URL(string: "https://cdn-lfs.hf.co/signed-file?signature=fixture")))
        request.setValue("Bearer hf_fixture", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=10-", forHTTPHeaderField: "Range")
        let redirected = HuggingFaceAuthentication.redirected(request, from: origin)
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected.value(forHTTPHeaderField: "Range") == "bytes=10-")
        request.url = origin
        #expect(HuggingFaceAuthentication.redirected(request, from: origin).value(forHTTPHeaderField: "Authorization") != nil)
    }
}

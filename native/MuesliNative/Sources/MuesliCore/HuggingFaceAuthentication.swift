import Foundation

/// Reuses standard local Hugging Face credentials; never stores or logs tokens.
public enum HuggingFaceAuthentication {
    public static func token(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN"] {
            if let value = cleaned(environment[key]) { return value }
        }
        let file: URL
        if let path = environment["HF_TOKEN_PATH"], !path.isEmpty {
            file = URL(fileURLWithPath: path)
        } else if let path = environment["HF_HOME"], !path.isEmpty {
            file = URL(fileURLWithPath: path).appendingPathComponent("token")
        } else if let path = environment["XDG_CACHE_HOME"], !path.isEmpty {
            file = URL(fileURLWithPath: path).appendingPathComponent("huggingface/token")
        } else {
            file = homeDirectory.appendingPathComponent(".cache/huggingface/token")
        }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 4096,
              let data = try? Data(contentsOf: file), data.count <= 4096
        else { return nil }
        return cleaned(String(data: data, encoding: .utf8))
    }

    public static func isTrusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "huggingface.co"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    public static func authorize(_ request: inout URLRequest) {
        guard isTrusted(request.url), let token = token() else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Signed CDN URLs authenticate themselves; a Hub token must never follow them.
    public static func redirected(_ request: URLRequest, from originalURL: URL?) -> URLRequest {
        var redirected = request
        if !isTrusted(originalURL) || !isTrusted(request.url) {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return redirected
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let token = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, token.utf8.count <= 4096,
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else { return nil }
        return token
    }
}

final class HuggingFaceRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(HuggingFaceAuthentication.redirected(request, from: response.url))
    }
}

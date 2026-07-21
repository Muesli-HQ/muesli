import Foundation

/// Hardened on-disk storage for the Notion integration token.
///
/// The token is a secret, so it lives in a dedicated JSON file in the app support
/// directory — written atomically with POSIX perms `0o600` and excluded from backups —
/// rather than in the general `config.json`. This mirrors the file-storage hardening
/// `ChatGPTAuthManager` applies to OAuth tokens (see its `saveTokens`/`tokenRead`).
enum NotionCredentialStore {
    private static var fileURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("notion-auth.json")
    }

    /// Reads the stored token, or "" if none/unreadable.
    static func read() -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = dict["token"] else {
            return ""
        }
        return token
    }

    /// Saves the token atomically with `0o600` perms, excluded from backup.
    /// An empty/whitespace-only token deletes the file instead.
    static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return
        }
        let dict: [String: String] = ["token": token]
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var url = fileURL
            try url.setResourceValues(resourceValues)
        } catch {
            fputs("[notion-auth] failed to save token: \(error)\n", stderr)
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// One-time migration: move a legacy plaintext `notion_token` out of `config.json`
    /// into this hardened store, and strip the key from `config.json` so no plaintext
    /// token lingers. No-ops on any parse/IO failure.
    static func migrateFromLegacyConfigIfNeeded(configURL: URL) {
        guard let data = try? Data(contentsOf: configURL),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        // Nothing to migrate/strip if the key is absent.
        guard dict["notion_token"] != nil else { return }

        let legacyToken = (dict["notion_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Only adopt the legacy token if we don't already have one stored.
        if !legacyToken.isEmpty, read().isEmpty {
            save(legacyToken)
        }
        // Strip the plaintext key from config.json regardless.
        dict.removeValue(forKey: "notion_token")
        guard let rewritten = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }
        try? rewritten.write(to: configURL, options: .atomic)
    }
}

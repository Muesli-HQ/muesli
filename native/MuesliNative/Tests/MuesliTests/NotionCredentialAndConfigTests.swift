import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

/// Covers the Notion hardening changes:
///  - `AppConfig` no longer persists the token (schema decode/round-trip).
///  - `NotionCredentialStore` stores the token in a hardened dedicated file and
///    migrates a legacy plaintext `notion_token` out of `config.json`.
///
/// `NotionCredentialStore` targets a fixed support-directory path (shared with the real
/// app), so this suite is `.serialized` and saves/restores any pre-existing credential.
@Suite("Notion credential + config", .serialized)
struct NotionCredentialAndConfigTests {

    // MARK: - AppConfig schema

    @Test("minimal old config with no notion fields decodes to defaults")
    func decodeDefaults() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(config.notionSyncEnabled == false)
        #expect(config.notionDataSourceID == "")
        #expect(config.notionLastSyncedAt == nil)
    }

    @Test("a legacy notion_token key is ignored and does not break decoding")
    func decodeIgnoresLegacyToken() throws {
        let json = Data(#"{"notion_token": "secret_x", "notion_sync_enabled": true}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(config.notionSyncEnabled == true)
        #expect(config.notionDataSourceID == "")
    }

    @Test("round-trip preserves notion sync fields and never encodes a token")
    func roundTripDropsToken() throws {
        var config = AppConfig()
        config.notionSyncEnabled = true
        config.notionDataSourceID = "ds-123"

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.notionSyncEnabled == true)
        #expect(decoded.notionDataSourceID == "ds-123")

        let jsonString = String(decoding: encoded, as: UTF8.self)
        #expect(!jsonString.contains("notion_token"))
    }

    // MARK: - NotionCredentialStore

    @Test("save then read round-trips; empty save deletes; file is 0o600")
    func credentialSaveReadDelete() throws {
        let saved = NotionCredentialStore.read()
        defer {
            // Restore any pre-existing real credential.
            if saved.isEmpty { NotionCredentialStore.delete() } else { NotionCredentialStore.save(saved) }
        }

        NotionCredentialStore.save("ntn_test_token_123")
        #expect(NotionCredentialStore.read() == "ntn_test_token_123")

        // Verify hardened POSIX perms on the on-disk file.
        let fileURL = AppIdentity.supportDirectoryURL.appendingPathComponent("notion-auth.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect(perms.int16Value == 0o600)

        // Empty (whitespace) save deletes the credential.
        NotionCredentialStore.save("   ")
        #expect(NotionCredentialStore.read() == "")
    }

    @Test("migration moves a legacy plaintext token out of config.json")
    func legacyMigration() throws {
        let saved = NotionCredentialStore.read()
        // Start from no stored credential so the migration adopts the legacy token.
        NotionCredentialStore.delete()
        defer {
            if saved.isEmpty { NotionCredentialStore.delete() } else { NotionCredentialStore.save(saved) }
        }

        let tmpConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-config-\(UUID().uuidString).json")
        let original = #"{"notion_token": "secret_legacy", "notion_sync_enabled": true, "sttModel": "parakeet"}"#
        try Data(original.utf8).write(to: tmpConfig)
        defer { try? FileManager.default.removeItem(at: tmpConfig) }

        NotionCredentialStore.migrateFromLegacyConfigIfNeeded(configURL: tmpConfig)

        #expect(NotionCredentialStore.read() == "secret_legacy")

        let rewritten = try String(contentsOf: tmpConfig, encoding: .utf8)
        #expect(!rewritten.contains("notion_token"))
        // Other keys are preserved.
        #expect(rewritten.contains("notion_sync_enabled"))
        #expect(rewritten.contains("sttModel"))
    }
}

/// Covers the owner-named / top-level database changes: parsing the integration owner from
/// `/users/me` and deriving the database title from it.
@Suite("Notion identity + database title")
struct NotionIdentityTests {

    @Test("parseIdentity reads the owner name from bot.owner.user.name")
    func parseOwnerName() {
        let json: [String: Any] = [
            "name": "Muesli",
            "id": "bot-id",
            "bot": [
                "workspace_name": "Abdo's Workspace",
                "owner": [
                    "type": "user",
                    "user": ["object": "user", "id": "u1", "name": "Abdo Mahmoud"],
                ],
            ],
        ]
        let identity = NotionClient.parseIdentity(json)
        #expect(identity.ownerName == "Abdo Mahmoud")
        #expect(identity.workspaceName == "Abdo's Workspace")
        #expect(identity.integrationName == "Muesli")
    }

    @Test("parseIdentity tolerates a missing owner/user")
    func parseMissingOwner() {
        let identity = NotionClient.parseIdentity(["bot": ["workspace_name": "WS"]])
        #expect(identity.ownerName == nil)
        #expect(identity.workspaceName == "WS")
    }

    @Test("database title prefers the Muesli onboarding name over Notion identity")
    func titleFromUserName() {
        let identity = NotionClient.NotionIdentity(
            integrationName: "Muesli", ownerName: "Someone Else", workspaceName: "Acme Team")
        #expect(NotionClient.muesliDatabaseTitle(userName: "Abdo Mahmoud", identity: identity) == "Abdo’s Muesli Notes")
    }

    @Test("database title falls back to the Notion identity when no Muesli name is set")
    func titleFromIdentity() {
        let owner = NotionClient.NotionIdentity(
            integrationName: "Muesli", ownerName: "Chris Weston", workspaceName: "Some Workspace")
        #expect(NotionClient.muesliDatabaseTitle(userName: "  ", identity: owner) == "Chris’s Muesli Notes")
        let workspace = NotionClient.NotionIdentity(
            integrationName: "Muesli", ownerName: nil, workspaceName: "Acme Team")
        #expect(NotionClient.muesliDatabaseTitle(userName: nil, identity: workspace) == "Acme’s Muesli Notes")
    }

    @Test("database title is plain “Muesli Notes” when no name is available")
    func titlePlainFallback() {
        let nils = NotionClient.NotionIdentity(integrationName: "Muesli", ownerName: nil, workspaceName: nil)
        #expect(NotionClient.muesliDatabaseTitle(userName: "   ", identity: nils) == "Muesli Notes")
        #expect(NotionClient.muesliDatabaseTitle(userName: nil, identity: nils) == "Muesli Notes")
    }
}

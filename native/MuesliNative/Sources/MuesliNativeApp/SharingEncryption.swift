import CryptoKit
import Foundation
import Security

/// Sender-side encryption and key delivery. No plaintext note keys leave this process.
@MainActor
enum SharingEncryption {
    private struct Grant: Codable {
        let key: Data
        let owner: String
        let recipients: [String]
        let expiresAt: Date
        var fingerprints: [String: String]
    }
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.muesli.plus.preview") + ".note-keys" }

    static func encrypt(title: String, summary: String, transcript: String, owner: String, recipients: [String]) throws -> [String: Any] {
        let sealed = try SharingCipher.encrypt(title: title, summary: summary, transcript: transcript)
        let grant = Grant(key: sealed.key, owner: owner.lowercased(), recipients: recipients.map { $0.lowercased() }, expiresAt: Date().addingTimeInterval(7 * 86400), fingerprints: [:])
        // Persist before upload. An interrupted upload must never lose its only key.
        try save(grant, id: sealed.id)
        return sealed.envelope
    }

    private static func deliverPending() async throws {
        guard let token = PlusPreviewClient.readToken() else { return }
        let account = try await PlusPreviewClient.call("account", token: token)
        guard let owner = account["email"] as? String else { return }
        let response = try await PlusPreviewClient.call("encryption/pending", token: token)
        guard let pending = response["pending"] as? [[String: Any]] else { return }
        // Stay within the preview write budget; remaining grants are retried next cycle.
        var delivered = 0
        for item in pending {
            guard let id = item["noteId"] as? String,
                  let email = item["email"] as? String,
                  let keyID = item["keyId"] as? String,
                  let publicString = item["publicKey"] as? String,
                  let publicData = Data(base64Encoded: publicString), publicData.count == 65,
                  var grant = load(id: id), grant.expiresAt > Date(), grant.owner == owner.lowercased(),
                  email == grant.owner || grant.recipients.contains(email),
                  SHA256.hash(data: publicData).map({ String(format: "%02x", $0) }).joined() == keyID
            else { continue }
            // Trust on first use, pinned per shared note. Replacing the registered key
            // requires a new explicit share, rather than silently granting a new device.
            if let pinned = grant.fingerprints[email], pinned != keyID { continue }
            let envelope = try SharingCipher.wrap(key: grant.key, noteID: id, publicData: publicData)
            grant.fingerprints[email] = keyID
            try save(grant, id: id)
            _ = try await PlusPreviewClient.call("encryption/grant", token: token, body: envelope)
            delivered += 1
            if delivered == 2 { break }

        }
    }
    private static func query(id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    private static func load(id: String) -> Grant? {
        var q = query(id: id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Grant.self, from: data)
    }
    private static func save(_ grant: Grant, id: String) throws {
        let data = try JSONEncoder().encode(grant)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(id: id) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure("Could not save the encryption key in Keychain.") }
        var q = query(id: id); attributes.forEach { q[$0.key] = $0.value }
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw failure("Could not save the encryption key in Keychain.") }
    }
    private static func failure(_ message: String) -> PlusPreviewClient.Failure { .init(status: 0, message: message) }
}

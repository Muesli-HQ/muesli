import CryptoKit
import Foundation
import Security

public protocol CredentialVault: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}

/// Stored only in Keychain. AppConfig remains the in-memory runtime snapshot.
public struct ConfigCredentials: Codable, Equatable, Sendable {
    public var openAI: String = ""
    public var anthropic: String = ""
    public var custom: String = ""
    public var customCommand: String = ""
    public var customHeaders: [CustomLLMRequestHeader] = []
    public init() {}
    public static let account = "provider-config"
    public var isEmpty: Bool {
        openAI.isEmpty && anthropic.isEmpty && custom.isEmpty && customCommand.isEmpty && customHeaders.isEmpty
    }
}

public enum CredentialVaultError: Error, LocalizedError {
    case unavailable, verificationFailed
    public var errorDescription: String? {
        "Credentials could not be saved or read in Keychain. Unlock your login keychain and try again."
    }
}

/// Each application-support identity owns a distinct service. The packaged CLI uses
/// the same namespace as its app, while DevA/B/C cannot read production credentials.
public struct KeychainCredentialVault: CredentialVault {
    public let service: String
    public init(supportDirectory: URL) {
        let digest = SHA256.hash(data: Data(supportDirectory.standardizedFileURL.path.utf8))
        service = "com.muesli.credentials." + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func enclosingAppBundle(from url: URL = Bundle.main.bundleURL) -> URL? {
        var bundle = url
        while bundle.path != "/", bundle.pathExtension != "app" { bundle.deleteLastPathComponent() }
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         // Background reads must fail promptly, never repeatedly ask for permission.
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    public func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialVaultError.unavailable }
        return data
    }

    public func write(_ data: Data, account: String) throws {
        let query = query(account)
        let values = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
            // Give only this signed app and its signed bundled CLI access. A shell
            // helper or another dev lane is not a trusted application for this item.
            if let bundle = Self.enclosingAppBundle() {
                let paths = [bundle.path, bundle.appendingPathComponent("Contents/MacOS/muesli-cli").path]
                var applications: [SecTrustedApplication] = []
                for path in paths where FileManager.default.fileExists(atPath: path) {
                    var application: SecTrustedApplication?
                    guard SecTrustedApplicationCreateFromPath(path, &application) == errSecSuccess,
                          let application else { throw CredentialVaultError.unavailable }
                    applications.append(application)
                }
                var access: SecAccess?
                guard !applications.isEmpty,
                      SecAccessCreate("muesli credentials" as CFString, applications as CFArray, &access) == errSecSuccess,
                      let access else { throw CredentialVaultError.unavailable }
                item[kSecAttrAccess as String] = access
            }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialVaultError.unavailable }
        guard try read(account) == data else { throw CredentialVaultError.verificationFailed }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVaultError.unavailable }
    }
}

/// Existing plaintext is removed only after a verified Keychain write. A locked
/// keychain leaves the old file intact and readable so migration can retry safely.
public struct CredentialFileMigration: Sendable {
    public let legacyURL: URL
    public let account: String
    public let vault: any CredentialVault

    public init(legacyURL: URL, account: String, vault: any CredentialVault) {
        self.legacyURL = legacyURL; self.account = account; self.vault = vault
    }

    public func load(validating validate: (Data) throws -> Void = { _ in }) throws -> Data? {
        do {
            if let existing = try vault.read(account) {
                try validate(existing)
                // A stale file must never overwrite a newer credential.
                if FileManager.default.fileExists(atPath: legacyURL.path) { try? FileManager.default.removeItem(at: legacyURL) }
                return existing
            }
        } catch {
            if let legacy = try? Data(contentsOf: legacyURL) { try validate(legacy); return legacy }
            throw error
        }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }
        let legacy = try Data(contentsOf: legacyURL)
        try validate(legacy)
        do { try save(legacy) } catch { /* Retain the only working copy for retry. */ }
        return legacy
    }

    public func save(_ data: Data) throws {
        try vault.write(data, account: account)
        guard try vault.read(account) == data else { throw CredentialVaultError.verificationFailed }
        if FileManager.default.fileExists(atPath: legacyURL.path) { try FileManager.default.removeItem(at: legacyURL) }
    }

    public func delete() throws {
        try vault.remove(account)
        if FileManager.default.fileExists(atPath: legacyURL.path) { try FileManager.default.removeItem(at: legacyURL) }
    }
}

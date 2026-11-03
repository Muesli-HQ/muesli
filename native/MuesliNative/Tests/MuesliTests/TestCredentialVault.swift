import Foundation
import MuesliCore
@testable import MuesliNativeApp

/// Synthetic fixtures never touch the developer's login Keychain.
final class TestCredentialVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var reads = 0
    var readCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
    var failReads = false
    var failingReadAccounts: Set<String> = []
    var failWrites = false
    var failDeletes = false
    func read(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if failReads || failingReadAccounts.contains(account) { throw CredentialVaultError.unavailable }
        return values[account]
    }
    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw CredentialVaultError.unavailable }
        values[account] = data
    }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failDeletes { throw CredentialVaultError.unavailable }
        values.removeValue(forKey: account)
    }
    private static let registry = Registry()
    static func forDirectory(_ url: URL) -> TestCredentialVault { registry.get(url.path) }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var vaults: [String: TestCredentialVault] = [:]
        func get(_ path: String) -> TestCredentialVault {
            lock.lock(); defer { lock.unlock() }
            if let vault = vaults[path] { return vault }
            let vault = TestCredentialVault(); vaults[path] = vault; return vault
        }
    }
}

func makeTestConfigStore(supportDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-config-" + UUID().uuidString)) -> ConfigStore {
    ConfigStore(supportDirectory: supportDirectory, vault: TestCredentialVault.forDirectory(supportDirectory))
}
func makeTestOpenRouterCredentialStore(supportDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-openrouter-" + UUID().uuidString)) -> OpenRouterCredentialStore {
    OpenRouterCredentialStore(supportDirectory: supportDirectory, vault: TestCredentialVault.forDirectory(supportDirectory))
}

@MainActor func makeTestChatGPTAuthManager() -> ChatGPTAuthManager {
    ChatGPTAuthManager(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), vault: TestCredentialVault())
}

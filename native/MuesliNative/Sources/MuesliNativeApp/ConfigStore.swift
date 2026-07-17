import Foundation
import MuesliCore

final class ConfigStore {
    private let configURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        self.configURL = supportDirectory.appendingPathComponent("config.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppConfig {
        ensureDirectory()
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }
        guard let config = try? decoder.decode(AppConfig.self, from: data) else {
            return AppConfig()
        }

        // AppConfig normalizes retired Cotypist model identifiers while decoding.
        // Persist that normalization so the settings UI and on-disk configuration
        // agree after upgrading from a build that offered Qwen for Cotypist.
        if let storedModel = storedCotypistModel(in: data),
           storedModel != config.cotypistModel {
            save(config)
        }

        return config
    }

    func save(_ config: AppConfig) {
        ensureDirectory()
        guard let data = try? encoder.encode(config) else { return }
        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
        } catch {
            fputs("[config-store] failed to save config: \(error)\n", stderr)
        }
    }

    func configPath() -> URL {
        configURL
    }

    func supportDirectory() -> URL {
        configURL.deletingLastPathComponent()
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func storedCotypistModel(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["cotypist_model"] as? String
    }
}

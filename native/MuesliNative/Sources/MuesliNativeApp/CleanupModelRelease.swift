import Foundation
import MuesliCore

/// One immutable build of a Muesli-administered cleanup model.
///
/// A cleanup *slot* (a `PostProcessorOption` id such as Cleanup Lite) keeps its
/// identity, prompt contract and runtime across releases; only the weights move.
/// Releases are ordered by `sequence`, so a new fine-tune can reach installed
/// users through the signed model catalog without an app update.
struct CleanupModelRelease: Codable, Equatable, Sendable {
    /// Inference engine a release needs. A catalog entry naming a runtime its
    /// slot does not use is ignored, so weights can never be pointed at an
    /// engine or prompt contract they were not trained for.
    enum Runtime: String, Codable, Sendable {
        case mlxQwen35 = "mlx-qwen3.5"
        case ggufLFM25 = "gguf-lfm2.5"

        var modelFileExtension: String {
            switch self {
            case .mlxQwen35: "safetensors"
            case .ggufLFM25: "gguf"
            }
        }
    }

    struct File: Codable, Equatable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    let slot: String
    let version: String
    let sequence: Int
    let runtime: Runtime
    let repo: String
    let revision: String
    let files: [File]
    var notes: String?
    var minimumAppVersion: String?

    enum CodingKeys: String, CodingKey {
        case slot, version, sequence, runtime, repo, revision, files, notes
        case minimumAppVersion = "minimum_app_version"
    }

    init(slot: String, version: String, sequence: Int, runtime: Runtime, notes: String? = nil,
         _ repo: String, _ revision: String, _ files: [(String, Int64, String)]) {
        self.slot = slot
        self.version = version
        self.sequence = sequence
        self.runtime = runtime
        self.repo = repo
        self.revision = revision
        self.files = files.map { File(path: $0.0, size: $0.1, sha256: $0.2) }
        self.notes = notes
    }

    var artifact: ManagedCleanupModel {
        ManagedCleanupModel(repo, revision, files.map { ($0.path, $0.size, $0.sha256) })
    }

    /// Bytes that must be fetched to move from `installed` to this release.
    /// Files with an identical path and digest are reused from the installed copy.
    func downloadByteCount(replacing installed: CleanupModelRelease?) -> Int64 {
        let reusable = Set((installed?.files ?? []).map { $0.path + "\u{0}" + $0.sha256 })
        return files.filter { !reusable.contains($0.path + "\u{0}" + $0.sha256) }.reduce(0) { $0 + $1.size }
    }

    /// Rejects anything the app could not run safely: wrong runtime, mutable or
    /// foreign sources, path traversal, unpinned digests, or a newer app floor.
    func validationFailure(for slot: CleanupModelSlot, appVersion: String) -> String? {
        guard self.slot == slot.id else { return "slot mismatch" }
        guard runtime == slot.runtime else { return "runtime \(runtime.rawValue) does not match \(slot.runtime.rawValue)" }
        guard sequence > 0, !version.isEmpty else { return "missing version" }
        guard repo.hasPrefix("Muesli-HQ/"), repo.split(separator: "/").count == 2,
              repo.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) else { return "untrusted repository \(repo)" }
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else { return "revision is not a commit hash" }
        // The runtime loads the slot's model file by name, so it is fixed per slot.
        guard let first = files.first, first.path == slot.bundled.files[0].path,
              (first.path as NSString).pathExtension == runtime.modelFileExtension else {
            return "first file must be \(slot.bundled.files[0].path)"
        }
        var seen = Set<String>()
        for file in files {
            guard !file.path.isEmpty, !file.path.contains("/"), !file.path.hasPrefix("."),
                  file.path.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }),
                  seen.insert(file.path).inserted else { return "invalid file path \(file.path)" }
            guard file.size > 0, file.sha256.count == 64, file.sha256.allSatisfy(\.isHexDigit),
                  file.sha256 == file.sha256.lowercased() else { return "invalid digest for \(file.path)" }
        }
        if let minimumAppVersion, Self.compareVersions(appVersion, minimumAppVersion) == .orderedAscending {
            return "requires app \(minimumAppVersion)"
        }
        return nil
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ value: String) -> [Int] {
            value.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// A cleanup model whose weights Muesli publishes and can update in place.
struct CleanupModelSlot: Sendable {
    let id: String
    let runtime: CleanupModelRelease.Runtime
    /// Newest release this app build knows about without the network.
    let bundled: CleanupModelRelease
    /// Releases shipped before install markers existed, identified by file sizes.
    let unmarkedLegacy: [CleanupModelRelease]

    static let liteID = "qwen35-postproc-v4"
    static let proQwenID = "qwen35-2b-cleanup-v12"
    static let proLFMID = "lfm25-cleanup-v12"

    static let all: [CleanupModelSlot] = [
        CleanupModelSlot(id: liteID, runtime: .mlxQwen35, bundled: .qwen08V14, unmarkedLegacy: [.qwen08V12]),
        CleanupModelSlot(id: proQwenID, runtime: .mlxQwen35, bundled: .qwen2BV14, unmarkedLegacy: [.qwen2BV12]),
        CleanupModelSlot(id: proLFMID, runtime: .ggufLFM25, bundled: .lfmV12, unmarkedLegacy: [.lfmV12]),
    ]

    static func slot(id: String) -> CleanupModelSlot? { all.first { $0.id == id } }
}

/// On-disk state of a managed cleanup model.
///
/// Every install is downloaded into a sibling staging folder, stamped with
/// `markerFilename`, then swapped into place, so the live folder is always a
/// complete, identified release and an update never breaks the model in use.
enum CleanupModelInstallation {
    static let markerFilename = ".muesli-cleanup-release.json"
    private static let stagingInfix = ".pending-"
    private static let retiredInfix = ".retired-"

    static func installedRelease(for slot: CleanupModelSlot, in directory: URL) -> CleanupModelRelease? {
        if let data = try? Data(contentsOf: directory.appendingPathComponent(markerFilename)),
           let release = try? JSONDecoder().decode(CleanupModelRelease.self, from: data),
           release.slot == slot.id, release.runtime == slot.runtime,
           release.artifact.isPresent(at: directory) {
            return release
        }
        return slot.unmarkedLegacy.first { $0.artifact.isPresent(at: directory) }
    }

    static func stagingDirectory(for release: CleanupModelRelease, liveDirectory: URL) -> URL {
        liveDirectory.deletingLastPathComponent()
            .appendingPathComponent(liveDirectory.lastPathComponent + stagingInfix + release.revision.prefix(12), isDirectory: true)
    }

    /// Creates the staging folder and clones unchanged files from the live install
    /// (an APFS clone costs no space), so an update fetches only what changed.
    /// Staging folders for other revisions are abandoned downloads and are removed.
    static func prepareStaging(for release: CleanupModelRelease, liveDirectory: URL,
                               installed: CleanupModelRelease?, fileManager: FileManager = .default) throws -> URL {
        let staging = stagingDirectory(for: release, liveDirectory: liveDirectory)
        for stale in siblingDirectories(of: liveDirectory, infix: stagingInfix, fileManager: fileManager) where stale != staging {
            try? fileManager.removeItem(at: stale)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let installed else { return staging }
        let installedDigests = Dictionary(installed.files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        for file in release.files where installedDigests[file.path] == file.sha256 {
            let target = staging.appendingPathComponent(file.path)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.copyItem(at: liveDirectory.appendingPathComponent(file.path), to: target)
        }
        return staging
    }

    /// Stamps a verified staging folder and swaps it into the live location.
    /// The previous build is moved aside first and restored if the swap fails.
    static func commit(_ release: CleanupModelRelease, staging: URL, liveDirectory: URL,
                       fileManager: FileManager = .default) throws {
        guard release.artifact.isPresent(at: staging) else {
            throw NSError(domain: "CleanupModelInstallation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The downloaded \(release.version) model is incomplete."])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(release).write(to: staging.appendingPathComponent(markerFilename), options: .atomic)
        // Leftover download bookkeeping is not part of an installed model.
        try? fileManager.removeItem(at: staging.appendingPathComponent(".muesli-download-state.json"))

        var retired: URL?
        if fileManager.fileExists(atPath: liveDirectory.path) {
            let aside = liveDirectory.deletingLastPathComponent()
                .appendingPathComponent(liveDirectory.lastPathComponent + retiredInfix + UUID().uuidString, isDirectory: true)
            try fileManager.moveItem(at: liveDirectory, to: aside)
            retired = aside
        }
        do {
            try fileManager.moveItem(at: staging, to: liveDirectory)
        } catch {
            if let retired { try? fileManager.moveItem(at: retired, to: liveDirectory) }
            throw error
        }
        // A loaded engine keeps its open or mapped files; unlinking them is safe.
        if let retired { try? fileManager.removeItem(at: retired) }
    }

    /// Staging and retired folders that belong to a model folder, for deletion and cleanup.
    static func auxiliaryDirectories(of liveDirectory: URL, fileManager: FileManager = .default) -> [URL] {
        siblingDirectories(of: liveDirectory, infix: stagingInfix, fileManager: fileManager)
            + siblingDirectories(of: liveDirectory, infix: retiredInfix, fileManager: fileManager)
    }

    private static func siblingDirectories(of liveDirectory: URL, infix: String, fileManager: FileManager) -> [URL] {
        let parent = liveDirectory.deletingLastPathComponent()
        let prefix = liveDirectory.lastPathComponent + infix
        let names = (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map { parent.appendingPathComponent($0, isDirectory: true) }
    }
}

// MARK: - Releases known to this build

extension CleanupModelRelease {
    static let qwen08V14 = Self(slot: CleanupModelSlot.liteID, version: "v14", sequence: 14, runtime: .mlxQwen35,
        notes: "Formats spoken lists, lead-ins and numbers more consistently.",
        "Muesli-HQ/qwen35-0.8b-muesli-cleanup-v14-mlx-8bit", "11ad4d97beedb3b25cbbcc357185b7cc07945376", [
        ("model.safetensors", 799_973_748, "1ee6bf6cd9bfe657c339bd49fa882309cd89e44ba9f5789a2b5aed8959b808c4"),
        ("config.json", 2733, "84c103783b0a7401ea32ee11318677b4186eda9dd9b1b0aeca8e1989d42063a2"),
        ("generation_config.json", 116, "e1b6129cc934dbc0a6e8f5fbc279e69cbc50d116a92ceb843db9caa68d40ffd0"),
        ("model.safetensors.index.json", 60784, "6d0e74ad17103021d9748ca2279ff13a5cae9a3b3e1f9e6422d18cb39dac3150"),
        ("tokenizer.json", 19_989_339, "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
        ("tokenizer_config.json", 1253, "62c19988f1acd7a4444246d3efac4092dd5d1f23b492fcefceed74d9d2f5cd27"),
        ("chat_template.jinja", 7755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
    ])
    static let qwen2BV14 = Self(slot: CleanupModelSlot.proQwenID, version: "v14", sequence: 14, runtime: .mlxQwen35,
        notes: "Better list and number formatting, and more accurate use of screen context.",
        "Muesli-HQ/qwen35-2b-muesli-cleanup-v14-mlx-8bit", "d627bb292c62c89a1e28bb25788e97f094c01064", [
        ("model.safetensors", 2_000_043_057, "286394c25ce248eed049bc5f55d1bc2aa5f52496a09a1a037c159d78984e3a3f"),
        ("config.json", 2733, "cc0f503cbdbc753495dcdcc755a4b5f91fc1948020f5e902878658b1fb392aef"),
        ("generation_config.json", 116, "e1b6129cc934dbc0a6e8f5fbc279e69cbc50d116a92ceb843db9caa68d40ffd0"),
        ("model.safetensors.index.json", 60786, "54d94d008c07e39846c0b454f68055622bb635a0623b51bce86d724e18733aab"),
        ("tokenizer.json", 19_989_339, "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
        ("tokenizer_config.json", 1253, "62c19988f1acd7a4444246d3efac4092dd5d1f23b492fcefceed74d9d2f5cd27"),
        ("chat_template.jinja", 7755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
    ])

    // v12 builds were installed without markers; their pins identify existing folders.
    static let qwen08V12 = Self(slot: CleanupModelSlot.liteID, version: "v12", sequence: 12, runtime: .mlxQwen35,
        ManagedCleanupModel.qwen08MLX.repoID, ManagedCleanupModel.qwen08MLX.revision, ManagedCleanupModel.qwen08MLX.pinnedFiles)
    static let qwen2BV12 = Self(slot: CleanupModelSlot.proQwenID, version: "v12", sequence: 12, runtime: .mlxQwen35,
        ManagedCleanupModel.qwenMLX.repoID, ManagedCleanupModel.qwenMLX.revision, ManagedCleanupModel.qwenMLX.pinnedFiles)
    static let lfmV12 = Self(slot: CleanupModelSlot.proLFMID, version: "v12", sequence: 12, runtime: .ggufLFM25,
        ManagedCleanupModel.lfm.repoID, ManagedCleanupModel.lfm.revision, ManagedCleanupModel.lfm.pinnedFiles)
}

private extension ManagedCleanupModel {
    var pinnedFiles: [(String, Int64, String)] {
        files.map { ($0.relativePath, $0.expectedByteCount ?? 0, $0.sha256 ?? "") }
    }
}

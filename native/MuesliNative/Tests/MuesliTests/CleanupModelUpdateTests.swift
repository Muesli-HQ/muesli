import CryptoKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Cleanup model updates")
struct CleanupModelUpdateTests {
    private static let revisionA = String(repeating: "a", count: 40)
    private static let revisionB = String(repeating: "b", count: 40)

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func release(slot: String = CleanupModelSlot.liteID, version: String, sequence: Int,
                                revision: String = revisionB, repo: String = "Muesli-HQ/test-cleanup",
                                runtime: CleanupModelRelease.Runtime = .mlxQwen35,
                                contents: [(String, String)]) -> CleanupModelRelease {
        CleanupModelRelease(slot: slot, version: version, sequence: sequence, runtime: runtime, repo, revision,
            contents.map { name, text in (name, Int64(Data(text.utf8).count), sha(Data(text.utf8))) })
    }

    private static func write(_ contents: [(String, String)], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in contents { try Data(text.utf8).write(to: directory.appendingPathComponent(name)) }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let liteSlot = CleanupModelSlot.slot(id: CleanupModelSlot.liteID)!

    @Test func bundledReleasesShipV14ForQwenSlots() {
        let latest = CleanupModelCatalog.bundledLatest
        #expect(latest[CleanupModelSlot.liteID]?.version == "v14")
        #expect(latest[CleanupModelSlot.liteID]?.revision == "11ad4d97beedb3b25cbbcc357185b7cc07945376")
        #expect(latest[CleanupModelSlot.proQwenID]?.version == "v14")
        #expect(latest[CleanupModelSlot.proQwenID]?.revision == "d627bb292c62c89a1e28bb25788e97f094c01064")
        #expect(latest[CleanupModelSlot.proLFMID]?.version == "v12")
        for slot in CleanupModelSlot.all where slot.runtime == .mlxQwen35 {
            #expect(slot.bundled.validationFailure(for: slot, appVersion: "0.0.1") == nil)
            #expect(slot.unmarkedLegacy.allSatisfy { $0.sequence < slot.bundled.sequence })
        }
        // Every managed option resolves to a slot whose bundled model file matches the option.
        for option in PostProcessorOption.all {
            guard let slot = option.cleanupSlot else { continue }
            #expect(slot.bundled.files[0].path == option.filename)
        }
    }

    @Test func signedCatalogOffersNewerRelease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let newer = Self.release(version: "v15", sequence: 15, contents: [("model.safetensors", "w15"), ("config.json", "{}")])
        let data = try JSONEncoder().encode(CleanupModelCatalog.Document(schema: 1, releases: [newer]))
        let signature = Data(try key.signature(for: data).base64EncodedString().utf8)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        let latest = try CleanupModelCatalog.latestReleases(catalog: data, signature: signature,
            publicKey: publicKey, appVersion: "1.0.0")
        #expect(latest[CleanupModelSlot.liteID] == newer)
        #expect(latest[CleanupModelSlot.proQwenID] == CleanupModelRelease.qwen2BV14)

        var tampered = data
        tampered.append(contentsOf: Array(" ".utf8))
        #expect(throws: CleanupModelCatalog.CatalogError.self) {
            try CleanupModelCatalog.latestReleases(catalog: tampered, signature: signature, publicKey: publicKey, appVersion: "1.0.0")
        }
        #expect(throws: CleanupModelCatalog.CatalogError.self) {
            try CleanupModelCatalog.latestReleases(catalog: data, signature: nil, publicKey: publicKey, appVersion: "1.0.0")
        }
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(throws: CleanupModelCatalog.CatalogError.self) {
            try CleanupModelCatalog.latestReleases(catalog: data, signature: signature, publicKey: otherKey, appVersion: "1.0.0")
        }
    }

    @Test func catalogNeverDowngradesOrAcceptsUnsafeReleases() throws {
        let model = [("model.safetensors", "w"), ("config.json", "{}")]
        let older = Self.release(version: "v13", sequence: 13, contents: model)
        let unsafe = [
            Self.release(version: "v20", sequence: 20, repo: "someone-else/cleanup", contents: model),
            Self.release(version: "v20", sequence: 20, revision: "main", contents: model),
            Self.release(version: "v20", sequence: 20, runtime: .ggufLFM25, contents: model),
            Self.release(version: "v20", sequence: 20, contents: [("model.safetensors", "w"), ("../escape", "x")]),
            Self.release(version: "v20", sequence: 20, contents: [("weights.safetensors", "w")]),
            Self.release(slot: "unknown-slot", version: "v20", sequence: 20, contents: model),
        ]
        var tooNew = Self.release(version: "v20", sequence: 20, contents: model)
        tooNew.minimumAppVersion = "9.0"
        let badMinimums = ["", "-", "1..0", "0.9-beta"].map { minimum in
            var release = Self.release(version: "v20", sequence: 20, contents: model)
            release.minimumAppVersion = minimum
            return release
        }
        for release in unsafe + [tooNew] + badMinimums {
            if let slot = CleanupModelSlot.slot(id: release.slot) {
                #expect(release.validationFailure(for: slot, appVersion: "1.0.0") != nil)
            }
        }
        let data = try JSONEncoder().encode(CleanupModelCatalog.Document(schema: 1, releases: [older] + unsafe + [tooNew] + badMinimums))
        let latest = try CleanupModelCatalog.latestReleases(catalog: data, signature: nil, publicKey: "",
            appVersion: "1.0.0", allowUnsigned: true)
        #expect(latest == CleanupModelCatalog.bundledLatest)
    }

    @Test func publishedCatalogMatchesBundledV14() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/models/cleanup-models.json")
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(CleanupModelCatalog.Document.self, from: data)
        for release in document.releases {
            let slot = try #require(CleanupModelSlot.slot(id: release.slot))
            #expect(release.validationFailure(for: slot, appVersion: AppIdentity.marketingVersion) == nil)
            if release.sequence == slot.bundled.sequence {
                #expect(Set(release.files.map(\.path)) == Set(slot.bundled.files.map(\.path)))
                #expect(release.revision == slot.bundled.revision)
                #expect(release.files.map(\.sha256).sorted() == slot.bundled.files.map(\.sha256).sorted())
            }
        }
    }

    @Test func stagedUpdateReusesUnchangedFilesAndSwapsAtomically() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("postproc-\(CleanupModelSlot.liteID)")
        let v14Contents = [("model.safetensors", "weights-14"), ("tokenizer.json", "shared-tokenizer")]
        let v15Contents = [("model.safetensors", "weights-15"), ("tokenizer.json", "shared-tokenizer")]
        let v14 = Self.release(version: "v14", sequence: 14, revision: Self.revisionA, contents: v14Contents)
        let v15 = Self.release(version: "v15", sequence: 15, revision: Self.revisionB, contents: v15Contents)

        // Fresh install: staging, then commit stamps the marker.
        let firstStaging = try CleanupModelInstallation.prepareStaging(for: v14, liveDirectory: live, installed: nil)
        try Self.write(v14Contents, to: firstStaging)
        try CleanupModelInstallation.commit(v14, staging: firstStaging, liveDirectory: live)
        #expect(CleanupModelInstallation.installedRelease(for: Self.liteSlot, in: live) == v14)
        #expect(!FileManager.default.fileExists(atPath: firstStaging.path))

        // Update: the unchanged tokenizer is cloned; only the weights are fetched.
        #expect(v15.downloadByteCount(replacing: v14) == Int64("weights-15".utf8.count))
        let staging = try CleanupModelInstallation.prepareStaging(for: v15, liveDirectory: live, installed: v14)
        #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("tokenizer.json").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("model.safetensors").path))
        // The live install is untouched while the update downloads.
        #expect(CleanupModelInstallation.installedRelease(for: Self.liteSlot, in: live) == v14)
        #expect(throws: (any Error).self) {
            try CleanupModelInstallation.commit(v15, staging: staging, liveDirectory: live)
        }
        #expect(CleanupModelInstallation.installedRelease(for: Self.liteSlot, in: live) == v14)

        try Data("weights-15".utf8).write(to: staging.appendingPathComponent("model.safetensors"))
        try CleanupModelInstallation.commit(v15, staging: staging, liveDirectory: live)
        #expect(CleanupModelInstallation.installedRelease(for: Self.liteSlot, in: live) == v15)
        #expect(try String(contentsOf: live.appendingPathComponent("model.safetensors"), encoding: .utf8) == "weights-15")
        #expect(CleanupModelInstallation.auxiliaryDirectories(of: live).isEmpty)
    }

    @Test func abandonedStagingForOtherRevisionsIsRemoved() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("postproc-\(CleanupModelSlot.liteID)")
        let v15 = Self.release(version: "v15", sequence: 15, revision: Self.revisionA, contents: [("model.safetensors", "a")])
        let v16 = Self.release(version: "v16", sequence: 16, revision: Self.revisionB, contents: [("model.safetensors", "b")])
        let stale = try CleanupModelInstallation.prepareStaging(for: v15, liveDirectory: live, installed: nil)
        let current = try CleanupModelInstallation.prepareStaging(for: v16, liveDirectory: live, installed: nil)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(CleanupModelInstallation.auxiliaryDirectories(of: live) == [current])
    }

    @Test func unmarkedFoldersResolveToLegacyReleaseBySize() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = [("model.safetensors", "legacy-weights"), ("config.json", "{\"v\":12}")]
        let legacy = Self.release(slot: "test-slot", version: "v12", sequence: 12, revision: Self.revisionA, contents: contents)
        let bundled = Self.release(slot: "test-slot", version: "v14", sequence: 14, contents: [("model.safetensors", "new"), ("config.json", "{}")])
        let slot = CleanupModelSlot(id: "test-slot", runtime: .mlxQwen35, bundled: bundled, unmarkedLegacy: [legacy])
        #expect(CleanupModelInstallation.installedRelease(for: slot, in: root) == nil)
        try Self.write(contents, to: root)
        #expect(CleanupModelInstallation.installedRelease(for: slot, in: root) == legacy)
        // A marker for another slot is ignored rather than trusted.
        let foreign = Self.release(version: "v99", sequence: 99, contents: contents)
        try JSONEncoder().encode(foreign).write(to: root.appendingPathComponent(CleanupModelInstallation.markerFilename))
        #expect(CleanupModelInstallation.installedRelease(for: slot, in: root) == legacy)
    }

    @MainActor
    @Test func libraryOffersUpdatesOnlyForInstalledOlderBuilds() {
        let library = ModelLibraryState()
        #expect(library.cleanupModelUpdates.isEmpty)
        library.installedCleanupReleases = [
            CleanupModelSlot.liteID: .qwen08V12,
            CleanupModelSlot.proQwenID: .qwen2BV14,
            CleanupModelSlot.proLFMID: .lfmV12,
        ]
        #expect(Set(library.cleanupModelUpdates.keys) == [CleanupModelSlot.liteID])
        #expect(library.cleanupModelUpdates[CleanupModelSlot.liteID] == .qwen08V14)
    }

    @Test func catalogSkipsEntriesThisBuildCannotDecode() throws {
        let newer = Self.release(version: "v15", sequence: 15, contents: [("model.safetensors", "w15"), ("config.json", "{}")])
        var document = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CleanupModelCatalog.Document(schema: 1, releases: [newer]))) as! [String: Any]
        let encoded = (document["releases"] as! [[String: Any]])[0]
        var future = encoded
        future["runtime"] = "mlx-lfm3"
        future["sequence"] = 16
        document["releases"] = [future, ["slot": 7], encoded]
        let data = try JSONSerialization.data(withJSONObject: document)

        let latest = try CleanupModelCatalog.latestReleases(catalog: data, signature: nil, publicKey: "",
            appVersion: "1.0.0", allowUnsigned: true)
        #expect(latest[CleanupModelSlot.liteID] == newer)
    }

    @Test func versionComparisonIsNumeric() {
        #expect(CleanupModelRelease.compareVersions("", "0.9") == .orderedAscending)
        #expect(CleanupModelRelease.compareVersions("0.8.10", "0.8.9") == .orderedDescending)
        #expect(CleanupModelRelease.compareVersions("0.9", "0.9.0") == .orderedSame)
        #expect(CleanupModelRelease.compareVersions("0.8.5-preprod.2", "0.8.6") == .orderedAscending)
    }

    @Test func trainingContextDropsFieldsTheModelsNeverSaw() {
        let context = "App: Safari (https://example.com/a(b))\nDocument context: Draft\nSelected text: line one\nline two\nOCR screen text: Inbox"
        #expect(MuesliCleanupV2Prompt.trainingContext(context) == "App: Safari\nDocument context: Draft\nOCR screen text: Inbox")
        #expect(MuesliCleanupV2Prompt.trainingContext("App: Notes\nDocument context:\nOCR screen text: x") == "App: Notes\nOCR screen text: x")
        #expect(MuesliCleanupV2Prompt.trainingContext("App: Notes (Work)") == "App: Notes (Work)")
    }
}

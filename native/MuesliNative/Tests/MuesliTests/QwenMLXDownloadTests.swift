import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite(.serialized)
struct QwenMLXDownloadTests {
    @Test func publishedArtifactsAndCacheReuse() async throws {
        guard let root = ProcessInfo.processInfo.environment["MUESLI_QWEN_MLX_DOWNLOAD_VERIFY_DIR"] else { return }
        for option in [PostProcessorOption.finetunedV4, .qwenV12] {
            let descriptor = try #require(option.managedModel)
            let directory = URL(fileURLWithPath: root).appendingPathComponent(option.id)
            let manifest = descriptor.manifest(id: option.id)
            try await ModelDownloadCoordinator.shared.download(manifest, to: directory)
            let model = directory.appendingPathComponent(descriptor.modelFilename)
            try descriptor.validate(modelURL: model)
            let before = try FileManager.default.attributesOfItem(atPath: model.path)[.modificationDate] as? Date
            try await ModelDownloadCoordinator.shared.download(manifest, to: directory)
            let after = try FileManager.default.attributesOfItem(atPath: model.path)[.modificationDate] as? Date
            #expect(before != nil && before == after)
            print("MLX DOWNLOAD verified_and_reused=\(option.id) revision=\(descriptor.revision)")
        }
    }
}

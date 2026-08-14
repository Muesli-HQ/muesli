import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Indic ASR model preparation")
struct IndicASRBackendTests {
    @Test("creates empty Core ML weights directories even when no files are missing")
    func createsEmptyWeightsDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("indic-asr-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try IndicASRModelStore.createRequiredEmptyWeightsDirectories(in: directory)

        let weightsDirectory = directory.appendingPathComponent(
            "coreml/rnnt/indic_conformer_joint_pre_net.mlpackage/Data/com.apple.CoreML/weights",
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: weightsDirectory.path))
    }
}

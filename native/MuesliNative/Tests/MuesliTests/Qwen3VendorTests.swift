import Testing
import Foundation
@testable import MuesliCore

struct Qwen3VendorTests {

    @available(macOS 15, *)
    @Test("installArtifacts copies every artifact and replaces stale files")
    func installArtifactsCopiesAllFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("qwen3-vendor-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)

        let encoderDir = source.appendingPathComponent("qwen3_asr_audio_encoder_v2.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: encoderDir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: encoderDir.appendingPathComponent("coremldata.bin"))
        try Data([0x02]).write(to: source.appendingPathComponent("vocab.json"))

        try MuesliQwen3AsrModels.installArtifacts(from: source, to: destination)

        #expect(fm.fileExists(atPath: destination.appendingPathComponent("vocab.json").path))
        #expect(fm.fileExists(
            atPath: destination
                .appendingPathComponent("qwen3_asr_audio_encoder_v2.mlmodelc/coremldata.bin").path
        ))

        // Re-run with a stale destination file: it must be replaced, not duplicated.
        try Data([0xFF]).write(to: destination.appendingPathComponent("vocab.json"))
        try MuesliQwen3AsrModels.installArtifacts(from: source, to: destination)
        let replaced = try Data(contentsOf: destination.appendingPathComponent("vocab.json"))
        #expect(replaced == Data([0x02]))
    }

    @available(macOS 15, *)
    @Test("default int8 cache directory matches the managed plan's install directory")
    func defaultCacheMatchesManagedPlan() {
        let plan = ManagedASRModelPlans.qwen3ASRInt8()
        let cache = MuesliQwen3AsrModels.defaultCacheDirectory(variant: .int8)
        #expect(cache.standardizedFileURL == plan.cacheDirectory.standardizedFileURL)
    }
}

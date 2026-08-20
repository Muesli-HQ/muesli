import Testing
import Foundation
@testable import MuesliCore
@testable import MuesliNativeApp

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

struct Qwen3LanguageTests {

    @Test("Language init parses ISO codes and English names")
    func languageInitParsesCodesAndNames() {
        #expect(MuesliQwen3AsrConfig.Language(from: "en") == .english)
        #expect(MuesliQwen3AsrConfig.Language(from: "English") == .english)
        #expect(MuesliQwen3AsrConfig.Language(from: "ENGLISH") == .english)
        #expect(MuesliQwen3AsrConfig.Language(from: "hi") == .hindi)
    }

    @Test("Language init rejects unknown input")
    func languageInitRejectsUnknownInput() {
        #expect(MuesliQwen3AsrConfig.Language(from: "eng") == nil)
        #expect(MuesliQwen3AsrConfig.Language(from: "") == nil)
        #expect(MuesliQwen3AsrConfig.Language(from: "chinese (simplified)") == nil)
    }
}

struct Qwen3LanguageSelectionTests {

    @available(macOS 15, *)
    @Test("Qwen3AsrLanguage resolves auto and pinned languages")
    func resolvesAutoAndPinned() {
        #expect(Qwen3AsrLanguage.resolved(nil) == .auto)
        #expect(Qwen3AsrLanguage.resolved("") == .auto)
        #expect(Qwen3AsrLanguage.resolved("auto") == .auto)
        #expect(Qwen3AsrLanguage.resolved("AUTO") == .auto)
        #expect(Qwen3AsrLanguage.resolved("en") == .pinned(.english))
        #expect(Qwen3AsrLanguage.resolved("English") == .pinned(.english))
        #expect(Qwen3AsrLanguage.resolved("bogus") == .auto)
    }

    @available(macOS 15, *)
    @Test("Qwen3AsrLanguage exposes codes and labels")
    func exposesCodesAndLabels() {
        #expect(Qwen3AsrLanguage.auto.pinnedCode == nil)
        #expect(Qwen3AsrLanguage.auto.rawValue == "auto")
        #expect(Qwen3AsrLanguage.auto.label == "Auto-detect")
        #expect(Qwen3AsrLanguage.pinned(.english).pinnedCode == "en")
        #expect(Qwen3AsrLanguage.pinned(.english).label == "English")
        #expect(Qwen3AsrLanguage.allCases.count == MuesliQwen3AsrConfig.Language.allCases.count + 1)
    }
}

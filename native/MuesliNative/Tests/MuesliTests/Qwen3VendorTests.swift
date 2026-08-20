import Testing
import Foundation
@testable import MuesliCore
@testable import MuesliNativeApp

struct Qwen3VendorTests {

    @available(macOS 15, *)
    @Test("default int8 cache directory matches the managed plan's install directory")
    func defaultCacheMatchesManagedPlan() {
        let plan = ManagedASRModelPlans.qwen3ASRInt8()
        let cache = MuesliQwen3AsrModels.defaultCacheDirectory(variant: .int8)
        #expect(cache.standardizedFileURL == plan.cacheDirectory.standardizedFileURL)
    }

    @available(macOS 15, *)
    @Test("qwen3ASRInt8(cacheDirectory:) honors an explicit install directory")
    func explicitCacheDirectoryIsHonored() {
        let custom = URL(fileURLWithPath: "/tmp/qwen3-custom-install")
        let plan = ManagedASRModelPlans.qwen3ASRInt8(cacheDirectory: custom)
        #expect(plan.cacheDirectory == custom)
        #expect(plan.modelID == "FluidInference/qwen3-asr-0.6b-coreml")
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

    @available(macOS 15, *)
    @Test("Qwen3AsrLanguage selection survives config encode/decode round-trip")
    func persistenceRoundTrip() throws {
        let selection = Qwen3AsrLanguage.pinned(.english)
        var config = AppConfig()
        config.qwen3AsrLanguage = selection.rawValue

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.resolvedQwen3AsrLanguage == .pinned(.english))
    }
}

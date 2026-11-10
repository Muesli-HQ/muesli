import Foundation
import FluidAudio
import Testing
import MuesliCore
@testable import MuesliNativeApp
@testable import MuesliCLI

@Suite("MedASR integration", .serialized)
struct MedASRIntegrationTests {
    @Test("Google frontend parity, app dictation and CLI use the published real model",
          .enabled(if: ProcessInfo.processInfo.environment["MUESLI_MEDASR_FIXTURE_DIR"] != nil))
    func appAndCLI() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MUESLI_MEDASR_FIXTURE_DIR"]))
        let source = root.appendingPathComponent("test_audio.wav")
        let license = try MedASRTestLicense()
        defer { license.remove() }
        let transcriber = MedASRTranscriber(license: license.store)
        let started = Date()
        try await transcriber.prepare()
        print("MedASR preparation seconds: \(Date().timeIntervalSince(started))")
        let result = try await transcriber.transcribe(wavURL: source)
        #expect(result.text.contains("CT chest PE protocol"))
        #expect(result.text.contains("54-year-old"))
        #expect(!result.text.contains("{period}"))
        #expect(result.text.count > 400, "The full recording must not be truncated at the 20-second model window")
        print("MedASR first real transcription seconds: \(result.processingTime)")
        await transcriber.shutdown()
        await #expect(throws: MedASRError.self) { _ = try await transcriber.transcribe(wavURL: source) }
        let cli = NativeModelsCLITranscriber(transcribeFile: { url, model, progress in
            try await NativeFileTranscriber.transcribe(wavURL: url, model: model, progress: progress,
                medASRLicense: license.store)
        })
        let cliResult = try await cli.transcribe(wavURL: source, model: .medASR, progress: { _ in })
        #expect(cliResult.text == result.text)

        let samples = try FluidAudioSamples.load(source)
        let frontend = try MedASRFrontend(directory: MedASRModel.plan().cacheDirectory)
        for (count, file) in [(MedASRModel.windowSamples, "reference-features.f32"),
                              (32_017, "reference-features-short.f32")] {
            let actual = try frontend.features(Array(samples.prefix(count)))
            let expected = try MedASRFrontend.readFloats(root.appendingPathComponent(file), count: actual.count)
            let error = zip(actual, expected).reduce(0.0) { $0 + pow(Double($1.0 - $1.1),2) }
            let norm = expected.reduce(0.0) { $0 + Double($1) * Double($1) }
            #expect(sqrt(error / norm) < 1e-5)
        }
    }
    @Test("Published pinned assets download anonymously without reading a saved HF login",
          .enabled(if: ProcessInfo.processInfo.environment["MUESLI_MEDASR_ANONYMOUS_DOWNLOAD_TEST"] == "1"))
    func anonymousDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("medasr-anonymous-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = MedASRModel.plan(modelsRoot: root)
        let directory = try await ManagedASRModelDownloader.downloadIfNeeded(plan)
        #expect(directory == plan.cacheDirectory)
        #expect(plan.isAvailableLocally())
        for file in MedASRModel.requiredFiles {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path))
        }
    }

}

private enum FluidAudioSamples {
    static func load(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}

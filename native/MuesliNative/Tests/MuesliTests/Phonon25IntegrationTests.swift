import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp
@testable import MuesliCLI

/// Opt-in public-fixture smoke test; normal CI never downloads model weights.
@Suite("Phonon-2.5 integration", .serialized)
struct Phonon25IntegrationTests {
    @Test("GPU model loads in the app and CLI, with language hints and independent unloading",
          .enabled(if: ProcessInfo.processInfo.environment["MUESLI_PHONON_FIXTURE_DIR"] != nil))
    func appAndCLI() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["MUESLI_PHONON_FIXTURE_DIR"])
        let root = URL(fileURLWithPath: directory)
        let app = FluidAudioTranscriber()
        let preparationStart = Date()
        try await app.loadModels(modelID: BackendOption.phonon25.model)
        let preparationSeconds = Date().timeIntervalSince(preparationStart)
        var dictationSeconds: [Double] = []
        let samples = [
            ("1089-134686-0000.flac", "en", "stew for dinner"),
            ("fr_fr-10043298898524273336.wav", "fr", "terrain montagneux"),
            ("de_de-10004059102127011984.wav", "de", "besten aussichten"),
            ("es_419-1001146817223348054.wav", "es", "a los viajeros"),
        ]
        for (name, language, phrase) in samples {
            let start = Date()
            let result = try await app.transcribe(wavURL: root.appendingPathComponent(name), language: language)
            dictationSeconds.append(Date().timeIntervalSince(start))
            #expect(result.text.lowercased().contains(phrase), "Unexpected \(language) transcript: \(result.text)")
        }
        print("Phonon preparation: \(preparationSeconds)s; real transcriptions after ready: \(dictationSeconds)s")
        // Both models use the v3 contract. Deleting v3 must not unload Phonon.
        await app.shutdown(ifLoadedModelID: BackendOption.parakeetMultilingual.model)
        let englishURL = root.appendingPathComponent(samples[0].0)
        let retained = try await app.transcribe(wavURL: englishURL)
        #expect(retained.text.lowercased().contains("stew for dinner"))
        await app.shutdown(ifLoadedModelID: BackendOption.phonon25.model)
        await #expect(throws: FluidAudioTranscriber.TranscriberError.self) {
            _ = try await app.transcribe(wavURL: englishURL)
        }
        let cli = FluidAudioCLITranscriber()
        let result = try await cli.transcribe(wavURL: englishURL, model: .phonon25, progress: { _ in })
        #expect(result.text.lowercased().contains("stew for dinner"))
    }
}

import Foundation
import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("Orukeet model installation")
struct OrukeetModelStoreTests {
    private func manifest(filename: String = "orukeet-r3-coreml-baseline.zip",
                          bytes: Int = OrukeetModelStore.archiveBytes,
                          sha256: String = OrukeetModelStore.archiveSHA256) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["archives": ["baseline": [
            "filename": filename, "bytes": bytes, "sha256": sha256,
        ]]])
    }

    @Test("Orukeet is optional and uses its own managed Hugging Face installation")
    func catalogAndDownloadIdentity() {
        #expect(BackendOption.experimental.contains(.orukeet))
        #expect(!BackendOption.onboarding.contains(.orukeet))
        #expect(!BackendOption.orukeet.recommended)
        #expect(BackendOption.resolve(backend: "fluidaudio", model: "oruk/orukeet") == .orukeet)
        let plan = OrukeetModelStore.plan
        #expect(plan.modelID == "oruk/orukeet")
        #expect(plan.repository == "oruk/orukeet")
        #expect(plan.revision == OrukeetModelStore.revision)
        #expect(plan.mirror == nil)
        #expect(plan.selections[0].includedPaths == ["manifest.json", "orukeet-r3-coreml-baseline.zip"])
    }

    @Test("Pinned integrity manifest rejects changed metadata")
    func manifestIntegrity() throws {
        _ = try OrukeetModelStore.validateManifest(manifest())
        #expect(throws: (any Error).self) { try OrukeetModelStore.validateManifest(manifest(filename: "other.zip")) }
        #expect(throws: (any Error).self) { try OrukeetModelStore.validateManifest(manifest(bytes: 1)) }
        #expect(throws: (any Error).self) { try OrukeetModelStore.validateManifest(manifest(sha256: "incorrect")) }
    }

    @Test("Incomplete and corrupt installations do not replace an existing cache")
    func failedInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("previous")
        try Data("previous".utf8).write(to: marker)
        try OrukeetModelStore.revision.write(to: destination.appendingPathComponent(".revision"), atomically: true, encoding: .utf8)
        #expect(!OrukeetModelStore.installed(at: destination))
        #expect(throws: (any Error).self) { try OrukeetModelStore.load(from: destination) }
        let archive = root.appendingPathComponent("corrupt.zip")
        try Data("corrupt".utf8).write(to: archive)
        #expect(throws: (any Error).self) { try OrukeetModelStore.installArchive(at: archive, to: destination) }
        #expect(throws: (any Error).self) {
            try OrukeetModelStore.commitInstallation(from: root.appendingPathComponent("missing"), to: destination)
        }
        #expect(try Data(contentsOf: marker) == Data("previous".utf8))
    }

    // Explicitly opt in: this test downloads the preview once and runs the real app backend.
    @Test("Repeated real-model transcription and cached reload", .enabled(if: ProcessInfo.processInfo.environment["ORUKEET_AUDIO_DIR"] != nil))
    func runtimeSmoke() async throws {
        let audio = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORUKEET_AUDIO_DIR"]!)
        let transcriber = FluidAudioTranscriber()
        try await transcriber.loadOrukeet()
        #expect(OrukeetModelStore.isInstalled)
        var transcripts: [String: String] = [:]
        for round in 0..<2 {
            for name in ["en", "de", "fr", "silence"] {
                let start = Date()
                let result = try await transcriber.transcribe(wavURL: audio.appendingPathComponent(name + ".wav"))
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "silence" { #expect(text.isEmpty) } else { #expect(!text.isEmpty) }
                if let previous = transcripts[name] { #expect(text == previous) }
                transcripts[name] = text
                print("ORUKEET_SMOKE round=\(round) clip=\(name) seconds=\(Date().timeIntervalSince(start)) text=\(text)")
            }
            await transcriber.shutdownOrukeet()
            try await transcriber.loadOrukeet()
        }
        await transcriber.shutdownOrukeet()
    }
}

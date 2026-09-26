import CryptoKit
import FluidAudio
import Foundation

struct OwnerVoiceExtractor: OwnerVoiceExtracting {
    let coordinator: TranscriptionCoordinator
    func extract(samples: [Float]) async throws -> OwnerVoiceWindow {
        try await coordinator.extractOwnerVoice(samples: samples)
    }

    /// Fingerprint the exact compiled artifacts used by the pinned online extractor.
    /// No model download and no telemetry version constant is involved here.
    static func modelIdentity(directory: URL = DiarizerModels.defaultModelsDirectory()) throws -> String {
        var digest = SHA256()
        for model in DiarizerModels.requiredModelNames.sorted() {
            let root = directory.appendingPathComponent(model, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw OwnerVoiceEnrollmentError.unavailable
            }
            let files = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
            var count = 0
            for file in files {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isSymbolicLink != true else { throw OwnerVoiceEnrollmentError.unavailable }
                guard attributes.isRegularFile == true else { continue }
                digest.update(data: Data((model + "/" + String(file.path.dropFirst(root.path.count + 1)) + "\0").utf8))
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { digest.update(data: chunk) }
                count += 1
            }
            guard count > 0 else { throw OwnerVoiceEnrollmentError.unavailable }
        }
        return "FluidAudio-0.15.5-online-" + digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

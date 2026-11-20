import AVFoundation
import CoreAISpeech
import FluidAudio
import Foundation

struct BenchmarkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct CoreAIBundleMetadata: Decodable {
    let name: String
    let kind: String
}

struct Clip {
    let name: String
    let samples: [Float]

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1,
              (16_000...960_000).contains(file.length),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchmarkError(message: "\(path) must be a mono 16 kHz audio file between 1 and 60 seconds.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength == file.length else {
            throw BenchmarkError(message: "Could not read all samples from \(path).")
        }
        name = url.lastPathComponent
        samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

actor CoreMLParakeet {
    private let manager = AsrManager(config: .default)

    init(directory: URL) async throws {
        let models = try AsrModels.loadLocal(from: directory, version: .v3)
        try await manager.loadModels(models)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &decoder).text
    }
}

@main
struct CoreAIBenchmark {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        #if !arch(arm64)
        throw BenchmarkError(message: "Run this benchmark natively on an Apple silicon Mac.")
        #else
        let paths = Array(CommandLine.arguments.dropFirst())
        guard paths.count >= 3 else {
            throw BenchmarkError(message: "Usage: CoreAIBenchmark <Core AI static bundle> <Core ML v3 directory> <16k-mono.wav> […]")
        }

        let coreAIURL = URL(fileURLWithPath: paths[0], isDirectory: true)
        let coreMLURL = URL(fileURLWithPath: paths[1], isDirectory: true)
        let metadata = try JSONDecoder().decode(
            CoreAIBundleMetadata.self,
            from: Data(contentsOf: coreAIURL.appendingPathComponent("metadata.json"))
        )
        guard metadata.kind == "speech_recognizer",
              metadata.name == "parakeet-tdt-0.6b-v3_float16_static" else {
            throw BenchmarkError(message: "Use the documented FP16 static Parakeet v3 export.")
        }
        let components = [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
        ]
        for component in components {
            guard FileManager.default.fileExists(atPath: coreMLURL.appendingPathComponent(component).path) else {
                throw BenchmarkError(message: "Missing Core ML v3 component \(component) in \(coreMLURL.path).")
            }
        }
        let clips = try paths.dropFirst(2).map(Clip.init(path:))

        let clock = ContinuousClock()
        let coreMLStart = clock.now
        let coreML = try await CoreMLParakeet(directory: coreMLURL)
        print("Core ML load: \(formatted(milliseconds(coreMLStart.duration(to: clock.now)))) ms")
        let coreAIStart = clock.now
        let coreAI = try await SpeechRecognitionModel(resourcesAt: coreAIURL)
        print("Core AI load: \(formatted(milliseconds(coreAIStart.duration(to: clock.now)))) ms")
        guard await coreAI.sampleRate == 16_000 else {
            throw BenchmarkError(message: "The Core AI model must accept 16 kHz PCM.")
        }

        // Apple's static runtime pads short clips and can silently truncate long ones.
        // Probe the time dimension outside the timed inference to reject truncation.
        let shape = await coreAI.melFeatures(pcm: clips[0].samples).shape
        let maxSamples = (shape[1] - 1) * MelConfig.parakeet.hopLength
        for clip in clips where clip.samples.count > maxSamples {
            throw BenchmarkError(message: "\(clip.name) exceeds the Core AI export's \(Double(maxSamples) / 16_000)-second window.")
        }

        for clip in clips {
            print("\n\(clip.name) (\(Double(clip.samples.count) / 16_000) s)")
            var ml: [Double] = []
            var ai: [Double] = []
            // Alternate execution order and retain both models for the whole run.
            for index in 0..<6 {
                if index.isMultiple(of: 2) {
                    ml.append(try await time("Core ML", first: index == 0) { try await coreML.transcribe(clip.samples) })
                    ai.append(try await time("Core AI", first: index == 0) { try await coreAI.transcribe(pcm: clip.samples).0 })
                } else {
                    ai.append(try await time("Core AI", first: false) { try await coreAI.transcribe(pcm: clip.samples).0 })
                    ml.append(try await time("Core ML", first: false) { try await coreML.transcribe(clip.samples) })
                }
            }
            let mlMedian = formatted(ml.dropFirst().sorted()[2])
            let aiMedian = formatted(ai.dropFirst().sorted()[2])
            print("Warm median (5 runs), Core ML \(mlMedian) ms, Core AI \(aiMedian) ms")
        }
        #endif
    }

    private static func time(_ name: String, first: Bool, run: () async throws -> String) async throws -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        let transcript = try await run()
        let elapsed = milliseconds(start.duration(to: clock.now))
        if first {
            print("\(name) first pass: \(formatted(elapsed)) ms | \(transcript)")
        }
        return elapsed
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private static func formatted(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }
}

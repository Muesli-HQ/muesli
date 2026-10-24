import Foundation
import MLX
import Testing
@testable import GemmaAudioEvaluation

@Suite(.serialized)
struct GemmaAudioEvaluationTests {
    init() {
        if let path = ProcessInfo.processInfo.environment["MUESLI_MLX_EVAL_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
        // Configure the metallib before any memory API initializes the GPU.
        Memory.cacheLimit = 256 * 1024 * 1024
    }
    @Test func silenceAndFrameBoundaries() throws {
        let frontend = try GemmaAudioFeatures()
        for count in [161,319,320,321,639,640,641,1919,1920,1921] {
            let output = try frontend.extract(samples: Array(repeating: 0, count: count), sampleRate: 16000)
            let padded = ((count+127)/128)*128
            #expect(output.features.shape == [1,(padded+160-321)/160+1,128])
            for (index, valid) in output.mask.enumerated() { #expect(valid == (index*160+160 < count)) }
            let expected = MLXArray(output.mask.flatMap { valid in [Float](repeating: valid ? Float(log(0.001)) : 0, count: 128) }).reshaped(output.features.shape)
            let metric = try GemmaAudioParity.compare(name: "silence", actual: output.features, expected: expected, absolute: 0.00001, relative: 0)
            #expect(metric.violations == 0)
        }
        #expect(throws: GemmaAudioError.self) { try frontend.extract(samples: [], sampleRate: 16000) }
        #expect(throws: GemmaAudioError.self) { try frontend.extract(samples: [.nan], sampleRate: 16000) }
        #expect(throws: GemmaAudioError.self) { try frontend.extract(samples: [0], sampleRate: 48000) }
    }
    /// Independent scalar Double DFT oracle, not the vectorized FFT implementation.
    /// Verifies DSP math only; it is NOT trained-encoder reference parity.
    @Test func waveformAgainstScalarDFT() throws {
        let samples = (0..<640).map { Float(0.2*sin(2*Double.pi*440*Double($0)/16000)) }
        let actual = try GemmaAudioFeatures().extract(samples: samples, sampleRate: 16000)
        var expected = [Float]()
        let melTop = 2595*log10(1+8000.0/700)
        let points = (0..<130).map { 700*(pow(10,Double($0)*melTop/129/2595)-1) }
        for frame in 0..<actual.mask.count {
            var spectrum = [Double]()
            for bin in 0...256 {
                var real = 0.0, imaginary = 0.0
                for n in 0..<320 {
                    let i = frame*160-160+n
                    let sample = i >= 0 && i < samples.count ? Double(samples[i]) : 0
                    let window = Float(0.5-0.5*cos(2*Double.pi*Double(n)/320))
                    let angle = -2*Double.pi*Double(bin*n)/512
                    let windowed = Double(Float(sample)*window)
                    real += windowed*cos(angle); imaginary += windowed*sin(angle)
                }
                spectrum.append(sqrt(real*real+imaginary*imaginary))
            }
            for mel in 0..<128 {
                var energy = 0.0
                for bin in 0...256 {
                    let frequency = Double(bin)*16000/512
                    let up = (frequency-points[mel])/(points[mel+1]-points[mel])
                    let down = (points[mel+2]-frequency)/(points[mel+2]-points[mel+1])
                    energy += spectrum[bin]*max(0,min(up,down))
                }
                expected.append(actual.mask[frame] ? Float(log(energy+0.001)) : 0)
            }
        }
        let metric = try GemmaAudioParity.compare(name: "DFT", actual: actual.features, expected: MLXArray(expected).reshaped(actual.features.shape), absolute: 0.00001, relative: 0.000001)
        print("Gemma frontend independent DFT: max_abs=\(metric.maximumAbsoluteError) rms=\(metric.rootMeanSquareError)")
        #expect(metric.violations == 0)
    }
    @Test func parityComparatorRejectsBadResults() throws {
        let result = try GemmaAudioParity.compare(name: "mismatch", actual: MLXArray([Float(1),2]), expected: MLXArray([Float(1),3]), absolute: 0.01, relative: 0)
        #expect(result.violations == 1)
        #expect(throws: GemmaAudioError.self) { try GemmaAudioParity.compare(name: "nan", actual: MLXArray([Float.nan]), expected: MLXArray([Float(0)]), absolute: 1, relative: 1) }
        #expect(throws: GemmaAudioError.self) { try GemmaAudioParity.compare(name: "shape", actual: MLXArray([Float(1)]), expected: MLXArray([Float(1),2]), absolute: 1, relative: 1) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_GEMMA_AUDIO_SMOKE_MODEL"] != nil))
    func savedEncoderSmoke() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUESLI_GEMMA_AUDIO_SMOKE_MODEL"]!)
        // Existing verified E4B artifact; this check is execution/shape/finite only.
        try GemmaAudioParity.verify(root.appendingPathComponent("model.safetensors"), sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff")
        try GemmaAudioParity.verify(root.appendingPathComponent("config.json"), sha256: "780ccb3a514a5f1ced161d383f948fc22eca9b84b752ca19494f625bd9bad7a6")
        struct Root: Decodable { let audio_config: GemmaAudioEncoder.Configuration }
        let c = try JSONDecoder().decode(Root.self, from: Data(contentsOf: root.appendingPathComponent("config.json"))).audio_config
        let w = try MLX.loadArrays(url: root.appendingPathComponent("model.safetensors")).filter { $0.key.hasPrefix("audio_tower.") }
        let encoder = try GemmaAudioEncoder(config: c, weights: w)
        let samples = (0..<16000).map { Float(0.2*sin(2*Double.pi*440*Double($0)/16000)) }
        let trace = try encoder.encode(GemmaAudioFeatures().extract(samples: samples, sampleRate: 16000))
        #expect(trace["encoder"]!.shape == [1,25,1536])
        #expect(trace.count == 9+c.num_hidden_layers)
        for (name,tensor) in trace { let finite = tensor.asType(.float32).asArray(Float.self).allSatisfy { $0.isFinite }; #expect(finite, "Nonfinite \(name)") }
        print("Saved E4B audio tower smoke completed: \(trace.count) stages. NOT reference parity.")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_GEMMA_AUDIO_E2B_MODEL"] != nil))
    func originalE2BEncoderSmoke() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["MUESLI_GEMMA_AUDIO_E2B_MODEL"]!)
        guard let hash = env["MUESLI_GEMMA_AUDIO_E2B_SHA256"], let configHash = env["MUESLI_GEMMA_AUDIO_E2B_CONFIG_SHA256"] else {
            throw GemmaAudioError.invalid("Explicit local E2B checkpoint/config hashes required")
        }
        try GemmaAudioParity.verify(root.appendingPathComponent("model.safetensors"), sha256: hash)
        try GemmaAudioParity.verify(root.appendingPathComponent("config.json"), sha256: configHash)
        struct Root: Decodable { let audio_config: GemmaAudioEncoder.Configuration }
        let c = try JSONDecoder().decode(Root.self, from: Data(contentsOf: root.appendingPathComponent("config.json"))).audio_config
        let w = try GemmaAudioParity.loadTower(model: root.appendingPathComponent("model.safetensors"), layout: .huggingFace)
        let encoder = try GemmaAudioEncoder(config: c, weights: w)
        let trace = try encoder.encode(GemmaAudioFeatures().extract(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000))
        #expect(trace["encoder"]!.shape == [1,25,1536])
        for (name,tensor) in trace { let finite = tensor.asType(.float32).asArray(Float.self).allSatisfy { $0.isFinite }; #expect(finite, "Nonfinite \(name)") }
        print("Saved original E2B tower: \(w.count) tensors and \(trace.count) finite stages. NOT reference parity.")
    }
    @Test func backendControlDoesNotExcuseCorruption() throws {
        let expected = MLXArray([Float(1),3])
        let baseline = try GemmaAudioParity.compare(name: "layer0", actual: expected, expected: expected, absolute: 0, relative: 0)
        let corrupt = try GemmaAudioParity.compare(name: "layer0", actual: -expected, expected: expected, absolute: 0, relative: 0)
        #expect(abs(corrupt.relativeL2Error - 2) < 0.000001)
        #expect(abs(corrupt.cosineSimilarity + 1) < 0.000001)
        #expect(!GemmaAudioParity.assessBF16BackendControl(native: corrupt, baseline: baseline).passed)
        // A broken original control cannot expand the gate without bound.
        #expect(!GemmaAudioParity.assessBF16BackendControl(native: baseline, baseline: corrupt).passed)
        let mask = try GemmaAudioParity.compare(name: "encoder_mask", actual: MLXArray([true,false]), expected: MLXArray([true,true]), absolute: 0, relative: 0)
        #expect(!GemmaAudioParity.assessBF16BackendControl(native: mask, baseline: mask).passed)
    }
    @Test func bf16BiasRoundsAfterAddition() {
        let x = MLXArray([Float(1), 1]).reshaped(1,2).asType(.bfloat16)
        let w = MLXArray([Float(1), 1.0/256]).reshaped(1,2).asType(.bfloat16)
        let bias = MLXArray([Float(-1)]).asType(.bfloat16)
        let actual = GemmaAudioEncoder.projectedWithBias(x, weight: w, bias: bias).item(Float.self)
        #expect(actual == 1.0/256)
        // Rounding the dot product first loses the entire small residual.
        #expect((matmul(x,w.T) + bias).item(Float.self) == 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_GEMMA_AUDIO_BF16_CONTROL"] != nil))
    func bf16OriginalBackendEnvelope() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bundle = env["MUESLI_GEMMA_AUDIO_REFERENCE"], let control = env["MUESLI_GEMMA_AUDIO_BF16_CONTROL"], let model = env["MUESLI_GEMMA_AUDIO_MODEL"] else {
            throw GemmaAudioError.invalid("BF16 reference, independent control and model are required")
        }
        let root = URL(fileURLWithPath: model), refs = URL(fileURLWithPath: bundle), controls = URL(fileURLWithPath: control)
        let fixtures = try FileManager.default.contentsOfDirectory(at: refs, includingPropertiesForKeys: nil).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }.sorted { $0.path < $1.path }
        #expect(!fixtures.isEmpty)
        for fixture in fixtures {
            let results = try autoreleasepool {
                try GemmaAudioParity.runBF16BackendControl(bundle: fixture, control: controls.appendingPathComponent(fixture.lastPathComponent), model: root.appendingPathComponent("model.safetensors"), config: root.appendingPathComponent("config.json"))
            }
            Memory.clearCache()
            print("BF16 backend control: \(fixture.lastPathComponent)")
            let data = try JSONEncoder().encode(results)
            if let path = env["MUESLI_GEMMA_AUDIO_METRICS_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(fixture.lastPathComponent + ".json"), options: .atomic)
            }
            for metric in results { print(String(decoding: try JSONEncoder().encode(metric), as: UTF8.self)) }
            for metric in results { #expect(metric.passed, "Native BF16 drift exceeds independent control at \(fixture.lastPathComponent)/\(metric.stage)") }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_GEMMA_AUDIO_OPERATIONS"] != nil))
    func originalOperationDiagnostics() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["MUESLI_GEMMA_AUDIO_MODEL"]!)
        struct Root: Decodable { let audio_config: GemmaAudioEncoder.Configuration }
        let c = try JSONDecoder().decode(Root.self, from: Data(contentsOf: root.appendingPathComponent("config.json"))).audio_config
        let w = try GemmaAudioParity.loadTower(model: root.appendingPathComponent("model.safetensors"), layout: .mlx)
        let encoder = try GemmaAudioEncoder(config: c, weights: w)
        let refs = try MLX.loadArrays(url: URL(fileURLWithPath: env["MUESLI_GEMMA_AUDIO_OPERATIONS"]!))
        let operationResults = try Device.withDefaultDevice(env["MUESLI_GEMMA_AUDIO_DIAGNOSTIC_CPU"] == "1" ? .cpu : .gpu) {
            try encoder.compareOperations(refs)
        }
        #expect(!operationResults.isEmpty)
        for result in operationResults {
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_GEMMA_AUDIO_REQUIRE_PARITY"] == "1" && ProcessInfo.processInfo.environment["MUESLI_GEMMA_AUDIO_BF16_CONTROL"] == nil))
    func trustedEncoderReferenceParity() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bundle = env["MUESLI_GEMMA_AUDIO_REFERENCE"], let model = env["MUESLI_GEMMA_AUDIO_MODEL"] else {
            throw GemmaAudioError.invalid("Trusted reference bundle/model missing; encoder parity has NOT passed")
        }
        let root = URL(fileURLWithPath: model)
        let reference = URL(fileURLWithPath: bundle)
        let bundles = FileManager.default.fileExists(atPath: reference.appendingPathComponent("manifest.json").path)
            ? [reference] : try FileManager.default.contentsOfDirectory(at: reference, includingPropertiesForKeys: nil)
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }.sorted { $0.path < $1.path }
        #expect(!bundles.isEmpty, "No reference fixtures found")
        for fixture in bundles {
            let results = try autoreleasepool {
                try GemmaAudioParity.run(bundle: fixture, model: root.appendingPathComponent("model.safetensors"), config: root.appendingPathComponent("config.json"))
            }
            Memory.clearCache()
            print("Reference fixture: \(fixture.lastPathComponent)")
            let data = try JSONEncoder().encode(results)
            if let path = env["MUESLI_GEMMA_AUDIO_METRICS_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(fixture.lastPathComponent + ".json"), options: .atomic)
            }
            for metric in results { print(String(decoding: try JSONEncoder().encode(metric), as: UTF8.self)) }
            for metric in results { #expect(metric.violations == 0, "Reference parity failure at \(fixture.lastPathComponent)/\(metric.stage)") }
        }
    }
}

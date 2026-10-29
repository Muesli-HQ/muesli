import Foundation
import CryptoKit
import MLX

/// External reference bundle contract. Expected tensors must come from an independent
/// trusted implementation, never from GemmaAudioEncoder's own trace.
public struct GemmaAudioParity {
    public enum WeightLayout: String, Codable { case mlx, huggingFace }
    /// Explicit format conversion only; never guess from an ambiguous shape.
    public static func loadTower(model: URL, layout: WeightLayout) throws -> [String: MLXArray] {
        let arrays = try MLX.loadArrays(url: model)
        var result: [String: MLXArray] = [:]
        let prefix = layout == .mlx ? "audio_tower." : "model.audio_tower."
        for (name, tensor) in arrays where name.hasPrefix(prefix) {
            let key = layout == .mlx ? name : String(name.dropFirst("model.".count))
            var value = tensor
            if layout == .huggingFace && key.hasSuffix(".conv.weight") {
                guard tensor.ndim == 4 else { throw GemmaAudioError.invalid("Expected HF Conv2D rank four") }
                value = tensor.transposed(0,2,3,1)
            } else if layout == .huggingFace && key.hasSuffix(".depthwise_conv1d.weight") {
                guard tensor.ndim == 3 else { throw GemmaAudioError.invalid("Expected HF Conv1D rank three") }
                value = tensor.transposed(0,2,1)
            }
            result[key] = value
        }
        guard !result.isEmpty else { throw GemmaAudioError.invalid("Model contains no audio tower in the declared layout") }
        return result
    }
    public struct Stage: Codable {
        public let name: String
        public let absoluteTolerance: Float
        public let relativeTolerance: Float
    }
    public struct Manifest: Codable {
        public let precision: GemmaAudioEncoder.Precision?
        public let weightLayout: WeightLayout
        public let producer: String
        public let referenceCommit: String
        public let modelSHA256: String
        public let configSHA256: String
        public let tensorsSHA256: String
        public let featureConfiguration: GemmaAudioFeatures.Configuration
        public let sampleRate: Int
        public let stages: [Stage]
    }
    public struct Metric: Codable {
        public let stage: String
        public let maximumAbsoluteError: Float
        public let rootMeanSquareError: Float
        public let relativeL2Error: Float
        public let cosineSimilarity: Float
        public let violations: Int
        public let count: Int
    }
    public static func sha256(_ url: URL) throws -> String {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var hash = SHA256()
        while let data = try f.read(upToCount: 4*1024*1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func verify(_ url: URL, sha256 expected: String) throws {
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }), try sha256(url) == expected.lowercased() else {
            throw GemmaAudioError.invalid("SHA-256 mismatch for \(url.lastPathComponent)")
        }
    }
    public static func compare(name: String, actual: MLXArray, expected: MLXArray, absolute: Float, relative: Float) throws -> Metric {
        guard actual.shape == expected.shape, absolute.isFinite, relative.isFinite, absolute >= 0, relative >= 0,
              actual.size > 0 else { throw GemmaAudioError.invalid("Invalid shape/tolerance for \(name)") }
        let a = actual.asType(.float32).asArray(Float.self), b = expected.asType(.float32).asArray(Float.self)
        guard a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { throw GemmaAudioError.invalid("Nonfinite values in \(name)") }
        var maxError: Float = 0, squared: Double = 0, referenceSquared: Double = 0, actualSquared: Double = 0, dot: Double = 0, violations = 0
        for (x,y) in zip(a,b) {
            referenceSquared += Double(y)*Double(y); actualSquared += Double(x)*Double(x); dot += Double(x)*Double(y)
            let error = abs(x-y); maxError = max(maxError,error); squared += Double(error)*Double(error)
            if error > absolute + relative*abs(y) { violations += 1 }
        }
        return Metric(stage: name, maximumAbsoluteError: maxError, rootMeanSquareError: Float(sqrt(squared/Double(a.count))), relativeL2Error: Float(sqrt(squared / max(referenceSquared, 1e-24))), cosineSimilarity: (actualSquared == 0 || referenceSquared == 0) ? (squared == 0 ? 1 : 0) : Float(dot / sqrt(actualSquared * referenceSquared)), violations: violations, count: a.count)
    }
    public struct BackendControlMetric: Codable {
        public let stage: String
        public let native: Metric
        public let originalCPUvsGPU: Metric
        public let relativeL2Limit: Float
        public let passed: Bool
    }
    /// A separate cross-backend BF16 diagnostic; never changes the strict elementwise result.
    /// Budgets use only the original CPU/GPU pair, not the native result being evaluated.
    public static func runBF16BackendControl(bundle: URL, control: URL, model: URL, config: URL) throws -> [BackendControlMetric] {
        let decode = JSONDecoder()
        let manifest = try decode.decode(Manifest.self, from: Data(contentsOf: bundle.appendingPathComponent("manifest.json")))
        let other = try decode.decode(Manifest.self, from: Data(contentsOf: control.appendingPathComponent("manifest.json")))
        guard (manifest.precision ?? .checkpoint) == .checkpoint,
              (other.precision ?? .checkpoint) == .checkpoint,
              manifest.modelSHA256 == other.modelSHA256, manifest.configSHA256 == other.configSHA256,
              manifest.referenceCommit == other.referenceCommit, manifest.weightLayout == other.weightLayout,
              manifest.sampleRate == other.sampleRate, manifest.featureConfiguration == other.featureConfiguration,
              manifest.stages.count == other.stages.count,
              manifest.producer.lowercased().contains(", cpu "), other.producer.lowercased().contains(", mps "),
              Set(manifest.stages.map(\.name)) == Set(other.stages.map(\.name)) else {
            throw GemmaAudioError.invalid("BF16 control must use the same checkpoint and original implementation on CPU and MPS")
        }
        let results = try run(bundle: bundle, model: model, config: config)
        let controlURL = control.appendingPathComponent("reference.safetensors")
        try verify(controlURL, sha256: other.tensorsSHA256)
        let primary = try MLX.loadArrays(url: bundle.appendingPathComponent("reference.safetensors"))
        let secondary = try MLX.loadArrays(url: controlURL)
        guard Set(primary.keys) == Set(secondary.keys),
              try compare(name: "samples", actual: primary["samples"]!, expected: secondary["samples"]!, absolute: 0, relative: 0).violations == 0 else {
            throw GemmaAudioError.invalid("BF16 control fixtures differ")
        }
        return try results.map { metric in
            let mask = metric.stage.hasSuffix("_mask"), mel = metric.stage == "mel"
            let baseline = try compare(name: metric.stage, actual: secondary[metric.stage]!, expected: primary[metric.stage]!, absolute: mask ? 0 : (mel ? 0.00001 : 0.02), relative: mask ? 0 : (mel ? 0.000001 : 0.02))
            return assessBF16BackendControl(native: metric, baseline: baseline)
        }
    }
    static func assessBF16BackendControl(native metric: Metric, baseline: Metric) -> BackendControlMetric {
        let exact = metric.stage.hasSuffix("_mask") || metric.stage == "mel"
        // This budget depends only on independent reference runs, with an upper cap.
        let limit: Float = min(0.1, max(0.01, 1.5 * baseline.relativeL2Error))
        let passed = exact ? (metric.violations == 0 && baseline.violations == 0)
            : (baseline.relativeL2Error <= 0.1 && metric.relativeL2Error <= limit && metric.cosineSimilarity >= 0.995)
        return BackendControlMetric(stage: metric.stage, native: metric, originalCPUvsGPU: baseline, relativeL2Limit: limit, passed: passed)
    }
    /// Strictly compare all boundaries; returns failure metrics without erasing them.
    public static func run(bundle: URL, model: URL, config: URL) throws -> [Metric] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: bundle.appendingPathComponent("manifest.json")))
        guard !manifest.producer.isEmpty, manifest.referenceCommit.count == 40, manifest.referenceCommit.allSatisfy({ $0.isHexDigit }) else {
            throw GemmaAudioError.invalid("Reference producer and full source revision are required")
        }
        try verify(model, sha256: manifest.modelSHA256); try verify(config, sha256: manifest.configSHA256)
        let tensorURL = bundle.appendingPathComponent("reference.safetensors")
        try verify(tensorURL, sha256: manifest.tensorsSHA256)
        struct Root: Decodable { let audio_config: GemmaAudioEncoder.Configuration }
        let c = try JSONDecoder().decode(Root.self, from: Data(contentsOf: config)).audio_config
        let required = Set(["mel","mel_mask","subsample0","subsample0_mask","subsample1","subsample1_mask","input_projection","encoder","encoder_mask"] + (0..<c.num_hidden_layers).map { "layer\($0)" })
        guard Set(manifest.stages.map(\.name)) == required, manifest.stages.count == required.count else { throw GemmaAudioError.invalid("Reference bundle must cover every encoder boundary exactly once") }
        let references = try MLX.loadArrays(url: tensorURL)
        guard let samples = references["samples"], samples.ndim == 1, Set(references.keys) == required.union(["samples"]) else { throw GemmaAudioError.invalid("Missing reference tensors or mono samples") }
        let weights = try loadTower(model: model, layout: manifest.weightLayout)
        let encoder = try GemmaAudioEncoder(config: c, weights: weights, precision: manifest.precision ?? .checkpoint)
        let frontend = try GemmaAudioFeatures(configuration: manifest.featureConfiguration)
        let trace = try encoder.encode(frontend.extract(samples: samples.asArray(Float.self), sampleRate: manifest.sampleRate))
        return try manifest.stages.map { stage in
            let isMask = stage.name.hasSuffix("_mask")
            guard !isMask || (stage.absoluteTolerance == 0 && stage.relativeTolerance == 0) else { throw GemmaAudioError.invalid("Masks require exact equality") }
            return try compare(name: stage.name, actual: trace[stage.name]!, expected: references[stage.name]!, absolute: stage.absoluteTolerance, relative: stage.relativeTolerance)
        }
    }
}

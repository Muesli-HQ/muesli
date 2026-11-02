// Evaluation-only, batch-one E-series audio tower. Not a production backend.
// Ported from the Apache-2.0 Hugging Face Gemma4 reference; see README.md.
import Foundation
import MLX

public struct GemmaAudioEncoder {
    public struct Configuration: Decodable, Sendable {
        public let hidden_size: Int
        public let num_hidden_layers: Int
        public let num_attention_heads: Int
        public let attention_chunk_size: Int
        public let attention_context_left: Int
        public let attention_context_right: Int
        public let attention_logit_cap: Float
        public let attention_invalid_logits_value: Float
        public let conv_kernel_size: Int
        public let output_proj_dims: Int
        public let subsampling_conv_channels: [Int]
        public let rms_norm_eps: Float
        public let residual_weight: Float
        public let gradient_clipping: Float
        public let hidden_act: String
        public let use_clipped_linears: Bool
    }
    public enum Precision: String, Codable { case checkpoint, float32 }
    public let config: Configuration
    private let weights: [String: MLXArray]
    /// Supply only the verified checkpoint's audio_tower tensors. Mixed quantization
    /// in embed_audio belongs to the later projector, not this BF16 encoder.
    public init(config: Configuration, weights: [String: MLXArray], precision: Precision = .checkpoint) throws {
        guard config.hidden_size > 0, config.hidden_size % 2 == 0, config.num_attention_heads > 0,
              config.hidden_size % config.num_attention_heads == 0, config.num_hidden_layers > 0,
              config.attention_chunk_size > 0, config.attention_context_left > 0,
              config.attention_context_right >= 0, config.subsampling_conv_channels.count == 2,
              config.subsampling_conv_channels.allSatisfy({ $0 > 0 }),
              config.conv_kernel_size > 0, config.output_proj_dims > 0,
              config.hidden_act == "silu", config.use_clipped_linears,
              config.rms_norm_eps > 0, config.attention_logit_cap > 0,
              config.gradient_clipping > 0 else { throw GemmaAudioError.invalid("Unsupported audio encoder configuration") }
        self.config = config
        var expected: [String: [Int]] = [:]
        let d = config.hidden_size
        func tensor(_ key: String, _ shape: [Int]) { expected["audio_tower." + key] = shape }
        func norm(_ key: String, _ width: Int) { tensor(key + ".weight", [width]) }
        func linear(_ key: String, _ input: Int, _ output: Int, clipped: Bool = true) {
            tensor(key + (clipped ? ".linear.weight" : ".weight"), [output, input])
            if clipped { for name in ["input_min", "input_max", "output_min", "output_max"] { tensor(key + "." + name, []) } }
        }
        var channels = 1
        for (index, output) in config.subsampling_conv_channels.enumerated() {
            let p = "subsample_conv_projection.layer\(index)"
            tensor(p + ".conv.weight", [output, 3, 3, channels]); norm(p + ".norm", output); channels = output
        }
        linear("subsample_conv_projection.input_proj_linear", 32 * channels, d, clipped: false)
        for i in 0..<config.num_hidden_layers {
            let p = "layers.\(i)"
            for ff in ["feed_forward1", "feed_forward2"] {
                linear(p + "." + ff + ".ffw_layer_1", d, d*4)
                linear(p + "." + ff + ".ffw_layer_2", d*4, d)
                norm(p + "." + ff + ".pre_layer_norm", d); norm(p + "." + ff + ".post_layer_norm", d)
            }
            for name in ["q_proj", "k_proj", "v_proj", "post"] { linear(p + ".self_attn." + name, d, d) }
            linear(p + ".self_attn.relative_k_proj", d, d, clipped: false)
            tensor(p + ".self_attn.per_dim_scale", [d/config.num_attention_heads])
            linear(p + ".lconv1d.linear_start", d, d*2); linear(p + ".lconv1d.linear_end", d, d)
            tensor(p + ".lconv1d.depthwise_conv1d.weight", [d, config.conv_kernel_size, 1])
            for name in ["pre_layer_norm", "conv_norm"] { norm(p + ".lconv1d." + name, d) }
            for name in ["norm_pre_attn", "norm_post_attn", "norm_out"] { norm(p + "." + name, d) }
        }
        linear("output_proj", d, config.output_proj_dims, clipped: false)
        tensor("output_proj.bias", [config.output_proj_dims])
        guard Set(weights.keys) == Set(expected.keys) else {
            throw GemmaAudioError.invalid("Encoder tensor set mismatch: missing \(Set(expected.keys).subtracting(weights.keys).sorted()); extra \(Set(weights.keys).subtracting(expected.keys).sorted())")
        }
        for (name, shape) in expected {
            guard let value = weights[name], value.shape == shape,
                  (value.dtype == .bfloat16 || (name.contains("norm") && name.hasSuffix(".weight") && value.dtype == .float32)) else {
                throw GemmaAudioError.invalid("Wrong shape/dtype for \(name); expected \(shape), BF16 (or F32 normalization weights)")
            }
        }
        self.weights = precision == .float32 ? weights.mapValues { $0.asType(.float32) } : weights
    }
    private func w(_ key: String) -> MLXArray { weights["audio_tower." + key]! }
    private func linear(_ x: MLXArray, _ key: String) -> MLXArray { matmul(x, w(key + ".weight").T) }
    /// Match a fused Linear bias: accumulate and add bias before rounding to BF16.
    static func projectedWithBias(_ x: MLXArray, weight: MLXArray, bias: MLXArray) -> MLXArray {
        (matmul(x.asType(.float32), weight.asType(.float32).T) + bias.asType(.float32)).asType(x.dtype)
    }
    private func clipped(_ x: MLXArray, _ key: String) -> MLXArray {
        let input = minimum(maximum(x, w(key + ".input_min")), w(key + ".input_max"))
        let output = linear(input, key + ".linear")
        return minimum(maximum(output, w(key + ".output_min")), w(key + ".output_max"))
    }
    private func rms(_ x: MLXArray, _ key: String) -> MLXArray {
        let f = x.asType(.float32)
        return (f * pow(mean(f*f, axis: -1, keepDims: true) + config.rms_norm_eps, -0.5) * w(key + ".weight").asType(.float32)).asType(x.dtype)
    }
    private func clip(_ x: MLXArray) -> MLXArray { minimum(maximum(x, -config.gradient_clipping), config.gradient_clipping) }
    private func silu(_ x: MLXArray) -> MLXArray {
        // PyTorch SiLU/GLU round once, after the activation and product.
        let f = x.asType(.float32)
        return (f * sigmoid(f)).asType(x.dtype)
    }
    private func feedForward(_ x: MLXArray, _ p: String) -> MLXArray {
        let h = rms(clip(x), p + ".pre_layer_norm")
        let z = clipped(silu(clipped(h, p + ".ffw_layer_1")), p + ".ffw_layer_2")
        return x + rms(clip(z), p + ".post_layer_norm") * config.residual_weight
    }
    private func convolution(_ x: MLXArray, _ p: String) -> MLXArray {
        let h = clipped(rms(x, p + ".pre_layer_norm"), p + ".linear_start")
        let d = config.hidden_size
        let gated = (h[0..., 0..., ..<d].asType(.float32) * sigmoid(h[0..., 0..., d...].asType(.float32))).asType(h.dtype)
        let padded = concatenated([MLXArray.zeros([1,config.conv_kernel_size-1,d], dtype: x.dtype), gated], axis: 1)
        let conv = conv1d(padded, w(p + ".depthwise_conv1d.weight"), groups: d)
        return x + clipped(silu(rms(clip(conv), p + ".conv_norm")), p + ".linear_end")
    }
    private func attention(_ x: MLXArray, mask: [Bool], prefix p: String) -> MLXArray {
        let c = config, t = x.dim(1), heads = c.num_attention_heads, d = c.hidden_size / c.num_attention_heads
        let chunk = c.attention_chunk_size, past = c.attention_context_left-1
        let context = chunk+past+c.attention_context_right, blocks = (t+chunk-1)/chunk
        let qScale = Float(pow(Double(d), -0.5) / log(2.0))
        let kScale = Float(log(1+exp(1.0))/log(2.0))
        var q = clipped(x, p + ".q_proj").asType(.float32).reshaped(t,heads,d)
        q = q * qScale * log(1 + exp(w(p + ".per_dim_scale").asType(.float32))).asType(x.dtype).asType(.float32)
        let k = clipped(x, p + ".k_proj").asType(.float32).reshaped(t,heads,d) * kScale
        let v = clipped(x, p + ".v_proj").asType(.float32).reshaped(t,heads,d)
        q = concatenated([q, MLXArray.zeros([blocks*chunk-t,heads,d])], axis: 0)
        let queries = q.reshaped(blocks,chunk,heads,d).transposed(2,0,1,3)
        var indices = [Int32](), validity = [Float](), invalid = [Bool]()
        for b in 0..<blocks {
            for j in 0..<context {
                let index = b*chunk-past+j
                indices.append(Int32(max(0,min(t-1,index))))
                validity.append(index >= 0 && index < t ? 1 : 0)
            }
            for i in 0..<chunk {
                let qi = b*chunk+i
                for j in 0..<context {
                    let ki = b*chunk-past+j
                    // The reference masks keys, not valid-range query positions.
                    // Its sliding-window distances are strict (<), not inclusive.
                    invalid.append(qi >= t || ki < 0 || ki >= t || !mask[max(0,min(ki,t-1))] || ki <= qi-past || (ki > qi && ki >= qi+c.attention_context_right))
                }
            }
        }
        let valid = MLXArray(validity).reshaped(blocks,context,1,1)
        let keys = (take(k, MLXArray(indices), axis: 0).reshaped(blocks,context,heads,d) * valid).transposed(2,0,3,1)
        let values = (take(v, MLXArray(indices), axis: 0).reshaped(blocks,context,heads,d) * valid).transposed(2,0,1,3)
        let positionCount = context/2+1, half = c.hidden_size/2
        var positions = [Float]()
        for pos in stride(from: context/2, through: 0, by: -1) {
            let scaled = (0..<half).map { Float(pos) * exp(Float($0) * -Float(log(10000.0)/Double(max(half-1,1)))) }
            positions += scaled.map { sin($0) } + scaled.map { cos($0) }
        }
        let relative = linear(MLXArray(positions).reshaped(positionCount,c.hidden_size).asType(x.dtype), p + ".relative_k_proj").asType(.float32).reshaped(positionCount,heads,d).transposed(1,2,0)
        let bd = matmul(queries.reshaped(heads,blocks*chunk,d), relative).reshaped(heads,blocks,chunk,positionCount)
        let padded = concatenated([bd, MLXArray.zeros([heads,blocks,chunk,context+1-positionCount])], axis: -1)
        let shifted = padded.reshaped(heads,blocks,chunk*(context+1))[0...,0...,..<(chunk*context)].reshaped(heads,blocks,chunk,context)
        let logits = tanh((matmul(queries,keys)+shifted)/c.attention_logit_cap)*c.attention_logit_cap
        let masked = MLX.where(MLXArray(invalid).reshaped(1,blocks,chunk,context), MLXArray(c.attention_invalid_logits_value), logits)
        let output = matmul(softmax(masked, axis: -1, precise: true),values).transposed(1,2,0,3).reshaped(1,blocks*chunk,c.hidden_size)[0...,..<t,0...]
        return clipped(output.asType(x.dtype), p + ".post")
    }
    /// Diagnostic isolation: apply a sub-operation to the ORIGINAL implementation's input.
    /// This prevents earlier-layer drift from hiding the first differing operation.
    public func compareOperations(_ references: [String: MLXArray]) throws -> [GemmaAudioParity.Metric] {
        var metrics = [GemmaAudioParity.Metric]()
        for entry in references.keys.filter({ $0.hasSuffix("/input") }).sorted() {
            let name = String(entry.dropLast(6)), input = references[entry]!
            guard let expected = references[name + "/output"] else { continue }
            let actual: MLXArray
            if name.hasSuffix("feed_forward1") || name.hasSuffix("feed_forward2") { actual = feedForward(input, name) }
            else if name.hasSuffix("lconv1d") { actual = convolution(input, name) }
            else if name.hasSuffix("self_attn") { actual = attention(input, mask: references["mask"]!.asArray(Bool.self), prefix: name) }
            else if name.contains("norm") { actual = rms(input, name) }
            else if weights["audio_tower." + name + ".input_min"] != nil { actual = clipped(input, name) }
            else if name.hasSuffix("linear") || name.hasSuffix("relative_k_proj") { actual = linear(input, name) }
            else { continue }
            metrics.append(try GemmaAudioParity.compare(name: name, actual: actual, expected: expected, absolute: 0, relative: 0))
        }
        return metrics
    }
    /// Exposes every boundary needed for externally supplied parity tensors.
    public func encode(_ input: GemmaAudioFeatures.Output, retainTrace: Bool = true) throws -> [String: MLXArray] {
        guard input.features.shape == [1,input.mask.count,128], !input.mask.isEmpty else { throw GemmaAudioError.invalid("Expected [1,T,128] mel tensor and T validity bits") }
        var trace: [String: MLXArray] = retainTrace ? ["mel": input.features, "mel_mask": MLXArray(input.mask)] : [:]
        var mask = input.mask
        var x = input.features.expandedDimensions(axis: -1).asType(w("subsample_conv_projection.layer0.conv.weight").dtype)
        for index in 0..<2 {
            let p = "subsample_conv_projection.layer\(index)"
            x = x * MLXArray(mask).asType(x.dtype).reshaped(1,mask.count,1,1)
            x = conv2d(x, w(p + ".conv.weight"), stride: 2, padding: 1)
            let f = x.asType(.float32), avg = mean(x.asType(.float32), axis: -1, keepDims: true)
            let variance = mean((f-avg)*(f-avg), axis: -1, keepDims: true)
            x = maximum(((f-avg)*pow(variance+config.rms_norm_eps,-0.5)*w(p + ".norm.weight").asType(.float32)).asType(x.dtype), 0)
            mask = stride(from: 0, to: mask.count, by: 2).map { mask[$0] }
            if retainTrace { trace["subsample\(index)"] = x; trace["subsample\(index)_mask"] = MLXArray(mask) }
        }
        x = linear(x.reshaped(1,x.dim(1),-1), "subsample_conv_projection.input_proj_linear")
        if retainTrace { trace["input_projection"] = x }
        for i in 0..<config.num_hidden_layers {
            let p = "layers.\(i)"
            x = feedForward(x, p + ".feed_forward1")
            x = x + rms(clip(attention(rms(clip(x), p + ".norm_pre_attn"), mask: mask, prefix: p + ".self_attn")), p + ".norm_post_attn")
            x = convolution(x, p + ".lconv1d")
            x = rms(clip(feedForward(x, p + ".feed_forward2")), p + ".norm_out")
            eval(x)
            if retainTrace { trace["layer\(i)"] = x }
        }
        trace["encoder"] = Self.projectedWithBias(x, weight: w("output_proj.weight"), bias: w("output_proj.bias"))
        trace["encoder_mask"] = MLXArray(mask)
        return trace
    }
}

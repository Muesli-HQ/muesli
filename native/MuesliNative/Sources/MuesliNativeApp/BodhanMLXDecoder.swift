import Accelerate
import Foundation
import CoreML
import MLX

/// Native hybrid decoder. Owned and called serially by BodhanTranscriber.
@available(macOS 15, *)
final class BodhanMLXDecoder {
    let weightPrecision: String
    private let w: [String: MLXArray]
    private typealias KV = (MLXArray, MLXArray)
    init(root: URL, weightPrecision: String = "fp16") throws {
        self.weightPrecision = weightPrecision
        let quantized = weightPrecision == "int8"
        let suffix = quantized ? "mlx-decoder-int8" : "mlx-decoder"
        let candidates = ["variants/" + suffix, "experiments/" + suffix]
        guard let directory = candidates.map({ root.appendingPathComponent($0) }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("decoder.safetensors").path)
        }) else {
            throw NSError(domain: "BodhanASR", code: 8, userInfo: [NSLocalizedDescriptionKey: "The MLX decoder weights are missing."])
        }
        w = try loadArrays(url: directory.appendingPathComponent("decoder.safetensors"))
        guard w.count == (quantized ? 1114 : 632), w["embedding.token_embedding.weight"]?.shape == [7152,1024] else {
            throw NSError(domain: "BodhanASR", code: 9, userInfo: [NSLocalizedDescriptionKey: "Incompatible Bodhan MLX decoder weights."])
        }
        if quantized {
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
            let q = config?["quantization"] as? [String: Any]
            guard q?["bits"] as? Int == 8, q?["group_size"] as? Int == 64,
                  q?["mode"] as? String == "affine" else {
                throw NSError(domain: "BodhanASR", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unsupported Bodhan INT8 quantization configuration."])
            }
            var projections: [(String, Int, Int)] = [("lm_head", 7152, 1024)]
            for i in 0..<24 {
                for layer in ["first_sub_layer", "second_sub_layer"] {
                    for name in ["key_net", "value_net", "query_net", "out_projection"] {
                        projections.append(("layers.\(i).\(layer).\(name)", 1024, 1024))
                    }
                }
                projections.append(("layers.\(i).third_sub_layer.dense_in", 4096, 1024))
                projections.append(("layers.\(i).third_sub_layer.dense_out", 1024, 4096))
            }
            for (prefix, output, input) in projections {
                guard w[prefix + ".weight"]?.dtype == .uint32,
                      w[prefix + ".weight"]?.shape == [output, input / 4],
                      w[prefix + ".scales"]?.shape == [output, input / 64],
                      w[prefix + ".biases"]?.shape == [output, input / 64],
                      w[prefix + ".bias"]?.shape == [output] else {
                    throw NSError(domain: "BodhanASR", code: 12, userInfo: [NSLocalizedDescriptionKey: "Incompatible Bodhan INT8 projection: \(prefix)."])
                }
            }
        }
        eval(Array(w.values))
    }
    private func linear(_ x: MLXArray, _ p: String) -> MLXArray {
        if weightPrecision == "int8" {
            return quantizedMM(x, w[p + ".weight"]!, scales: w[p + ".scales"]!,
                               biases: w[p + ".biases"]!, transpose: true, groupSize: 64,
                               bits: 8, mode: .affine) + w[p + ".bias"]!
        }
        return addMM(w[p + ".bias"]!, x, w[p + ".weight"]!.T)
    }
    private func norm(_ x: MLXArray, _ p: String) -> MLXArray {
        MLXFast.layerNorm(x, weight: w[p + ".weight"]!, bias: w[p + ".bias"]!, eps: 1e-5)
    }
    private func split(_ x: MLXArray) -> MLXArray {
        x.reshaped(x.dim(0), x.dim(1), 8, 128).transposed(0,2,1,3)
    }
    private func project(_ x: MLXArray, _ p: String) -> KV {
        (split(linear(x,p + ".key_net")) / Float(pow(128.0,0.25)), split(linear(x,p + ".value_net")))
    }
    private func attention(_ x: MLXArray, _ kv: KV, _ p: String, causal: Bool = false) -> MLXArray {
        let q = split(linear(x,p + ".query_net")) / Float(pow(128.0,0.25))
        let a = MLXFast.scaledDotProductAttention(queries: q, keys: kv.0, values: kv.1, scale: 1,
                                                  mask: causal ? .causal : .none)
        return linear(a.transposed(0,2,1,3).reshaped(x.dim(0),x.dim(1),1024), p + ".out_projection")
    }
    private func step(_ ids: [Int], _ position: Int, _ cross: [KV], _ cache: [KV]?) -> (MLXArray,[KV]) {
        let indices = MLXArray(ids,[1,ids.count])
        let positions = MLXArray(Array(position..<position+ids.count))
        var x = w["embedding.token_embedding.weight"]![indices] + w["embedding.position_embedding.pos_enc"]![positions].expandedDimensions(axis: 0)
        x = norm(x,"embedding.layer_norm")
        var next: [KV] = []
        for i in 0..<24 {
            let p = "layers.\(i)"
            let n = norm(x,p + ".layer_norm_1")
            var (k,v) = project(n,p + ".first_sub_layer")
            if let cache { k = concatenated([cache[i].0,k],axis:2); v = concatenated([cache[i].1,v],axis:2) }
            next.append((k,v))
            x = x + attention(n,(k,v),p + ".first_sub_layer",causal:ids.count > 1)
            x = x + attention(norm(x,p + ".layer_norm_2"),cross[i],p + ".second_sub_layer")
            x = x + linear(maximum(linear(norm(x,p + ".layer_norm_3"),p + ".third_sub_layer.dense_in"),0),p + ".third_sub_layer.dense_out")
        }
        return (linear(norm(x,"final_layer_norm"),"lm_head"),next)
    }
    func generate(acoustic: MLMultiArray, length: Int, tokenizer: BodhanCoreML.Tokenizer,
                  language: String?, mixed: Bool, frontendSeconds: Double, encoderSeconds: Double,
                  encoderPolicy: String) throws -> BodhanCoreML.Result {
        let crossStart = Date()
        // Respect Core ML strides and trim padding before attention.
        guard length > 0, acoustic.shape.count == 3, acoustic.shape[2].intValue == 1024,
              length <= acoustic.shape[1].intValue else {
            throw NSError(domain: "BodhanASR", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid encoder output dimensions."])
        }
        let transferTrace = BodhanProfiling.begin("EncoderOutputToMLX")
        var values = [Float](repeating:0,count:length*1024)
        if acoustic.strides[2].intValue == 1 && acoustic.strides[1].intValue == 1024 && acoustic.dataType == .float16 {
            values.withUnsafeMutableBufferPointer { buffer in
                var source = vImage_Buffer(data: acoustic.dataPointer, height: 1, width: vImagePixelCount(buffer.count), rowBytes: buffer.count*2)
                var target = vImage_Buffer(data: buffer.baseAddress!, height: 1, width: vImagePixelCount(buffer.count), rowBytes: buffer.count*4)
                vImageConvert_Planar16FtoPlanarF(&source, &target, vImage_Flags(kvImageNoFlags))
            }
        } else if acoustic.strides[2].intValue == 1 && acoustic.strides[1].intValue == 1024 && acoustic.dataType == .float32 {
            values = Array(UnsafeBufferPointer(start: acoustic.dataPointer.assumingMemoryBound(to: Float.self), count: values.count))
        } else {
            for t in 0..<length { for d in 0..<1024 {
                values[t*1024+d] = acoustic[[0,NSNumber(value:t),NSNumber(value:d)]].floatValue
            } }
        }
        let encoded = MLXArray(values,[1,length,1024]).asType(.float16)
        eval(encoded)
        BodhanProfiling.end("EncoderOutputToMLX", transferTrace)
        let transferSeconds = Date().timeIntervalSince(crossStart)
        let projectionStart = Date()
        let crossTrace = BodhanProfiling.begin("MLXCrossProjection")
        let cross = (0..<24).map { project(encoded,"layers.\($0).second_sub_layer") }
        eval(cross.flatMap { [$0.0,$0.1] })
        BodhanProfiling.end("MLXCrossProjection", crossTrace)
        let crossSeconds = Date().timeIntervalSince(projectionStart)
        let start = Date()
        let decodeTrace = BodhanProfiling.begin("MLXDecode")
        defer { BodhanProfiling.end("MLXDecode", decodeTrace) }
        var chosen = language
        if chosen == nil {
            let (logits,_) = step(Array(tokenizer.prompts["hi"]!.prefix(3)),0,cross,nil)
            let scores = logits[0,2]; eval(scores)
            chosen = tokenizer.prompts.keys.sorted().max { scores[tokenizer.prompts[$0]![3]].item(Float.self) < scores[tokenizer.prompts[$1]![3]].item(Float.self) }
        }
        guard let chosen, let prompt = (mixed ? tokenizer.mixed_prompts : tokenizer.prompts)?[chosen] else {
            throw NSError(domain:"BodhanASR",code:7,userInfo:[NSLocalizedDescriptionKey:"Missing language prompt."])
        }
        var ids = prompt, position = 0, tokens: [Int] = []
        var cache: [KV]? = nil
        var ended = false
        for _ in 0..<256 {
            if Task<Never,Never>.isCancelled { throw CancellationError() }
            let (logits,nextCache) = BodhanProfiling.measure("MLXStepGraph") { step(ids,position,cross,cache) }
            let next = argMax(logits[0,ids.count-1],axis:-1)
            BodhanProfiling.measure("MLXStepEvaluate") { eval([next] + nextCache.flatMap { [$0.0,$0.1] }) }
            let token = next.item(Int.self)
            cache = nextCache; position += ids.count
            if token == tokenizer.eos_id { ended = true; break }
            tokens.append(token); ids = [token]
        }
        guard ended else { throw NSError(domain:"BodhanASR",code:6,userInfo:[NSLocalizedDescriptionKey:"Bodhan reached its token limit. Try a shorter recording."]) }
        let seconds = Date().timeIntervalSince(start)
        let text = tokens.filter { $0 >= tokenizer.special_count }.map { tokenizer.pieces[$0] }.joined().replacingOccurrences(of:"▁",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        var result = BodhanCoreML.Result(text:text,language:chosen,tokens:tokens.count,endedWithEOS:true,frontendSeconds:frontendSeconds,
                     encoderSeconds:encoderSeconds,crossSeconds:crossSeconds,decodeSeconds:seconds,
                     predictionSeconds:seconds,selectionSeconds:0,encoderPolicy:encoderPolicy)
        result.decoderWeightPrecision = weightPrecision
        result.transferSeconds = transferSeconds
        return result
    }
}

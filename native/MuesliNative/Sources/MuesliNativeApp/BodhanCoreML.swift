import Accelerate
import CoreML
import Foundation
import Darwin

@available(macOS 15, *)
final class BodhanCoreML {
    static var weightPrecision: String {
        ProcessInfo.processInfo.environment["MUESLI_BODHAN_WEIGHT_PRECISION"]
            ?? UserDefaults.standard.string(forKey: "bodhanWeightPrecision") ?? "fp16"
    }
    static var decoderRuntime: String {
        ProcessInfo.processInfo.environment["MUESLI_BODHAN_DECODER_RUNTIME"]
            ?? UserDefaults.standard.string(forKey: "bodhanDecoderRuntime") ?? "coreml"
    }
    static var encoderShapePolicy: String {
        ProcessInfo.processInfo.environment["MUESLI_BODHAN_ENCODER_SHAPES"]
            ?? UserDefaults.standard.string(forKey: "bodhanEncoderShapePolicy") ?? "dynamic"
    }
    static var specializeEncoder: Bool {
        if let override = ProcessInfo.processInfo.environment["MUESLI_BODHAN_ENCODER_SPECIALIZE"] { return override == "1" }
        return UserDefaults.standard.bool(forKey: "bodhanEncoderSpecialize")
    }
    struct Tokenizer: Decodable {
        let pieces: [String]
        let special_count: Int
        let eos_id: Int
        let prompts: [String: [Int]]
        let mixed_prompts: [String: [Int]]?
    }
    struct Result: Codable {
        var encoderAsset: String = "coreml/encoder"
        var decoderWeightPrecision: String = "fp16"
        var encoderSpecialized: Bool = false
        var threadQoS: UInt32 = 0
        var thermalState: Int = 0
        var lowPowerMode: Bool = false
        var onMainThread: Bool = false
        var encoderInputFrames: Int = 0
        var encoderValidFrames: Int = 0
        var encoderShapePolicy: String = "dynamic"
        var transferSeconds: Double = 0
        let text: String
        let language: String
        let tokens: Int
        let endedWithEOS: Bool
        let frontendSeconds: Double
        let encoderSeconds: Double
        let crossSeconds: Double
        let decodeSeconds: Double
        let predictionSeconds: Double
        let selectionSeconds: Double
        let encoderPolicy: String
    }
    let encoderPolicy: String
    let encoderAsset: String
    let shapePolicy: String
    let encoderSpecialized: Bool
    let encoder: MLModel
    let cross: MLModel!
    let decoder: MLModel!
    let mlx: BodhanMLXDecoder?
    let frontend: BodhanFrontend
    let tokenizer: Tokenizer
    private var logitsScratch: [Float] = []

    init(root: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let precision = Self.weightPrecision
        guard ["fp16", "int8"].contains(precision), precision != "int8" || Self.decoderRuntime == "mlx" else {
            throw NSError(domain: "BodhanASR", code: 13, userInfo: [NSLocalizedDescriptionKey: "The full INT8 experiment requires the MLX decoder runtime."])
        }
        let selectedEncoderAsset = ProcessInfo.processInfo.environment["MUESLI_BODHAN_ENCODER_ASSET"].map { "coreml/" + $0 }
            ?? (precision == "int8" ? "experiments/coreml-int8/encoder" : "coreml/encoder")
        encoderAsset = selectedEncoderAsset
        let policy = ProcessInfo.processInfo.environment["MUESLI_BODHAN_ENCODER_COMPUTE"] ?? "gpu"
        encoderPolicy = policy
        shapePolicy = Self.encoderShapePolicy
        let specialize = Self.encoderShapePolicy == "buckets" && Self.specializeEncoder
        encoderSpecialized = specialize
        func load(_ name: String) throws -> MLModel {
            let selectedConfig = MLModelConfiguration()
            if name == "encoder" && specialize {
                // Both bucket shapes are explicitly warmed before dictation.
                selectedConfig.optimizationHints.reshapeFrequency = .infrequent
            }
            selectedConfig.computeUnits = name == "encoder" ? (policy == "ane" ? .cpuAndNeuralEngine : policy == "all" ? .all : computeUnits) : computeUnits
            let asset = ProcessInfo.processInfo.environment["MUESLI_BODHAN_" + name.uppercased() + "_ASSET"] ?? name
            let assetPath = name == "encoder" ? selectedEncoderAsset : "coreml/\(asset)"
            let compiled = root.appendingPathComponent("\(assetPath).mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let temp = try MLModel.compileModel(at: root.appendingPathComponent("\(assetPath).mlpackage"))
                try FileManager.default.moveItem(at: temp, to: compiled)
            }
            return try MLModel(contentsOf: compiled, configuration: selectedConfig)
        }
        encoder = try load("encoder")
        if Self.decoderRuntime == "mlx" {
            mlx = try BodhanMLXDecoder(root: root, weightPrecision: precision)
            cross = nil; decoder = nil
        } else {
            mlx = nil
            cross = try load("cross")
            decoder = try load("decoder")
        }
        frontend = try BodhanFrontend(constants: root.appendingPathComponent("native-assets/frontend.bin"))
        tokenizer = try JSONDecoder().decode(Tokenizer.self, from: Data(contentsOf: root.appendingPathComponent("native-assets/tokenizer.json")))
    }

    private func floats(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        values.withUnsafeBufferPointer { source in
            array.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: source.count)
        }
        return array
    }
    private func ints(_ values: [Int], _ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in values.indices { pointer[i] = Int32(values[i]) }
        return array
    }
    private func predict(_ model: MLModel, _ inputs: [String: MLMultiArray], state: MLState? = nil) throws -> MLFeatureProvider {
        let features = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        if let state { return try model.prediction(from: features, using: state) }
        return try model.prediction(from: features)
    }
    private func array(_ output: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let result = output.featureValue(for: name)?.multiArrayValue else {
            throw NSError(domain: "BodhanASR", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing model output \(name)."])
        }
        return result
    }
    private func argmaxLast(_ logits: MLMultiArray) -> Int {
        let last = logits.shape[1].intValue-1
        let base = last * logits.strides[1].intValue
        let stride = logits.strides[2].intValue
        if logits.dataType == .float16 && stride == 1 {
            if logitsScratch.count != tokenizer.pieces.count {
                logitsScratch = Array(repeating: 0, count: tokenizer.pieces.count)
            }
            return logitsScratch.withUnsafeMutableBufferPointer { buffer in
                var source = vImage_Buffer(data: logits.dataPointer.advanced(by: base * 2), height: 1,
                                           width: vImagePixelCount(buffer.count), rowBytes: buffer.count * 2)
                var target = vImage_Buffer(data: buffer.baseAddress!, height: 1,
                                           width: vImagePixelCount(buffer.count), rowBytes: buffer.count * 4)
                vImageConvert_Planar16FtoPlanarF(&source, &target, vImage_Flags(kvImageNoFlags))
                var value: Float = 0
                var index: vDSP_Length = 0
                vDSP_maxvi(buffer.baseAddress!, 1, &value, &index, vDSP_Length(buffer.count))
                return Int(index)
            }
        }
        if logits.dataType == .float32 && stride == 1 {
            var value: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(logits.dataPointer.assumingMemoryBound(to: Float.self) + base,
                       vDSP_Stride(stride), &value, &index, vDSP_Length(tokenizer.pieces.count))
            return Int(index)
        }
        var best = 0
        var score = -Float.infinity
        for token in 0..<tokenizer.pieces.count {
            let offset = base + token * stride
            let value: Float
            switch logits.dataType {
            case .float32: value = logits.dataPointer.assumingMemoryBound(to: Float.self)[offset]
            case .float16: value = Float(logits.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
            default: value = logits[[0, NSNumber(value:last), NSNumber(value:token)]].floatValue
            }
            if value > score { best = token; score = value }
        }
        return best
    }

    /// Reuse just two input shapes across utterances; warm both before the first dictation.
    func warmupEncoderShapes() throws {
        guard shapePolicy == "buckets" else { return }
        for frames in [1501, 3001] {
            if Task<Never,Never>.isCancelled { throw CancellationError() }
            let output = try predict(encoder, [
                "features": floats(Array(repeating: 0, count: 128*frames), [1,128,frames]),
                "mask": ints((0..<frames).map { $0 < 101 ? 1 : 0 }, [1,frames])])
            // Materialize an output before reporting warmup complete.
            _ = try array(output, "encoder")[0].floatValue
        }
    }

    func transcribe(samples: [Float], language: String? = nil, mixedScript: Bool = false) throws -> Result {
        let trace = BodhanProfiling.begin("BodhanTranscription")
        defer { BodhanProfiling.end("BodhanTranscription", trace) }
        let entryQoS = qos_class_self().rawValue
        let entryThermal = ProcessInfo.processInfo.thermalState.rawValue
        let entryLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let entryMainThread = Thread.isMainThread
        guard !samples.isEmpty, samples.count <= 30*16000 else {
            throw NSError(domain: "BodhanASR", code: 4, userInfo: [NSLocalizedDescriptionKey: "The validation runtime accepts 0–30 seconds of 16 kHz audio."])
        }
        if let language, tokenizer.prompts[language] == nil {
            throw NSError(domain: "BodhanASR", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unsupported language \(language)."])
        }
        let start = Date()
        let mel = BodhanProfiling.measure("Frontend") { frontend.compute(samples) }
        let frontendSeconds = Date().timeIntervalSince(start)
        let encodeStart = Date()
        let inputTrace = BodhanProfiling.begin("EncoderInputPreparation")
        let inputFrames = shapePolicy == "buckets" ? (mel.frames <= 1501 ? 1501 : 3001) : mel.frames
        var paddedFeatures = mel.features
        if inputFrames != mel.frames {
            paddedFeatures = [Float](repeating: 0, count: 128*inputFrames)
            paddedFeatures.withUnsafeMutableBufferPointer { destination in
                mel.features.withUnsafeBufferPointer { source in
                    for band in 0..<128 {
                        (destination.baseAddress! + band*inputFrames).update(from: source.baseAddress! + band*mel.frames, count: mel.frames)
                    }
                }
            }
        }
        let inputs = try ["features":floats(paddedFeatures,[1,128,inputFrames]),
                          "mask":ints((0..<inputFrames).map { $0 < mel.frames ? 1 : 0 },[1,inputFrames])]
        BodhanProfiling.end("EncoderInputPreparation", inputTrace)
        let encoded = try BodhanProfiling.measure("CoreMLEncoderPrediction") { try predict(encoder, inputs) }
        let acoustic = try array(encoded,"encoder")
        let length = try array(encoded,"lengths")[0].intValue
        let encoderSeconds = Date().timeIntervalSince(encodeStart)
        if let mlx {
            var result = try mlx.generate(acoustic: acoustic, length: length, tokenizer: tokenizer, language: language,
                                    mixed: mixedScript, frontendSeconds: frontendSeconds,
                                    encoderSeconds: encoderSeconds, encoderPolicy: encoderPolicy)
            result.encoderAsset = encoderAsset
            result.encoderSpecialized = encoderSpecialized
            result.threadQoS = entryQoS
            result.thermalState = entryThermal
            result.lowPowerMode = entryLowPower
            result.onMainThread = entryMainThread
            result.encoderInputFrames = inputFrames
            result.encoderValidFrames = mel.frames
            result.encoderShapePolicy = shapePolicy
            return result
        }
        let crossStart = Date()
        let kv = try array(predict(cross,["encoder":acoustic]),"cross_kv")
        let crossSeconds = Date().timeIntervalSince(crossStart)
        let t = acoustic.shape[1].intValue
        let crossMask = try floats((0..<t).map { $0 < length ? 0 : -10000 },[1,1,1,t])
        var predictionSeconds = 0.0
        var selectionSeconds = 0.0
        func decode(_ ids: [Int], position: Int, state: MLState) throws -> MLMultiArray {
            var mask = [Float](repeating: -10000, count: ids.count*512)
            for q in ids.indices { for k in 0...position+q { mask[q*512+k] = 0 } }
            let predictionStart = Date()
            defer { predictionSeconds += Date().timeIntervalSince(predictionStart) }
            return try array(predict(decoder,["ids":ints(ids,[1,ids.count]),
                              "position":ints([position],[1]),"self_mask":floats(mask,[1,1,ids.count,512]),
                              "cross_kv":kv,"cross_mask":crossMask],state:state),"logits")
        }
        let decodeStart = Date()
        var selected = language
        if selected == nil {
            let prefix = Array(tokenizer.prompts["hi"]!.prefix(3))
            let logits = try decode(prefix,position:0,state:decoder.makeState())
            var best = -Float.infinity
            for code in tokenizer.prompts.keys.sorted() {
                let id = tokenizer.prompts[code]![3]
                let score = logits[[0,2,NSNumber(value:id)]].floatValue
                if score > best { selected = code; best = score }
            }
        }
        let chosen = selected!
        if mixedScript && tokenizer.mixed_prompts?[chosen] == nil {
            throw NSError(domain: "BodhanASR", code: 7, userInfo: [NSLocalizedDescriptionKey: "The Flex mixed-script tokenizer is missing. Download the model again."])
        }
        var ids = (mixedScript ? tokenizer.mixed_prompts?[chosen] : nil) ?? tokenizer.prompts[chosen]!
        let state = decoder.makeState()
        var position = 0
        var tokens: [Int] = []
        var ended = false
        for _ in 0..<256 {
            if Task<Never,Never>.isCancelled { throw CancellationError() }
            let logits = try decode(ids,position:position,state:state)
            let selectionStart = Date()
            let next = argmaxLast(logits)
            selectionSeconds += Date().timeIntervalSince(selectionStart)
            position += ids.count
            if next == tokenizer.eos_id { ended = true; break }
            tokens.append(next)
            ids = [next]
        }
        guard ended else {
            throw NSError(domain: "BodhanASR", code: 6, userInfo: [NSLocalizedDescriptionKey: "Bodhan ASR reached its token limit before finishing. Try a shorter recording."])
        }
        let text = tokens.filter { $0 >= tokenizer.special_count }.map { tokenizer.pieces[$0] }.joined().replacingOccurrences(of:"▁",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        var result = Result(text:text,language:chosen,tokens:tokens.count,endedWithEOS:ended,
                      frontendSeconds:frontendSeconds,encoderSeconds:encoderSeconds,crossSeconds:crossSeconds,
                      decodeSeconds:Date().timeIntervalSince(decodeStart), predictionSeconds:predictionSeconds,
                      selectionSeconds:selectionSeconds, encoderPolicy:encoderPolicy)
        result.encoderAsset = encoderAsset
        result.encoderSpecialized = encoderSpecialized
        result.threadQoS = entryQoS
        result.thermalState = entryThermal
        result.lowPowerMode = entryLowPower
        result.onMainThread = entryMainThread
        result.encoderInputFrames = inputFrames
        result.encoderValidFrames = mel.frames
        result.encoderShapePolicy = shapePolicy
        return result
    }
}

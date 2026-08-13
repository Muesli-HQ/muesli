import Accelerate
@preconcurrency import CoreML
import Foundation

/// Shared RNNT streaming engine for the NVIDIA Nemotron CoreML backends.
///
/// Shared RNNT helpers for Nemotron CoreML streaming backends.
///
/// The active app backend is `Nemotron35StreamingTranscriber` (multilingual
/// `nemotron35`). Per-model geometry, vocab/blank size, chunk length, optional
/// language `prompt_id`, and tokenizer tag handling live in `NemotronRNNTConfig`;
/// the decode loop, mel padding, and cache wiring live here.

/// Per-model geometry/behaviour. Values come from each variant's `metadata.json`.
struct NemotronRNNTConfig {
    /// Samples per streaming chunk (e.g. 8960 = 560ms, 35840 = 2240ms at 16kHz).
    let chunkSamples: Int
    /// `cache_channel` third dimension (att_context left: 70 for EN, 42 for 3.5).
    let cacheChannelFrames: Int
    /// Mel frames fed to the encoder per chunk (chunk + pre-encode cache).
    let totalMelFrames: Int
    let encoderDim: Int          // d_model (1024)
    let decoderHiddenSize: Int   // LSTM pred_hidden (640)
    /// Blank/last logit index (= vocab_size): 1024 for EN, 13087 for 3.5.
    let blankTokenId: Int
    /// Language prompt id fed to the encoder as `prompt_id`, or nil if the model
    /// has no language input (EN backend). 101 = auto-detect for the 3.5 model.
    let promptId: Int32?
    /// Drop `<…>` tag pieces on decode (3.5 emits `<lang>`/`<unk>` tags; EN does not).
    let stripAngleBracketTags: Bool
}

/// Carries all mutable state between chunk-by-chunk transcription calls. Neutral
/// (not owned by either transcriber) so both backends share one type.
struct RNNTStreamState {
    var cacheChannel: MLMultiArray   // [1, 24, cacheChannelFrames, 1024]
    var cacheTime: MLMultiArray      // [1, 24, 1024, 8]
    var cacheLen: MLMultiArray       // [1]
    var hState: MLMultiArray         // [2, 1, 640]
    var cState: MLMultiArray         // [2, 1, 640]
    var lastToken: Int32             // SOS/blank = 0
    var allTokens: [Int]             // accumulated token IDs
}

enum NemotronRNNTError: Error, LocalizedError {
    case notLoaded
    case downloadFailed(String)
    case preprocessingFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Nemotron models not loaded."
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .preprocessingFailed(let m): return "Preprocessing failed: \(m)"
        case .decodingFailed(let m): return "Decoding failed: \(m)"
        }
    }
}

// MARK: - State

func nemotronZeroFill(_ array: MLMultiArray) {
    let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    memset(ptr, 0, array.count * MemoryLayout<Float>.size)
}

/// Create a fresh streaming state with zero-initialized caches sized for `config`.
func nemotronMakeStreamState(config: NemotronRNNTConfig) throws -> RNNTStreamState {
    let cacheChannel = try MLMultiArray(
        shape: [1, 24, NSNumber(value: config.cacheChannelFrames), 1024], dataType: .float32)
    let cacheTime = try MLMultiArray(shape: [1, 24, 1024, 8], dataType: .float32)
    let cacheLen = try MLMultiArray(shape: [1], dataType: .int32)
    nemotronZeroFill(cacheChannel); nemotronZeroFill(cacheTime)
    cacheLen[0] = NSNumber(value: Int32(0))

    let hState = try MLMultiArray(shape: [2, 1, NSNumber(value: config.decoderHiddenSize)], dataType: .float32)
    let cState = try MLMultiArray(shape: [2, 1, NSNumber(value: config.decoderHiddenSize)], dataType: .float32)
    nemotronZeroFill(hState); nemotronZeroFill(cState)

    return RNNTStreamState(
        cacheChannel: cacheChannel, cacheTime: cacheTime, cacheLen: cacheLen,
        hState: hState, cState: cState, lastToken: 0, allTokens: []
    )
}

// MARK: - Token decoding

/// Decode token IDs to text: map id→piece, `▁`→space. When `stripAngleBracketTags`
/// is set, drop `<…>` special/language-tag pieces (the 3.5 vocab carries native
/// punctuation in-vocab, so no punctuation stripping is done either way).
func nemotronDecodeTokens(
    _ tokenIds: [Int],
    tokenizer: [Int: String],
    stripAngleBracketTags: Bool,
    trim: Bool
) -> String {
    var pieces: [String] = []
    for id in tokenIds {
        guard let piece = tokenizer[id] else { continue }
        if stripAngleBracketTags, piece.count >= 2, piece.hasPrefix("<"), piece.hasSuffix(">") { continue }
        pieces.append(piece)
    }
    let text = pieces.joined().replacingOccurrences(of: "▁", with: " ")
    return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
}

// MARK: - Chunk transcription (preprocessor → encoder → RNNT greedy decode)

/// Process one audio chunk and return the token IDs newly decoded from it.
/// `state` is mutated in-place to carry the encoder cache + LSTM state forward.
func nemotronTranscribeChunk(
    preprocessor: MLModel,
    encoder: MLModel,
    decoder: MLModel,
    joint: MLModel,
    config: NemotronRNNTConfig,
    samples: [Float],
    state: inout RNNTStreamState
) async throws -> [Int] {
    let tokensBefore = state.allTokens.count

    // 1. Preprocessor: audio → mel spectrogram
    let audioArray = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
    let audioPtr = audioArray.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
    _ = samples.withUnsafeBufferPointer { src in
        memcpy(audioPtr, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
    }
    let audioLenArray = try MLMultiArray(shape: [1], dataType: .int32)
    audioLenArray[0] = NSNumber(value: Int32(samples.count))

    let prepInput = try MLDictionaryFeatureProvider(dictionary: [
        "audio": MLFeatureValue(multiArray: audioArray),
        "audio_length": MLFeatureValue(multiArray: audioLenArray),
    ])
    let prepOutput = try await preprocessor.prediction(from: prepInput)

    guard let mel = prepOutput.featureValue(for: "mel")?.multiArrayValue,
          let melLength = prepOutput.featureValue(for: "mel_length")?.multiArrayValue else {
        throw NemotronRNNTError.preprocessingFailed("No mel output")
    }

    // 2. Pad/crop mel to totalMelFrames for the encoder
    let actualMelFrames = melLength[0].intValue
    let totalMelFrames = config.totalMelFrames
    let encoderMel = try MLMultiArray(shape: [1, 128, NSNumber(value: totalMelFrames)], dataType: .float32)
    let melSrcPtr = mel.dataPointer.bindMemory(to: Float.self, capacity: mel.count)
    let melDstPtr = encoderMel.dataPointer.bindMemory(to: Float.self, capacity: encoderMel.count)
    memset(melDstPtr, 0, encoderMel.count * MemoryLayout<Float>.size)

    let melFramesToCopy = min(mel.shape[2].intValue, totalMelFrames)
    for bin in 0..<128 {
        let srcOffset = bin * mel.shape[2].intValue
        let dstOffset = bin * totalMelFrames
        memcpy(melDstPtr.advanced(by: dstOffset), melSrcPtr.advanced(by: srcOffset), melFramesToCopy * MemoryLayout<Float>.size)
    }

    let encoderMelLen = try MLMultiArray(shape: [1], dataType: .int32)
    encoderMelLen[0] = NSNumber(value: Int32(min(actualMelFrames, totalMelFrames)))

    // 3. Encoder: mel + cache (+ optional prompt_id) → encoded + new cache
    var encDict: [String: MLFeatureValue] = [
        "mel": MLFeatureValue(multiArray: encoderMel),
        "mel_length": MLFeatureValue(multiArray: encoderMelLen),
        "cache_channel": MLFeatureValue(multiArray: state.cacheChannel),
        "cache_time": MLFeatureValue(multiArray: state.cacheTime),
        "cache_len": MLFeatureValue(multiArray: state.cacheLen),
    ]
    if let promptId = config.promptId {
        let promptIdArray = try MLMultiArray(shape: [1], dataType: .int32)
        promptIdArray[0] = NSNumber(value: promptId)
        encDict["prompt_id"] = MLFeatureValue(multiArray: promptIdArray)
    }
    let encInput = try MLDictionaryFeatureProvider(dictionary: encDict)
    let encOutput = try await encoder.prediction(from: encInput)

    guard let encoded = encOutput.featureValue(for: "encoded")?.multiArrayValue,
          let encodedLength = encOutput.featureValue(for: "encoded_length")?.multiArrayValue else {
        throw NemotronRNNTError.decodingFailed("No encoder output")
    }
    if let cc = encOutput.featureValue(for: "cache_channel_out")?.multiArrayValue { state.cacheChannel = cc }
    if let ct = encOutput.featureValue(for: "cache_time_out")?.multiArrayValue { state.cacheTime = ct }
    if let cl = encOutput.featureValue(for: "cache_len_out")?.multiArrayValue { state.cacheLen = cl }

    // 4. RNNT greedy decode over encoder frames
    let numFrames = encodedLength[0].intValue
    let encodedPtr = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
    let encoderDim = config.encoderDim

    for t in 0..<numFrames {
        // Yield periodically to let CoreML release intermediate GPU/ANE buffers.
        // Note: Task.yield() is a cooperative scheduling hint, not an autoreleasepool
        // drain. The async predictions (decoder, joint) inside the inner loop can't be
        // wrapped in autoreleasepool. This mitigates but doesn't fully prevent buffer
        // accumulation in very long sessions — a known limitation of async CoreML.
        if t > 0 && t % 10 == 0 { await Task.yield() }

        var maxSteps = 10
        while maxSteps > 0 {
            maxSteps -= 1

            let tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
            tokenArray[0] = NSNumber(value: state.lastToken)
            let tokenLen = try MLMultiArray(shape: [1], dataType: .int32)
            tokenLen[0] = NSNumber(value: Int32(1))

            let decInput = try MLDictionaryFeatureProvider(dictionary: [
                "token": MLFeatureValue(multiArray: tokenArray),
                "token_length": MLFeatureValue(multiArray: tokenLen),
                "h_in": MLFeatureValue(multiArray: state.hState),
                "c_in": MLFeatureValue(multiArray: state.cState),
            ])
            let decOutput = try await decoder.prediction(from: decInput)

            guard let decoderOut = decOutput.featureValue(for: "decoder_out")?.multiArrayValue else {
                throw NemotronRNNTError.decodingFailed("No decoder output")
            }

            // Joint: encoder [1, encoderDim, 1] + decoder [1, 640, 1] → logits.
            // Encoded is [1, encoderDim, numFrames]; access [0, d, t] via stride.
            let encFrame = try MLMultiArray(shape: [1, NSNumber(value: encoderDim), 1], dataType: .float32)
            let encFramePtr = encFrame.dataPointer.bindMemory(to: Float.self, capacity: encoderDim)
            let encodedStride1 = encoded.strides[1].intValue
            for d in 0..<encoderDim {
                encFramePtr[d] = encodedPtr[d * encodedStride1 + t]
            }

            let jointInput = try MLDictionaryFeatureProvider(dictionary: [
                "encoder": MLFeatureValue(multiArray: encFrame),
                "decoder": MLFeatureValue(multiArray: decoderOut),
            ])
            let jointOutput = try await joint.prediction(from: jointInput)

            guard let logits = jointOutput.featureValue(for: "logits")?.multiArrayValue else {
                throw NemotronRNNTError.decodingFailed("No joint logits")
            }

            // Argmax
            let logitsCount = logits.count
            let logitsPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: logitsCount)
            var maxVal: Float = -Float.infinity
            var maxIdx: vDSP_Length = 0
            vDSP_maxvi(logitsPtr, 1, &maxVal, &maxIdx, vDSP_Length(logitsCount))
            let predictedToken = Int(maxIdx)

            if predictedToken == config.blankTokenId {
                break
            }

            state.allTokens.append(predictedToken)
            state.lastToken = Int32(predictedToken)

            if let hOut = decOutput.featureValue(for: "h_out")?.multiArrayValue,
               let cOut = decOutput.featureValue(for: "c_out")?.multiArrayValue {
                state.hState = hOut
                state.cState = cOut
            }
        }
    }

    return Array(state.allTokens[tokensBefore...])
}

// MARK: - WAV loading

func nemotronLoadWavAsFloats(url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { throw NemotronRNNTError.decodingFailed("WAV too small") }
    let pcmData = data.dropFirst(44)
    let count = pcmData.count / 2
    var floats = [Float](repeating: 0, count: count)
    pcmData.withUnsafeBytes { raw in
        let buf = raw.bindMemory(to: Int16.self)
        for i in 0..<count { floats[i] = Float(buf[i]) / 32767.0 }
    }
    return floats
}

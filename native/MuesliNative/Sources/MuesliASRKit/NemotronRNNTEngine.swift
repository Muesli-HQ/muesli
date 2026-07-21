import Accelerate
@preconcurrency import CoreML
import Foundation
import MuesliCore

/// Shared RNNT streaming engine for the NVIDIA Nemotron CoreML backends.
///
/// Shared RNNT helpers for Nemotron CoreML streaming backends.
///
/// The active app backend is `Nemotron35StreamingTranscriber` (multilingual
/// `nemotron35`). Per-model geometry, vocab/blank size, chunk length, optional
/// language `prompt_id`, and tokenizer tag handling live in `NemotronRNNTConfig`;
/// the decode loop, mel padding, and cache wiring live here.

/// Per-model geometry/behaviour. Values come from each variant's `metadata.json`.
public struct NemotronRNNTConfig {
    /// Samples per streaming chunk (e.g. 8960 = 560ms, 35840 = 2240ms at 16kHz).
    public let chunkSamples: Int
    /// `cache_channel` third dimension (att_context left: 70 for EN, 42 for 3.5).
    public let cacheChannelFrames: Int
    /// Mel frames fed to the encoder per chunk (chunk + pre-encode cache).
    public let totalMelFrames: Int
    public let encoderDim: Int          // d_model (1024)
    public let decoderHiddenSize: Int   // LSTM pred_hidden (640)
    /// Blank/last logit index (= vocab_size): 1024 for EN, 13087 for 3.5.
    public let blankTokenId: Int
    /// Language prompt id fed to the encoder as `prompt_id`, or nil if the model
    /// has no language input (EN backend). 101 = auto-detect for the 3.5 model.
    public let promptId: Int32?
    /// Drop `<…>` tag pieces on decode (3.5 emits `<lang>`/`<unk>` tags; EN does not).
    public let stripAngleBracketTags: Bool

    public init(
        chunkSamples: Int,
        cacheChannelFrames: Int,
        totalMelFrames: Int,
        encoderDim: Int,
        decoderHiddenSize: Int,
        blankTokenId: Int,
        promptId: Int32?,
        stripAngleBracketTags: Bool
    ) {
        self.chunkSamples = chunkSamples
        self.cacheChannelFrames = cacheChannelFrames
        self.totalMelFrames = totalMelFrames
        self.encoderDim = encoderDim
        self.decoderHiddenSize = decoderHiddenSize
        self.blankTokenId = blankTokenId
        self.promptId = promptId
        self.stripAngleBracketTags = stripAngleBracketTags
    }
}

/// Carries all mutable state between chunk-by-chunk transcription calls. Neutral
/// (not owned by either transcriber) so both backends share one type.
public struct RNNTStreamState {
    public var cacheChannel: MLMultiArray   // [1, 24, cacheChannelFrames, 1024]
    public var cacheTime: MLMultiArray      // [1, 24, 1024, 8]
    public var cacheLen: MLMultiArray       // [1]
    public var hState: MLMultiArray         // [2, 1, 640]
    public var cState: MLMultiArray         // [2, 1, 640]
    public var lastToken: Int32             // SOS/blank = 0
    public var allTokens: [Int]             // accumulated token IDs

    public init(
        cacheChannel: MLMultiArray, cacheTime: MLMultiArray, cacheLen: MLMultiArray,
        hState: MLMultiArray, cState: MLMultiArray, lastToken: Int32, allTokens: [Int]
    ) {
        self.cacheChannel = cacheChannel
        self.cacheTime = cacheTime
        self.cacheLen = cacheLen
        self.hState = hState
        self.cState = cState
        self.lastToken = lastToken
        self.allTokens = allTokens
    }
}

public enum NemotronRNNTError: Error, LocalizedError {
    case notLoaded
    case downloadFailed(String)
    case preprocessingFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
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
public func nemotronMakeStreamState(config: NemotronRNNTConfig) throws -> RNNTStreamState {
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
public func nemotronDecodeTokens(
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
public func nemotronTranscribeChunk(
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

public func nemotronLoadWavAsFloats(url: URL) throws -> [Float] {
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

// MARK: - HuggingFace tree download

/// Recursively download a HuggingFace model subtree into `localDir`, preserving the
/// directory structure under `remotePath`. Files already present are skipped, as are
/// any whose relative path begins with `skipRelativePrefix` (e.g. an unused component).
public func nemotronDownloadHuggingFaceTree(
    repoID: String,
    apiURL: String,
    remotePath: String,
    localDir: URL,
    skipRelativePrefix: String? = nil,
    logPrefix: String,
    onFileDownloaded: (() -> Void)? = nil
) async throws {
    guard let url = URL(string: apiURL) else {
        throw NemotronRNNTError.downloadFailed("Invalid HuggingFace API URL: \(apiURL)")
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw NemotronRNNTError.downloadFailed("HuggingFace tree request failed with HTTP \(http.statusCode): \(apiURL)")
    }
    guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw NemotronRNNTError.downloadFailed("Unexpected HuggingFace tree payload for \(apiURL)")
    }

    for entry in entries {
        guard let path = entry["path"] as? String, let type = entry["type"] as? String else { continue }
        let relativePath = String(path.dropFirst(remotePath.count + 1))

        if let skip = skipRelativePrefix, relativePath.hasPrefix(skip) { continue }

        if type == "directory" {
            let subAPI = "https://huggingface.co/api/models/\(repoID)/tree/main/\(path)"
            let subDir = localDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            try await nemotronDownloadHuggingFaceTree(
                repoID: repoID, apiURL: subAPI, remotePath: remotePath, localDir: localDir,
                skipRelativePrefix: skipRelativePrefix, logPrefix: logPrefix, onFileDownloaded: onFileDownloaded)
        } else if type == "file" {
            guard let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(path)") else {
                throw NemotronRNNTError.downloadFailed("Invalid HuggingFace file URL for \(path)")
            }
            let localFile = localDir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: localFile.path) { continue }

            let parentDir = localFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            fputs("\(logPrefix) downloading \(relativePath)...\n", stderr)
            try await downloadWithRetry(from: fileURL, to: localFile)
            onFileDownloaded?()
        }
    }
}

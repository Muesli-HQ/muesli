// Vendored from FluidAudio v0.15.1 (ASR/Qwen3/), Apache License 2.0.
// Original: https://github.com/FluidInference/FluidAudio — types renamed with MuesliQwen3 prefix.
// Licensed under the Apache License, Version 2.0; see LICENSE-Apache-2.0 in this directory.
@preconcurrency import CoreML
import Foundation
import OSLog

/// Model artifact file names for the vendored Qwen3 ASR backend.
private enum MuesliQwen3ModelFiles {
    static let audioEncoderName = "qwen3_asr_audio_encoder_v2"
    static let decoderStatefulName = "qwen3_asr_decoder_stateful"
    static let audioEncoder = "\(audioEncoderName).mlmodelc"
    static let decoderStateful = "\(decoderStatefulName).mlmodelc"
    static let embeddings = "qwen3_asr_embeddings.bin"
    static let vocab = "vocab.json"
}

private let logger = Logger(subsystem: "FluidAudio", category: "MuesliQwen3AsrModels")

/// Qwen3-ASR model variant (precision).
public enum MuesliQwen3AsrVariant: String, CaseIterable, Sendable {
    /// Full precision (FP16 weights). Best speed, ~1.75 GB.
    case f32
    /// Int8 quantized weights. Half the RAM (~900 MB), same quality.
    case int8

    /// On-disk cache folder name (matches the layout Muesli's managed downloader uses).
    public var folderName: String {
        switch self {
        case .f32: return "qwen3-asr-0.6b/f32"
        case .int8: return "qwen3-asr-0.6b/int8"
        }
    }
}

// MARK: - Qwen3-ASR CoreML Model Container (2-model pipeline)

/// Holds CoreML model components for the optimized 2-model Qwen3-ASR pipeline.
///
/// This uses Swift-side embedding lookup from a preloaded weight matrix,
/// eliminating the embedding CoreML model. Reduces CoreML calls from 3 to 2 per token.
///
/// Components:
/// - `audioEncoder`: mel spectrogram -> 1024-dim audio features (single window)
/// - `decoderStateful`: stateful decoder with fused lmHead (outputs logits directly)
/// - `embeddingWeights`: [151936, 1024] float16 matrix for Swift-side embedding lookup
@available(macOS 15, iOS 18, *)
public struct MuesliQwen3AsrModels: Sendable {
    public let audioEncoder: MLModel
    public let decoderStateful: MLModel
    public let embeddingWeights: MuesliQwen3EmbeddingWeights
    public let vocabulary: [Int: String]

    /// Load Qwen3-ASR models (2-model pipeline with Swift-side embedding) from a directory.
    ///
    /// Expected directory structure:
    /// ```
    /// qwen3-asr/
    ///   qwen3_asr_audio_encoder_v2.mlmodelc
    ///   qwen3_asr_decoder_stateful.mlmodelc
    ///   qwen3_asr_embeddings.bin  (float16 embedding weights)
    ///   vocab.json
    /// ```
    public static func load(
        from directory: URL,
        computeUnits: MLComputeUnits = .all
    ) async throws -> MuesliQwen3AsrModels {
        let modelConfig = MLModelConfiguration()
        modelConfig.computeUnits = computeUnits

        logger.info("Loading Qwen3-ASR models (2-model pipeline) from \(directory.path)")
        let start = CFAbsoluteTimeGetCurrent()

        // Load audio encoder
        let audioEncoder = try await loadModel(
            named: MuesliQwen3ModelFiles.audioEncoderName,
            from: directory,
            configuration: modelConfig
        )

        // Load stateful decoder (with fused lmHead)
        let decoderStateful = try await loadModel(
            named: MuesliQwen3ModelFiles.decoderStatefulName,
            from: directory,
            configuration: modelConfig
        )

        // Load embedding weights for Swift-side lookup
        let embeddingWeights = try loadMuesliQwen3EmbeddingWeights(from: directory)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("Loaded Qwen3-ASR models (2-model) in \(String(format: "%.2f", elapsed))s")

        // Load vocabulary from tokenizer
        let vocabulary = try loadVocabulary(from: directory)

        return MuesliQwen3AsrModels(
            audioEncoder: audioEncoder,
            decoderStateful: decoderStateful,
            embeddingWeights: embeddingWeights,
            vocabulary: vocabulary
        )
    }

    /// Download models from HuggingFace and load them.
    ///
    /// Downloads to the default cache directory if not already present,
    /// then loads all model components.
    public static func downloadAndLoad(
        variant: MuesliQwen3AsrVariant = .int8,
        to directory: URL? = nil,
        computeUnits: MLComputeUnits = .all,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MuesliQwen3AsrModels {
        let targetDir = try await download(variant: variant, to: directory, progressHandler: progressHandler)
        return try await load(from: targetDir, computeUnits: computeUnits)
    }

    /// Download Qwen3-ASR models through Muesli's managed model downloader.
    ///
    /// - Parameters:
    ///   - variant: Model variant to download (`.int8` managed; `.f32` unsupported).
    ///   - directory: Target directory. Uses default cache directory if nil.
    ///   - force: Force re-download even if models exist.
    ///   - progressHandler: Optional callback for download progress updates.
    /// - Returns: Path to the directory containing the downloaded models.
    @discardableResult
    public static func download(
        variant: MuesliQwen3AsrVariant = .int8,
        to directory: URL? = nil,
        force: Bool = false,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let targetDir = directory ?? defaultCacheDirectory(variant: variant)

        guard variant == .int8 else {
            throw MuesliQwen3AsrError.downloadUnavailable(
                "The f32 variant is not managed; use the int8 managed plan."
            )
        }

        if !force && modelsExist(at: targetDir) {
            logger.info("Qwen3-ASR \(variant.rawValue) models already present at: \(targetDir.path)")
            return targetDir
        }

        // Delegate entirely to the managed downloader: the plan's cacheDirectory
        // IS the requested destination, so the downloader's own resume/marker
        // machinery owns the directory (same semantics as every other model in
        // the app). `force` reuses the app-standard delete-then-download flow.
        logger.info("Downloading Qwen3-ASR \(variant.rawValue) models via managed downloader...")
        let plan = ManagedASRModelPlans.qwen3ASRInt8(cacheDirectory: targetDir)
        if force {
            // A failed delete would let the downloader short-circuit on the stale
            // cache, so surface the failure instead of silently keeping old files.
            try plan.delete(fileManager: .default)
        }
        _ = try await ManagedASRModelDownloader.downloadIfNeeded(
            plan,
            progress: { fraction, _ in progressHandler?(fraction) }
        )
        logger.info("Successfully downloaded Qwen3-ASR \(variant.rawValue) models")
        return targetDir
    }

    /// Check if all required model files exist locally.
    public static func modelsExist(at directory: URL) -> Bool {
        let fm = FileManager.default
        let requiredFiles = [
            MuesliQwen3ModelFiles.audioEncoder,
            MuesliQwen3ModelFiles.decoderStateful,
            MuesliQwen3ModelFiles.embeddings,
            MuesliQwen3ModelFiles.vocab,
        ]
        return requiredFiles.allSatisfy { file in
            fm.fileExists(atPath: directory.appendingPathComponent(file).path)
        }
    }

    /// Root directory for all FluidAudio model caches.
    private static func modelsRootDirectory() -> URL {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            // Fallback to temporary directory if application support unavailable
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("FluidAudio", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }
        return
            appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Default cache directory for Qwen3-ASR models.
    public static func defaultCacheDirectory(variant: MuesliQwen3AsrVariant = .f32) -> URL {
        modelsRootDirectory()
            .appendingPathComponent(variant.folderName, isDirectory: true)
    }

    // MARK: Private

    private static func loadModel(
        named name: String,
        from directory: URL,
        configuration: MLModelConfiguration
    ) async throws -> MLModel {
        // Try .mlmodelc first (pre-compiled), then compile .mlpackage on the fly
        let compiledPath = directory.appendingPathComponent("\(name).mlmodelc")
        let packagePath = directory.appendingPathComponent("\(name).mlpackage")

        let modelURL: URL
        if FileManager.default.fileExists(atPath: compiledPath.path) {
            modelURL = compiledPath
        } else if FileManager.default.fileExists(atPath: packagePath.path) {
            // .mlpackage must be compiled to .mlmodelc before loading
            logger.info("Compiling \(name).mlpackage -> .mlmodelc ...")
            let compileStart = CFAbsoluteTimeGetCurrent()
            let compiledURL = try await MLModel.compileModel(at: packagePath)
            let compileElapsed = CFAbsoluteTimeGetCurrent() - compileStart
            logger.info("  \(name): compiled in \(String(format: "%.2f", compileElapsed))s")

            // Move compiled model next to the package for caching
            try? FileManager.default.removeItem(at: compiledPath)
            try FileManager.default.copyItem(at: compiledURL, to: compiledPath)
            // Clean up the temp compiled model
            try? FileManager.default.removeItem(at: compiledURL)

            modelURL = compiledPath
        } else {
            throw MuesliQwen3AsrError.modelNotFound(name)
        }

        let start = CFAbsoluteTimeGetCurrent()
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.debug("  \(name): loaded in \(String(format: "%.2f", elapsed))s")
        return model
    }

    private static func loadMuesliQwen3EmbeddingWeights(from directory: URL) throws -> MuesliQwen3EmbeddingWeights {
        #if !arch(arm64)
        // Fail loading with a clear error instead of reaching the fatalError in
        // embedding(for:) on non-Apple-Silicon machines.
        throw MuesliQwen3AsrError.unsupportedHardware
        #endif
        let path = directory.appendingPathComponent(MuesliQwen3ModelFiles.embeddings)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw MuesliQwen3AsrError.modelNotFound("qwen3_asr_embeddings.bin")
        }

        let start = CFAbsoluteTimeGetCurrent()
        let weights = try MuesliQwen3EmbeddingWeights(contentsOf: path)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info(
            "Loaded embedding weights in \(String(format: "%.2f", elapsed))s (\(weights.vocabSize) x \(weights.hiddenSize))"
        )
        return weights
    }

    private static func loadVocabulary(from directory: URL) throws -> [Int: String] {
        let vocabPath = directory.appendingPathComponent(MuesliQwen3ModelFiles.vocab)
        guard FileManager.default.fileExists(atPath: vocabPath.path) else {
            throw MuesliQwen3AsrError.modelNotFound(MuesliQwen3ModelFiles.vocab)
        }

        let data = try Data(contentsOf: vocabPath)
        guard let stringToId = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw MuesliQwen3AsrError.invalidVocabulary
        }

        // Invert: token string -> token ID becomes token ID -> token string
        var idToString: [Int: String] = [:]
        idToString.reserveCapacity(stringToId.count)
        for (token, id) in stringToId {
            idToString[id] = token
        }
        logger.info("Loaded vocabulary: \(idToString.count) tokens")
        return idToString
    }
}

// MARK: - Embedding Weights

/// Preloaded embedding weights for Swift-side token embedding lookup.
/// Eliminates the need for a separate embedding CoreML model.
public final class MuesliQwen3EmbeddingWeights: Sendable {
    public let vocabSize: Int
    public let hiddenSize: Int
    private let data: Data

    /// Load embedding weights from a binary file.
    /// Format: uint32 vocabSize, uint32 hiddenSize, then float16[vocabSize * hiddenSize]
    public init(contentsOf url: URL) throws {
        let fileData = try Data(contentsOf: url)
        guard fileData.count >= 8 else {
            throw MuesliQwen3AsrError.invalidVocabulary
        }

        // Read header. Data's backing buffer is not guaranteed to be aligned, so
        // use loadUnaligned to avoid trapping on unaligned addresses.
        let vocab = fileData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let hidden = fileData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        self.vocabSize = Int(vocab)
        self.hiddenSize = Int(hidden)

        // Validate against config
        guard vocabSize == MuesliQwen3AsrConfig.vocabSize else {
            throw MuesliQwen3AsrError.generationFailed(
                "Embedding vocab size \(vocabSize) != config \(MuesliQwen3AsrConfig.vocabSize)"
            )
        }
        guard hiddenSize == MuesliQwen3AsrConfig.hiddenSize else {
            throw MuesliQwen3AsrError.generationFailed(
                "Embedding hidden size \(hiddenSize) != config \(MuesliQwen3AsrConfig.hiddenSize)"
            )
        }

        // Verify file size
        let expectedSize = 8 + vocabSize * hiddenSize * 2  // header + float16 data
        guard fileData.count == expectedSize else {
            throw MuesliQwen3AsrError.generationFailed(
                "Embedding file size mismatch: expected \(expectedSize), got \(fileData.count)"
            )
        }

        self.data = fileData
    }

    /// Get embedding vector for a token ID.
    /// Returns float32 array of length hiddenSize.
    public func embedding(for tokenId: Int) -> [Float] {
        guard tokenId >= 0, tokenId < vocabSize else {
            return [Float](repeating: 0, count: hiddenSize)
        }

        let offset = 8 + tokenId * hiddenSize * 2  // header + token offset (float16)
        var result = [Float](repeating: 0, count: hiddenSize)

        #if arch(arm64)
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            for i in 0..<hiddenSize {
                let value = ptr.loadUnaligned(
                    fromByteOffset: offset + i * 2,
                    as: Float16.self
                )
                result[i] = Float(value)
            }
        }
        #else
        // Float16 is only available on Apple Silicon
        fatalError("Qwen3-ASR requires Apple Silicon (arm64)")
        #endif

        return result
    }

    /// Get embeddings for multiple token IDs.
    /// Returns [seqLen][hiddenSize] array.
    public func embeddings(for tokenIds: [Int32]) -> [[Float]] {
        tokenIds.map { embedding(for: Int($0)) }
    }
}

// MARK: - Errors

public enum MuesliQwen3AsrError: Error, LocalizedError {
    case modelNotFound(String)
    case invalidVocabulary
    case encoderFailed(String)
    case decoderFailed(String)
    case generationFailed(String)
    case downloadUnavailable(String)
    case audioTooLong(String)
    case unsupportedHardware

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Qwen3-ASR model not found: \(name)"
        case .invalidVocabulary:
            return "Invalid vocabulary file"
        case .encoderFailed(let detail):
            return "Audio encoder failed: \(detail)"
        case .decoderFailed(let detail):
            return "Decoder failed: \(detail)"
        case .generationFailed(let detail):
            return "Generation failed: \(detail)"
        case .downloadUnavailable(let detail):
            return detail
        case .audioTooLong(let detail):
            return detail
        case .unsupportedHardware:
            return "Qwen3-ASR requires Apple Silicon (arm64)"
        }
    }
}

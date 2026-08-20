// Vendored from FluidAudio v0.15.1 (ASR/Qwen3/), Apache License 2.0.
// Original: https://github.com/FluidInference/FluidAudio — types renamed with MuesliQwen3 prefix.
// Licensed under the Apache License, Version 2.0; see LICENSE-Apache-2.0 in this directory.
import Foundation

// MARK: - Rotary Position Embeddings for Qwen3-ASR

/// Computes RoPE (Rotary Position Embedding) cos/sin values for the Qwen3 decoder.
///
/// Qwen3-ASR uses M-RoPE (Multi-dimensional Rotary Position Embedding) with
/// interleaved sections [24, 20, 20] and rope_theta = 1,000,000.
/// For ASR (no spatial dimensions), temporal position is used for all 3 sections,
/// so this simplifies to standard RoPE with the full head_dim = 128.
///
/// All positions 0..<maxCacheSeqLen are precomputed at init to avoid per-token
/// trigonometric calls in the hot decode loop.
public struct MuesliQwen3RoPE: Sendable {
    private let invFreq: [Float]
    public let headDim: Int

    /// Precomputed cos/sin tables for positions 0..<maxPosition.
    /// Layout: [pos0(headDim), pos1(headDim), ...] — contiguous per position.
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let maxPosition: Int

    /// Initialize with Qwen3-ASR config constants.
    ///
    /// inv_freq = 1.0 / (theta ^ (i / dim)) for i in [0, 2, 4, ..., dim-2]
    /// Precomputes cos/sin for all positions up to maxCacheSeqLen.
    public init() {
        self.headDim = MuesliQwen3AsrConfig.headDim
        self.maxPosition = MuesliQwen3AsrConfig.maxCacheSeqLen
        let theta = Float(MuesliQwen3AsrConfig.ropeTheta)
        let dim = Float(MuesliQwen3AsrConfig.headDim)

        var freq = [Float](repeating: 0.0, count: MuesliQwen3AsrConfig.headDim / 2)
        for i in stride(from: 0, to: MuesliQwen3AsrConfig.headDim, by: 2) {
            let exponent = Float(i) / dim
            freq[i / 2] = 1.0 / powf(theta, exponent)
        }
        self.invFreq = freq

        // Precompute all positions
        let halfDim = MuesliQwen3AsrConfig.headDim / 2
        var cosVals = [Float](repeating: 0.0, count: maxPosition * MuesliQwen3AsrConfig.headDim)
        var sinVals = [Float](repeating: 0.0, count: maxPosition * MuesliQwen3AsrConfig.headDim)

        for p in 0..<maxPosition {
            let pos = Float(p)
            let offset = p * MuesliQwen3AsrConfig.headDim
            for i in 0..<halfDim {
                let angle = pos * freq[i]
                let c = cosf(angle)
                let s = sinf(angle)
                // Concatenated-halves layout: [cos0,...,cos63, cos0,...,cos63]
                // Matches CoreML model's rotate_half which splits at head_dim/2.
                cosVals[offset + i] = c
                cosVals[offset + i + halfDim] = c
                sinVals[offset + i] = s
                sinVals[offset + i + halfDim] = s
            }
        }
        self.cosTable = cosVals
        self.sinTable = sinVals
    }

    /// Copy precomputed cos/sin for a position directly into destination buffers.
    ///
    /// Writes headDim floats to each pointer. Avoids intermediate array allocation
    /// in the hot decode loop.
    public func fill(
        position: Int,
        cosPtr: UnsafeMutablePointer<Float>,
        sinPtr: UnsafeMutablePointer<Float>
    ) {
        guard position < maxPosition else {
            let (cos, sin) = computeDynamic(position: position)
            cos.withUnsafeBufferPointer { src in
                _ = memcpy(cosPtr, src.baseAddress!, headDim * MemoryLayout<Float>.stride)
            }
            sin.withUnsafeBufferPointer { src in
                _ = memcpy(sinPtr, src.baseAddress!, headDim * MemoryLayout<Float>.stride)
            }
            return
        }
        let offset = position * headDim
        cosTable.withUnsafeBufferPointer { buf in
            _ = memcpy(cosPtr, buf.baseAddress! + offset, headDim * MemoryLayout<Float>.stride)
        }
        sinTable.withUnsafeBufferPointer { buf in
            _ = memcpy(sinPtr, buf.baseAddress! + offset, headDim * MemoryLayout<Float>.stride)
        }
    }

    /// Compute cos and sin embeddings for a given position.
    ///
    /// Returns (cos, sin) each of shape [headDim], suitable for creating
    /// CoreML input tensors of shape [1, 1, headDim].
    public func compute(position: Int) -> (cos: [Float], sin: [Float]) {
        guard position < maxPosition else {
            return computeDynamic(position: position)
        }
        let offset = position * headDim
        return (
            cos: Array(cosTable[offset..<(offset + headDim)]),
            sin: Array(sinTable[offset..<(offset + headDim)])
        )
    }

    /// Compute cos and sin embeddings for a contiguous range of positions.
    ///
    /// Returns flat arrays of length `count * headDim`, laid out as
    /// `[pos0(128), pos1(128), ...]` for creating `[1, count, headDim]` tensors.
    /// Used for batched prefill where all prompt positions are processed at once.
    public func computeRange(startPosition: Int, count: Int) -> (cos: [Float], sin: [Float]) {
        let endPosition = startPosition + count
        guard endPosition <= maxPosition else {
            return computeRangeDynamic(startPosition: startPosition, count: count)
        }
        let startOffset = startPosition * headDim
        let endOffset = endPosition * headDim
        return (
            cos: Array(cosTable[startOffset..<endOffset]),
            sin: Array(sinTable[startOffset..<endOffset])
        )
    }

    // MARK: - Dynamic fallbacks for positions beyond precomputed table

    private func computeDynamic(position: Int) -> (cos: [Float], sin: [Float]) {
        let pos = Float(position)
        var cosValues = [Float](repeating: 0.0, count: headDim)
        var sinValues = [Float](repeating: 0.0, count: headDim)

        let halfDim = headDim / 2
        for i in 0..<halfDim {
            let angle = pos * invFreq[i]
            let c = cosf(angle)
            let s = sinf(angle)
            cosValues[i] = c
            cosValues[i + halfDim] = c
            sinValues[i] = s
            sinValues[i + halfDim] = s
        }

        return (cos: cosValues, sin: sinValues)
    }

    private func computeRangeDynamic(startPosition: Int, count: Int) -> (cos: [Float], sin: [Float]) {
        let totalSize = count * headDim
        var cosValues = [Float](repeating: 0.0, count: totalSize)
        var sinValues = [Float](repeating: 0.0, count: totalSize)

        let halfDim = headDim / 2
        for p in 0..<count {
            let pos = Float(startPosition + p)
            let offset = p * headDim
            for i in 0..<halfDim {
                let angle = pos * invFreq[i]
                let c = cosf(angle)
                let s = sinf(angle)
                cosValues[offset + i] = c
                cosValues[offset + i + halfDim] = c
                sinValues[offset + i] = s
                sinValues[offset + i + halfDim] = s
            }
        }

        return (cos: cosValues, sin: sinValues)
    }
}

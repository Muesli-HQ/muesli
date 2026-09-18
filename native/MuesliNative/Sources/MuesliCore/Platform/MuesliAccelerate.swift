import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

/// Portable replacements for the Accelerate/vDSP primitives used by
/// `MuesliQwen3WhisperMelSpectrogram` and the Qwen3 argmax.
///
/// macOS keeps the vectorized Accelerate path (identical results, faster).
/// Windows uses scalar loops with the same semantics. Any floating-point
/// difference is second-order accumulation-order noise; tests document the
/// tolerance.
enum MuesliAccelerate {

    /// Index and value of the maximum element. Ties resolve to the lowest index,
    /// matching `vDSP_maxvi`.
    static func argmax(_ values: UnsafePointer<Float>, count: Int) -> (value: Float, index: Int) {
        precondition(count > 0, "argmax requires a non-empty buffer")
        #if canImport(Accelerate)
        var maxValue: Float = 0
        var maxIndex = vDSP_Length(0)
        vDSP_maxvi(values, 1, &maxValue, &maxIndex, vDSP_Length(count))
        return (maxValue, Int(maxIndex))
        #else
        var maxValue = values[0]
        var maxIndex = 0
        if count > 1 {
            for index in 1..<count where values[index] > maxValue {
                maxValue = values[index]
                maxIndex = index
            }
        }
        return (maxValue, maxIndex)
        #endif
    }

    /// `output[r] = sum_c(matrix[r, c] * vector[c])` for a `rows x columns`
    /// row-major matrix and a length-`columns` vector.
    static func matvec(
        matrix: UnsafePointer<Float>,
        rows: Int,
        columns: Int,
        vector: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>
    ) {
        #if canImport(Accelerate)
        vDSP_mmul(matrix, 1, vector, 1, output, 1, vDSP_Length(rows), 1, vDSP_Length(columns))
        #else
        for row in 0..<rows {
            let base = row * columns
            var sum: Float = 0
            for column in 0..<columns {
                sum += matrix[base + column] * vector[column]
            }
            output[row] = sum
        }
        #endif
    }

    /// Element-wise square. `source` and `destination` may alias.
    static func square(
        _ source: UnsafePointer<Float>,
        _ destination: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        #if canImport(Accelerate)
        vDSP_vsq(source, 1, destination, 1, vDSP_Length(count))
        #else
        for index in 0..<count { destination[index] = source[index] * source[index] }
        #endif
    }

    /// Element-wise addition. `destination` may alias `a` or `b`.
    static func add(
        _ a: UnsafePointer<Float>,
        _ b: UnsafePointer<Float>,
        _ destination: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        #if canImport(Accelerate)
        vDSP_vadd(a, 1, b, 1, destination, 1, vDSP_Length(count))
        #else
        for index in 0..<count { destination[index] = a[index] + b[index] }
        #endif
    }

    /// Clamp each element into `[low, high]`. In-place is allowed.
    static func clip(
        _ source: UnsafePointer<Float>,
        _ destination: UnsafeMutablePointer<Float>,
        low: Float,
        high: Float,
        count: Int
    ) {
        #if canImport(Accelerate)
        var low = low
        var high = high
        vDSP_vclip(source, 1, &low, &high, destination, 1, vDSP_Length(count))
        #else
        for index in 0..<count {
            destination[index] = Swift.min(Swift.max(source[index], low), high)
        }
        #endif
    }

    /// Base-10 logarithm, in place.
    static func log10(_ values: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate)
        var count = Int32(count)
        vvlog10f(values, values, &count)
        #else
        for index in 0..<count { values[index] = log10f(values[index]) }
        #endif
    }

    /// Maximum element of `values`.
    static func max(_ values: UnsafePointer<Float>, count: Int) -> Float {
        #if canImport(Accelerate)
        var result: Float = 0
        vDSP_maxv(values, 1, &result, vDSP_Length(count))
        return result
        #else
        var result = values[0]
        if count > 1 {
            for index in 1..<count where values[index] > result { result = values[index] }
        }
        return result
        #endif
    }

    /// Add a scalar to each element. In-place is allowed.
    static func addScalar(
        _ source: UnsafePointer<Float>,
        _ destination: UnsafeMutablePointer<Float>,
        scalar: Float,
        count: Int
    ) {
        #if canImport(Accelerate)
        var scalar = scalar
        vDSP_vsadd(source, 1, &scalar, destination, 1, vDSP_Length(count))
        #else
        for index in 0..<count { destination[index] = source[index] + scalar }
        #endif
    }

    /// Divide each element by a scalar. In-place is allowed.
    static func divideScalar(
        _ source: UnsafePointer<Float>,
        _ destination: UnsafeMutablePointer<Float>,
        scalar: Float,
        count: Int
    ) {
        #if canImport(Accelerate)
        var scalar = scalar
        vDSP_vsdiv(source, 1, &scalar, destination, 1, vDSP_Length(count))
        #else
        for index in 0..<count { destination[index] = source[index] / scalar }
        #endif
    }
}

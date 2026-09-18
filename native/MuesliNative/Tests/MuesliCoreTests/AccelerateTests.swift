import Foundation
import XCTest
@testable import MuesliCore

/// Numerical tests for the portable Accelerate replacements. Tolerances are
/// documented per test and reflect float32 accumulation-order differences versus
/// vDSP on macOS.
final class AccelerateTests: XCTestCase {
    private let tolerance: Float = 1e-5

    func testArgmaxBasic() {
        let values: [Float] = [1, 5, 3]
        let result = values.withUnsafeBufferPointer { MuesliAccelerate.argmax($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.value, 5)
    }

    func testArgmaxAllNegative() {
        let values: [Float] = [-3, -9, -1, -4]
        let result = values.withUnsafeBufferPointer { MuesliAccelerate.argmax($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(result.index, 2)
        XCTAssertEqual(result.value, -1)
    }

    func testArgmaxTieReturnsFirstIndex() {
        let values: [Float] = [2, 2, 1, 2]
        let result = values.withUnsafeBufferPointer { MuesliAccelerate.argmax($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.value, 2)
    }

    func testArgmaxSingleElement() {
        let values: [Float] = [7]
        let result = values.withUnsafeBufferPointer { MuesliAccelerate.argmax($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.value, 7)
    }

    func testMatvecMatchesNaiveReference() {
        let matrix: [Float] = [1, 2, 3, 4, 5, 6] // 2 x 3
        let vector: [Float] = [0.5, -1.0, 2.0]
        var output = [Float](repeating: 0, count: 2)

        matrix.withUnsafeBufferPointer { matrixPointer in
            vector.withUnsafeBufferPointer { vectorPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    MuesliAccelerate.matvec(
                        matrix: matrixPointer.baseAddress!,
                        rows: 2,
                        columns: 3,
                        vector: vectorPointer.baseAddress!,
                        output: outputPointer.baseAddress!
                    )
                }
            }
        }

        let reference: [Float] = [1 * 0.5 + 2 * -1.0 + 3 * 2.0, 4 * 0.5 + 5 * -1.0 + 6 * 2.0]
        XCTAssertEqual(output[0], reference[0], accuracy: tolerance)
        XCTAssertEqual(output[1], reference[1], accuracy: tolerance)
    }

    func testElementwiseOperations() {
        let source: [Float] = [-2, 0.5, 3]
        var destination = [Float](repeating: 0, count: source.count)

        source.withUnsafeBufferPointer { sourcePointer in
            destination.withUnsafeMutableBufferPointer { destinationPointer in
                MuesliAccelerate.square(sourcePointer.baseAddress!, destinationPointer.baseAddress!, count: source.count)
            }
        }
        XCTAssertEqual(destination, [4, 0.25, 9])

        destination.withUnsafeMutableBufferPointer { pointer in
            MuesliAccelerate.clip(pointer.baseAddress!, pointer.baseAddress!, low: 0.5, high: 5, count: pointer.count)
        }
        XCTAssertEqual(destination, [4, 0.5, 5])

        destination.withUnsafeMutableBufferPointer { pointer in
            MuesliAccelerate.addScalar(pointer.baseAddress!, pointer.baseAddress!, scalar: 1, count: pointer.count)
            MuesliAccelerate.divideScalar(pointer.baseAddress!, pointer.baseAddress!, scalar: 5, count: pointer.count)
        }
        XCTAssertEqual(destination[0], 1.0, accuracy: tolerance)
        XCTAssertEqual(destination[1], 0.3, accuracy: tolerance)
        XCTAssertEqual(destination[2], 1.2, accuracy: tolerance)
    }

    func testAddAndMax() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [4, 5, 6]
        var output = [Float](repeating: 0, count: 3)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                output.withUnsafeMutableBufferPointer { op in
                    MuesliAccelerate.add(ap.baseAddress!, bp.baseAddress!, op.baseAddress!, count: 3)
                }
            }
        }
        XCTAssertEqual(output, [5, 7, 9])
        let maximum = output.withUnsafeBufferPointer { MuesliAccelerate.max($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(maximum, 9)
    }

    func testLog10InPlace() {
        var values: [Float] = [1, 10, 100, 1e-10]
        values.withUnsafeMutableBufferPointer { pointer in
            MuesliAccelerate.log10(pointer.baseAddress!, count: pointer.count)
        }
        XCTAssertEqual(values[0], 0, accuracy: tolerance)
        XCTAssertEqual(values[1], 1, accuracy: tolerance)
        XCTAssertEqual(values[2], 2, accuracy: tolerance)
        XCTAssertEqual(values[3], -10, accuracy: 1e-3)
    }

    // MARK: - Mel spectrogram pipeline

    func testSilenceProducesConstantFloor() {
        let spectrogram = MuesliQwen3WhisperMelSpectrogram()
        let frames = 1600 / 160
        let mel = spectrogram.compute(audio: [Float](repeating: 0, count: 1600))

        XCTAssertEqual(mel.count, MuesliQwen3AsrConfig.numMelBins)
        XCTAssertEqual(mel.first?.count, frames)
        for row in mel {
            for value in row {
                XCTAssertEqual(value, -1.5, accuracy: 1e-3)
            }
        }
    }

    func testToneConcentratesEnergyInLowMelBins() {
        let spectrogram = MuesliQwen3WhisperMelSpectrogram()
        let sampleRate = Float(MuesliQwen3AsrConfig.sampleRate)
        let samples = 16000
        let audio: [Float] = (0..<samples).map { index in
            sinf(2 * .pi * 440 * Float(index) / sampleRate)
        }

        let mel = spectrogram.compute(audio: audio)
        XCTAssertEqual(mel.count, MuesliQwen3AsrConfig.numMelBins)

        for row in mel {
            XCTAssertTrue(row.allSatisfy { $0.isFinite })
        }

        func average(_ rows: ArraySlice<[Float]>) -> Float {
            let values = rows.flatMap { $0 }
            return values.reduce(0, +) / Float(values.count)
        }
        let low = average(mel[0..<10])
        let high = average(mel[(mel.count - 10)..<mel.count])
        XCTAssertGreaterThan(low, high, "440 Hz tone should favour low mel bins")
    }
}

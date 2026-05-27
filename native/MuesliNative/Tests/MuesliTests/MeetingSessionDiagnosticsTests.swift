import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingSessionDiagnostics")
struct MeetingSessionDiagnosticsTests {

    @Test("WAV measurement reads data chunk after metadata chunks")
    func wavMeasurementReadsDataChunkAfterMetadataChunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-diagnostics-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples: [Int16] = [0, 16_384, -16_384, 0]
        var data = Data()
        let dataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        let listPayload = Data("test".utf8)
        let riffSize = UInt32(4 + 8 + 16 + 8 + listPayload.count + 8 + Int(dataByteCount))

        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16_000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(32_000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        data.append(contentsOf: "LIST".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(listPayload.count).littleEndian) { Array($0) })
        data.append(listPayload)
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataByteCount.littleEndian) { Array($0) })
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)

        let stats = try #require(MeetingSessionDiagnostics.measureInt16Wav(at: url))

        #expect(stats.sampleCount == samples.count)
        #expect(stats.zeroSampleCount == 2)
        #expect(abs(stats.peak - 0.5) < 0.001)
    }
}

import Foundation
import XCTest
@testable import MuesliCore

/// Golden vectors for the LZFSE abstraction.
///
/// `goldenPayload` was encoded by Apple's reference LZFSE encoder (`liblzfse`),
/// which is the same bitstream format macOS `Compression` (`COMPRESSION_LZFSE`)
/// produces and accepts. On Windows the portable path decodes it via `liblzfse`;
/// on macOS the same test decodes it via `Compression`, proving the two
/// implementations interoperate on the canonical reference stream.
final class CompressionGoldenTests: XCTestCase {
    private static let goldenPayload =
        "muesli-core-lzfse-golden-v1|the quick brown fox jumps over the lazy dog|the quick brown fox jumps over the lazy dog|0123456789|abcdefghijklmnopqrstuvwxyz"
    private static let goldenBase64 =
        "YnZ4bpkAAAB7AAAA4CttdWVzbGktY29yZS1semZzZS1nb2xkZW4tdjF8dGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIAgf6GxhenkgZG9nOCzwE+AVMDEyMzQ1Njc4OXxhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5egYAAAAAAAAAYnZ4JA=="

    func testDecodesReferenceGoldenVector() throws {
        let golden = try XCTUnwrap(Data(base64Encoded: Self.goldenBase64))
        let expected = Data(Self.goldenPayload.utf8)

        var output = Data(count: expected.count)
        let written = output.withUnsafeMutableBytes { destination in
            golden.withUnsafeBytes { source in
                MuesliCompression.lzfseDecode(
                    source: source.bindMemory(to: UInt8.self).baseAddress!,
                    sourceCount: golden.count,
                    destination: destination.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity: expected.count
                )
            }
        }
        XCTAssertEqual(written, expected.count)
        XCTAssertEqual(output, expected)
    }

    func testEncodeDecodeRoundTripMatchesSource() throws {
        let source = Data(Self.goldenPayload.utf8)
        let encoded = try XCTUnwrap(encode(source))
        XCTAssertLessThan(encoded.count, source.count, "expected compressible payload")
        let decoded = try XCTUnwrap(decode(encoded, originalCount: source.count))
        XCTAssertEqual(decoded, source)
    }

    /// The codec uses marker 1 for LZFSE and falls back to marker 0 for
    /// incompressible payloads; both keep byte-exact round-trips.
    func testInsightsContributionCodecRoundTrip() {
        let pairs = [
            InsightsContributionCodec.Pair(tokenID: 42, count: 7),
            InsightsContributionCodec.Pair(tokenID: 43, count: 3),
            InsightsContributionCodec.Pair(tokenID: 1_000_000, count: 1),
        ]
        let encoded = InsightsContributionCodec.encode(pairs)
        XCTAssertEqual(InsightsContributionCodec.decode(encoded), pairs)
    }

    func testInsightsContributionCodecEmptyRoundTrip() {
        XCTAssertEqual(InsightsContributionCodec.decode(InsightsContributionCodec.encode([])), [])
    }

    func testCodecRejectsOversizedDeclaredLength() {
        // marker 1 + varint(> maximumDecodedBytes) must be rejected without decoding.
        var malicious = Data([1])
        var value = UInt64(InsightsContributionCodec.maximumDecodedBytes + 1)
        while value >= 0x80 {
            malicious.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        malicious.append(UInt8(value))
        XCTAssertEqual(InsightsContributionCodec.decode(malicious), [])
    }

    // MARK: - Helpers (mirror the abstraction under test)

    private func encode(_ data: Data) -> Data? {
        var output = Data(count: max(64, data.count + data.count / 4))
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                MuesliCompression.lzfseEncode(
                    source: source.bindMemory(to: UInt8.self).baseAddress!,
                    sourceCount: data.count,
                    destination: destination.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity: destination.count
                )
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    private func decode(_ data: Data, originalCount: Int) -> Data? {
        var output = Data(count: originalCount)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                MuesliCompression.lzfseDecode(
                    source: source.bindMemory(to: UInt8.self).baseAddress!,
                    sourceCount: data.count,
                    destination: destination.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity: originalCount
                )
            }
        }
        guard written == originalCount else { return nil }
        return output
    }
}

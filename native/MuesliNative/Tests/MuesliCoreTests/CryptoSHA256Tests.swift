import Foundation
import XCTest
@testable import MuesliCore

/// SHA-256 golden vectors for the CryptoKit/Swift-Crypto compatibility layer.
final class CryptoSHA256Tests: XCTestCase {
    private func hex(_ digest: MuesliSHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    func testKnownVectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "The quick brown fox jumps over the lazy dog",
                "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
            ),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(hex(MuesliSHA256.hash(data: Data(input.utf8))), expected, "input: \(input)")
        }
    }

    func testIncrementalMatchesOneShot() {
        var payload = Data()
        for index in 0..<(1 << 18) { // 256 KiB
            payload.append(UInt8(index & 0xff))
        }

        var hasher = MuesliSHA256()
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 4096, payload.count)
            hasher.update(data: payload[offset..<end])
            offset = end
        }
        let incremental = hex(hasher.finalize())
        let oneShot = hex(MuesliSHA256.hash(data: payload))
        XCTAssertEqual(incremental, oneShot)
    }

    /// Matches the manifest fingerprint composition in `ModelDownloadCoordinator`
    /// (length-delimited concatenation), so the abstraction is exercised the way
    /// production code uses it.
    func testLengthDelimitedFingerprintIsDeterministic() {
        func fingerprint(_ parts: [String]) -> String {
            var hasher = MuesliSHA256()
            for part in parts {
                hasher.update(data: Data(part.utf8))
                hasher.update(data: Data([0]))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let first = fingerprint(["alpha", "beta", "gamma"])
        XCTAssertEqual(first, fingerprint(["alpha", "beta", "gamma"]))
        XCTAssertNotEqual(first, fingerprint(["alpha", "beta", "gamma "]))
    }
}

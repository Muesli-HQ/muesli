// Internal Data helpers shared across the KittenTTS pipeline.

import Foundation

extension Data {
    /// Read a little-endian UInt16 at the given byte offset.
    func u16LE(at offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }

    /// Read a little-endian UInt32 at the given byte offset.
    func u32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    /// Read a little-endian UInt64 (returned as Int to avoid overflow in index arithmetic).
    func u64LE(at offset: Int) -> Int {
        Int(withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian)
    }

    /// Append a little-endian UInt16.
    mutating func appendLE16(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    /// Append a little-endian UInt32.
    mutating func appendLE32(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

extension String {
    /// Drop the last vowel (used in phonemics derivation for -ing forms).
    func droppingLastVowel() -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "ə", "æ", "ɑ", "ɔ", "ɛ", "ɪ", "ʊ"]
        guard let lastVowelIdx = lastIndex(where: { vowels.contains($0) }) else { return self }
        var s = self
        s.remove(at: lastVowelIdx)
        return s
    }
}

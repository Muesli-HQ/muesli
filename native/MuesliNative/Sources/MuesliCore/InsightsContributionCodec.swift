import Compression
import Foundation

enum InsightsContributionCodec {
    static let maximumDecodedBytes = 16 * 1024 * 1024

    struct Pair: Equatable {
        let tokenID: Int64
        let count: Int
    }

    static func encode(_ pairs: [Pair]) -> Data {
        var raw = Data()
        var previousID: Int64 = 0
        for pair in pairs.sorted(by: { $0.tokenID < $1.tokenID }) where pair.tokenID > 0 && pair.count > 0 {
            appendVarint(UInt64(pair.tokenID - previousID), to: &raw)
            appendVarint(UInt64(pair.count), to: &raw)
            previousID = pair.tokenID
        }
        guard !raw.isEmpty, let compressed = compress(raw), compressed.count < raw.count else {
            return framed(marker: 0, originalCount: raw.count, payload: raw)
        }
        return framed(marker: 1, originalCount: raw.count, payload: compressed)
    }

    static func decode(_ data: Data) -> [Pair] {
        guard let marker = data.first, marker == 0 || marker == 1 else { return [] }
        var offset = 1
        guard let originalCount = readVarint(data, offset: &offset),
              originalCount <= UInt64(Int.max),
              originalCount <= UInt64(maximumDecodedBytes) else { return [] }
        let payload = data.suffix(from: offset)
        let raw: Data
        if marker == 1 {
            guard let decoded = decompress(Data(payload), originalCount: Int(originalCount)) else { return [] }
            raw = decoded
        } else {
            guard payload.count == Int(originalCount) else { return [] }
            raw = Data(payload)
        }

        var pairs: [Pair] = []
        var rawOffset = 0
        var tokenID: Int64 = 0
        while rawOffset < raw.count {
            guard let delta = readVarint(raw, offset: &rawOffset),
                  let count = readVarint(raw, offset: &rawOffset),
                  delta <= UInt64(Int64.max - tokenID), count <= UInt64(Int.max) else { return [] }
            tokenID += Int64(delta)
            pairs.append(Pair(tokenID: tokenID, count: Int(count)))
        }
        return pairs
    }

    private static func framed(marker: UInt8, originalCount: Int, payload: Data) -> Data {
        var result = Data([marker])
        appendVarint(UInt64(originalCount), to: &result)
        result.append(payload)
        return result
    }

    private static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        var capacity = max(64, data.count + data.count / 4)
        for _ in 0..<3 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compression_encode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                        nil, COMPRESSION_LZFSE
                    )
                }
            }
            if written > 0 {
                output.count = written
                return output
            }
            capacity *= 2
        }
        return nil
    }

    private static func decompress(_ data: Data, originalCount: Int) -> Data? {
        guard originalCount >= 0, originalCount <= maximumDecodedBytes else { return nil }
        if originalCount == 0 { return Data() }
        var output = Data(count: originalCount)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, originalCount,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard written == originalCount else { return nil }
        return output
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private static func readVarint(_ data: Data, offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift <= 63 {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

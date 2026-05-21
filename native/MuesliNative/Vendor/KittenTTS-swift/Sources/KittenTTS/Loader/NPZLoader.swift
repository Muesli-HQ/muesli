import Foundation
import Czlib

/// A voice embedding loaded from a `.npz` file.
///
/// The rows dimension is indexed by `min(text_length, rows - 1)` following
/// the KittenTTS Python implementation.
struct VoiceEmbedding: Sendable {

    /// Number of rows (text-length buckets).
    let rows: Int

    /// Embedding dimension (e.g. 256).
    let cols: Int

    // Raw flat array, row-major.
    let data: [Float]

    /// Return the embedding slice for a given text length.
    ///
    /// - Parameter length: Number of tokens in the input sequence.
    /// - Returns: A `[Float]` vector of length ``cols``.
    func slice(forTextLength length: Int) -> [Float] {
        let idx   = min(length, rows - 1)
        let start = idx * cols
        return Array(data[start ..< start + cols])
    }
}

// MARK: - Errors

enum NPZError: Error {
    case readFailed
    case invalidZipSignature
    case invalidNPYMagic
    case unsupportedNPYVersion
    case unsupportedDType(String)
    case decompressionFailed
    case shapeParseFailed
    case truncated
}

// MARK: - Loader

/// Loads NumPy `.npz` archives (ZIP collections of `.npy` arrays).
///
/// Supports:
/// - ZIP stored (method 0) and DEFLATE-compressed (method 8) entries
/// - ZIP64 local headers (sizes stored as `0xFFFFFFFF` sentinel)
/// - float32 (`<f4`) and float16 (`<f2`) `.npy` arrays, little- and big-endian
enum NPZLoader {

    /// Load all float arrays from a `.npz` file.
    ///
    /// - Parameter url: File URL of the `.npz` archive on disk.
    /// - Returns: Dictionary mapping array names (without `.npy` extension) to
    ///   their ``VoiceEmbedding`` values.
    /// - Throws: ``NPZError`` on parse failure, or a `CocoaError` on I/O failure.
    static func load(contentsOf url: URL) throws -> [String: VoiceEmbedding] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parseZIP(data)
    }

    // MARK: - ZIP parsing

    private static func parseZIP(_ data: Data) throws -> [String: VoiceEmbedding] {
        var result: [String: VoiceEmbedding] = [:]
        var offset = 0

        while offset + 30 <= data.count {
            guard data.u32LE(at: offset) == 0x04034b50 else { break }

            let method           = Int(data.u16LE(at: offset + 8))
            var compressedSize   = Int(data.u32LE(at: offset + 18))
            var uncompressedSize = Int(data.u32LE(at: offset + 22))
            let nameLen          = Int(data.u16LE(at: offset + 26))
            let extraLen         = Int(data.u16LE(at: offset + 28))

            let nameStart  = offset + 30
            let extraStart = nameStart + nameLen
            let dataStart  = extraStart + extraLen

            // ZIP64: sizes are 0xFFFFFFFF → read from ZIP64 extra field (tag 0x0001)
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF {
                var exOff = extraStart
                while exOff + 4 <= extraStart + extraLen {
                    let tag  = Int(data.u16LE(at: exOff))
                    let size = Int(data.u16LE(at: exOff + 2))
                    if tag == 0x0001 && exOff + 4 + size >= exOff + 20 {
                        uncompressedSize = Int(data.u64LE(at: exOff + 4))
                        compressedSize   = Int(data.u64LE(at: exOff + 12))
                        break
                    }
                    exOff += 4 + size
                }
            }

            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { throw NPZError.truncated }

            let entryName = String(bytes: data[nameStart ..< nameStart + nameLen],
                                   encoding: .utf8) ?? ""

            if entryName.hasSuffix(".npy") {
                let compressed = data.subdata(in: dataStart ..< dataEnd)
                let fileData: Data
                switch method {
                case 0:  fileData = compressed
                case 8:  fileData = try deflateDecompress(compressed, expected: uncompressedSize)
                default: offset = dataEnd; continue
                }
                let arrayName = String(entryName.dropLast(4))
                if let embedding = try? parseNPY(fileData) {
                    result[arrayName] = embedding
                }
            }

            offset = dataEnd
        }

        return result
    }

    // MARK: - NPY parsing

    private static func parseNPY(_ data: Data) throws -> VoiceEmbedding {
        guard data.count >= 10 else { throw NPZError.truncated }

        // Magic bytes: 0x93 NUMPY
        guard data[0] == 0x93,
              data[1] == 0x4e, data[2] == 0x55, data[3] == 0x4d,
              data[4] == 0x50, data[5] == 0x59 else {
            throw NPZError.invalidNPYMagic
        }

        let major = data[6]
        let headerLen: Int
        let headerBase: Int
        if major >= 2 {
            guard data.count >= 12 else { throw NPZError.truncated }
            headerLen  = Int(data.u32LE(at: 8))
            headerBase = 12
        } else {
            headerLen  = Int(data.u16LE(at: 8))
            headerBase = 10
        }

        let dataStart = headerBase + headerLen
        guard dataStart <= data.count else { throw NPZError.truncated }

        let headerBytes = data.subdata(in: headerBase ..< headerBase + headerLen)
        let header = String(bytes: headerBytes, encoding: .ascii) ?? ""

        let shape  = try parseShape(header)
        guard shape.count >= 1 else { throw NPZError.shapeParseFailed }

        let rawData = data.subdata(in: dataStart ..< data.count)

        if header.contains("'f4'") || header.contains("<f4") || header.contains(">f4") {
            return try makeEmbedding(float32Data: rawData, shape: shape, bigEndian: header.contains(">f4"))
        } else if header.contains("'f2'") || header.contains("<f2") || header.contains(">f2") {
            return try makeEmbedding(float16Data: rawData, shape: shape, bigEndian: header.contains(">f2"))
        } else {
            let dtypeRange = header.range(of: "'descr': '") ?? header.range(of: "\"descr\": \"")
            if let r = dtypeRange {
                let after = String(header[r.upperBound...])
                throw NPZError.unsupportedDType(String(after.prefix(4)))
            }
            throw NPZError.unsupportedDType("unknown")
        }
    }

    private static func makeEmbedding(float32Data: Data, shape: [Int], bigEndian: Bool) throws -> VoiceEmbedding {
        let count = float32Data.count / 4
        var floats = [Float](unsafeUninitializedCapacity: count) { buf, n in
            float32Data.withUnsafeBytes { src in _ = src.copyBytes(to: buf) }
            n = count
        }
        if bigEndian {
            floats = floats.map { Float(bitPattern: $0.bitPattern.byteSwapped) }
        }
        let rows = shape.count >= 2 ? shape[0] : 1
        let cols = shape.count >= 2 ? shape[1] : shape[0]
        return VoiceEmbedding(rows: rows, cols: cols, data: floats)
    }

    private static func makeEmbedding(float16Data: Data, shape: [Int], bigEndian: Bool) throws -> VoiceEmbedding {
        let count = float16Data.count / 2
        let floats: [Float] = float16Data.withUnsafeBytes { ptr in
            let buf = ptr.bindMemory(to: UInt16.self)
            return (0 ..< count).map { i in
                let bits = bigEndian ? buf[i].byteSwapped : buf[i]
                return float16ToFloat(bits)
            }
        }
        let rows = shape.count >= 2 ? shape[0] : 1
        let cols = shape.count >= 2 ? shape[1] : shape[0]
        return VoiceEmbedding(rows: rows, cols: cols, data: floats)
    }

    private static func parseShape(_ header: String) throws -> [Int] {
        guard let open  = header.range(of: "("),
              let close = header.range(of: ")", range: open.upperBound ..< header.endIndex)
        else { throw NPZError.shapeParseFailed }

        let inside = String(header[open.upperBound ..< close.lowerBound])
        if inside.trimmingCharacters(in: .whitespaces).isEmpty { return [1] }

        let parts = inside.split(separator: ",").compactMap { part -> Int? in
            Int(part.trimmingCharacters(in: .whitespaces))
        }
        guard !parts.isEmpty else { throw NPZError.shapeParseFailed }
        return parts
    }

    // MARK: - DEFLATE decompression

    /// Decompress raw DEFLATE data (ZIP method 8, no zlib wrapper).
    private static func deflateDecompress(_ input: Data, expected: Int) throws -> Data {
        var output = Data(count: expected)
        var stream = z_stream()

        let ret = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr -> Int32 in
                stream.next_in   = UnsafeMutablePointer(mutating: inPtr.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in  = uInt(input.count)
                stream.next_out  = outPtr.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(expected)
                // -15 = raw DEFLATE (no zlib/gzip header)
                guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return Z_VERSION_ERROR
                }
                let r = inflate(&stream, Z_FINISH)
                inflateEnd(&stream)
                return r
            }
        }

        guard ret == Z_STREAM_END || ret == Z_OK else { throw NPZError.decompressionFailed }
        return output
    }

    // MARK: - Float16 conversion

    private static func float16ToFloat(_ bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits >> 15) << 31
        let exp16  = Int32((bits >> 10) & 0x1F)
        let mant16 = UInt32(bits & 0x3FF)

        if exp16 == 0 {
            if mant16 == 0 { return Float(bitPattern: sign) }
            var m = mant16; var e: Int32 = -14
            while (m & 0x400) == 0 { m <<= 1; e -= 1 }
            m &= 0x3FF
            let exp32 = UInt32(e + 127) << 23
            return Float(bitPattern: sign | exp32 | (m << 13))
        } else if exp16 == 31 {
            return Float(bitPattern: sign | 0x7F800000 | (mant16 << 13))
        }
        let exp32 = UInt32(exp16 - 15 + 127) << 23
        return Float(bitPattern: sign | exp32 | (mant16 << 13))
    }
}

import Foundation

#if canImport(Compression)
import Compression
#else
import CLZFSE
#endif

/// Platform-neutral LZFSE codec.
///
/// Apple platforms use Apple's `Compression` framework; Windows uses the
/// reference `liblzfse` implementation from vcpkg. Both produce and consume the
/// same LZFSE bitstream, so data written on one platform is readable on the
/// other. The only difference is that `liblzfse` requires a caller-provided
/// encode scratch buffer.
enum MuesliCompression {
    /// Encode `source` into `destination` using LZFSE.
    /// - Returns: number of bytes written, or `0` if the destination is too small
    ///   or encoding fails. Mirrors `compression_encode_buffer` semantics.
    static func lzfseEncode(
        source: UnsafePointer<UInt8>,
        sourceCount: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationCapacity: Int
    ) -> Int {
        #if canImport(Compression)
        return compression_encode_buffer(
            destination,
            destinationCapacity,
            source,
            sourceCount,
            nil,
            COMPRESSION_LZFSE
        )
        #else
        let scratchSize = max(lzfse_encode_scratch_size(), 1)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 8)
        defer { scratch.deallocate() }
        return lzfse_encode_buffer(
            destination,
            destinationCapacity,
            source,
            sourceCount,
            scratch
        )
        #endif
    }

    /// Decode an LZFSE bitstream from `source` into `destination`.
    /// - Returns: number of bytes written, or `0` if decoding fails or the
    ///   destination is too small. Mirrors `compression_decode_buffer` semantics.
    static func lzfseDecode(
        source: UnsafePointer<UInt8>,
        sourceCount: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationCapacity: Int
    ) -> Int {
        #if canImport(Compression)
        return compression_decode_buffer(
            destination,
            destinationCapacity,
            source,
            sourceCount,
            nil,
            COMPRESSION_LZFSE
        )
        #else
        return lzfse_decode_buffer(
            destination,
            destinationCapacity,
            source,
            sourceCount,
            nil
        )
        #endif
    }
}

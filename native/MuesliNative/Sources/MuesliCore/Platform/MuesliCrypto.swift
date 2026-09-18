import Foundation

#if canImport(CryptoKit)
import CryptoKit
/// SHA-256 implementation. Apple platforms keep CryptoKit; Windows uses
/// Apple Swift Crypto, which exposes an identical `SHA256` API.
typealias MuesliSHA256 = CryptoKit.SHA256
#else
import Crypto
typealias MuesliSHA256 = Crypto.SHA256
#endif

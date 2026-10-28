import CryptoKit
import Foundation

/// Wire format shared with the browser. No networking, persistence, or credentials.
enum SharingCipher {
    enum Failure: LocalizedError {
        case tooLarge, invalidContent
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Notes are limited to 100 KB for this preview."
            case .invalidContent: return "Use a title of 1–200 characters and include notes or a transcript."
            }
        }
    }
    static let format = "muesli-note-aes256gcm-v1"
    static func encrypt(title: String, summary: String, transcript: String) throws -> (key: Data, id: String, envelope: [String: String]) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf16.count <= 200,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Failure.invalidContent }
        let data = try JSONSerialization.data(withJSONObject: ["title": title, "summary": summary, "transcript": transcript])
        guard data.count <= 100 * 1024 else { throw Failure.tooLarge }
        let key = SymmetricKey(size: .bits256)
        let id = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data("\(format):\(id)".utf8))
        return (key.withUnsafeBytes { Data($0) }, id,
                ["format": format, "sharingId": id,
                 "nonce": sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                 "ciphertext": (sealed.ciphertext + sealed.tag).base64EncodedString()])
    }
    static func wrap(key: Data, noteID: String, publicData: Data) throws -> [String: String] {
        guard key.count == 32, noteID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CocoaError(.coderInvalidValue) }
        let keyID = SHA256.hash(data: publicData).map { String(format: "%02x", $0) }.joined()
        let remote = try P256.KeyAgreement.PublicKey(x963Representation: publicData)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: remote)
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let info = Data("muesli-wrap-p256-v1:\(noteID):\(keyID)".utf8)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.seal(key, using: wrapping, authenticating: info)
        return ["noteId": noteID, "keyId": keyID,
                "ephemeralPublicKey": ephemeral.publicKey.x963Representation.base64EncodedString(),
                "salt": salt.base64EncodedString(),
                "nonce": box.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                "ciphertext": (box.ciphertext + box.tag).base64EncodedString()]
    }
}

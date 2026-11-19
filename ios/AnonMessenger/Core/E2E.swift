import Foundation
import CryptoKit

/// End-to-end encryption: X25519 key agreement -> HKDF -> ChaCha20-Poly1305.
/// The server only ever sees the base64 ciphertext produced here.
enum E2E {
    enum Failure: Error { case badCiphertext }

    private static let salt = Data("anon-messenger-v1".utf8)

    private static func key(_ mine: Curve25519.KeyAgreement.PrivateKey,
                            _ theirs: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let secret = try mine.sharedSecretFromKeyAgreement(with: theirs)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(), outputByteCount: 32)
    }

    static func encrypt(_ text: String,
                        from mine: Curve25519.KeyAgreement.PrivateKey,
                        to theirs: Curve25519.KeyAgreement.PublicKey) throws -> String {
        let sealed = try ChaChaPoly.seal(Data(text.utf8), using: try key(mine, theirs))
        return sealed.combined.base64EncodedString()
    }

    static func decrypt(_ body: String,
                        using mine: Curve25519.KeyAgreement.PrivateKey,
                        from theirs: Curve25519.KeyAgreement.PublicKey) throws -> String {
        guard let data = Data(base64Encoded: body) else { throw Failure.badCiphertext }
        let box = try ChaChaPoly.SealedBox(combined: data)
        let plain = try ChaChaPoly.open(box, using: try key(mine, theirs))
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.badCiphertext }
        return text
    }

    /// Both people see the same code. If it matches when compared out-of-band (in person,
    /// over a call), nobody - including the server - swapped keys in between.
    static func safetyNumber(_ a: Curve25519.KeyAgreement.PublicKey,
                             _ b: Curve25519.KeyAgreement.PublicKey) -> String {
        let (x, y) = (a.rawRepresentation, b.rawRepresentation)
        let ordered = x.lexicographicallyPrecedes(y) ? x + y : y + x
        let digest = Array(SHA256.hash(data: ordered).prefix(10))
        let hex = digest.map { String(format: "%02X", $0) }
        return stride(from: 0, to: hex.count, by: 2).map { hex[$0] + hex[$0 + 1] }.joined(separator: " ")
    }
}

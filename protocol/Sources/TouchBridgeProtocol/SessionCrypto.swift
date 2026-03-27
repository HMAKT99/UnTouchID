import Foundation
import CryptoKit

/// Errors during session key operations.
public enum SessionCryptoError: Error, Sendable {
    case keyAgreementFailed
    case encryptionFailed
    case decryptionFailed
}

/// Manages per-connection ECDH ephemeral session keys and AES-GCM encryption.
///
/// Each BLE connection establishes a new `SessionCrypto` instance via ECDH key agreement.
/// The shared secret is derived into an AES-256 key via HKDF-SHA256.
/// All challenge nonces are encrypted in transit using AES-GCM.
public struct SessionCrypto: Sendable {
    /// The derived symmetric key for this session.
    private let symmetricKey: SymmetricKey

    /// Initialize with a pre-derived symmetric key (for testing or key import).
    public init(symmetricKey: SymmetricKey) {
        self.symmetricKey = symmetricKey
    }

    // MARK: - Key Agreement

    /// Generate an ephemeral P-256 key pair for ECDH.
    public static func generateEphemeralKeyPair() -> (
        privateKey: P256.KeyAgreement.PrivateKey,
        publicKey: P256.KeyAgreement.PublicKey
    ) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }

    /// Derive a session from ECDH key agreement between our private key and their public key.
    public static func deriveSession(
        myPrivate: P256.KeyAgreement.PrivateKey,
        theirPublic: P256.KeyAgreement.PublicKey
    ) throws -> SessionCrypto {
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try myPrivate.sharedSecretFromKeyAgreement(with: theirPublic)
        } catch {
            throw SessionCryptoError.keyAgreementFailed
        }

        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("TouchBridge-v1".utf8),
            outputByteCount: 32
        )

        return SessionCrypto(symmetricKey: symmetricKey)
    }

    // MARK: - Encryption / Decryption

    /// Encrypt plaintext using AES-256-GCM.
    ///
    /// Returns: nonce (12 bytes) + ciphertext + tag (16 bytes).
    public func encrypt(plaintext: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            guard let combined = sealedBox.combined else {
                throw SessionCryptoError.encryptionFailed
            }
            return combined
        } catch is SessionCryptoError {
            throw SessionCryptoError.encryptionFailed
        } catch {
            throw SessionCryptoError.encryptionFailed
        }
    }

    /// Decrypt AES-256-GCM ciphertext (nonce + ciphertext + tag).
    public func decrypt(ciphertext: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw SessionCryptoError.decryptionFailed
        }
    }

    // MARK: - Public Key Serialization

    /// Export a P-256 public key to its compact representation for wire transfer.
    public static func exportPublicKey(_ key: P256.KeyAgreement.PublicKey) -> Data {
        key.x963Representation
    }

    /// Import a P-256 public key from its compact representation.
    public static func importPublicKey(_ data: Data) throws -> P256.KeyAgreement.PublicKey {
        try P256.KeyAgreement.PublicKey(x963Representation: data)
    }
}

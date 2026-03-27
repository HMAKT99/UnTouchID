import Foundation
import Security

/// Errors from Secure Enclave operations.
public enum SecureEnclaveError: Error, Sendable {
    case keyGenerationFailed(String)
    case signingFailed(String)
    case publicKeyExportFailed(String)
    case keyNotFound
    case deletionFailed(OSStatus)
    case accessControlCreationFailed
}

/// Protocol for signing operations — enables mock testing without Secure Enclave hardware.
public protocol SigningProvider: Sendable {
    func generateKeyPair(tag: String) throws -> Data
    func sign(data: Data, keyTag: String) throws -> Data
    func publicKey(for tag: String) throws -> Data
    func deleteKey(tag: String) throws
}

/// Manages ECDSA P-256 keys inside the Secure Enclave on iOS.
///
/// The private key never leaves the Secure Enclave chip. All signing operations
/// happen inside the hardware. Only the public key can be exported.
///
/// Key properties:
/// - Algorithm: ECDSA P-256 (secp256r1)
/// - Storage: `kSecAttrTokenIDSecureEnclave`
/// - Access: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// - Protection: `.privateKeyUsage` + `.biometryCurrentSet` (requires biometric)
public final class SecureEnclaveManager: SigningProvider, @unchecked Sendable {
    public init() {}

    /// Generate a new P-256 key pair in the Secure Enclave.
    ///
    /// - Parameter tag: Application tag to identify this key (e.g., "dev.touchbridge.signing").
    /// - Returns: The public key in X9.62 uncompressed format (65 bytes).
    public func generateKeyPair(tag: String) throws -> Data {
        // Delete any existing key with this tag first
        try? deleteKey(tag: tag)

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            nil
        ) else {
            throw SecureEnclaveError.accessControlCreationFailed
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecAttrAccessControl as String: accessControl,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw SecureEnclaveError.keyGenerationFailed(desc)
        }

        guard let pubKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.publicKeyExportFailed("could not extract public key")
        }

        guard let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw SecureEnclaveError.publicKeyExportFailed(desc)
        }

        return pubKeyData
    }

    /// Sign data with the Secure Enclave private key.
    ///
    /// This triggers a biometric prompt (Face ID / Touch ID) because the key
    /// was created with `.biometryCurrentSet` access control.
    ///
    /// - Parameters:
    ///   - data: The data to sign (typically a 32-byte challenge nonce).
    ///   - keyTag: The application tag of the signing key.
    /// - Returns: ECDSA signature in X9.62 DER format.
    public func sign(data: Data, keyTag: String) throws -> Data {
        let privateKey = try retrievePrivateKey(tag: keyTag)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw SecureEnclaveError.signingFailed(desc)
        }

        return signature
    }

    /// Export the public key for a given tag.
    ///
    /// - Parameter tag: The application tag of the key pair.
    /// - Returns: Public key in X9.62 uncompressed format (65 bytes).
    public func publicKey(for tag: String) throws -> Data {
        let privateKey = try retrievePrivateKey(tag: tag)

        guard let pubKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.publicKeyExportFailed("could not extract public key")
        }

        var error: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw SecureEnclaveError.publicKeyExportFailed(desc)
        }

        return pubKeyData
    }

    /// Delete a key pair by tag.
    public func deleteKey(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureEnclaveError.deletionFailed(status)
        }
    }

    // MARK: - Private

    private func retrievePrivateKey(tag: String) throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let key = result else {
            throw SecureEnclaveError.keyNotFound
        }

        // swiftlint:disable:next force_cast
        return key as! SecKey
    }
}

/// Mock signing provider for testing without Secure Enclave hardware.
///
/// Uses software P-256 keys instead of hardware-backed keys.
/// Suitable for simulator and CI testing.
public final class MockSigningProvider: SigningProvider, @unchecked Sendable {
    private var keys: [String: SecKey] = [:]

    public init() {}

    public func generateKeyPair(tag: String) throws -> Data {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw SecureEnclaveError.keyGenerationFailed(desc)
        }

        keys[tag] = privateKey

        guard let pubKey = SecKeyCopyPublicKey(privateKey),
              let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            throw SecureEnclaveError.publicKeyExportFailed("failed")
        }

        return pubKeyData
    }

    public func sign(data: Data, keyTag: String) throws -> Data {
        guard let privateKey = keys[keyTag] else {
            throw SecureEnclaveError.keyNotFound
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw SecureEnclaveError.signingFailed("mock signing failed")
        }

        return signature
    }

    public func publicKey(for tag: String) throws -> Data {
        guard let privateKey = keys[tag] else {
            throw SecureEnclaveError.keyNotFound
        }

        guard let pubKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.publicKeyExportFailed("no public key")
        }

        var error: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            throw SecureEnclaveError.publicKeyExportFailed("export failed")
        }

        return pubKeyData
    }

    public func deleteKey(tag: String) throws {
        keys.removeValue(forKey: tag)
    }
}

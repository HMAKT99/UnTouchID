import Foundation
import os.log

/// Orchestrates the iOS side of challenge-response:
/// decrypt challenge → prompt biometric → sign nonce → encrypt response → send via BLE.
public final class ChallengeHandler: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "ChallengeHandler")

    private let signingProvider: SigningProvider
    private let localAuth: LocalAuthManager
    private let signingKeyTag: String

    /// Session crypto for the current BLE connection (set after ECDH).
    public var sessionCrypto: SessionCryptoWrapper?

    /// Callback to send the signed response back over BLE.
    public var sendResponse: ((Data) -> Bool)?

    public init(
        signingProvider: SigningProvider,
        localAuth: LocalAuthManager,
        signingKeyTag: String = "dev.touchbridge.signing"
    ) {
        self.signingProvider = signingProvider
        self.localAuth = localAuth
        self.signingKeyTag = signingKeyTag
    }

    /// Handle an incoming encrypted challenge from the Mac.
    ///
    /// Flow:
    /// 1. Decrypt with session key
    /// 2. Parse ChallengeIssuedMessage
    /// 3. Prompt biometric via LocalAuthManager
    /// 4. Sign nonce with Secure Enclave key
    /// 5. Build ChallengeResponseMessage
    /// 6. Encrypt with session key
    /// 7. Send via BLE
    @MainActor
    public func handleChallenge(encryptedData: Data, deviceID: String) async -> ChallengeHandlerResult {
        // 1. Decrypt
        guard let session = sessionCrypto else {
            logger.error("No session crypto — ECDH not yet completed")
            return .failed(.noSession)
        }

        let decryptedPayload: Data
        do {
            decryptedPayload = try session.decrypt(ciphertext: encryptedData)
        } catch {
            logger.error("Failed to decrypt challenge: \(error.localizedDescription)")
            return .failed(.decryptionFailed)
        }

        // 2. Parse
        let challengeMsg: ChallengeIssuedMessageCompanion
        do {
            challengeMsg = try JSONDecoder().decode(ChallengeIssuedMessageCompanion.self, from: decryptedPayload)
        } catch {
            logger.error("Failed to parse challenge: \(error.localizedDescription)")
            return .failed(.parseFailed)
        }

        // Check expiry
        let expiryDate = Date(timeIntervalSince1970: TimeInterval(challengeMsg.expiryUnix))
        guard Date() < expiryDate else {
            logger.warning("Challenge expired before biometric prompt")
            return .failed(.expired)
        }

        // 3. Prompt biometric
        let reason = "TouchBridge: \(challengeMsg.reason)"
        do {
            let authenticated = try await localAuth.authenticateUser(reason: reason)
            guard authenticated else {
                logger.info("Biometric authentication returned false")
                return .failed(.biometricDenied)
            }
        } catch {
            logger.info("Biometric authentication failed: \(error.localizedDescription)")
            return .failed(.biometricDenied)
        }

        // 4. Sign nonce
        let signature: Data
        do {
            signature = try signingProvider.sign(data: challengeMsg.encryptedNonce, keyTag: signingKeyTag)
        } catch {
            logger.error("Signing failed: \(error.localizedDescription)")
            return .failed(.signingFailed)
        }

        // 5. Build response
        let response = ChallengeResponseCompanion(
            challengeID: challengeMsg.challengeID,
            signature: signature,
            deviceID: deviceID
        )

        // 6. Encode
        let responseData: Data
        do {
            responseData = try JSONEncoder().encode(response)
        } catch {
            logger.error("Failed to encode response: \(error.localizedDescription)")
            return .failed(.encodingFailed)
        }

        // 7. Send
        if let send = sendResponse {
            let sent = send(responseData)
            if !sent {
                logger.warning("Failed to send response over BLE")
                return .failed(.sendFailed)
            }
        }

        logger.info("Challenge \(challengeMsg.challengeID) handled successfully")
        return .success(challengeID: challengeMsg.challengeID)
    }
}

// MARK: - Supporting Types

/// Result of handling a challenge.
public enum ChallengeHandlerResult: Sendable {
    case success(challengeID: String)
    case failed(ChallengeHandlerError)
}

public enum ChallengeHandlerError: Sendable, CustomStringConvertible {
    public var description: String {
        switch self {
        case .noSession: return "no_session"
        case .decryptionFailed: return "decryption_failed"
        case .parseFailed: return "parse_failed"
        case .expired: return "expired"
        case .biometricDenied: return "biometric_denied"
        case .signingFailed: return "signing_failed"
        case .encodingFailed: return "encoding_failed"
        case .sendFailed: return "send_failed"
        }
    }

    case noSession
    case decryptionFailed
    case parseFailed
    case expired
    case biometricDenied
    case signingFailed
    case encodingFailed
    case sendFailed
}

/// Wrapper around SessionCrypto operations for the companion side.
/// Avoids importing CryptoKit directly in the handler.
public final class SessionCryptoWrapper: @unchecked Sendable {
    private let encryptFn: (Data) throws -> Data
    private let decryptFn: (Data) throws -> Data

    public init(encrypt: @escaping (Data) throws -> Data, decrypt: @escaping (Data) throws -> Data) {
        self.encryptFn = encrypt
        self.decryptFn = decrypt
    }

    public func encrypt(plaintext: Data) throws -> Data {
        try encryptFn(plaintext)
    }

    public func decrypt(ciphertext: Data) throws -> Data {
        try decryptFn(ciphertext)
    }
}

/// Local copies of message types for the companion app (avoids cross-package dependency for Phase 0).
struct ChallengeIssuedMessageCompanion: Codable {
    let challengeID: String
    let encryptedNonce: Data
    let reason: String
    let expiryUnix: UInt64

    enum CodingKeys: String, CodingKey {
        case challengeID = "challengeID"
        case encryptedNonce
        case reason
        case expiryUnix
    }
}

struct ChallengeResponseCompanion: Codable {
    let challengeID: String
    let signature: Data
    let deviceID: String
}

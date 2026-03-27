import Foundation
import Security
import TouchBridgeProtocol

/// Result of a challenge verification attempt.
public enum ChallengeResult: Sendable, Equatable {
    case verified
    case expired
    case invalidSignature
    case replayDetected
    case unknownChallenge
}

/// A pending challenge awaiting a signed response.
public struct Challenge: Sendable {
    public let id: UUID
    public let nonce: Data
    public let issuedAt: Date
    public let expiresAt: Date
    public let deviceID: String

    public init(id: UUID, nonce: Data, issuedAt: Date, expiresAt: Date, deviceID: String) {
        self.id = id
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.deviceID = deviceID
    }
}

/// Provides the current time — injectable for testing.
public protocol TimeProvider: Sendable {
    func now() -> Date
}

/// Default time provider using system clock.
public struct SystemTimeProvider: TimeProvider, Sendable {
    public init() {}
    public func now() -> Date { Date() }
}

/// Manages challenge-response lifecycle: issuance, verification, expiry, and replay protection.
///
/// Thread-safe via Swift `actor` isolation. All state mutations are serialized.
public actor ChallengeManager {
    private let timeProvider: TimeProvider
    private let expiryInterval: TimeInterval
    private let replayWindowInterval: TimeInterval

    /// Active challenges keyed by UUID.
    private var pending: [UUID: Challenge] = [:]

    /// Seen nonces mapped to their expiry time for replay protection.
    private var seenNonces: [Data: Date] = [:]

    public init(
        timeProvider: TimeProvider = SystemTimeProvider(),
        expiryInterval: TimeInterval = TouchBridgeConstants.challengeExpirySeconds,
        replayWindowInterval: TimeInterval = TouchBridgeConstants.replayWindowSeconds
    ) {
        self.timeProvider = timeProvider
        self.expiryInterval = expiryInterval
        self.replayWindowInterval = replayWindowInterval
    }

    /// Issue a new challenge for the given device.
    ///
    /// Generates a 32-byte cryptographic nonce with a 10-second expiry window.
    public func issue(for deviceID: String) throws -> Challenge {
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else {
            throw ChallengeManagerError.nonceGenerationFailed(status)
        }

        let now = timeProvider.now()
        let challenge = Challenge(
            id: UUID(),
            nonce: Data(nonceBytes),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(expiryInterval),
            deviceID: deviceID
        )

        pending[challenge.id] = challenge
        return challenge
    }

    /// Verify a signed response to a previously issued challenge.
    ///
    /// Checks: challenge exists, not expired, nonce not replayed, ECDSA signature valid.
    public func verify(
        challengeID: UUID,
        signature: Data,
        publicKey: SecKey
    ) -> ChallengeResult {
        guard let challenge = pending.removeValue(forKey: challengeID) else {
            return .unknownChallenge
        }

        let now = timeProvider.now()

        // Check expiry
        if now > challenge.expiresAt {
            return .expired
        }

        // Check replay
        pruneExpiredNonces()
        if seenNonces[challenge.nonce] != nil {
            return .replayDetected
        }

        // Verify ECDSA signature
        var error: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(
            publicKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge.nonce as CFData,
            signature as CFData,
            &error
        )

        guard valid else {
            return .invalidSignature
        }

        // Mark nonce as seen for replay protection
        seenNonces[challenge.nonce] = now.addingTimeInterval(replayWindowInterval)

        return .verified
    }

    /// Remove expired challenges and stale replay-protection entries.
    public func pruneExpired() {
        let now = timeProvider.now()
        pending = pending.filter { $0.value.expiresAt > now }
        pruneExpiredNonces()
    }

    /// Number of pending challenges (for testing).
    public var pendingCount: Int { pending.count }

    /// Number of tracked seen nonces (for testing).
    public var seenNonceCount: Int { seenNonces.count }

    // MARK: - Private

    private func pruneExpiredNonces() {
        let now = timeProvider.now()
        seenNonces = seenNonces.filter { $0.value > now }
    }
}

public enum ChallengeManagerError: Error, Sendable {
    case nonceGenerationFailed(OSStatus)
}

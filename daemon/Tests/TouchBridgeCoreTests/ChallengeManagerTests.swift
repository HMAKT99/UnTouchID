import Testing
import Foundation
import Security
@testable import TouchBridgeCore

/// Controllable time provider for deterministic tests.
final class MockTimeProvider: TimeProvider, @unchecked Sendable {
    private var _now: Date

    init(now: Date = Date()) {
        self._now = now
    }

    func now() -> Date { _now }

    func advance(by interval: TimeInterval) {
        _now = _now.addingTimeInterval(interval)
    }
}

/// Helper to generate a software P-256 key pair for testing (no Secure Enclave).
private func generateTestKeyPair() -> (privateKey: SecKey, publicKey: SecKey) {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
    ]

    var error: Unmanaged<CFError>?
    let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!
    let publicKey = SecKeyCopyPublicKey(privateKey)!
    return (privateKey, publicKey)
}

/// Sign data with a SecKey using ECDSA P-256 SHA-256.
private func sign(data: Data, with privateKey: SecKey) -> Data {
    var error: Unmanaged<CFError>?
    let signature = SecKeyCreateSignature(
        privateKey,
        .ecdsaSignatureMessageX962SHA256,
        data as CFData,
        &error
    )!
    return signature as Data
}

// MARK: - Tests

@Test func issueProduces32ByteNonce() async throws {
    let manager = ChallengeManager()
    let challenge = try await manager.issue(for: "test-device")

    #expect(challenge.nonce.count == 32)
    #expect(challenge.deviceID == "test-device")
    #expect(challenge.expiresAt > challenge.issuedAt)
}

@Test func issuedNoncesAreUnique() async throws {
    let manager = ChallengeManager()
    let c1 = try await manager.issue(for: "device")
    let c2 = try await manager.issue(for: "device")

    #expect(c1.nonce != c2.nonce)
    #expect(c1.id != c2.id)
}

@Test func verifyValidSignature() async throws {
    let (privateKey, publicKey) = generateTestKeyPair()
    let manager = ChallengeManager()

    let challenge = try await manager.issue(for: "device")
    let signature = sign(data: challenge.nonce, with: privateKey)

    let result = await manager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: publicKey
    )

    #expect(result == .verified)
}

@Test func verifyExpiredChallenge() async throws {
    let time = MockTimeProvider()
    let manager = ChallengeManager(timeProvider: time, expiryInterval: 10.0)

    let (privateKey, publicKey) = generateTestKeyPair()
    let challenge = try await manager.issue(for: "device")
    let signature = sign(data: challenge.nonce, with: privateKey)

    // Advance past expiry
    time.advance(by: 11.0)

    let result = await manager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: publicKey
    )

    #expect(result == .expired)
}

@Test func verifyReplayDetected() async throws {
    let (privateKey, publicKey) = generateTestKeyPair()
    let manager = ChallengeManager()

    // Issue and verify first challenge
    let challenge = try await manager.issue(for: "device")
    let signature = sign(data: challenge.nonce, with: privateKey)

    let firstResult = await manager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: publicKey
    )
    #expect(firstResult == .verified)

    // Trying to verify the same challenge ID again should fail (already consumed)
    let replayResult = await manager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: publicKey
    )
    #expect(replayResult == .unknownChallenge)
}

@Test func verifyInvalidSignature() async throws {
    let (_, publicKey) = generateTestKeyPair()
    let manager = ChallengeManager()

    let challenge = try await manager.issue(for: "device")
    let garbageSignature = Data(repeating: 0xAB, count: 64)

    let result = await manager.verify(
        challengeID: challenge.id,
        signature: garbageSignature,
        publicKey: publicKey
    )

    #expect(result == .invalidSignature)
}

@Test func verifyWrongKey() async throws {
    let (privateKey1, _) = generateTestKeyPair()
    let (_, publicKey2) = generateTestKeyPair()
    let manager = ChallengeManager()

    let challenge = try await manager.issue(for: "device")
    let signature = sign(data: challenge.nonce, with: privateKey1)

    // Verify with a different public key
    let result = await manager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: publicKey2
    )

    #expect(result == .invalidSignature)
}

@Test func verifyUnknownChallenge() async throws {
    let (_, publicKey) = generateTestKeyPair()
    let manager = ChallengeManager()

    let result = await manager.verify(
        challengeID: UUID(),
        signature: Data(repeating: 0, count: 64),
        publicKey: publicKey
    )

    #expect(result == .unknownChallenge)
}

@Test func pruneRemovesExpiredChallenges() async throws {
    let time = MockTimeProvider()
    let manager = ChallengeManager(timeProvider: time, expiryInterval: 10.0)

    _ = try await manager.issue(for: "device1")
    _ = try await manager.issue(for: "device2")
    #expect(await manager.pendingCount == 2)

    time.advance(by: 11.0)
    await manager.pruneExpired()

    #expect(await manager.pendingCount == 0)
}

@Test func pruneRemovesExpiredSeenNonces() async throws {
    let time = MockTimeProvider()
    let (privateKey, publicKey) = generateTestKeyPair()
    let manager = ChallengeManager(
        timeProvider: time,
        expiryInterval: 10.0,
        replayWindowInterval: 60.0
    )

    let challenge = try await manager.issue(for: "device")
    let signature = sign(data: challenge.nonce, with: privateKey)
    let result = await manager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: publicKey
    )
    #expect(result == .verified)
    #expect(await manager.seenNonceCount == 1)

    // Advance past replay window
    time.advance(by: 61.0)
    await manager.pruneExpired()

    #expect(await manager.seenNonceCount == 0)
}

@Test func challengeExpiryWindowIsCorrect() async throws {
    let time = MockTimeProvider()
    let manager = ChallengeManager(timeProvider: time, expiryInterval: 10.0)

    let challenge = try await manager.issue(for: "device")
    let diff = challenge.expiresAt.timeIntervalSince(challenge.issuedAt)

    #expect(abs(diff - 10.0) < 0.001)
}

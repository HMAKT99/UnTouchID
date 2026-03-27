import Testing
import Foundation
import Security
import CryptoKit
@testable import TouchBridgeCore
@testable import TouchBridgeProtocol

/// End-to-end crypto integration test: simulates the full challenge-response
/// flow without BLE. Verifies the crypto pipe works from nonce generation
/// through ECDH encryption, signing, and verification.
@Test func endToEndChallengeResponseFlow() async throws {
    // --- Setup: simulate pairing ---
    // "iOS side" generates a signing key pair (simulating Secure Enclave)
    let signingKeyAttrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
    ]
    var error: Unmanaged<CFError>?
    let iosPrivateKey = SecKeyCreateRandomKey(signingKeyAttrs as CFDictionary, &error)!
    let iosPublicKey = SecKeyCopyPublicKey(iosPrivateKey)!
    let iosPublicKeyData = SecKeyCopyExternalRepresentation(iosPublicKey, &error)! as Data

    // "Mac side" stores the paired device
    let keychainService = "dev.touchbridge.test.integration.\(UUID().uuidString)"
    let store = KeychainStore(service: keychainService)
    defer { try? store.removeAll() }

    let device = PairedDevice(
        deviceID: "integration-test-device",
        publicKey: iosPublicKeyData,
        displayName: "Test iPhone",
        pairedAt: Date()
    )
    try store.storePairedDevice(device)

    // --- Setup: ECDH session ---
    let (macPrivate, macPublic) = SessionCrypto.generateEphemeralKeyPair()
    let (iosSessionPrivate, iosSessionPublic) = SessionCrypto.generateEphemeralKeyPair()

    let macSession = try SessionCrypto.deriveSession(myPrivate: macPrivate, theirPublic: iosSessionPublic)
    let iosSession = try SessionCrypto.deriveSession(myPrivate: iosSessionPrivate, theirPublic: macPublic)

    // --- Mac side: issue challenge ---
    let challengeManager = ChallengeManager()
    let challenge = try await challengeManager.issue(for: "integration-test-device")

    // Mac encrypts nonce for transmission
    let encryptedNonce = try macSession.encrypt(plaintext: challenge.nonce)

    // Simulate wire message
    let challengeMsg = ChallengeIssuedMessage(
        challengeID: challenge.id.uuidString,
        encryptedNonce: encryptedNonce,
        reason: "sudo",
        expiryUnix: UInt64(challenge.expiresAt.timeIntervalSince1970)
    )
    let wireData = try WireFormat.encode(.challengeIssued, challengeMsg)

    // Verify wire message fits in BLE limit
    #expect(wireData.count <= TouchBridgeConstants.maxMessageSize)

    // --- iOS side: receive, decrypt, sign ---
    let (_, payload) = try WireFormat.decode(data: wireData)
    let received = try WireFormat.decodePayload(ChallengeIssuedMessage.self, from: payload)

    let decryptedNonce = try iosSession.decrypt(ciphertext: received.encryptedNonce)
    #expect(decryptedNonce == challenge.nonce)

    // iOS signs the nonce with its Secure Enclave key (simulated with software key)
    let signature = SecKeyCreateSignature(
        iosPrivateKey,
        .ecdsaSignatureMessageX962SHA256,
        decryptedNonce as CFData,
        &error
    )! as Data

    // iOS builds response
    let responseMsg = ChallengeResponseMessage(
        challengeID: received.challengeID,
        signature: signature,
        deviceID: "integration-test-device"
    )
    let responseWire = try WireFormat.encode(.challengeResponse, responseMsg)
    #expect(responseWire.count <= TouchBridgeConstants.maxMessageSize)

    // --- Mac side: verify ---
    let (_, responsePayload) = try WireFormat.decode(data: responseWire)
    let response = try WireFormat.decodePayload(ChallengeResponseMessage.self, from: responsePayload)

    let storedPublicKey = try store.retrievePublicKey(for: response.deviceID)

    let result = await challengeManager.verify(
        challengeID: UUID(uuidString: response.challengeID)!,
        signature: response.signature,
        publicKey: storedPublicKey
    )

    #expect(result == .verified)

    // --- Audit log ---
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("touchbridge-integration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: logDir) }

    let auditLog = AuditLog(logDirectory: logDir)
    await auditLog.log(AuditEntry(
        sessionID: challenge.id.uuidString,
        surface: "pam_sudo",
        requestingProcess: "sudo",
        companionDevice: "Test iPhone",
        deviceID: "integration-test-device",
        result: "VERIFIED",
        authType: "biometric",
        rssi: -58,
        latencyMs: 150
    ))

    let entries = try await auditLog.readEntries()
    #expect(entries.count == 1)
    #expect(entries[0].result == "VERIFIED")
}

/// Verify that replayed nonces are rejected even through the full flow.
@Test func endToEndReplayRejection() async throws {
    let signingKeyAttrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
    ]
    var error: Unmanaged<CFError>?
    let iosPrivateKey = SecKeyCreateRandomKey(signingKeyAttrs as CFDictionary, &error)!
    let iosPublicKey = SecKeyCopyPublicKey(iosPrivateKey)!

    let challengeManager = ChallengeManager()
    let challenge = try await challengeManager.issue(for: "device-1")

    let signature = SecKeyCreateSignature(
        iosPrivateKey,
        .ecdsaSignatureMessageX962SHA256,
        challenge.nonce as CFData,
        &error
    )! as Data

    // First verification succeeds
    let result1 = await challengeManager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: iosPublicKey
    )
    #expect(result1 == .verified)

    // Second attempt with same challenge ID fails (consumed)
    let result2 = await challengeManager.verify(
        challengeID: challenge.id,
        signature: signature,
        publicKey: iosPublicKey
    )
    #expect(result2 == .unknownChallenge)
}

/// Verify ECDH public key can survive wire serialization round-trip.
@Test func ecdhPublicKeyWireSerialization() throws {
    let (_, publicKey) = SessionCrypto.generateEphemeralKeyPair()
    let exported = SessionCrypto.exportPublicKey(publicKey)

    // Wrap in a PairRequestMessage and round-trip through wire format
    let msg = PairRequestMessage(deviceName: "Test", publicKey: exported)
    let wireData = try WireFormat.encode(.pairRequest, msg)
    let (_, payload) = try WireFormat.decode(data: wireData)
    let decoded = try WireFormat.decodePayload(PairRequestMessage.self, from: payload)

    let importedKey = try SessionCrypto.importPublicKey(decoded.publicKey)
    #expect(SessionCrypto.exportPublicKey(importedKey) == exported)
}

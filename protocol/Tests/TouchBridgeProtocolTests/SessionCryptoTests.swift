import Testing
import Foundation
import CryptoKit
@testable import TouchBridgeProtocol

@Test func ecdhKeyAgreementProducesSameSession() throws {
    let (privA, pubA) = SessionCrypto.generateEphemeralKeyPair()
    let (privB, pubB) = SessionCrypto.generateEphemeralKeyPair()

    let sessionA = try SessionCrypto.deriveSession(myPrivate: privA, theirPublic: pubB)
    let sessionB = try SessionCrypto.deriveSession(myPrivate: privB, theirPublic: pubA)

    // Both sides should be able to decrypt what the other encrypts
    let plaintext = Data("hello touchbridge".utf8)
    let encrypted = try sessionA.encrypt(plaintext: plaintext)
    let decrypted = try sessionB.decrypt(ciphertext: encrypted)

    #expect(decrypted == plaintext)
}

@Test func encryptDecryptRoundTrip() throws {
    let (privA, _) = SessionCrypto.generateEphemeralKeyPair()
    let (_, pubB) = SessionCrypto.generateEphemeralKeyPair()

    let session = try SessionCrypto.deriveSession(myPrivate: privA, theirPublic: pubB)

    let plaintext = Data(repeating: 0x42, count: 32) // simulated nonce
    let encrypted = try session.encrypt(plaintext: plaintext)
    let decrypted = try session.decrypt(ciphertext: encrypted)

    #expect(decrypted == plaintext)
    #expect(encrypted != plaintext)
    #expect(encrypted.count > plaintext.count) // nonce + tag overhead
}

@Test func tamperDetected() throws {
    let (privA, _) = SessionCrypto.generateEphemeralKeyPair()
    let (_, pubB) = SessionCrypto.generateEphemeralKeyPair()

    // Use A's private with B's public for a valid session (won't match B's side, but we just need one side)
    let session = try SessionCrypto.deriveSession(myPrivate: privA, theirPublic: pubB)

    let plaintext = Data("sensitive data".utf8)
    var encrypted = try session.encrypt(plaintext: plaintext)

    // Tamper with the ciphertext
    let tamperIndex = encrypted.count / 2
    encrypted[tamperIndex] ^= 0xFF

    #expect(throws: SessionCryptoError.self) {
        try session.decrypt(ciphertext: encrypted)
    }
}

@Test func differentSessionsDifferentCiphertexts() throws {
    let (privA1, _) = SessionCrypto.generateEphemeralKeyPair()
    let (_, pubB1) = SessionCrypto.generateEphemeralKeyPair()

    let (privA2, _) = SessionCrypto.generateEphemeralKeyPair()
    let (_, pubB2) = SessionCrypto.generateEphemeralKeyPair()

    let session1 = try SessionCrypto.deriveSession(myPrivate: privA1, theirPublic: pubB1)
    let session2 = try SessionCrypto.deriveSession(myPrivate: privA2, theirPublic: pubB2)

    let plaintext = Data("same input".utf8)
    let encrypted1 = try session1.encrypt(plaintext: plaintext)
    let encrypted2 = try session2.encrypt(plaintext: plaintext)

    // Different sessions produce different ciphertexts (different keys + random nonces)
    #expect(encrypted1 != encrypted2)
}

@Test func crossSessionDecryptFails() throws {
    let (privA, _) = SessionCrypto.generateEphemeralKeyPair()
    let (_, pubB) = SessionCrypto.generateEphemeralKeyPair()
    let (privC, _) = SessionCrypto.generateEphemeralKeyPair()
    let (_, pubD) = SessionCrypto.generateEphemeralKeyPair()

    let session1 = try SessionCrypto.deriveSession(myPrivate: privA, theirPublic: pubB)
    let session2 = try SessionCrypto.deriveSession(myPrivate: privC, theirPublic: pubD)

    let plaintext = Data("secret".utf8)
    let encrypted = try session1.encrypt(plaintext: plaintext)

    // Session 2 should NOT be able to decrypt session 1's ciphertext
    #expect(throws: SessionCryptoError.self) {
        try session2.decrypt(ciphertext: encrypted)
    }
}

@Test func publicKeyExportImportRoundTrip() throws {
    let (_, publicKey) = SessionCrypto.generateEphemeralKeyPair()

    let exported = SessionCrypto.exportPublicKey(publicKey)
    let imported = try SessionCrypto.importPublicKey(exported)

    #expect(SessionCrypto.exportPublicKey(imported) == exported)
}

@Test func encryptedNonceFitsInWireLimit() throws {
    let (privA, _) = SessionCrypto.generateEphemeralKeyPair()
    let (_, pubB) = SessionCrypto.generateEphemeralKeyPair()

    let session = try SessionCrypto.deriveSession(myPrivate: privA, theirPublic: pubB)

    // 32-byte nonce (the real challenge nonce size)
    let nonce = Data(repeating: 0xAA, count: 32)
    let encrypted = try session.encrypt(plaintext: nonce)

    // AES-GCM overhead: 12 (nonce) + 16 (tag) = 28 bytes
    // Total: 32 + 28 = 60 bytes — well within 256-byte wire limit
    #expect(encrypted.count == 32 + 12 + 16)
    #expect(encrypted.count <= TouchBridgeConstants.maxMessageSize)
}

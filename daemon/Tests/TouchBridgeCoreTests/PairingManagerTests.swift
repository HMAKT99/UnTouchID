import Testing
import Foundation
import Security
@testable import TouchBridgeCore
@testable import TouchBridgeProtocol

/// Generate a valid P-256 public key (65 bytes, uncompressed X9.62 format).
private func generateTestPublicKey() -> (privateKey: SecKey, publicKeyData: Data) {
    let attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
    ]
    var error: Unmanaged<CFError>?
    let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
    let publicKey = SecKeyCopyPublicKey(privateKey)!
    let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error)! as Data
    return (privateKey, publicKeyData)
}

private func makeStore() -> KeychainStore {
    KeychainStore(service: "dev.touchbridge.test.pairing.\(UUID().uuidString)")
}

// MARK: - Tests

@Test func generatePairingQRDataProducesValidJSON() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store, macName: "Test Mac")
    let qrData = try await manager.generatePairingQRData()

    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)
    #expect(payload.version == 1)
    #expect(payload.serviceUUID == TouchBridgeConstants.serviceUUID)
    #expect(payload.pairingToken.count == 16)
    #expect(payload.macName == "Test Mac")
}

@Test func generatePairingQRDataProducesUniqueTokens() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)

    let qr1 = try await manager.generatePairingQRData()
    let payload1 = try JSONDecoder().decode(PairingPayload.self, from: qr1)

    let qr2 = try await manager.generatePairingQRData()
    let payload2 = try JSONDecoder().decode(PairingPayload.self, from: qr2)

    #expect(payload1.pairingToken != payload2.pairingToken)
}

@Test func validatePairingRequestSucceeds() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)
    let qrData = try await manager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    let (_, publicKeyData) = generateTestPublicKey()

    let device = try await manager.validatePairingRequest(
        token: payload.pairingToken,
        devicePublicKey: publicKeyData,
        deviceName: "Test iPhone",
        deviceID: "device-123"
    )

    #expect(device.deviceID == "device-123")
    #expect(device.displayName == "Test iPhone")
    #expect(device.publicKey == publicKeyData)
}

@Test func validatePairingRequestRejectsWrongToken() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)
    _ = try await manager.generatePairingQRData()

    let (_, publicKeyData) = generateTestPublicKey()
    let wrongToken = Data(repeating: 0xFF, count: 16)

    await #expect(throws: PairingError.self) {
        try await manager.validatePairingRequest(
            token: wrongToken,
            devicePublicKey: publicKeyData,
            deviceName: "Test iPhone",
            deviceID: "device-123"
        )
    }
}

@Test func validatePairingRequestRejectsExpiredToken() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    // Use 0 second expiry so token is immediately expired
    let manager = PairingManager(keychainStore: store, tokenExpiry: 0)
    let qrData = try await manager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    let (_, publicKeyData) = generateTestPublicKey()

    // Token should be expired immediately
    await #expect(throws: PairingError.self) {
        try await manager.validatePairingRequest(
            token: payload.pairingToken,
            devicePublicKey: publicKeyData,
            deviceName: "Test iPhone",
            deviceID: "device-123"
        )
    }
}

@Test func validatePairingRequestRejectsNoPairingActive() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)
    let (_, publicKeyData) = generateTestPublicKey()

    // No pairing session started
    await #expect(throws: PairingError.self) {
        try await manager.validatePairingRequest(
            token: Data(repeating: 0, count: 16),
            devicePublicKey: publicKeyData,
            deviceName: "Test iPhone",
            deviceID: "device-123"
        )
    }
}

@Test func validatePairingRequestRejectsInvalidPublicKey() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)
    let qrData = try await manager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    // Invalid key: wrong length
    let badKey = Data(repeating: 0x04, count: 32)

    await #expect(throws: PairingError.self) {
        try await manager.validatePairingRequest(
            token: payload.pairingToken,
            devicePublicKey: badKey,
            deviceName: "Test iPhone",
            deviceID: "device-123"
        )
    }
}

@Test func completePairingStoresDevice() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)
    let qrData = try await manager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    let (_, publicKeyData) = generateTestPublicKey()

    let device = try await manager.validatePairingRequest(
        token: payload.pairingToken,
        devicePublicKey: publicKeyData,
        deviceName: "Test iPhone",
        deviceID: "device-456"
    )

    try await manager.completePairing(device: device)

    // Verify stored in Keychain
    let retrieved = try store.retrievePairedDevice(deviceID: "device-456")
    #expect(retrieved.displayName == "Test iPhone")
    #expect(retrieved.publicKey == publicKeyData)
}

@Test func completePairingClearsPairingSession() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)
    let qrData = try await manager.generatePairingQRData()
    let payload = try JSONDecoder().decode(PairingPayload.self, from: qrData)

    let (_, publicKeyData) = generateTestPublicKey()
    let device = try await manager.validatePairingRequest(
        token: payload.pairingToken,
        devicePublicKey: publicKeyData,
        deviceName: "Test iPhone",
        deviceID: "device-789"
    )

    try await manager.completePairing(device: device)

    // Pairing session should be cleared — second attempt should fail
    await #expect(throws: PairingError.self) {
        try await manager.validatePairingRequest(
            token: payload.pairingToken,
            devicePublicKey: publicKeyData,
            deviceName: "Another iPhone",
            deviceID: "device-999"
        )
    }
}

@Test func cancelPairingClearsSession() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)
    _ = try await manager.generatePairingQRData()

    #expect(await manager.isPairingActive == true)

    await manager.cancelPairing()

    #expect(await manager.isPairingActive == false)
}

@Test func isPairingActiveReflectsState() async throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let manager = PairingManager(keychainStore: store)

    // No pairing started
    #expect(await manager.isPairingActive == false)

    // Start pairing
    _ = try await manager.generatePairingQRData()
    #expect(await manager.isPairingActive == true)
}

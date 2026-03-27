import Testing
import Foundation
import Security
@testable import TouchBridgeCore

/// Each test gets its own Keychain service to avoid parallel test interference.
private func makeStore() -> KeychainStore {
    KeychainStore(service: "dev.touchbridge.test.\(UUID().uuidString)")
}

private func makeDevice(id: String = "test-device-1", name: String = "Test iPhone") -> PairedDevice {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
    ]
    var error: Unmanaged<CFError>?
    let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!
    let publicKey = SecKeyCopyPublicKey(privateKey)!
    let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error)! as Data

    return PairedDevice(
        deviceID: id,
        publicKey: publicKeyData,
        displayName: name,
        pairedAt: Date()
    )
}

// MARK: - Tests

@Test func storeAndRetrieve() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device = makeDevice()
    try store.storePairedDevice(device)

    let retrieved = try store.retrievePairedDevice(deviceID: device.deviceID)
    #expect(retrieved.deviceID == device.deviceID)
    #expect(retrieved.publicKey == device.publicKey)
    #expect(retrieved.displayName == device.displayName)
}

@Test func storeOverwritesExisting() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device1 = makeDevice(id: "same-id", name: "First")
    try store.storePairedDevice(device1)

    let device2 = makeDevice(id: "same-id", name: "Second")
    try store.storePairedDevice(device2)

    let retrieved = try store.retrievePairedDevice(deviceID: "same-id")
    #expect(retrieved.displayName == "Second")
}

@Test func retrieveNonexistentThrows() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    #expect(throws: KeychainStoreError.self) {
        try store.retrievePairedDevice(deviceID: "nonexistent")
    }
}

@Test func listDevices() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device1 = makeDevice(id: "device-a", name: "iPhone A")
    let device2 = makeDevice(id: "device-b", name: "iPhone B")
    try store.storePairedDevice(device1)
    try store.storePairedDevice(device2)

    let devices = try store.listPairedDevices()
    #expect(devices.count == 2)

    let ids = Set(devices.map(\.deviceID))
    #expect(ids.contains("device-a"))
    #expect(ids.contains("device-b"))
}

@Test func listDevicesEmptyReturnsEmptyArray() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let devices = try store.listPairedDevices()
    #expect(devices.isEmpty)
}

@Test func removeDevice() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device = makeDevice()
    try store.storePairedDevice(device)
    try store.removePairedDevice(deviceID: device.deviceID)

    #expect(throws: KeychainStoreError.self) {
        try store.retrievePairedDevice(deviceID: device.deviceID)
    }
}

@Test func removeNonexistentDoesNotThrow() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    try store.removePairedDevice(deviceID: "does-not-exist")
}

@Test func retrievePublicKeyReconstructsSecKey() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device = makeDevice()
    try store.storePairedDevice(device)

    let key = try store.retrievePublicKey(for: device.deviceID)

    let attributes = SecKeyCopyAttributes(key) as? [String: Any]
    let keyType = attributes?[kSecAttrKeyType as String] as? String
    #expect(keyType == kSecAttrKeyTypeECSECPrimeRandom as String)
}

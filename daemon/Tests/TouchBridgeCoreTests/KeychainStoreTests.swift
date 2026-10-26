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

/// Distinct services and permanent identity keys must remain isolated under
/// concurrent native Keychain I/O, including the QR/pairing workflow.
/// Each item is written once. A failed read is surfaced with its exact status,
/// never repaired by retrying or overwriting the item.
@Test func concurrentIsolatedStoreReadback() async throws {
    let services = (0..<24).map { _ in "dev.touchbridge.test.concurrent.\(UUID().uuidString)" }
    defer {
        for service in services {
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data((service + ".mac-identity-v2").utf8)] as CFDictionary)
        }
    }
    let (_, keyData) = { () -> (SecKey, Data) in
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
        let key = SecKeyCreateRandomKey(attrs as CFDictionary, nil)!
        return (key, SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
    }()
    await withTaskGroup(of: String?.self) { group in
        for index in 0..<24 {
            group.addTask {
                let service = services[index]
                let store = KeychainStore(service: service)
                defer { try? store.removeAll() }
                let device = PairedDevice(deviceID: "concurrent-\(index)", publicKey: keyData, displayName: "Fixture", pairedAt: Date())
                do {
                    if index.isMultiple(of: 3) { _ = try store.macIdentityPublicKey() }
                    try store.storePairedDevice(device)
                    let actual = try store.retrievePairedDevice(deviceID: device.deviceID)
                    guard actual == device else { return "readback value mismatch for fixture \(index)" }
                    return nil
                } catch { return "native Keychain fixture \(index): \(String(reflecting: error))" }
            }
        }
        for await failure in group { if let failure { Issue.record(Comment(rawValue: failure)) } }
    }
}

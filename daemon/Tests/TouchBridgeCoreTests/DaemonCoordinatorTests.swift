import Testing
import Foundation
import Security
import CryptoKit
@testable import TouchBridgeCore
@testable import TouchBridgeProtocol

// MARK: - MockBLEServer

/// Mock BLE server for DaemonCoordinator integration tests.
///
/// Records all outgoing calls (challenges, pairing responses, session keys) and
/// exposes `simulate*` methods to drive incoming BLE events without real hardware.
final class MockBLEServer: BLEServerInterface, @unchecked Sendable {
    weak var delegate: BLEServerDelegate?

    // Outgoing calls recorded for assertions
    var sentChallenges: [(data: Data, centralID: UUID)] = []
    var sentPairingResponses: [(data: Data, centralID: UUID)] = []
    var sentSessionKeys: [(data: Data, centralID: UUID)] = []

    // Configurable RSSI per central (default -60 dBm)
    var rssiValues: [UUID: Int] = [:]

    // Set to false to simulate BLE transmit queue full
    var sendSucceeds: Bool = true

    func startAdvertising() {}
    func stopAdvertising() {}

    @discardableResult
    func sendChallenge(_ data: Data, to centralID: UUID) -> Bool {
        sentChallenges.append((data, centralID))
        return sendSucceeds
    }

    @discardableResult
    func sendPairingData(_ data: Data, to centralID: UUID) -> Bool {
        sentPairingResponses.append((data, centralID))
        return sendSucceeds
    }

    @discardableResult
    func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool {
        sentSessionKeys.append((data, centralID))
        return sendSucceeds
    }

    var connectedCentralIDs: [UUID] { [] }

    func averageRSSI(for centralID: UUID) -> Int? {
        rssiValues[centralID] ?? -60
    }

    // MARK: - Test event simulators

    func simulateConnect(_ centralID: UUID) {
        delegate?.bleServer(self, centralDidConnect: centralID)
    }

    func simulateDisconnect(_ centralID: UUID) {
        delegate?.bleServer(self, centralDidDisconnect: centralID)
    }

    /// Simulate companion sending its ECDH public key; returns server's public key.
    func simulateSessionKey(_ keyData: Data, from centralID: UUID) -> Data? {
        delegate?.bleServer(self, didReceiveSessionKey: keyData, from: centralID)
    }

    func simulatePairingData(_ data: Data, from centralID: UUID) {
        delegate?.bleServer(self, didReceivePairingData: data, from: centralID)
    }

    func simulateResponse(_ data: Data, from centralID: UUID) {
        delegate?.bleServer(self, didReceiveResponse: data, from: centralID)
    }
}

// MARK: - CompanionSimulator

/// Simulates the iOS companion app's BLE/crypto behaviour for testing.
///
/// Handles ECDH key exchange, encrypted identify messages, challenge signing,
/// and key-invalidated error generation — matching the protocol the daemon expects.
final class CompanionSimulator: @unchecked Sendable {
    let centralID: UUID
    let deviceID: String
    let deviceName: String

    // P-256 signing key (simulates Secure Enclave)
    private let signingPrivateKey: SecKey
    /// Public key bytes to store in the daemon's Keychain during test setup.
    let signingPublicKeyData: Data

    // ECDH session (derived after key exchange)
    private(set) var sessionCrypto: SessionCrypto?
    private var ecdhPrivateKey: P256.KeyAgreement.PrivateKey?

    init(
        centralID: UUID = UUID(),
        deviceID: String = UUID().uuidString,
        deviceName: String = "Test iPhone"
    ) {
        self.centralID = centralID
        self.deviceID = deviceID
        self.deviceName = deviceName

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var cfErr: Unmanaged<CFError>?
        self.signingPrivateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr)!
        let pub = SecKeyCopyPublicKey(signingPrivateKey)!
        self.signingPublicKeyData = SecKeyCopyExternalRepresentation(pub, &cfErr)! as Data
    }

    // MARK: - ECDH

    /// Generate our ephemeral public key to send to the daemon.
    func ecdhPublicKeyData() -> Data {
        let key = P256.KeyAgreement.PrivateKey()
        ecdhPrivateKey = key
        return SessionCrypto.exportPublicKey(key.publicKey)
    }

    /// Receive the daemon's ECDH public key and derive the shared session.
    func completeECDH(daemonPublicKeyData: Data) throws {
        guard let myPrivate = ecdhPrivateKey else {
            throw CompanionError.ecdhNotStarted
        }
        let daemonPublic = try SessionCrypto.importPublicKey(daemonPublicKeyData)
        sessionCrypto = try SessionCrypto.deriveSession(myPrivate: myPrivate, theirPublic: daemonPublic)
    }

    // MARK: - Identify

    /// Create an encrypted identify message: [1, 6] + AES-GCM(JSON{deviceID, deviceName}).
    func makeIdentifyData() throws -> Data {
        guard let crypto = sessionCrypto else { throw CompanionError.noSession }

        struct Payload: Codable { let deviceID: String; let deviceName: String }
        let json = try JSONEncoder().encode(Payload(deviceID: deviceID, deviceName: deviceName))
        let encrypted = try crypto.encrypt(plaintext: json)

        var wire = Data([1, 6]) // version=1, type=identify(6)
        wire.append(encrypted)
        return wire
    }

    // MARK: - Challenge Response

    /// Receive a challenge wire frame and return a valid signed response wire frame.
    ///
    /// Wire in:  [1, 3] + JSON ChallengeIssuedMessage (encryptedNonce = AES-GCM(nonce))
    /// Wire out: [1, 4] + JSON ChallengeResponseMessage
    func respondToChallenge(_ wireData: Data) throws -> Data {
        guard let crypto = sessionCrypto else { throw CompanionError.noSession }

        // Parse challenge (strip 2-byte wire header)
        guard wireData.count > 2 else { throw CompanionError.invalidData }
        let payload = wireData.dropFirst(2)
        let msg = try WireFormat.decodePayload(ChallengeIssuedMessage.self, from: payload)

        // Decrypt nonce
        let nonce = try crypto.decrypt(ciphertext: msg.encryptedNonce)

        // Sign
        var cfErr: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signingPrivateKey,
            .ecdsaSignatureMessageX962SHA256,
            nonce as CFData,
            &cfErr
        ) as Data? else {
            throw CompanionError.signingFailed
        }

        // Encode response with wire header
        let response = ChallengeResponseMessage(
            challengeID: msg.challengeID,
            signature: signature,
            deviceID: deviceID
        )
        return try WireFormat.encode(.challengeResponse, response)
    }

    /// Respond with a bad signature (causes .invalidSignature on daemon side).
    func respondWithBadSignature(_ wireData: Data) throws -> Data {
        guard wireData.count > 2 else { throw CompanionError.invalidData }
        let payload = wireData.dropFirst(2)
        let msg = try WireFormat.decodePayload(ChallengeIssuedMessage.self, from: payload)

        let garbage = Data(repeating: 0xFF, count: 64)
        let response = ChallengeResponseMessage(
            challengeID: msg.challengeID,
            signature: garbage,
            deviceID: deviceID
        )
        return try WireFormat.encode(.challengeResponse, response)
    }

    // MARK: - Key Invalidated Error

    /// Create an encrypted key-invalidated error: [1, 5] + AES-GCM(JSON{code, description, challengeID}).
    ///
    /// Consumes the first challenge in wireData to extract the challengeID.
    func makeKeyInvalidatedError(for challengeWireData: Data) throws -> Data {
        guard let crypto = sessionCrypto else { throw CompanionError.noSession }
        guard challengeWireData.count > 2 else { throw CompanionError.invalidData }

        let payload = challengeWireData.dropFirst(2)
        let msg = try WireFormat.decodePayload(ChallengeIssuedMessage.self, from: payload)

        struct ErrorPayload: Codable {
            let code: UInt16
            let description: String
            let challengeID: String?
        }
        let errPayload = ErrorPayload(code: 1001, description: "key_invalidated", challengeID: msg.challengeID)
        let json = try JSONEncoder().encode(errPayload)
        let encrypted = try crypto.encrypt(plaintext: json)

        var wire = Data([1, 5]) // version=1, type=error(5)
        wire.append(encrypted)
        return wire
    }

    enum CompanionError: Error {
        case ecdhNotStarted, noSession, invalidData, signingFailed
    }
}

// MARK: - Test Helpers

/// Creates an isolated DaemonCoordinator with a MockBLEServer and temp keychain/log.
private func makeTestCoordinator() -> (
    coordinator: DaemonCoordinator,
    bleServer: MockBLEServer,
    keychain: KeychainStore,
    auditLog: AuditLog
) {
    let bleServer = MockBLEServer()
    let keychain = KeychainStore(service: "dev.touchbridge.test.\(UUID().uuidString)")
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString)")
    let auditLog = AuditLog(logDirectory: logDir)

    let coordinator = DaemonCoordinator(
        keychainStore: keychain,
        auditLog: auditLog,
        bleServer: bleServer
    )
    return (coordinator, bleServer, keychain, auditLog)
}

/// Register a companion's signing key in the keychain so `identify` and auth work.
private func register(_ companion: CompanionSimulator, in keychain: KeychainStore) throws {
    let device = PairedDevice(
        deviceID: companion.deviceID,
        publicKey: companion.signingPublicKeyData,
        displayName: companion.deviceName,
        pairedAt: Date()
    )
    try keychain.storePairedDevice(device)
}

/// Full companion connection setup: connect → ECDH → identify.
/// Leaves the companion's session ready to receive challenges.
private func fullyConnect(
    companion: CompanionSimulator,
    to coordinator: DaemonCoordinator,
    via bleServer: MockBLEServer
) async throws {
    // Connect
    bleServer.simulateConnect(companion.centralID)

    // ECDH: companion sends its public key, daemon responds
    let clientPubKey = companion.ecdhPublicKeyData()
    guard let serverPubKey = bleServer.simulateSessionKey(clientPubKey, from: companion.centralID) else {
        throw TestSetupError.ecdhFailed
    }
    try companion.completeECDH(daemonPublicKeyData: serverPubKey)

    // Identify: companion sends encrypted identity
    let identifyData = try companion.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000) // let the async identify Task complete
}

enum TestSetupError: Error { case ecdhFailed }

// MARK: - Session Lifecycle Tests

@Test func connectCreatesReadySession() async throws {
    let (coordinator, bleServer, _, _) = makeTestCoordinator()
    let centralID = UUID()

    #expect(coordinator.readyCentrals.isEmpty)
    bleServer.simulateConnect(centralID)
    // No ECDH yet — session exists but is not "ready" (no sessionCrypto)
    #expect(coordinator.readyCentrals.isEmpty)
}

@Test func ecdhExchangeProducesReadySession() async throws {
    let (coordinator, bleServer, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()

    bleServer.simulateConnect(companion.centralID)
    let clientPubKey = companion.ecdhPublicKeyData()
    let serverPubKey = bleServer.simulateSessionKey(clientPubKey, from: companion.centralID)

    #expect(serverPubKey != nil)
    #expect(coordinator.readyCentrals.contains(companion.centralID))

    // Companion can derive the same session
    #expect(throws: Never.self) {
        try companion.completeECDH(daemonPublicKeyData: serverPubKey!)
    }
}

@Test func disconnectClearsSession() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)
    #expect(coordinator.readyCentrals.contains(companion.centralID))

    bleServer.simulateDisconnect(companion.centralID)
    #expect(coordinator.readyCentrals.isEmpty)
}

@Test func multipleCompanionsCanConnectSimultaneously() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let c1 = CompanionSimulator()
    let c2 = CompanionSimulator()
    try register(c1, in: keychain)
    try register(c2, in: keychain)

    try await fullyConnect(companion: c1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: c2, to: coordinator, via: bleServer)

    #expect(coordinator.readyCentrals.count == 2)
}

// MARK: - Identify Tests

@Test func identifyKnownDeviceSetsDeviceID() async throws {
    let (coordinator, bleServer, keychain, auditLog) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // ECDH only (no identify yet)
    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    // Session is ECDH-ready but not identified — auth should fail
    let pre = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.5)
    #expect(pre.success == false)
    #expect(pre.reason == "no_companion_connected")

    // Now identify
    let identifyData = try companion.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    // Identified entry should be in audit log
    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "IDENTIFIED" })
}

@Test func identifyUnknownDeviceIsIgnored() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    // Deliberately NOT registering in keychain

    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    let identifyData = try companion.makeIdentifyData()
    bleServer.simulatePairingData(identifyData, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    // Device in keychain is unknown — should still not appear as auth target
    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.2)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func identifyWithoutECDHIsIgnored() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    bleServer.simulateConnect(companion.centralID)
    // No ECDH → no sessionCrypto → identify silently dropped

    // Fabricate an identify message without a real session (daemon can't decrypt it)
    let fakeIdentify = Data([1, 6]) + Data(repeating: 0xAA, count: 32)
    bleServer.simulatePairingData(fakeIdentify, from: companion.centralID)
    try await Task.sleep(nanoseconds: 80_000_000)

    let result = await coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 0.2)
    #expect(result.success == false)
}

// MARK: - Authentication — Happy Path

@Test func authFailsWithNoConnectedDevices() async throws {
    let (coordinator, _, _, _) = makeTestCoordinator()

    let result = await coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 1.0)

    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func authFailsWithUnidentifiedDevice() async throws {
    let (coordinator, bleServer, _, _) = makeTestCoordinator()
    let companion = CompanionSimulator()

    // ECDH only — no identify
    bleServer.simulateConnect(companion.centralID)
    let clientKey = companion.ecdhPublicKeyData()
    let serverKey = bleServer.simulateSessionKey(clientKey, from: companion.centralID)!
    try companion.completeECDH(daemonPublicKeyData: serverKey)

    let result = await coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 0.3)
    #expect(result.success == false)
    #expect(result.reason == "no_companion_connected")
}

@Test func authFullFlowSucceeds() async throws {
    let (coordinator, bleServer, keychain, auditLog) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1234, timeout: 5.0
    )

    // Wait for challenge to be dispatched
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge was sent to companion")
        return
    }
    #expect(sent.centralID == companion.centralID)

    // Companion signs and responds
    let response = try companion.respondToChallenge(sent.data)
    bleServer.simulateResponse(response, from: companion.centralID)

    let result = await authResult
    #expect(result.success == true)
    #expect(result.reason == nil)

    // Audit log must have a VERIFIED entry
    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "VERIFIED" })
}

@Test func authSuccessLogsVerifiedEntry() async throws {
    let (coordinator, bleServer, keychain, auditLog) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "screensaver", pid: 99, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    if let sent = bleServer.sentChallenges.last {
        let response = try companion.respondToChallenge(sent.data)
        bleServer.simulateResponse(response, from: companion.centralID)
    }
    _ = await authResult

    let entries = try await auditLog.readEntries()
    let verified = entries.filter { $0.result == "VERIFIED" }
    #expect(verified.count == 1)
    // The VERIFIED audit entry uses surface="challenge" (logged by didReceiveResponse, which
    // doesn't have access to the original PAM service name — that's in the ISSUED entry).
    #expect(verified[0].surface == "challenge")
}

@Test func authMultipleSequentialRequestsSucceed() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    for _ in 0..<3 {
        let initialCount = bleServer.sentChallenges.count

        async let authResult = coordinator.authenticateFromPAM(
            user: "arun", service: "sudo", pid: 1, timeout: 5.0
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        guard let sent = bleServer.sentChallenges.last, bleServer.sentChallenges.count > initialCount else {
            Issue.record("No new challenge sent")
            return
        }
        let response = try companion.respondToChallenge(sent.data)
        bleServer.simulateResponse(response, from: companion.centralID)

        let result = await authResult
        #expect(result.success == true)
    }
}

// MARK: - Authentication — Error Paths

@Test func authTimeoutReturnsTimeoutReason() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Use a very short timeout and never respond
    let result = await coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 0.2
    )

    #expect(result.success == false)
    #expect(result.reason == "timeout")
}

@Test func authInvalidSignatureReturnsFailure() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let sent = bleServer.sentChallenges.last else { return }
    let badResponse = try companion.respondWithBadSignature(sent.data)
    bleServer.simulateResponse(badResponse, from: companion.centralID)

    let result = await authResult
    #expect(result.success == false)
    #expect(result.reason == "invalid_signature")
}

@Test func authKeyInvalidatedReturnsFastFail() async throws {
    let (coordinator, bleServer, keychain, auditLog) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 10.0  // long timeout — should resolve fast
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    guard let sent = bleServer.sentChallenges.last else {
        Issue.record("No challenge sent")
        return
    }

    // Companion signals key invalidation instead of signing
    let errData = try companion.makeKeyInvalidatedError(for: sent.data)
    bleServer.simulateResponse(errData, from: companion.centralID)

    let result = await authResult
    #expect(result.success == false)
    #expect(result.reason == "key_invalidated")

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "FAILED_KEY_INVALIDATED" })
}

@Test func authDisconnectDuringPendingAuthTimesOut() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 0.5
    )
    try await Task.sleep(nanoseconds: 100_000_000)

    // Companion disconnects mid-auth
    bleServer.simulateDisconnect(companion.centralID)

    let result = await authResult
    // Disconnecting removes the session but doesn't resume the continuation — it times out
    #expect(result.success == false)
}

@Test func noDeviceLogsFailedNoDeviceEntry() async throws {
    let (coordinator, _, _, auditLog) = makeTestCoordinator()

    let result = await coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 1.0
    )
    #expect(result.success == false)

    let entries = try await auditLog.readEntries()
    #expect(entries.contains { $0.result == "FAILED_NO_DEVICE" })
}

// MARK: - Multi-Device Tests

@Test func authBroadcastsToAllIdentifiedDevices() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let c1 = CompanionSimulator()
    let c2 = CompanionSimulator()
    try register(c1, in: keychain)
    try register(c2, in: keychain)

    try await fullyConnect(companion: c1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: c2, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 200_000_000)

    // Both devices should have received a challenge
    let challenged = Set(bleServer.sentChallenges.map(\.centralID))
    #expect(challenged.contains(c1.centralID))
    #expect(challenged.contains(c2.centralID))

    // First response wins
    guard let c1Challenge = bleServer.sentChallenges.first(where: { $0.centralID == c1.centralID }) else { return }
    let response = try c1.respondToChallenge(c1Challenge.data)
    bleServer.simulateResponse(response, from: c1.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func authFirstResponseWins() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let c1 = CompanionSimulator()
    let c2 = CompanionSimulator()
    try register(c1, in: keychain)
    try register(c2, in: keychain)

    try await fullyConnect(companion: c1, to: coordinator, via: bleServer)
    try await fullyConnect(companion: c2, to: coordinator, via: bleServer)

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 200_000_000)

    // C2 responds first — should win
    guard let c2Challenge = bleServer.sentChallenges.first(where: { $0.centralID == c2.centralID }),
          let c1Challenge = bleServer.sentChallenges.first(where: { $0.centralID == c1.centralID }) else {
        return
    }

    let r2 = try c2.respondToChallenge(c2Challenge.data)
    bleServer.simulateResponse(r2, from: c2.centralID)

    // C1 responds second — continuation already consumed, should be a no-op
    let r1 = try c1.respondToChallenge(c1Challenge.data)
    bleServer.simulateResponse(r1, from: c1.centralID)

    let result = await authResult
    #expect(result.success == true)
}

@Test func authOnlyIdentifiedDevicesAreChallenged() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let identified = CompanionSimulator()
    let unidentified = CompanionSimulator()
    try register(identified, in: keychain)
    // unidentified is NOT registered and does NOT send identify

    // Connect identified — full setup
    try await fullyConnect(companion: identified, to: coordinator, via: bleServer)

    // Connect unidentified — ECDH only, no identify
    bleServer.simulateConnect(unidentified.centralID)
    let upk = unidentified.ecdhPublicKeyData()
    let spk = bleServer.simulateSessionKey(upk, from: unidentified.centralID)!
    try unidentified.completeECDH(daemonPublicKeyData: spk)

    let preChallengeCount = bleServer.sentChallenges.count

    async let authResult = coordinator.authenticateFromPAM(
        user: "arun", service: "sudo", pid: 1, timeout: 5.0
    )
    try await Task.sleep(nanoseconds: 150_000_000)

    // Only the identified companion should have been challenged
    let newChallenges = bleServer.sentChallenges.dropFirst(preChallengeCount)
    #expect(newChallenges.allSatisfy { $0.centralID == identified.centralID })
    #expect(!newChallenges.contains { $0.centralID == unidentified.centralID })

    // Complete auth so the test doesn't hang
    if let challenge = newChallenges.first {
        let response = try identified.respondToChallenge(challenge.data)
        bleServer.simulateResponse(response, from: identified.centralID)
    }
    _ = await authResult
}

// MARK: - Edge Cases

@Test func authLateResponseAfterTimeoutIsNoOp() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let result = coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 0.05)
    // Wait past the timeout
    try await Task.sleep(nanoseconds: 200_000_000)

    // Send a valid response AFTER timeout — OnceContinuation must not crash (no double-resume)
    guard let challengeWire = bleServer.sentChallenges.last?.data else {
        Issue.record("No challenge was sent")
        return
    }
    let lateResponse = try companion.respondToChallenge(challengeWire)
    bleServer.simulateResponse(lateResponse, from: companion.centralID)

    let (success, reason) = await result
    #expect(success == false)
    #expect(reason == "timeout")
}

@Test func authBLESendFailureResultsInImmediateFailure() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Simulate BLE transmit queue full — sendChallenge returns false
    bleServer.sendSucceeds = false

    let start = Date()
    let result = await coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 5.0)
    let elapsed = Date().timeIntervalSince(start)

    #expect(result.success == false)
    #expect(result.reason == "challenge_failed")
    #expect(elapsed < 1.0)  // must fail fast, not after the full 5s timeout
}

@Test func authResponseWithWrongDeviceIDIsIgnored() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    async let result = coordinator.authenticateFromPAM(user: "arun", service: "sudo", pid: 1, timeout: 2.0)
    try await Task.sleep(nanoseconds: 100_000_000)

    guard let challengeWire = bleServer.sentChallenges.last?.data else {
        Issue.record("No challenge was sent")
        return
    }
    let payload = challengeWire.dropFirst(2)
    let msg = try WireFormat.decodePayload(ChallengeIssuedMessage.self, from: payload)

    // Spoof: valid challengeID but a deviceID that is not in the keychain
    let spoofed = ChallengeResponseMessage(
        challengeID: msg.challengeID,
        signature: Data(repeating: 0, count: 64),
        deviceID: "spoofed-unknown-device"
    )
    let spoofWire = try WireFormat.encode(.challengeResponse, spoofed)
    bleServer.simulateResponse(spoofWire, from: companion.centralID)
    try await Task.sleep(nanoseconds: 50_000_000)  // let coordinator process the spoof

    // Correct response should still resolve auth successfully
    let goodResponse = try companion.respondToChallenge(challengeWire)
    bleServer.simulateResponse(goodResponse, from: companion.centralID)

    let (success, reason) = await result
    #expect(success == true)
    #expect(reason == nil)
}

// MARK: - Identify-on-Reconnect

@Test func reconnectAndReidentifyRestoresAuth() async throws {
    let (coordinator, bleServer, keychain, _) = makeTestCoordinator()
    let companion = CompanionSimulator()
    try register(companion, in: keychain)

    // First connection — full setup + auth
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)
    async let firstAuth = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 5.0)
    try await Task.sleep(nanoseconds: 150_000_000)
    if let challenge = bleServer.sentChallenges.last {
        bleServer.simulateResponse(try companion.respondToChallenge(challenge.data), from: companion.centralID)
    }
    let first = await firstAuth
    #expect(first.success == true)

    // Simulate Mac reboot: disconnect → reconnect → new ECDH → re-identify
    bleServer.simulateDisconnect(companion.centralID)
    try await fullyConnect(companion: companion, to: coordinator, via: bleServer)

    // Auth should work again without re-pairing
    async let secondAuth = coordinator.authenticateFromPAM(user: "u", service: "sudo", pid: 1, timeout: 5.0)
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let challenge2 = bleServer.sentChallenges.last else {
        Issue.record("No challenge after reconnect")
        return
    }
    bleServer.simulateResponse(try companion.respondToChallenge(challenge2.data), from: companion.centralID)
    let second = await secondAuth
    #expect(second.success == true)
}

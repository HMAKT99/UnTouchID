import XCTest
import CryptoKit
import UIKit
@testable import TouchBridge

@MainActor
private final class IsolatedBLE: BLEClient {
    var scans = 0
    var disconnects = 0
    var sessionWrites: [Data] = []
    var pairingWrites: [Data] = []
    var responses: [Data] = []
    init() { super.init(enableBluetooth: false) }
    override func startScanning() { scans += 1 }
    override func disconnect() { disconnects += 1; super.disconnect() }
    override func sendSessionKey(_ data: Data) -> Bool { sessionWrites.append(data); return true }
    override func sendPairingData(_ data: Data) -> Bool { pairingWrites.append(data); return true }
    override func sendResponse(_ data: Data) -> Bool { responses.append(data); return true }
}
private final class IsolatedSigner: SigningProvider, @unchecked Sendable {
    let backing = MockSigningProvider()
    var signatures = 0
    var failDeletion = false
    func generateKeyPair(tag: String) throws -> Data { try backing.generateKeyPair(tag: tag) }
    func publicKey(for tag: String) throws -> Data { try backing.publicKey(for: tag) }
    func sign(data: Data, keyTag: String) throws -> Data { signatures += 1; return try backing.sign(data: data, keyTag: keyTag) }
    func deleteKey(tag: String) throws { if failDeletion { throw ProtocolSecurityError.revoked }; try backing.deleteKey(tag: tag) }
}
@MainActor
final class CompanionSecurityTests: XCTestCase {
    let tag = "dev.touchbridge.signing"
    private func defaults() -> UserDefaults {
        let name = "dev.touchbridge.security-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func verifiedCoordinator(signer: IsolatedSigner, ble: IsolatedBLE, defaults: UserDefaults, authenticate: (@MainActor (String) async throws -> Bool)? = nil) throws -> (CompanionCoordinator, SessionCrypto) {
        let identity = P256.Signing.PrivateKey(), serverEphemeral = P256.KeyAgreement.PrivateKey()
        let phonePublic = try signer.generateKeyPair(tag: tag)
        defaults.set(TouchBridgeConstants.serviceUUID, forKey: "pairedMacID")
        defaults.set(identity.publicKey.x963Representation, forKey: "pairedMacPublicKey")
        defaults.set("test-phone", forKey: "companionDeviceID")
        let coordinator = CompanionCoordinator(signingProvider: signer, bleClient: ble, defaults: defaults, authenticate: authenticate)
        coordinator.bleClientDidBecomeReadyForSecureSession(ble, peripheralID: UUID())
        let client = try JSONDecoder().decode(ClientHello.self, from: XCTUnwrap(ble.sessionWrites.last))
        let transcript = try SecureHandshake.transcript(clientKey: client.ephemeralKey, serverKey: serverEphemeral.publicKey.x963Representation, service: TouchBridgeConstants.serviceUUID)
        let hello = ServerHello(ephemeralKey: serverEphemeral.publicKey.x963Representation, identityKey: identity.publicKey.x963Representation, signature: try identity.signature(for: transcript).derRepresentation)
        coordinator.bleClient(ble, didReceiveSessionKey: try JSONEncoder().encode(hello), from: UUID())
        let crypto = try SessionCrypto.deriveSession(myPrivate: serverEphemeral, theirPublic: SessionCrypto.importPublicKey(client.ephemeralKey))
        let identify = try WireFormat.open(XCTUnwrap(ble.pairingWrites.last), crypto: crypto)
        XCTAssertEqual(identify.type, .identify)
        coordinator.bleClient(ble, didReceivePairingData: try WireFormat.seal(.pairResponse, PairResponseMessage(deviceID: "test-phone", publicKey: phonePublic, accepted: true), crypto: crypto), from: UUID())
        XCTAssertTrue(coordinator.isSessionReady)
        return (coordinator, crypto)
    }
    private func challenge(_ coordinator: CompanionCoordinator, crypto: SessionCrypto, purpose: AuthorizationPayload.Purpose = .diagnostics) throws -> Data {
        let issued = UInt64(Date().timeIntervalSince1970)
        let payload = AuthorizationPayload(purpose: purpose, nonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }), macIdentityHash: try XCTUnwrap(coordinator.challengeHandler.macIdentityHash), uid: 501, pid: 1234, issued: issued, expiry: issued + 20, user: "alice", service: "sudo")
        return try WireFormat.seal(.challengeIssued, AuthorizationChallengeMessage(challengeID: UUID().uuidString, authorization: payload.encode()), crypto: crypto)
    }
    func testUnpairRevokesKeySessionAndLateApproval() async throws {
        let signer = IsolatedSigner(), ble = IsolatedBLE(), prefs = defaults()
        var pending: CheckedContinuation<Bool, Never>?
        let (coordinator, crypto) = try verifiedCoordinator(signer: signer, ble: ble, defaults: prefs, authenticate: { _ in await withCheckedContinuation { pending = $0 } })
        let initialSignatures = signer.signatures
        let bytes = try challenge(coordinator, crypto: crypto)
        let task = Task { await coordinator.challengeHandler.handleChallenge(encryptedData: bytes, deviceID: "test-phone") }
        while pending == nil { await Task.yield() }
        try coordinator.unpair()
        pending?.resume(returning: true)
        _ = await task.value
        XCTAssertEqual(signer.signatures, initialSignatures)
        XCTAssertTrue(ble.responses.isEmpty)
        XCTAssertFalse(coordinator.isSessionReady)
        XCTAssertNil(prefs.data(forKey: "pairedMacPublicKey"))
        XCTAssertTrue(prefs.bool(forKey: "pairingRevoked"))
        XCTAssertFalse(prefs.bool(forKey: "unpairIncomplete"))
        XCTAssertThrowsError(try signer.publicKey(for: tag))
        let scans = ble.scans
        coordinator.startScanning(); coordinator.resetConnectionAndScan()
        coordinator.bleClientDidBecomeReadyForSecureSession(ble, peripheralID: UUID())
        XCTAssertEqual(ble.scans, scans)
        XCTAssertEqual(ble.sessionWrites.count, 1)
        XCTAssertGreaterThan(ble.disconnects, 0)
    }
    func testDeletionFailureRemainsRevokedAcrossRestart() throws {
        let signer = IsolatedSigner(), ble = IsolatedBLE(), prefs = defaults()
        let (coordinator, _) = try verifiedCoordinator(signer: signer, ble: ble, defaults: prefs)
        signer.failDeletion = true
        XCTAssertThrowsError(try coordinator.unpair())
        XCTAssertTrue(prefs.bool(forKey: "pairingRevoked")); XCTAssertTrue(prefs.bool(forKey: "unpairIncomplete"))
        let nextBLE = IsolatedBLE()
        let restarted = CompanionCoordinator(signingProvider: signer, bleClient: nextBLE, defaults: prefs)
        restarted.startScanning(); XCTAssertEqual(nextBLE.scans, 0)
        XCTAssertThrowsError(try restarted.getOrCreateSigningKey())
        signer.failDeletion = false; XCTAssertNoThrow(try restarted.unpair())
    }
    func testCancelSuppressesLateCallbackWithoutDeletingPairing() async throws {
        let signer = IsolatedSigner(), ble = IsolatedBLE(), prefs = defaults()
        var pending: CheckedContinuation<Bool, Never>?
        let (coordinator, crypto) = try verifiedCoordinator(signer: signer, ble: ble, defaults: prefs, authenticate: { _ in await withCheckedContinuation { pending = $0 } })
        let signatures = signer.signatures
        let bytes = try challenge(coordinator, crypto: crypto)
        let task = Task { await coordinator.challengeHandler.handleChallenge(encryptedData: bytes, deviceID: "test-phone") }
        while pending == nil { await Task.yield() }
        coordinator.cancelCurrentChallenge(); pending?.resume(returning: true); _ = await task.value
        XCTAssertTrue(ble.responses.isEmpty); XCTAssertEqual(signer.signatures, signatures)
        XCTAssertTrue(coordinator.isSessionReady)
    }
    func testValidatedContextAndFullSignatureThenReplayRejected() async throws {
        let signer = IsolatedSigner(), ble = IsolatedBLE(), prefs = defaults()
        var reason = ""
        let (coordinator, crypto) = try verifiedCoordinator(signer: signer, ble: ble, defaults: prefs, authenticate: { reason = $0; return true })
        let bytes = try challenge(coordinator, crypto: crypto)
        let result = await coordinator.challengeHandler.handleChallenge(encryptedData: bytes, deviceID: "test-phone")
        guard case .success = result else { return XCTFail("legitimate diagnostic authorization rejected") }
        XCTAssertTrue(reason.contains("alice")); XCTAssertTrue(reason.contains("sudo")); XCTAssertTrue(reason.contains("1234"))
        let response = try WireFormat.open(XCTUnwrap(ble.responses.last), crypto: crypto)
        let proof = try WireFormat.decodePayload(ChallengeResponseMessage.self, from: response.payload)
        let original = try coordinator.challengeHandler.validatedChallenge(bytes).0.authorization
        let key = try P256.Signing.PublicKey(x963Representation: signer.publicKey(for: tag))
        XCTAssertTrue(try key.isValidSignature(P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: original))
        let count = ble.responses.count
        _ = await coordinator.challengeHandler.handleChallenge(encryptedData: bytes, deviceID: "test-phone")
        XCTAssertEqual(ble.responses.count, count)
        var corrupt = bytes; corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try coordinator.challengeHandler.validatedChallenge(corrupt))
        XCTAssertThrowsError(try coordinator.challengeHandler.validatedChallenge(Data([1, 3]) + bytes.dropFirst(2)))
    }
    func testSimulatorNeverSignsPAMEvidence() async throws {
        #if targetEnvironment(simulator)
        let signer = IsolatedSigner(), ble = IsolatedBLE(), prefs = defaults()
        let (coordinator, crypto) = try verifiedCoordinator(signer: signer, ble: ble, defaults: prefs, authenticate: { _ in true })
        let signatures = signer.signatures
        _ = await coordinator.challengeHandler.handleChallenge(encryptedData: try challenge(coordinator, crypto: crypto, purpose: .pam), deviceID: "test-phone")
        XCTAssertTrue(ble.responses.isEmpty); XCTAssertEqual(signer.signatures, signatures)
        #endif
    }
    func testForgedMacCannotGetTokenOrPersistAcceptance() throws {
        let ble = IsolatedBLE(), signer = IsolatedSigner(), prefs = defaults()
        let coordinator = CompanionCoordinator(signingProvider: signer, bleClient: ble, defaults: prefs)
        let pinned = P256.Signing.PrivateKey(), attacker = P256.Signing.PrivateKey(), ephemeral = P256.KeyAgreement.PrivateKey()
        coordinator.beginPairing(serviceUUID: TouchBridgeConstants.serviceUUID, token: Data(repeating: 7, count: 16), macName: "Mac", macPublicKey: pinned.publicKey.x963Representation)
        coordinator.bleClientDidBecomeReadyForSecureSession(ble, peripheralID: UUID())
        let client = try JSONDecoder().decode(ClientHello.self, from: XCTUnwrap(ble.sessionWrites.last))
        let transcript = try SecureHandshake.transcript(clientKey: client.ephemeralKey, serverKey: ephemeral.publicKey.x963Representation, service: TouchBridgeConstants.serviceUUID)
        let hello = ServerHello(ephemeralKey: ephemeral.publicKey.x963Representation, identityKey: attacker.publicKey.x963Representation, signature: try attacker.signature(for: transcript).derRepresentation)
        coordinator.bleClient(ble, didReceiveSessionKey: try JSONEncoder().encode(hello), from: UUID())
        XCTAssertTrue(ble.pairingWrites.isEmpty)
        coordinator.bleClient(ble, didReceivePairingData: Data("{\"accepted\":true}".utf8), from: UUID())
        XCTAssertNil(prefs.string(forKey: "pairedMacID")); XCTAssertFalse(coordinator.isSessionReady)
    }
}

extension CompanionSecurityTests {
    func testLegitimatePairingReleasesTokenOnlyAfterPinnedHandshakeAndPersistsAfterAcceptance() throws {
        let ble = IsolatedBLE(), signer = IsolatedSigner(), prefs = defaults()
        let coordinator = CompanionCoordinator(signingProvider: signer, bleClient: ble, defaults: prefs)
        let identity = P256.Signing.PrivateKey(), ephemeral = P256.KeyAgreement.PrivateKey(), token = Data(repeating: 7, count: 16)
        coordinator.beginPairing(serviceUUID: TouchBridgeConstants.serviceUUID, token: token, macName: "Trusted Mac", macPublicKey: identity.publicKey.x963Representation)
        XCTAssertNil(prefs.string(forKey: "pairedMacID")); XCTAssertNil(prefs.data(forKey: "pairedMacPublicKey"))
        coordinator.bleClientDidBecomeReadyForSecureSession(ble, peripheralID: UUID())
        XCTAssertTrue(ble.pairingWrites.isEmpty)
        let client = try JSONDecoder().decode(ClientHello.self, from: XCTUnwrap(ble.sessionWrites.last))
        let transcript = try SecureHandshake.transcript(clientKey: client.ephemeralKey, serverKey: ephemeral.publicKey.x963Representation, service: TouchBridgeConstants.serviceUUID)
        let hello = ServerHello(ephemeralKey: ephemeral.publicKey.x963Representation, identityKey: identity.publicKey.x963Representation, signature: try identity.signature(for: transcript).derRepresentation)
        coordinator.bleClient(ble, didReceiveSessionKey: try JSONEncoder().encode(hello), from: UUID())
        let crypto = try SessionCrypto.deriveSession(myPrivate: ephemeral, theirPublic: SessionCrypto.importPublicKey(client.ephemeralKey))
        let pairWire = try XCTUnwrap(ble.pairingWrites.last)
        XCTAssertThrowsError(try WireFormat.decodePayload(PairRequestMessage.self, from: pairWire.dropFirst(2)))
        let pair = try WireFormat.decodePayload(PairRequestMessage.self, from: WireFormat.open(pairWire, crypto: crypto).payload)
        XCTAssertEqual(pair.pairingToken, token)
        let bytes = try SecureHandshake.possessionBytes(transcript: transcript, deviceID: XCTUnwrap(pair.deviceID), deviceName: pair.deviceName, publicKey: pair.publicKey, token: pair.pairingToken)
        XCTAssertTrue(try P256.Signing.PublicKey(x963Representation: pair.publicKey).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: XCTUnwrap(pair.signature)), for: bytes))
        XCTAssertNil(prefs.string(forKey: "pairedMacID"))
        let accepted = try WireFormat.seal(.pairResponse, PairResponseMessage(deviceID: XCTUnwrap(pair.deviceID), publicKey: pair.publicKey, accepted: true), crypto: crypto)
        coordinator.bleClient(ble, didReceivePairingData: accepted, from: UUID())
        XCTAssertTrue(coordinator.isConnected); XCTAssertTrue(coordinator.discoveredMacs.isEmpty)
        XCTAssertEqual(coordinator.pairedDeviceID, pair.deviceID)
        XCTAssertEqual(coordinator.pairedSigningPublicKey, pair.publicKey)
        XCTAssertEqual(coordinator.pairedMacFingerprint?.count, 64); XCTAssertEqual(coordinator.signingFingerprint?.count, 64)
        XCTAssertEqual(prefs.data(forKey: "pairedMacPublicKey"), identity.publicKey.x963Representation)
        coordinator.disconnect(); XCTAssertFalse(coordinator.isSessionReady)
    }
    func testCoordinatorOnlyPresentsValidatedCanonicalContextAndSuppressesLateResultAfterUnpair() async throws {
        let signer = IsolatedSigner(), ble = IsolatedBLE(), prefs = defaults()
        var approval: CheckedContinuation<Bool, Never>?
        let (coordinator, crypto) = try verifiedCoordinator(signer: signer, ble: ble, defaults: prefs, authenticate: { _ in await withCheckedContinuation { approval = $0 } })
        var context: String?
        var results = 0
        coordinator.onChallengeReceived = { context = $0 }
        coordinator.onChallengeResult = { _, _, _ in results += 1 }
        let bytes = try challenge(coordinator, crypto: crypto)
        var tampered = bytes; tampered[tampered.count - 1] ^= 1
        coordinator.bleClient(ble, didReceiveChallenge: tampered, from: UUID())
        XCTAssertNil(context)
        coordinator.bleClient(ble, didReceiveChallenge: bytes, from: UUID())
        // The unit-test host may be backgrounded. Exercise the deferred lifecycle path.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 { if approval != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(approval)
        XCTAssertEqual(context, "alice — sudo (PID 1234)")
        try coordinator.unpair(); approval?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(results, 0); XCTAssertTrue(ble.responses.isEmpty)
        coordinator.bleClient(ble, connectionStateChanged: false, peripheralID: UUID())
    }
    func testLegacyPairingAndMalformedQRNeverStartScanning() {
        let ble = IsolatedBLE(), prefs = defaults()
        let coordinator = CompanionCoordinator(signingProvider: IsolatedSigner(), bleClient: ble, defaults: prefs)
        var failures = 0; coordinator.onPairingFailed = { failures += 1 }
        coordinator.beginPairing(serviceUUID: TouchBridgeConstants.serviceUUID, token: Data(repeating: 0, count: 16), macName: "legacy")
        coordinator.beginPairing(serviceUUID: "bad", token: Data(), macName: "bad", macPublicKey: Data())
        XCTAssertEqual(failures, 2); XCTAssertEqual(ble.scans, 0)
    }
}

extension CompanionSecurityTests {
    func testEncryptedHeartbeatNeedsNoBiometricAndUnpairStopsEcho() throws {
        let signer = IsolatedSigner(), ble = IsolatedBLE(), prefs = defaults()
        var approvals = 0
        let (coordinator, crypto) = try verifiedCoordinator(signer: signer, ble: ble, defaults: prefs, authenticate: { _ in approvals += 1; return true })
        let signatures = signer.signatures
        let nonce = Data(repeating: 3, count: 32)
        let ping = try WireFormat.seal(.presencePing, PresenceHeartbeatMessage(nonce: nonce), crypto: crypto)
        coordinator.bleClient(ble, didReceiveChallenge: ping, from: UUID())
        let response = try WireFormat.open(XCTUnwrap(ble.responses.last), crypto: crypto)
        XCTAssertEqual(response.type, .presencePong)
        XCTAssertEqual(try WireFormat.decodePayload(PresenceHeartbeatMessage.self, from: response.payload).nonce, nonce)
        XCTAssertEqual(approvals, 0); XCTAssertEqual(signer.signatures, signatures)
        let count = ble.responses.count
        var corrupt = ping; corrupt[corrupt.count - 1] ^= 1
        coordinator.bleClient(ble, didReceiveChallenge: corrupt, from: UUID())
        XCTAssertEqual(ble.responses.count, count)
        try coordinator.unpair()
        coordinator.bleClient(ble, didReceiveChallenge: ping, from: UUID())
        XCTAssertEqual(ble.responses.count, count)
    }
}

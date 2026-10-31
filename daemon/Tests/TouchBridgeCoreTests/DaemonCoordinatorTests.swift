import XCTest
import CryptoKit
import Security
@testable import TouchBridgeCore
import TouchBridgeProtocol

/// Logical BLE fixture, not native radio/Secure Enclave acceptance.
final class MockBLEServer: BLEServerInterface, @unchecked Sendable {
    weak var delegate: BLEServerDelegate?
    private let lock = NSLock()
    private var challenges: [(data: Data, centralID: UUID)] = []
    private var pairs: [(data: Data, centralID: UUID)] = []
    private var _sendSucceeds = true
    var sendSucceeds: Bool {
        get { lock.withLock { _sendSucceeds } }
        set { lock.withLock { _sendSucceeds = newValue } }
    }
    var sentChallenges: [(data: Data, centralID: UUID)] { lock.withLock { challenges } }
    var sentPairingResponses: [(data: Data, centralID: UUID)] { lock.withLock { pairs } }
    var connectedCentralIDs: [UUID] { [] }
    func startAdvertising() {}
    func stopAdvertising() {}
    func averageRSSI(for centralID: UUID) -> Int? { -60 }
    func sendChallenge(_ data: Data, to centralID: UUID) -> Bool {
        lock.withLock {
            challenges.append((data, centralID))
            return _sendSucceeds
        }
    }
    func sendPairingData(_ data: Data, to centralID: UUID) -> Bool {
        lock.withLock {
            pairs.append((data, centralID))
            return _sendSucceeds
        }
    }
    func sendSessionKey(_ data: Data, to centralID: UUID) -> Bool { true }
    func simulateConnect(_ id: UUID) { delegate?.bleServer(self, centralDidConnect: id) }
    func simulateDisconnect(_ id: UUID) { delegate?.bleServer(self, centralDidDisconnect: id) }
    func simulateSessionKey(_ bytes: Data, from id: UUID) -> Data? { delegate?.bleServer(self, didReceiveSessionKey: bytes, from: id) }
    func simulatePairingData(_ bytes: Data, from id: UUID) { delegate?.bleServer(self, didReceivePairingData: bytes, from: id) }
    func simulateResponse(_ bytes: Data, from id: UUID) { delegate?.bleServer(self, didReceiveResponse: bytes, from: id) }
}
private final class Phone {
    let id = UUID()
    let deviceID = UUID().uuidString
    let name = "Fixture Phone"
    let key = P256.Signing.PrivateKey()
    var crypto: SessionCrypto!
    var transcript = Data()
    func connect(_ harness: Harness, pin: Data? = nil) throws {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let request = try JSONEncoder().encode(ClientHello(ephemeralKey: ephemeral.publicKey.x963Representation))
        let bytes = try XCTUnwrap(harness.ble.simulateSessionKey(request, from: id))
        let hello = try JSONDecoder().decode(ServerHello.self, from: bytes)
        transcript = try hello.verify(clientKey: ephemeral.publicKey.x963Representation, pinnedIdentity: pin ?? harness.store.macIdentityPublicKey(), service: TouchBridgeConstants.serviceUUID)
        crypto = try SessionCrypto.deriveSession(myPrivate: ephemeral, theirPublic: SessionCrypto.importPublicKey(hello.ephemeralKey))
    }
    func identity(signature: Data? = nil) throws -> Data {
        let bytes = try SecureHandshake.possessionBytes(transcript: transcript, deviceID: deviceID, deviceName: name, publicKey: key.publicKey.x963Representation, token: nil)
        return try WireFormat.seal(.identify, IdentifyMessage(deviceID: deviceID, deviceName: name, signature: signature ?? key.signature(for: bytes).derRepresentation), crypto: crypto)
    }
    func pairing(token: Data, tamperToken: Bool = false, tamperKey: Bool = false) throws -> Data {
        let bytes = try SecureHandshake.possessionBytes(transcript: transcript, deviceID: deviceID, deviceName: name, publicKey: key.publicKey.x963Representation, token: token)
        return try WireFormat.seal(.pairRequest, PairRequestMessage(deviceName: name, publicKey: tamperKey ? P256.Signing.PrivateKey().publicKey.x963Representation : key.publicKey.x963Representation, deviceID: deviceID, pairingToken: tamperToken ? Data(repeating: 9, count: 16) : token, signature: key.signature(for: bytes).derRepresentation), crypto: crypto)
    }
    func response(_ data: Data, deviceID override: String? = nil, tamper: Bool = false) throws -> Data {
        let decoded = try WireFormat.open(data, crypto: crypto)
        let message = try WireFormat.decodePayload(AuthorizationChallengeMessage.self, from: decoded.payload)
        let signature = try key.signature(for: tamper ? message.authorization + Data([0]) : message.authorization).derRepresentation
        return try WireFormat.seal(.challengeResponse, ChallengeResponseMessage(challengeID: message.challengeID, signature: signature, deviceID: override ?? deviceID), crypto: crypto)
    }
}
private final class Harness {
    let service = "dev.touchbridge.test.v2.\(UUID().uuidString)"
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("tb-v2-\(UUID().uuidString)")
    let ble = MockBLEServer()
    lazy var store = KeychainStore(service: service)
    private let presenceNow: @Sendable () -> TimeInterval
    lazy var coordinator = DaemonCoordinator(keychainStore: store, auditLog: AuditLog(logDirectory: log), bleServer: ble, presenceNow: presenceNow)
    init(presenceNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.presenceNow = presenceNow; _ = coordinator }
    deinit {
        coordinator.stop(); try? store.removeAll(); try? FileManager.default.removeItem(at: log)
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data((service + ".mac-identity-v2").utf8)] as CFDictionary)
    }
    func enrolled(_ phone: Phone) throws { try store.storePairedDevice(PairedDevice(deviceID: phone.deviceID, publicKey: phone.key.publicKey.x963Representation, displayName: phone.name, pairedAt: Date())) }
    func verified(_ phone: Phone) async throws { try enrolled(phone); try phone.connect(self); ble.simulatePairingData(try phone.identity(), from: phone.id); for _ in 0..<100 { if coordinator.identifiedCentrals.contains(phone.id) { return }; try await Task.sleep(nanoseconds: 20_000_000) }; XCTFail("identify did not verify") }
    func challenge() throws -> Data {
        let issued = UInt64(Date().timeIntervalSince1970)
        return try AuthorizationPayload(purpose: .pam, nonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }), macIdentityHash: Data(SHA256.hash(data: store.macIdentityPublicKey())), uid: getuid(), pid: 1234, issued: issued, expiry: issued + 10, user: "test-user", service: "sudo").encode()
    }
    func pause() async throws { try await Task.sleep(nanoseconds: 50_000_000) }
    func waitChallenge(_ phone: Phone, count: Int = 1) async throws {
        for _ in 0..<100 { if ble.sentChallenges.filter({ $0.centralID == phone.id }).count >= count { return }; try await Task.sleep(nanoseconds: 20_000_000) }; XCTFail("challenge not dispatched")
    }
    func sent(to phone: Phone) throws -> Data { try XCTUnwrap(ble.sentChallenges.last { $0.centralID == phone.id }?.data) }
}
final class DaemonCoordinatorV2Tests: XCTestCase {
    func testAnonymousCannotBecomeVerifiedAndDowngradeRejected() async throws {
        let h = Harness(), p = Phone()
        h.ble.simulateConnect(p.id); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        XCTAssertNil(h.ble.simulateSessionKey(P256.KeyAgreement.PrivateKey().publicKey.x963Representation, from: p.id))
        try p.connect(h); XCTAssertEqual(h.coordinator.readyCentrals.count, 1); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        h.ble.simulatePairingData(try p.identity(), from: p.id); try await h.pause()
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        let proof = await h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 1); XCTAssertNil(proof)
        let legacy = await h.coordinator.authenticateFromPAM(user: "test", service: "sudo", pid: 1, timeout: 1)
        XCTAssertFalse(legacy.success); XCTAssertEqual(legacy.reason, "diagnostic_authentication_failed")
    }
    func testPinnedMacHandshakeRejectsForgedIdentity() throws {
        let h = Harness(), p = Phone()
        XCTAssertThrowsError(try p.connect(h, pin: P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
    }
    func testReconnectRequiresPossessionAndFreshTranscript() async throws {
        let h = Harness(), p = Phone(); try h.enrolled(p); try p.connect(h)
        let old = try p.identity()
        h.ble.simulatePairingData(old, from: p.id); try await h.pause(); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 1)
        h.ble.simulateDisconnect(p.id); try p.connect(h)
        h.ble.simulatePairingData(old, from: p.id); try await h.pause(); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        h.ble.simulatePairingData(try p.identity(signature: Data(repeating: 0, count: 64)), from: p.id); try await h.pause(); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        h.ble.simulatePairingData(try p.identity(), from: p.id); try await h.pause(); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 1)
    }
    func testVerifiedCountIgnoresAnonymousAndClearsOnStop() async throws {
        let h = Harness(), p = Phone(), anonymous = Phone()
        let counts = LockedBox<[Int]>([])
        h.coordinator.onVerifiedCompanionCountChanged = { count in counts.mutate { $0.append(count) } }
        try await h.verified(p); try anonymous.connect(h)
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 1)
        h.ble.simulateDisconnect(anonymous.id); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 1)
        h.ble.simulateDisconnect(p.id); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        try await h.verified(p); h.coordinator.stop(); await h.coordinator.waitForPresencePublications(); XCTAssertEqual(counts.value.last, 0)
    }
    func testPairingEncryptsAndBindsTokenKeyAndAcceptance() async throws {
        let h = Harness(), p = Phone()
        let qr = try JSONDecoder().decode(PairingPayload.self, from: await h.coordinator.pairingManager.generatePairingQRData())
        XCTAssertEqual(qr.version, 2); XCTAssertEqual(qr.publicKey, try h.store.macIdentityPublicKey())
        // A valid QR token alone cannot create a peer without the authenticated session.
        let plaintext = try WireFormat.encode(.pairRequest, PairRequestMessage(deviceName: p.name, publicKey: p.key.publicKey.x963Representation, deviceID: p.deviceID, pairingToken: qr.pairingToken))
        h.ble.simulatePairingData(plaintext, from: p.id); try await h.pause(); XCTAssertThrowsError(try h.store.retrievePairedDevice(deviceID: p.deviceID))
        try p.connect(h, pin: qr.publicKey)
        h.ble.simulatePairingData(try p.pairing(token: qr.pairingToken, tamperToken: true), from: p.id)
        h.ble.simulatePairingData(try p.pairing(token: qr.pairingToken, tamperKey: true), from: p.id)
        try await h.pause(); XCTAssertThrowsError(try h.store.retrievePairedDevice(deviceID: p.deviceID))
        h.ble.simulatePairingData(try p.pairing(token: qr.pairingToken), from: p.id); try await h.pause()
        XCTAssertEqual(try h.store.retrievePairedDevice(deviceID: p.deviceID).publicKey, p.key.publicKey.x963Representation)
        let accepted = try XCTUnwrap(h.ble.sentPairingResponses.last?.data)
        XCTAssertThrowsError(try WireFormat.decodePayload(PairResponseMessage.self, from: accepted.dropFirst(2)))
        let decoded = try WireFormat.open(accepted, crypto: p.crypto)
        XCTAssertTrue(try WireFormat.decodePayload(PairResponseMessage.self, from: decoded.payload).accepted)
    }
    func testAtomicTokenCanOnlyPairOneContender() async throws {
        let h = Harness(), a = Phone(), b = Phone()
        let qr = try JSONDecoder().decode(PairingPayload.self, from: await h.coordinator.pairingManager.generatePairingQRData())
        try a.connect(h); try b.connect(h)
        h.ble.simulatePairingData(try a.pairing(token: qr.pairingToken), from: a.id)
        h.ble.simulatePairingData(try b.pairing(token: qr.pairingToken), from: b.id)
        try await h.pause()
        XCTAssertEqual(try h.store.listPairedDevices().count, 1); XCTAssertEqual(h.coordinator.verifiedCompanionCount, 1)
    }
    func testEvidenceIsRetainedExactlyAndProofUsesPhoneSignature() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p)
        let retained = try h.challenge()
        async let future = h.coordinator.authenticateProof(challenge: retained, timeout: 1)
        try await h.waitChallenge(p)
        let wire = try h.sent(to: p)
        let decoded = try WireFormat.open(wire, crypto: p.crypto)
        let message = try WireFormat.decodePayload(AuthorizationChallengeMessage.self, from: decoded.payload)
        XCTAssertEqual(message.authorization, retained)
        h.ble.simulateResponse(try p.response(wire), from: p.id)
        let futureValue = await future
        let proof = try XCTUnwrap(futureValue)
        XCTAssertEqual(proof.deviceID, p.deviceID)
        XCTAssertTrue(try p.key.publicKey.isValidSignature(P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: retained))
        XCTAssertFalse(try p.key.publicKey.isValidSignature(P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: retained + Data([0])))
    }
    func testWrongDeviceCannotConsumeRealChallenge() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p)
        async let future = h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 1)
        try await h.waitChallenge(p); let wire = try h.sent(to: p)
        h.ble.simulateResponse(try p.response(wire, deviceID: "spoof"), from: p.id); try await h.pause()
        h.ble.simulateResponse(try p.response(wire), from: p.id)
        let proof = try await future; XCTAssertNotNil(proof)
    }
    func testBadSignatureFullMetadataTamperingFails() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p)
        async let future = h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 1)
        try await h.waitChallenge(p); h.ble.simulateResponse(try p.response(h.sent(to: p), tamper: true), from: p.id)
        let result = try await future; XCTAssertNil(result)
    }
    func testReplayLateResponseAndNewSessionFail() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p)
        async let first = h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 1)
        try await h.waitChallenge(p); let oldResponse = try p.response(h.sent(to: p)); let result = try await first; XCTAssertNil(result)
        h.ble.simulateResponse(oldResponse, from: p.id)
        h.ble.simulateDisconnect(p.id); try await h.verified(p)
        async let next = h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 0.3)
        try await h.pause(); h.ble.simulateResponse(oldResponse, from: p.id)
        let second = try await next; XCTAssertNil(second)
    }
    func testBroadcastFirstValidProofWinsAndCleansSiblings() async throws {
        let h = Harness(), a = Phone(), b = Phone(); try await h.verified(a); try await h.verified(b)
        async let future = h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 1)
        try await h.waitChallenge(a); try await h.waitChallenge(b); XCTAssertEqual(h.ble.sentChallenges.count, 2)
        h.ble.simulateResponse(try b.response(h.sent(to: b)), from: b.id)
        let proof = try await future; XCTAssertEqual(proof?.deviceID, b.deviceID)
        h.ble.simulateResponse(try a.response(h.sent(to: a)), from: a.id)
        try await h.pause(); let pendingCount = await h.coordinator.challengeManager.pendingCount; XCTAssertEqual(pendingCount, 0)
    }
    func testDisconnectAndStopCancelPendingProof() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p)
        async let future = h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 10)
        try await h.pause(); h.ble.simulateDisconnect(p.id)
        let proof = try await future; XCTAssertNil(proof)
        try await h.verified(p)
        async let next = h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 10)
        try await h.pause(); h.coordinator.stop()
        let nextProof = try await next; XCTAssertNil(nextProof)
    }
    func testSendFailureAndMalformedEvidenceFailFast() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p); h.ble.sendSucceeds = false
        let proof = await h.coordinator.authenticateProof(challenge: try h.challenge(), timeout: 1); XCTAssertNil(proof)
        let malformed = await h.coordinator.authenticateProof(challenge: Data(repeating: 0, count: 32), timeout: 1); XCTAssertNil(malformed)
    }
}


extension DaemonCoordinatorV2Tests {
    func testDiagnosticPurposeCannotBeUsedAsPrivilegedEvidence() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p)
        let rootBytes = try h.challenge(), root = try AuthorizationPayload.parse(rootBytes)
        let diagnostic = AuthorizationPayload(purpose: .diagnostics, nonce: root.nonce, macIdentityHash: root.macIdentityHash, uid: root.uid, pid: root.pid, issued: root.issued, expiry: root.expiry, user: root.user, service: root.service)
        let rejected = await h.coordinator.authenticateProof(challenge: try diagnostic.encode(), timeout: 1)
        XCTAssertNil(rejected); XCTAssertTrue(h.ble.sentChallenges.isEmpty)
        async let diagnosticResult = h.coordinator.authenticateFromPAM(user: "test-user", service: "sudo", pid: 1234, timeout: 1)
        try await h.waitChallenge(p)
        let sent = try h.sent(to: p), decoded = try WireFormat.open(sent, crypto: p.crypto)
        let issued = try WireFormat.decodePayload(AuthorizationChallengeMessage.self, from: decoded.payload)
        XCTAssertEqual(try AuthorizationPayload.parse(issued.authorization).purpose, .diagnostics)
        let response = try p.response(sent), proof = try WireFormat.decodePayload(ChallengeResponseMessage.self, from: WireFormat.open(response, crypto: p.crypto).payload)
        XCTAssertFalse(try p.key.publicKey.isValidSignature(P256.Signing.ECDSASignature(derRepresentation: proof.signature), for: rootBytes))
        h.ble.simulateResponse(response, from: p.id)
        let result = await diagnosticResult; XCTAssertTrue(result.success)
    }
    func testSuccessfulEvidenceCannotBeReplayedForNewRequest() async throws {
        let h = Harness(), p = Phone(); try await h.verified(p)
        let bytes = try h.challenge()
        async let first = h.coordinator.authenticateProof(challenge: bytes, timeout: 1)
        try await h.waitChallenge(p); h.ble.simulateResponse(try p.response(h.sent(to: p)), from: p.id)
        let accepted = await first; XCTAssertNotNil(accepted)
        async let replay = h.coordinator.authenticateProof(challenge: bytes, timeout: 0.3)
        try await h.waitChallenge(p, count: 2); h.ble.simulateResponse(try p.response(h.sent(to: p)), from: p.id)
        let rejected = await replay; XCTAssertNil(rejected)
    }
}

extension DaemonCoordinatorV2Tests {
    func testPresencePublicationCannotPublishOldVerifiedAfterDisconnect() async throws {
        let h = Harness(), p = Phone()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let counts = LockedBox<[Int]>([])
        h.coordinator.onVerifiedCompanionCountChanged = { value in
            if value == 1 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            counts.mutate { $0.append(value) }
        }
        try await h.verified(p)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        h.ble.simulateDisconnect(p.id)
        release.signal()
        await h.coordinator.waitForPresencePublications()
        XCTAssertEqual(counts.value.suffix(2), [1, 0])
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
    }
    func testPresenceLeaseExpiresWithCentralStillSubscribedAndReplayCannotRevive() async throws {
        let now = LockedBox<TimeInterval>(100)
        let h = Harness(presenceNow: { now.value }), p = Phone()
        try await h.verified(p)
        let oldIdentify = try p.identity()
        h.coordinator.maintainPresence()
        let pingWire = try h.sent(to: p)
        let decoded = try WireFormat.open(pingWire, crypto: p.crypto)
        XCTAssertEqual(decoded.type, .presencePing)
        let ping = try WireFormat.decodePayload(PresenceHeartbeatMessage.self, from: decoded.payload)
        let pong = try WireFormat.seal(.presencePong, PresenceHeartbeatMessage(nonce: ping.nonce), crypto: p.crypto)
        now.mutate { $0 = 107 }
        h.ble.simulateResponse(pong, from: p.id)
        try await h.pause()
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 1)
        now.mutate { $0 = 114 }
        // Replayed consumed pong must not extend the renewed deadline (115).
        h.ble.simulateResponse(pong, from: p.id)
        try await h.pause()
        now.mutate { $0 = 116 }
        h.coordinator.maintainPresence()
        await h.coordinator.waitForPresencePublications()
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        XCTAssertTrue(h.coordinator.readyCentrals.isEmpty)
        h.ble.simulatePairingData(oldIdentify, from: p.id)
        h.ble.simulateResponse(pong, from: p.id)
        try await h.pause()
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
    }
    func testUnansweredPresencePingAndWrongNonceCannotKeepGhostSession() async throws {
        let now = LockedBox<TimeInterval>(200)
        let h = Harness(presenceNow: { now.value }), p = Phone()
        let counts = LockedBox<[Int]>([])
        h.coordinator.onVerifiedCompanionCountChanged = { value in counts.mutate { $0.append(value) } }
        try await h.verified(p)
        h.coordinator.maintainPresence()
        let bad = try WireFormat.seal(.presencePong, PresenceHeartbeatMessage(nonce: Data(repeating: 0, count: 32)), crypto: p.crypto)
        h.ble.simulateResponse(bad, from: p.id)
        try await h.pause()
        now.mutate { $0 = 208 }
        h.coordinator.maintainPresence()
        await h.coordinator.waitForPresencePublications()
        XCTAssertEqual(counts.value.last, 0)
        XCTAssertEqual(h.coordinator.verifiedCompanionCount, 0)
        let challenge = await h.coordinator.issueChallenge(to: p.id, reason: "sudo")
        XCTAssertNil(challenge)
    }
}

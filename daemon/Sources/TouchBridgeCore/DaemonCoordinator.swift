import Foundation
import CoreBluetooth
import CryptoKit
import OSLog
import TouchBridgeProtocol

public final class DaemonCoordinator: NSObject, PAMAuthHandler, PAMProofAuthHandler, @unchecked Sendable {
    public let bleServer: any BLEServerInterface
    public let challengeManager: ChallengeManager
    public let pairingManager: PairingManager
    public let keychainStore: KeychainStore
    public let auditLog: AuditLog
    private let stateLock = NSLock()
    private let serviceUUID: String
    private var sessions: [UUID: SessionState] = [:]
    private var pending: [UUID: Pending] = [:]
    private var pruneTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private let presenceQueue = DispatchQueue(label: "dev.touchbridge.verified-presence")
    private var presenceCallback: ((Int) -> Void)?
    private let presenceNow: @Sendable () -> TimeInterval
    private let presenceLease: TimeInterval
    private let heartbeatInterval: TimeInterval
    public var onChallengeResult: ((UUID, ChallengeResult, String?) -> Void)?
    public var onPairingComplete: ((PairedDevice) -> Void)?
    public var onVerifiedCompanionCountChanged: ((Int) -> Void)? {
        get { stateLock.withLock { presenceCallback } }
        set { stateLock.withLock { presenceCallback = newValue; publishPresenceLocked() } }
    }
    public var verifiedCompanionCount: Int { identifiedCentrals.count }
    private struct SessionState {
        let id = UUID()
        let crypto: SessionCrypto
        let transcript: Data
        var deviceID: String?
        var presenceDeadline: TimeInterval = 0
        var nextHeartbeatAt: TimeInterval = 0
        var pendingHeartbeatNonce: Data?
    }
    private struct Pending { let centralID: UUID; let sessionID: UUID; let deviceID: String; let waiter: ProofWaiter? }
    public init(keychainStore: KeychainStore = KeychainStore(), auditLog: AuditLog = AuditLog(), challengeManager: ChallengeManager = ChallengeManager(), pairingManager: PairingManager? = nil, rssiThreshold: Int = TouchBridgeConstants.defaultRSSIThreshold, serviceUUID: String = TouchBridgeConstants.serviceUUID, bleServer: (any BLEServerInterface)? = nil, presenceLeaseSeconds: TimeInterval = 8, presenceHeartbeatInterval: TimeInterval = 2, presenceNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.presenceNow = presenceNow
        self.presenceLease = presenceLeaseSeconds.isFinite ? min(max(2, presenceLeaseSeconds), 30) : 8
        self.heartbeatInterval = presenceHeartbeatInterval.isFinite ? min(max(0.5, presenceHeartbeatInterval), self.presenceLease / 2) : 2
        self.keychainStore = keychainStore; self.auditLog = auditLog; self.challengeManager = challengeManager; self.serviceUUID = serviceUUID
        self.bleServer = bleServer ?? BLEServer(rssiThreshold: rssiThreshold, serviceUUID: serviceUUID)
        self.pairingManager = pairingManager ?? PairingManager(keychainStore: keychainStore, serviceUUID: serviceUUID)
        super.init(); self.bleServer.delegate = self
    }
    public func start() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                self?.maintainPresence()
            }
        }
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                guard let self else { break }
                await self.challengeManager.pruneExpired()
                let expired = self.stateLock.withLock { () -> [UUID] in
                    let ids = self.pending.filter { $0.value.waiter == nil }.map(\.key)
                    for id in ids { self.pending.removeValue(forKey: id) }; return ids
                }
                for id in expired { await self.challengeManager.cancel(id) }
            }
        }
    }
    public func startAdvertising() { bleServer.startAdvertising() }
    public func stop() {
        bleServer.stopAdvertising(); pruneTask?.cancel(); pruneTask = nil
        presenceTask?.cancel(); presenceTask = nil
        let old = stateLock.withLock { () -> [Pending] in
            let old = Array(pending.values); pending.removeAll(); sessions.removeAll()
            publishPresenceLocked(); return old
        }
        for item in old { item.waiter?.resume(nil) }
    }
    public var readyCentrals: [UUID] { stateLock.withLock { Array(sessions.keys) } }
    public var identifiedCentrals: [UUID] {
        let now = presenceNow()
        return stateLock.withLock { sessions.filter { isVerified($0.value, now: now) }.map(\.key) }
    }
    private func isVerified(_ session: SessionState, now: TimeInterval) -> Bool {
        session.deviceID != nil && session.presenceDeadline > now
    }
    /// Called only under stateLock. Enqueue there to preserve mutation order;
    /// callbacks always execute later on a single queue, outside the lock.
    private func publishPresenceLocked() {
        let count = sessions.values.filter { isVerified($0, now: presenceNow()) }.count
        let callback = presenceCallback
        presenceQueue.async { callback?(count) }
    }
    func waitForPresencePublications() async {
        await withCheckedContinuation { continuation in
            presenceQueue.async { continuation.resume() }
        }
    }
    /// Monotonic, independently testable lease maintenance; no biometric prompts.
    func maintainPresence() {
        let now = presenceNow()
        var pings: [(UUID, SessionState, Data)] = []
        var cancelled: [UUID: Pending] = [:]
        stateLock.withLock {
            var removed = false
            for centralID in Array(sessions.keys) {
                guard var session = sessions[centralID], session.deviceID != nil else { continue }
                if session.presenceDeadline <= now {
                    // Remove the transcript too: replaying the original identify cannot revive it.
                    sessions.removeValue(forKey: centralID); removed = true
                    for (id, item) in pending where item.centralID == centralID {
                        cancelled[id] = item
                    }
                    continue
                }
                if session.pendingHeartbeatNonce == nil && session.nextHeartbeatAt <= now {
                    let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                    session.pendingHeartbeatNonce = nonce
                    session.nextHeartbeatAt = now + heartbeatInterval
                    sessions[centralID] = session
                    pings.append((centralID, session, nonce))
                }
            }
            for id in cancelled.keys { pending.removeValue(forKey: id) }
            if removed { publishPresenceLocked() }
        }
        for item in cancelled.values { item.waiter?.resume(nil) }
        if !cancelled.isEmpty {
            let ids = Array(cancelled.keys)
            Task { for id in ids { await challengeManager.cancel(id) } }
        }
        for (centralID, session, nonce) in pings {
            guard let wire = try? WireFormat.seal(.presencePing, PresenceHeartbeatMessage(nonce: nonce), crypto: session.crypto) else { continue }
            _ = bleServer.sendChallenge(wire, to: centralID)
        }
    }
    public var macIdentityPublicKey: Data? { try? keychainStore.macIdentityPublicKey() }
    public var macIdentityFingerprint: String? { macIdentityPublicKey.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
    public func issueChallenge(to centralID: UUID, reason: String) async -> UUID? {
        guard let hash = try? keychainStore.macIdentityPublicKey().sha256 else { return nil }
        let issued = UInt64(Date().timeIntervalSince1970)
        let service = reason.utf8.count <= 64 && reason.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [95,46,58,45].contains($0) }) && !reason.isEmpty ? reason : "diagnostics"
        let payload = AuthorizationPayload(purpose: .diagnostics, nonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }), macIdentityHash: hash, uid: getuid(), pid: UInt32(getpid()), issued: issued, expiry: issued + 10, user: NSUserName(), service: service)
        guard let bytes = try? payload.encode() else { return nil }
        return await dispatch(centralID: centralID, authorization: bytes, waiter: nil)
    }
    private func dispatch(centralID: UUID, authorization: Data, waiter: ProofWaiter?) async -> UUID? {
        guard let session = stateLock.withLock({ sessions[centralID] }), isVerified(session, now: presenceNow()), let deviceID = session.deviceID else { return nil }
        do {
            let challenge = try await challengeManager.issue(for: deviceID, authorization: authorization, sessionID: session.id)
            let message = AuthorizationChallengeMessage(challengeID: challenge.id.uuidString, authorization: authorization)
            let bytes = try WireFormat.seal(.challengeIssued, message, crypto: session.crypto)
            let valid = stateLock.withLock { () -> Bool in
                guard let current = sessions[centralID], current.id == session.id, isVerified(current, now: presenceNow()), waiter?.isResolved != true else { return false }
                pending[challenge.id] = Pending(centralID: centralID, sessionID: session.id, deviceID: deviceID, waiter: waiter); return true
            }
            guard valid, bleServer.sendChallenge(bytes, to: centralID) else {
                stateLock.withLock { _ = pending.removeValue(forKey: challenge.id) }; await challengeManager.cancel(challenge.id); return nil
            }
            let context = try AuthorizationPayload.parse(authorization)
            await auditLog.log(AuditEntry(sessionID: challenge.id.uuidString, surface: context.service, deviceID: deviceID, result: "ISSUED"))
            return challenge.id
        } catch { return nil }
    }
    /// Used only by the explicit diagnostic socket action, never privileged PAM.
    public func authenticateFromPAM(user: String, service: String, pid: Int, timeout: TimeInterval) async -> (success: Bool, reason: String?) {
        guard pid > 0, pid <= Int(UInt32.max), let identity = try? keychainStore.macIdentityPublicKey() else { return (false, "invalid_diagnostic_context") }
        let now = UInt64(Date().timeIntervalSince1970)
        let payload = AuthorizationPayload(purpose: .diagnostics, nonce: Data((0..<32).map { _ in UInt8.random(in: 0...255) }), macIdentityHash: identity.sha256, uid: getuid(), pid: UInt32(pid), issued: now, expiry: now + 10, user: user, service: service)
        guard let bytes = try? payload.encode() else { return (false, "invalid_diagnostic_context") }
        let proof = await requestProof(challenge: bytes, timeout: timeout, purpose: .diagnostics)
        return (proof != nil, proof == nil ? "diagnostic_authentication_failed" : nil)
    }
    public func authenticateProof(challenge: Data, timeout: TimeInterval) async -> PAMProof? {
        await requestProof(challenge: challenge, timeout: timeout, purpose: .pam)
    }
    private func requestProof(challenge: Data, timeout: TimeInterval, purpose: AuthorizationPayload.Purpose) async -> PAMProof? {
        guard let payload = try? AuthorizationPayload.parse(challenge), payload.purpose == purpose,
              let identity = try? keychainStore.macIdentityPublicKey(), (try? payload.validate(macIdentityHash: identity.sha256)) != nil else { return nil }
        let targets = identifiedCentrals
        guard !targets.isEmpty else { return nil }
        let waiter = ProofWaiter()
        let deadline = min(max(0, timeout), TimeInterval(payload.expiry) - Date().timeIntervalSince1970, 30)
        guard deadline > 0 else { return nil }
        let timeoutTask = Task { do { try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000)); waiter.resume(nil) } catch {} }
        for id in targets { if waiter.isResolved { break }; _ = await dispatch(centralID: id, authorization: challenge, waiter: waiter) }
        let hasPending = stateLock.withLock { pending.values.contains { $0.waiter === waiter } }
        if !hasPending { waiter.resume(nil) }
        let proof = await withTaskCancellationHandler(operation: { await waiter.value() }, onCancel: { waiter.resume(nil) })
        timeoutTask.cancel()
        let ids = stateLock.withLock { () -> [UUID] in let ids = pending.filter { $0.value.waiter === waiter }.map(\.key); for id in ids { pending.removeValue(forKey: id) }; return ids }
        for id in ids { await challengeManager.cancel(id) }
        return proof
    }
}

extension DaemonCoordinator: BLEServerDelegate {
    public func bleServer(_ server: any BLEServerInterface, centralDidConnect centralID: UUID) {}
    public func bleServer(_ server: any BLEServerInterface, centralDidDisconnect centralID: UUID) {
        let old = stateLock.withLock { () -> [Pending] in
            sessions.removeValue(forKey: centralID)
            let old = pending.filter { $0.value.centralID == centralID }
            for id in old.keys { pending.removeValue(forKey: id) }
            publishPresenceLocked(); return Array(old.values)
        }
        for item in old { item.waiter?.resume(nil) }
    }
    public func bleServer(_ server: any BLEServerInterface, didReceiveSessionKey data: Data, from centralID: UUID) -> Data? {
        do {
            let hello = try JSONDecoder().decode(ClientHello.self, from: data)
            guard hello.version == 2, data.count <= 512 else { return nil }
            let client = try SessionCrypto.importPublicKey(hello.ephemeralKey)
            let (key, pub) = SessionCrypto.generateEphemeralKeyPair()
            let transcript = try SecureHandshake.transcript(clientKey: hello.ephemeralKey, serverKey: pub.x963Representation, service: serviceUUID)
            let crypto = try SessionCrypto.deriveSession(myPrivate: key, theirPublic: client)
            let response = ServerHello(ephemeralKey: pub.x963Representation, identityKey: try keychainStore.macIdentityPublicKey(), signature: try keychainStore.signMacIdentity(transcript))
            let replaced = stateLock.withLock { () -> Bool in
                guard sessions[centralID] != nil || sessions.count < 32 else { return false }
                sessions[centralID] = SessionState(crypto: crypto, transcript: transcript)
                publishPresenceLocked(); return true
            }
            guard replaced else { return nil }
            return try JSONEncoder().encode(response)
        } catch { return nil }
    }
    public func bleServer(_ server: any BLEServerInterface, didReceivePairingData data: Data, from centralID: UUID) {
        Task {
            guard let session = stateLock.withLock({ sessions[centralID] }), session.deviceID == nil else { return }
            do {
                let decoded = try WireFormat.open(data, crypto: session.crypto)
                let device: PairedDevice
                if decoded.type == .pairRequest {
                    let msg = try WireFormat.decodePayload(PairRequestMessage.self, from: decoded.payload)
                    guard let id = msg.deviceID, let token = msg.pairingToken, let signature = msg.signature else { return }
                    let bytes = try SecureHandshake.possessionBytes(transcript: session.transcript, deviceID: id, deviceName: msg.deviceName, publicKey: msg.publicKey, token: token)
                    guard try P256.Signing.PublicKey(x963Representation: msg.publicKey).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: bytes) else { return }
                    guard stateLock.withLock({ sessions[centralID]?.id == session.id }) else { return }
                    device = try await pairingManager.validatePairingRequest(token: token, devicePublicKey: msg.publicKey, deviceName: msg.deviceName, deviceID: id)
                    guard stateLock.withLock({ sessions[centralID]?.id == session.id }) else { return }
                    try await pairingManager.completePairing(device: device)
                } else if decoded.type == .identify {
                    let msg = try WireFormat.decodePayload(IdentifyMessage.self, from: decoded.payload)
                    guard let signature = msg.signature else { return }
                    device = try keychainStore.retrievePairedDevice(deviceID: msg.deviceID)
                    let bytes = try SecureHandshake.possessionBytes(transcript: session.transcript, deviceID: msg.deviceID, deviceName: msg.deviceName, publicKey: device.publicKey, token: nil)
                    guard try P256.Signing.PublicKey(x963Representation: device.publicKey).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: bytes) else { return }
                } else { return }
                let valid = stateLock.withLock { () -> Bool in
                    guard sessions[centralID]?.id == session.id, sessions[centralID]?.deviceID == nil else { return false }
                    sessions[centralID]?.deviceID = device.deviceID
                    sessions[centralID]?.presenceDeadline = presenceNow() + presenceLease
                    sessions[centralID]?.nextHeartbeatAt = presenceNow()
                    publishPresenceLocked(); return true
                }
                guard valid else { return }
                let response = PairResponseMessage(deviceID: device.deviceID, publicKey: device.publicKey, accepted: true)
                _ = server.sendPairingData(try WireFormat.seal(.pairResponse, response, crypto: session.crypto), to: centralID)
                if decoded.type == .pairRequest { onPairingComplete?(device) }
                await auditLog.log(AuditEntry(sessionID: centralID.uuidString, surface: decoded.type == .pairRequest ? "pairing" : "identify", deviceID: device.deviceID, result: decoded.type == .pairRequest ? "PAIRED" : "IDENTIFIED"))
            } catch { /* Reject silently; no unauthenticated acceptance or downgrade. */ }
        }
    }
    public func bleServer(_ server: any BLEServerInterface, didReceiveResponse data: Data, from centralID: UUID) {
        Task {
            guard let session = stateLock.withLock({ sessions[centralID] }), isVerified(session, now: presenceNow()), let deviceID = session.deviceID else { return }
            do {
                let decoded = try WireFormat.open(data, crypto: session.crypto)
                if decoded.type == .presencePong {
                    let pong = try WireFormat.decodePayload(PresenceHeartbeatMessage.self, from: decoded.payload)
                    guard pong.nonce.count == 32 else { return }
                    stateLock.withLock {
                        guard var current = sessions[centralID], current.id == session.id,
                              isVerified(current, now: presenceNow()), current.pendingHeartbeatNonce == pong.nonce else { return }
                        current.pendingHeartbeatNonce = nil // Consume before extending the lease.
                        current.presenceDeadline = presenceNow() + presenceLease
                        current.nextHeartbeatAt = presenceNow() + heartbeatInterval
                        sessions[centralID] = current
                    }
                    return
                }
                if decoded.type == .error {
                    let message = try WireFormat.decodePayload(ErrorMessage.self, from: decoded.payload)
                    guard message.code == ErrorCode.keyInvalidated.rawValue, let text = message.challengeID, let id = UUID(uuidString: text) else { return }
                    let item = stateLock.withLock { () -> Pending? in guard let item = pending[id], item.centralID == centralID, item.sessionID == session.id else { return nil }; return pending.removeValue(forKey: id) }
                    guard let item else { return }
                    await challengeManager.cancel(id)
                    await auditLog.log(AuditEntry(sessionID: id.uuidString, surface: "challenge", deviceID: deviceID, result: "FAILED_KEY_INVALIDATED"))
                    item.waiter?.resume(nil); onChallengeResult?(id, .keyInvalidated, deviceID); return
                }
                guard decoded.type == .challengeResponse else { return }
                let response = try WireFormat.decodePayload(ChallengeResponseMessage.self, from: decoded.payload)
                guard response.deviceID == deviceID, let id = UUID(uuidString: response.challengeID),
                      let item = stateLock.withLock({ pending[id] }), item.centralID == centralID, item.sessionID == session.id, item.deviceID == deviceID else { return }
                let key = try keychainStore.retrievePublicKey(for: deviceID)
                let result = await challengeManager.verify(challengeID: id, signature: response.signature, publicKey: key, expectedDeviceID: deviceID, expectedSessionID: session.id)
                let stillValid = stateLock.withLock { () -> Bool in guard let current = sessions[centralID], current.id == session.id, isVerified(current, now: presenceNow()) else { return false }; return pending.removeValue(forKey: id) != nil }
                guard stillValid else { return }
                await auditLog.log(AuditEntry(sessionID: id.uuidString, surface: "challenge", deviceID: deviceID, result: result == .verified ? "VERIFIED" : "FAILED_SIGNATURE"))
                guard stateLock.withLock({ sessions[centralID].map { $0.id == session.id && isVerified($0, now: presenceNow()) } == true }) else { item.waiter?.resume(nil); return }
                if result == .verified { item.waiter?.resume(PAMProof(deviceID: deviceID, signature: response.signature)) }
                onChallengeResult?(id, result, deviceID)
            } catch { }
        }
    }
}
private extension Data { var sha256: Data { Data(SHA256.hash(data: self)) } }
private final class ProofWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var proof: PAMProof?
    private var continuation: CheckedContinuation<PAMProof?, Never>?
    var isResolved: Bool { lock.withLock { done } }
    func resume(_ value: PAMProof?) { lock.withLock { guard !done else { return }; done = true; proof = value; continuation?.resume(returning: value); continuation = nil } }
    func value() async -> PAMProof? { await withCheckedContinuation { c in lock.withLock { if done { c.resume(returning: proof) } else { continuation = c } } } }
}

final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&_value) } }
}
final class OnceContinuation: @unchecked Sendable {
    private var inner: CheckedContinuation<ChallengeResult?, Never>?
    private let lock = NSLock()
    init(_ continuation: CheckedContinuation<ChallengeResult?, Never>) { inner = continuation }
    func resume(returning value: ChallengeResult?) { lock.withLock { guard let c = inner else { return }; inner = nil; c.resume(returning: value) } }
}

import Foundation
import UIKit
import CryptoKit
import UserNotifications

/// Owns the pinned Mac session and revocation state. Delegate callbacks run on the main queue.
@MainActor
public final class CompanionCoordinator: NSObject {
    public let bleClient: BLEClient
    public let challengeHandler: ChallengeHandler
    public let signingProvider: SigningProvider
    public let localAuth: LocalAuthManager
    private let defaults: UserDefaults
    private var ephemeralPrivateKey: P256.KeyAgreement.PrivateKey?
    private var sessionCrypto: SessionCrypto?
    private var transcript: Data?
    private var deviceID: String
    private var pendingPairingToken: Data?
    private var pendingMacName: String?
    private var pendingMacKey: Data?
    private var verified = false
    private var generation: UInt64 = 0
    private var deferredChallenge: Data?
    private var lifecycleObserver: NSObjectProtocol?
    private let signingKeyTag = "dev.touchbridge.signing"
    public var onConnectionChanged: ((Bool) -> Void)?
    public var onChallengeReceived: ((String) -> Void)?
    public var onChallengeResult: ((String, Bool, ChallengeHandlerError?) -> Void)?
    public var onPairingComplete: ((String) -> Void)?
    public var onPairingFailed: (() -> Void)?
    public init(signingProvider: SigningProvider? = nil, deviceID: String? = nil, bleClient: BLEClient? = nil, defaults: UserDefaults = .standard, authenticate: (@MainActor (String) async throws -> Bool)? = nil) {
        self.bleClient = bleClient ?? BLEClient(); self.localAuth = LocalAuthManager(); self.defaults = defaults
        #if targetEnvironment(simulator)
        self.signingProvider = signingProvider ?? MockSigningProvider()
        #else
        self.signingProvider = signingProvider ?? SecureEnclaveManager()
        #endif
        self.challengeHandler = ChallengeHandler(signingProvider: self.signingProvider, localAuth: self.localAuth, authenticate: authenticate)
        self.deviceID = deviceID ?? defaults.string(forKey: "companionDeviceID") ?? UUID().uuidString
        super.init(); self.bleClient.delegate = self
        if !defaults.bool(forKey: "pairingRevoked"), defaults.data(forKey: "pairedMacPublicKey") != nil, let service = defaults.string(forKey: "pairedMacID") { self.bleClient.serviceUUID = service }
        challengeHandler.sendResponse = { [weak self] bytes in guard let self, self.verified, !self.isRevoked else { return false }; return self.bleClient.sendResponse(bytes) }
        lifecycleObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, let data = self.deferredChallenge else { return }; self.deferredChallenge = nil; self.processChallenge(data) }
        }
    }
    deinit { if let lifecycleObserver { NotificationCenter.default.removeObserver(lifecycleObserver) } }
    private var isRevoked: Bool { defaults.bool(forKey: "pairingRevoked") }
    public var isSessionReady: Bool { verified && sessionCrypto != nil && !isRevoked }
    public var discoveredMacs: [UUID] { bleClient.discoveredPeripheralIDs }
    public var isConnected: Bool { isSessionReady }
    public var pairedDeviceID: String { deviceID }
    public var pairedMacFingerprint: String? { defaults.data(forKey: "pairedMacPublicKey").map { Self.fingerprint($0) } }
    public var pairedSigningPublicKey: Data? { try? signingProvider.publicKey(for: signingKeyTag) }
    public var signingFingerprint: String? { pairedSigningPublicKey.map(Self.fingerprint) }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func startScanning() { guard !isRevoked, pendingMacKey != nil || defaults.data(forKey: "pairedMacPublicKey") != nil else { return }; bleClient.startScanning() }
    public func resetConnectionAndScan() { guard !isRevoked else { return }; clearSession(); bleClient.resetConnectionAndScan() }
    public func connect(to peripheralID: UUID) { guard !isRevoked else { return }; bleClient.connect(to: peripheralID) }
    public func disconnect() { bleClient.disconnect(); clearSession() }
    public func cancelCurrentChallenge() { generation &+= 1; deferredChallenge = nil; challengeHandler.cancel(); UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
    private func clearSession() { cancelCurrentChallenge(); verified = false; sessionCrypto = nil; transcript = nil; ephemeralPrivateKey = nil; challengeHandler.sessionCrypto = nil; challengeHandler.macIdentityHash = nil }
    /// Revocation is persisted before deletion so a deletion error fails closed across restarts.
    public func unpair() throws {
        defaults.set(true, forKey: "pairingRevoked")
        defaults.set(true, forKey: "unpairIncomplete")
        bleClient.stopScanning(); bleClient.disconnect(); clearSession()
        pendingPairingToken = nil; pendingMacName = nil; pendingMacKey = nil
        for key in ["pairedMacID", "pairedMacName", "pairedMacPublicKey", "companionDeviceID"] { defaults.removeObject(forKey: key) }
        deviceID = UUID().uuidString
        try signingProvider.deleteKey(tag: signingKeyTag)
        defaults.set(false, forKey: "unpairIncomplete")
    }
    public func getOrCreateSigningKey() throws -> Data {
        guard !isRevoked else { throw ProtocolSecurityError.revoked }
        if let key = try? signingProvider.publicKey(for: signingKeyTag) { return key }
        // Never rotate an enrolled key silently.
        guard pendingPairingToken != nil else { throw SecureEnclaveError.keyInvalidated }
        return try signingProvider.generateKeyPair(tag: signingKeyTag)
    }
    public func beginPairing(serviceUUID: String, token: Data, macName: String, macPublicKey: Data) {
        guard UUID(uuidString: serviceUUID) != nil, token.count == 16, (try? P256.Signing.PublicKey(x963Representation: macPublicKey)) != nil else { onPairingFailed?(); return }
        do { try unpair() } catch { onPairingFailed?(); return }
        pendingPairingToken = token; pendingMacName = macName; pendingMacKey = macPublicKey
        bleClient.serviceUUID = serviceUUID; defaults.set(false, forKey: "pairingRevoked"); startScanning()
    }
    /// Legacy QR data cannot authorize pairing.
    public func beginPairing(serviceUUID: String, token: Data, macName: String) { onPairingFailed?() }
    private func performECDHKeyExchange() {
        guard !isRevoked, pendingMacKey != nil || defaults.data(forKey: "pairedMacPublicKey") != nil else { return }
        clearSession(); let key = P256.KeyAgreement.PrivateKey(); ephemeralPrivateKey = key
        if let bytes = try? JSONEncoder().encode(ClientHello(ephemeralKey: key.publicKey.x963Representation)) { _ = bleClient.sendSessionKey(bytes) }
    }
    private func completeECDH(_ bytes: Data) {
        guard !isRevoked, let key = ephemeralPrivateKey, let pin = pendingMacKey ?? defaults.data(forKey: "pairedMacPublicKey") else { return }
        do {
            guard bytes.count <= 1024 else { throw ProtocolSecurityError.malformed }
            let hello = try JSONDecoder().decode(ServerHello.self, from: bytes)
            let boundTranscript = try hello.verify(clientKey: key.publicKey.x963Representation, pinnedIdentity: pin, service: bleClient.serviceUUID)
            let crypto = try SessionCrypto.deriveSession(myPrivate: key, theirPublic: SessionCrypto.importPublicKey(hello.ephemeralKey))
            transcript = boundTranscript; sessionCrypto = crypto
            // No pairing token is released before the QR-pinned signature above verifies.
            if pendingPairingToken != nil { sendPairingRequest(macName: pendingMacName ?? "Mac") } else { try sendIdentify(crypto) }
        } catch { clearSession(); bleClient.disconnect(); onPairingFailed?() }
    }
    private func sendIdentify(_ crypto: SessionCrypto) throws {
        guard let transcript else { return }
        let key = try getOrCreateSigningKey(), name = String(UIDevice.current.name.prefix(40))
        let bytes = try SecureHandshake.possessionBytes(transcript: transcript, deviceID: deviceID, deviceName: name, publicKey: key, token: nil)
        let signature = try signingProvider.sign(data: bytes, keyTag: signingKeyTag)
        _ = bleClient.sendPairingData(try WireFormat.seal(.identify, IdentifyMessage(deviceID: deviceID, deviceName: name, signature: signature), crypto: crypto))
    }
    public func sendPairingRequest(macName: String) {
        guard !isRevoked, let crypto = sessionCrypto, let transcript, let token = pendingPairingToken else { return }
        do {
            let key = try getOrCreateSigningKey(), name = String(UIDevice.current.name.prefix(40))
            let bytes = try SecureHandshake.possessionBytes(transcript: transcript, deviceID: deviceID, deviceName: name, publicKey: key, token: token)
            let signature = try signingProvider.sign(data: bytes, keyTag: signingKeyTag)
            _ = bleClient.sendPairingData(try WireFormat.seal(.pairRequest, PairRequestMessage(deviceName: name, publicKey: key, deviceID: deviceID, pairingToken: token, signature: signature), crypto: crypto))
        } catch { onPairingFailed?() }
    }
    private func processChallenge(_ data: Data) {
        guard isSessionReady, let (_, payload) = try? challengeHandler.validatedChallenge(data) else { return }
        let token = generation
        onChallengeReceived?("\(payload.user) — \(payload.service) (PID \(payload.pid))")
        Task { @MainActor in
            guard token == self.generation, self.isSessionReady else { return }
            let result = await self.challengeHandler.handleChallenge(encryptedData: data, deviceID: self.deviceID)
            guard token == self.generation, self.isSessionReady else { return }
            switch result { case .success(let id): self.onChallengeResult?(id, true, nil); case .failed(let error): self.onChallengeResult?("", false, error) }
        }
    }
}
extension CompanionCoordinator: BLEClientDelegate {
    public func bleClient(_ client: BLEClient, connectionStateChanged connected: Bool, peripheralID: UUID) {
        if !connected { clearSession(); onConnectionChanged?(false) }
    }
    public func bleClientDidBecomeReadyForSecureSession(_ client: BLEClient, peripheralID: UUID) { performECDHKeyExchange() }
    public func bleClient(_ client: BLEClient, didReceiveSessionKey data: Data, from peripheralID: UUID) { completeECDH(data) }
    public func bleClient(_ client: BLEClient, didReceiveChallenge data: Data, from peripheralID: UUID) {
        // A validated session can echo freshness while backgrounded without a
        // biometric prompt. Revocation/session checks precede every echo.
        guard isSessionReady, let crypto = sessionCrypto else { return }
        if let decoded = try? WireFormat.open(data, crypto: crypto), decoded.type == .presencePing {
            guard let ping = try? WireFormat.decodePayload(PresenceHeartbeatMessage.self, from: decoded.payload), ping.nonce.count == 32,
                  let pong = try? WireFormat.seal(.presencePong, ping, crypto: crypto), isSessionReady else { return }
            _ = client.sendResponse(pong)
            return
        }
        guard isSessionReady, let (_, payload) = try? challengeHandler.validatedChallenge(data) else { return }
        if UIApplication.shared.applicationState == .active { processChallenge(data) } else {
            deferredChallenge = data
            let content = UNMutableNotificationContent(); content.title = "TouchBridge"; content.body = "\(payload.user) — \(payload.service)"; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dev.touchbridge.challenge", content: content, trigger: nil))
        }
    }
    public func bleClient(_ client: BLEClient, didReceivePairingData data: Data, from peripheralID: UUID) {
        guard !isRevoked, let crypto = sessionCrypto else { return }
        do {
            let decoded = try WireFormat.open(data, crypto: crypto)
            guard decoded.type == .pairResponse else { return }
            let response = try WireFormat.decodePayload(PairResponseMessage.self, from: decoded.payload)
            guard response.accepted, response.deviceID == deviceID, response.publicKey == (try signingProvider.publicKey(for: signingKeyTag)),
                  let pin = pendingMacKey ?? defaults.data(forKey: "pairedMacPublicKey") else { throw ProtocolSecurityError.invalidProof }
            if let pendingMacKey {
                defaults.set(pendingMacKey, forKey: "pairedMacPublicKey"); defaults.set(client.serviceUUID, forKey: "pairedMacID")
                defaults.set(pendingMacName, forKey: "pairedMacName"); defaults.set(deviceID, forKey: "companionDeviceID")
            }
            verified = true; challengeHandler.macIdentityHash = Data(SHA256.hash(data: pin)); challengeHandler.sessionCrypto = crypto
            let newPair = pendingPairingToken != nil
            pendingPairingToken = nil; pendingMacName = nil; pendingMacKey = nil
            onConnectionChanged?(true); if newPair { onPairingComplete?(client.serviceUUID) }
        } catch { clearSession(); onPairingFailed?() }
    }
}

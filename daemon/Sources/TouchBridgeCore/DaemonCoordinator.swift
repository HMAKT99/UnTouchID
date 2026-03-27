import Foundation
import CoreBluetooth
import CryptoKit
import OSLog
import TouchBridgeProtocol

/// Coordinates all daemon components: BLE server, challenge management,
/// pairing, session crypto, and audit logging.
///
/// This is the central integration point that wires events from the BLE layer
/// to the crypto and storage layers.
public final class DaemonCoordinator: NSObject, PAMAuthHandler, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "Coordinator")

    // Components
    public let bleServer: BLEServer
    public let challengeManager: ChallengeManager
    public let pairingManager: PairingManager
    public let keychainStore: KeychainStore
    public let auditLog: AuditLog

    // Per-central session state
    private var sessions: [UUID: SessionState] = [:]

    /// Pending PAM authentications awaiting challenge results.
    private var pendingAuthentications: [UUID: CheckedContinuation<ChallengeResult, Never>] = [:]

    /// Callback invoked when a challenge is verified or fails.
    public var onChallengeResult: ((UUID, ChallengeResult, String?) -> Void)?

    /// Callback invoked when pairing completes.
    public var onPairingComplete: ((PairedDevice) -> Void)?

    private struct SessionState {
        var ephemeralPrivateKey: P256.KeyAgreement.PrivateKey?
        var sessionCrypto: SessionCrypto?
        var deviceID: String?
    }

    public init(
        keychainStore: KeychainStore = KeychainStore(),
        auditLog: AuditLog = AuditLog(),
        challengeManager: ChallengeManager = ChallengeManager(),
        pairingManager: PairingManager? = nil,
        rssiThreshold: Int = TouchBridgeConstants.defaultRSSIThreshold
    ) {
        self.keychainStore = keychainStore
        self.auditLog = auditLog
        self.challengeManager = challengeManager
        self.bleServer = BLEServer(rssiThreshold: rssiThreshold)

        let pm = pairingManager ?? PairingManager(keychainStore: keychainStore)
        self.pairingManager = pm

        super.init()
        self.bleServer.delegate = self
    }

    // MARK: - Public API

    /// Start the daemon: begin advertising over BLE.
    public func start() {
        logger.info("DaemonCoordinator starting")
        // BLEServer will start advertising once Bluetooth is powered on
        // (handled in peripheralManagerDidUpdateState via delegate)
    }

    /// Start advertising (call after BLE is ready).
    public func startAdvertising() {
        bleServer.startAdvertising()
    }

    /// Stop advertising and clean up.
    public func stop() {
        bleServer.stopAdvertising()
        sessions.removeAll()
        logger.info("DaemonCoordinator stopped")
    }

    /// Issue a challenge to a specific connected device.
    ///
    /// - Parameters:
    ///   - centralID: The BLE central UUID of the connected companion.
    ///   - reason: The reason string to show on the companion (e.g., "sudo").
    /// - Returns: The challenge ID, or nil if sending failed.
    public func issueChallenge(to centralID: UUID, reason: String) async -> UUID? {
        guard let session = sessions[centralID],
              let crypto = session.sessionCrypto,
              let deviceID = session.deviceID else {
            logger.warning("Cannot issue challenge: no session for central \(centralID)")
            return nil
        }

        do {
            let challenge = try await challengeManager.issue(for: deviceID)

            // Encrypt nonce for wire transfer
            let encryptedNonce = try crypto.encrypt(plaintext: challenge.nonce)

            let msg = ChallengeIssuedMessage(
                challengeID: challenge.id.uuidString,
                encryptedNonce: encryptedNonce,
                reason: reason,
                expiryUnix: UInt64(challenge.expiresAt.timeIntervalSince1970)
            )

            let wireData = try WireFormat.encode(.challengeIssued, msg)
            let sent = bleServer.sendChallenge(wireData, to: centralID)

            if sent {
                logger.info("Challenge \(challenge.id) issued to \(centralID)")
                await auditLog.log(AuditEntry(
                    sessionID: challenge.id.uuidString,
                    surface: reason,
                    result: "ISSUED",
                    rssi: bleServer.averageRSSI(for: centralID)
                ))
                return challenge.id
            } else {
                logger.warning("Failed to send challenge over BLE")
                return nil
            }
        } catch {
            logger.error("Challenge issuance failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Authenticate a PAM request by issuing a challenge to a connected companion.
    ///
    /// Called by `SocketServer` when a PAM module connects.
    /// Blocks (async) until the companion responds or the timeout expires.
    public func authenticateFromPAM(
        user: String,
        service: String,
        pid: Int,
        timeout: TimeInterval
    ) async -> (success: Bool, reason: String?) {
        guard let centralID = readyCentrals.first else {
            logger.warning("PAM auth: no companion connected")
            await auditLog.log(AuditEntry(
                sessionID: UUID().uuidString,
                surface: "pam_\(service)",
                requestingProcess: service,
                deviceID: "",
                result: "FAILED_NO_DEVICE"
            ))
            return (false, "no_companion_connected")
        }

        // Issue challenge and await result with timeout
        let result: ChallengeResult? = await withTaskGroup(of: ChallengeResult?.self) { group in
            group.addTask {
                // Issue challenge and wait for BLE response
                await withCheckedContinuation { (continuation: CheckedContinuation<ChallengeResult, Never>) in
                    Task {
                        guard let challengeID = await self.issueChallenge(to: centralID, reason: service) else {
                            continuation.resume(returning: .unknownChallenge)
                            return
                        }
                        self.pendingAuthentications[challengeID] = continuation
                    }
                }
            }

            group.addTask {
                // Timeout
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            // Return whichever finishes first
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let result, result == .verified {
            return (true, nil)
        }

        let reason: String
        switch result {
        case .expired: reason = "challenge_expired"
        case .invalidSignature: reason = "invalid_signature"
        case .replayDetected: reason = "replay_detected"
        case .unknownChallenge: reason = "challenge_failed"
        case nil: reason = "timeout"
        case .verified: reason = "unknown" // unreachable
        }

        return (false, reason)
    }

    /// Get all connected central UUIDs that have completed ECDH.
    public var readyCentrals: [UUID] {
        sessions.filter { $0.value.sessionCrypto != nil }.map(\.key)
    }
}

// MARK: - BLEServerDelegate

extension DaemonCoordinator: BLEServerDelegate {

    public func bleServer(_ server: BLEServer, centralDidConnect centralID: UUID) {
        logger.info("Central connected: \(centralID)")
        sessions[centralID] = SessionState()
    }

    public func bleServer(_ server: BLEServer, centralDidDisconnect centralID: UUID) {
        logger.info("Central disconnected: \(centralID)")
        sessions.removeValue(forKey: centralID)
    }

    public func bleServer(_ server: BLEServer, didReceiveSessionKey data: Data, from centralID: UUID) -> Data? {
        logger.info("Received session key from \(centralID)")

        do {
            // Import their ephemeral public key
            let theirPublic = try SessionCrypto.importPublicKey(data)

            // Generate our ephemeral key pair
            let (myPrivate, myPublic) = SessionCrypto.generateEphemeralKeyPair()

            // Derive session
            let session = try SessionCrypto.deriveSession(myPrivate: myPrivate, theirPublic: theirPublic)

            sessions[centralID]?.ephemeralPrivateKey = myPrivate
            sessions[centralID]?.sessionCrypto = session

            logger.info("ECDH session established with \(centralID)")

            // Return our public key for them to derive the same session
            return SessionCrypto.exportPublicKey(myPublic)
        } catch {
            logger.error("ECDH key exchange failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func bleServer(_ server: BLEServer, didReceivePairingData data: Data, from centralID: UUID) {
        logger.info("Received pairing data from \(centralID)")

        Task {
            do {
                let (_, payload) = try WireFormat.decode(data: data)
                let request = try WireFormat.decodePayload(PairRequestMessage.self, from: payload)

                let device = try await pairingManager.validatePairingRequest(
                    token: Data(), // Token comes from the QR code scan, validated separately
                    devicePublicKey: request.publicKey,
                    deviceName: request.deviceName,
                    deviceID: centralID.uuidString
                )

                try await pairingManager.completePairing(device: device)
                sessions[centralID]?.deviceID = device.deviceID

                // Send acceptance response
                let response = PairResponseMessage(
                    deviceID: device.deviceID,
                    publicKey: Data(),
                    accepted: true
                )
                let wireResponse = try WireFormat.encode(.pairResponse, response)
                _ = server.sendPairingData(wireResponse, to: centralID)

                await auditLog.log(AuditEntry(
                    sessionID: centralID.uuidString,
                    surface: "pairing",
                    companionDevice: device.displayName,
                    deviceID: device.deviceID,
                    result: "PAIRED"
                ))

                onPairingComplete?(device)
                logger.info("Pairing completed for \(device.displayName)")
            } catch {
                logger.error("Pairing failed: \(error.localizedDescription)")

                // Send rejection
                if let response = try? WireFormat.encode(.pairResponse, PairResponseMessage(
                    deviceID: "",
                    publicKey: Data(),
                    accepted: false
                )) {
                    _ = server.sendPairingData(response, to: centralID)
                }
            }
        }
    }

    public func bleServer(_ server: BLEServer, didReceiveResponse data: Data, from centralID: UUID) {
        logger.info("Received challenge response from \(centralID)")

        Task {
            do {
                let (_, payload) = try WireFormat.decode(data: data)
                let response = try WireFormat.decodePayload(ChallengeResponseMessage.self, from: payload)

                guard let challengeID = UUID(uuidString: response.challengeID) else {
                    logger.error("Invalid challenge ID in response")
                    return
                }

                let publicKey = try keychainStore.retrievePublicKey(for: response.deviceID)
                let startTime = Date()

                let result = await challengeManager.verify(
                    challengeID: challengeID,
                    signature: response.signature,
                    publicKey: publicKey
                )

                let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

                let resultString: String
                switch result {
                case .verified: resultString = "VERIFIED"
                case .expired: resultString = "FAILED_TIMEOUT"
                case .invalidSignature: resultString = "FAILED_SIGNATURE"
                case .replayDetected: resultString = "FAILED_REPLAY"
                case .unknownChallenge: resultString = "FAILED_SIGNATURE"
                }

                await auditLog.log(AuditEntry(
                    sessionID: response.challengeID,
                    surface: "challenge",
                    companionDevice: response.deviceID,
                    deviceID: response.deviceID,
                    result: resultString,
                    rssi: server.averageRSSI(for: centralID),
                    latencyMs: latencyMs
                ))

                // Resume any pending PAM authentication continuation
                if let continuation = pendingAuthentications.removeValue(forKey: challengeID) {
                    continuation.resume(returning: result)
                }

                onChallengeResult?(challengeID, result, response.deviceID)

                logger.info("Challenge \(response.challengeID): \(resultString)")
            } catch {
                logger.error("Response processing failed: \(error.localizedDescription)")
            }
        }
    }
}

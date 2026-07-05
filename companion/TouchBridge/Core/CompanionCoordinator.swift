import Foundation
import UIKit
import CryptoKit
import UserNotifications
import os.log

/// Coordinates all companion app components: BLE client, ECDH session,
/// challenge handling, Secure Enclave signing, and biometric auth.
///
/// This is the central integration point on the iOS side.
public final class CompanionCoordinator: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "CompanionCoordinator")

    // Components
    public let bleClient: BLEClient
    public let challengeHandler: ChallengeHandler
    public let signingProvider: SigningProvider
    public let localAuth: LocalAuthManager

    // Session state
    private var ephemeralPrivateKey: P256.KeyAgreement.PrivateKey?
    private var sessionCrypto: SessionCryptoWrapper?
    private var deviceID: String

    // Callbacks
    public var onConnectionChanged: ((Bool) -> Void)?
    public var onChallengeReceived: ((String) -> Void)?
    /// Called when a challenge completes. Parameters: challengeID, success, errorCode (nil on success).
    public var onChallengeResult: ((String, Bool, ChallengeHandlerError?) -> Void)?
    public var onPairingComplete: ((String) -> Void)?
    /// Called when the Mac rejects a pairing request (wrong/expired token, no pairing window).
    public var onPairingFailed: (() -> Void)?

    // Active pairing session (set by beginPairing, cleared when the Mac responds)
    private var pendingPairingToken: Data?
    private var pendingMacName: String?

    // Challenge received while backgrounded — Face ID can't prompt without UI,
    // so it's held here and processed when the app becomes active.
    private var deferredChallenge: Data?
    private var lifecycleObserver: NSObjectProtocol?

    /// Signing key tag in Keychain/Secure Enclave.
    private let signingKeyTag = "dev.touchbridge.signing"

    public init(
        signingProvider: SigningProvider? = nil,
        deviceID: String? = nil
    ) {
        self.bleClient = BLEClient()
        self.localAuth = LocalAuthManager()

        // Use real Secure Enclave on device, mock on simulator
        #if targetEnvironment(simulator)
        self.signingProvider = signingProvider ?? MockSigningProvider()
        #else
        self.signingProvider = signingProvider ?? SecureEnclaveManager()
        #endif

        self.challengeHandler = ChallengeHandler(
            signingProvider: self.signingProvider,
            localAuth: self.localAuth,
            signingKeyTag: "dev.touchbridge.signing"
        )

        self.deviceID = deviceID ?? (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)

        super.init()

        bleClient.delegate = self

        // If already paired, scan only for the paired Mac's unique service UUID.
        // This prevents connecting to other people's TouchBridge Macs nearby.
        if let storedUUID = UserDefaults.standard.string(forKey: "pairedMacID"),
           !storedUUID.isEmpty {
            bleClient.serviceUUID = storedUUID
        }

        // Wire challenge handler's send callback to BLE
        challengeHandler.sendResponse = { [weak self] data in
            self?.bleClient.sendResponse(data) ?? false
        }

        // Process any challenge that arrived while backgrounded as soon as
        // the user opens the app (typically by tapping the notification).
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let data = self.deferredChallenge else { return }
            self.deferredChallenge = nil
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            self.processChallenge(data)
        }
    }

    deinit {
        if let observer = lifecycleObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Start scanning for Mac daemon peripherals.
    public func startScanning() {
        bleClient.startScanning()
        logger.info("Started scanning for Mac")
    }

    /// Force a fresh BLE handshake with the paired Mac.
    public func resetConnectionAndScan() {
        sessionCrypto = nil
        ephemeralPrivateKey = nil
        challengeHandler.sessionCrypto = nil
        bleClient.resetConnectionAndScan()
        logger.info("Reset BLE connection and restarted scanning")
    }

    /// Connect to a discovered Mac peripheral.
    public func connect(to peripheralID: UUID) {
        bleClient.connect(to: peripheralID)
    }

    /// Disconnect from the Mac.
    public func disconnect() {
        bleClient.disconnect()
        sessionCrypto = nil
        ephemeralPrivateKey = nil
    }

    /// Generate or retrieve the signing key pair and return the public key.
    public func getOrCreateSigningKey() throws -> Data {
        // Try to get existing key first
        if let existingKey = try? signingProvider.publicKey(for: signingKeyTag) {
            return existingKey
        }

        // Generate new key pair
        return try signingProvider.generateKeyPair(tag: signingKeyTag)
    }

    /// Whether ECDH session is established.
    public var isSessionReady: Bool { sessionCrypto != nil }

    /// List of discovered Mac peripheral UUIDs.
    public var discoveredMacs: [UUID] { bleClient.discoveredPeripheralIDs }

    /// Whether connected to a Mac.
    public var isConnected: Bool { bleClient.isConnected }

    // MARK: - ECDH Session Setup

    private func performECDHKeyExchange() {
        // Generate ephemeral key pair
        let privateKey = P256.KeyAgreement.PrivateKey()
        ephemeralPrivateKey = privateKey

        // Export public key and send to Mac
        let publicKeyData = privateKey.publicKey.x963Representation
        _ = bleClient.sendSessionKey(publicKeyData)

        logger.info("Sent ECDH public key to Mac")
    }

    private func completeECDH(macPublicKeyData: Data) {
        guard let myPrivate = ephemeralPrivateKey else {
            logger.error("No ephemeral private key — ECDH not initiated")
            return
        }

        do {
            let macPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: macPublicKeyData)
            let sharedSecret = try myPrivate.sharedSecretFromKeyAgreement(with: macPublicKey)

            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: Data("TouchBridge-v1".utf8),
                outputByteCount: 32
            )

            let crypto = SessionCryptoWrapper(
                encrypt: { plaintext in
                    let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
                    return sealedBox.combined!
                },
                decrypt: { ciphertext in
                    let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
                    return try AES.GCM.open(sealedBox, using: symmetricKey)
                }
            )

            sessionCrypto = crypto
            challengeHandler.sessionCrypto = crypto

            logger.info("ECDH session established with Mac")

            // Immediately identify ourselves to the daemon.
            // This allows the Mac to recognise us as a previously-paired device
            // without going through the full pairing ceremony again.
            sendIdentify(using: crypto)
        } catch {
            logger.error("ECDH failed: \(error.localizedDescription)")
        }
    }

    /// Send an encrypted identify message to the Mac after ECDH.
    ///
    /// Wire format: [version=1][type=6(identify)] + AES-GCM encrypted JSON
    /// The Mac decrypts it, looks up deviceID in the keychain, and marks
    /// this session as identified so it can receive challenges.
    private func sendIdentify(using crypto: SessionCryptoWrapper) {
        struct IdentifyPayload: Codable {
            let deviceID: String
            let deviceName: String
        }

        do {
            let payload = IdentifyPayload(
                deviceID: deviceID,
                deviceName: UIDevice.current.name
            )
            let plaintext = try JSONEncoder().encode(payload)
            let encrypted = try crypto.encrypt(plaintext: plaintext)

            var wireData = Data([1, 6]) // version=1, type=identify(6)
            wireData.append(encrypted)

            _ = bleClient.sendPairingData(wireData)
            logger.info("Sent identify for device \(self.deviceID)")
        } catch {
            logger.error("Failed to send identify: \(error.localizedDescription)")
        }
    }

    // MARK: - Pairing

    /// Start a pairing session from a scanned/pasted pairing payload.
    ///
    /// Locks BLE scanning to the Mac's service UUID from the payload and holds
    /// the one-time token so `sendPairingRequest` can present it to the daemon.
    public func beginPairing(serviceUUID: String, token: Data, macName: String) {
        pendingPairingToken = token
        pendingMacName = macName
        bleClient.serviceUUID = serviceUUID
        startScanning()
        logger.info("Pairing session started for \(macName)")
    }

    /// Send pairing request to Mac with our signing public key and the pairing token.
    ///
    /// Wire format: [version=1][type=1(pairRequest)] + JSON PairRequestMessage.
    public func sendPairingRequest(macName: String) {
        do {
            let publicKey = try getOrCreateSigningKey()
            // Truncate so the wire frame stays under the 256-byte protocol cap
            let deviceName = String(UIDevice.current.name.prefix(20))

            struct PairRequest: Codable {
                let deviceName: String
                let publicKey: Data
                let deviceID: String
                let pairingToken: Data?
            }
            let request = PairRequest(
                deviceName: deviceName,
                publicKey: publicKey,
                deviceID: deviceID,
                pairingToken: pendingPairingToken
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let payload = try encoder.encode(request)

            var wireData = Data([1, 1]) // version=1, type=pairRequest(1)
            wireData.append(payload)
            _ = bleClient.sendPairingData(wireData)

            logger.info("Sent pairing request to \(macName)")
        } catch {
            logger.error("Failed to send pairing request: \(error.localizedDescription)")
        }
    }
}

// MARK: - BLEClientDelegate

extension CompanionCoordinator: BLEClientDelegate {

    public func bleClient(_ client: BLEClient, connectionStateChanged connected: Bool, peripheralID: UUID) {
        logger.info("Connection state: \(connected) for \(peripheralID)")

        if connected {
            logger.info("Connected; waiting for BLE characteristics before ECDH")
        } else {
            sessionCrypto = nil
            ephemeralPrivateKey = nil
            challengeHandler.sessionCrypto = nil
        }

        DispatchQueue.main.async {
            self.onConnectionChanged?(connected)
        }
    }

    public func bleClientDidBecomeReadyForSecureSession(_ client: BLEClient, peripheralID: UUID) {
        logger.info("BLE session is ready; starting ECDH for \(peripheralID)")
        performECDHKeyExchange()
    }

    public func bleClient(_ client: BLEClient, didReceiveChallenge data: Data, from peripheralID: UUID) {
        logger.info("Received challenge from Mac")

        DispatchQueue.main.async {
            self.onChallengeReceived?("Challenge received")

            if UIApplication.shared.applicationState == .active {
                self.processChallenge(data)
            } else {
                // Backgrounded: Face ID can't prompt without UI. Buzz the user with
                // a notification and handle the challenge when the app opens.
                self.deferredChallenge = data
                self.postChallengeNotification(reason: self.challengeReason(from: data))
            }
        }
    }

    /// Run the decrypt → Face ID → sign → respond flow (must start from an active app).
    private func processChallenge(_ data: Data) {
        Task { @MainActor in
            let result = await challengeHandler.handleChallenge(
                encryptedData: data,
                deviceID: deviceID
            )

            switch result {
            case .success(let challengeID):
                logger.info("Challenge \(challengeID) approved")
                self.onChallengeResult?(challengeID, true, nil)
            case .failed(let error):
                logger.warning("Challenge failed: \(error)")
                self.onChallengeResult?("", false, error)
            }
        }
    }

    /// Extract the plaintext reason from a challenge wire frame (only the nonce is encrypted).
    private func challengeReason(from data: Data) -> String {
        guard data.count > 2,
              let msg = try? JSONDecoder().decode(ChallengeIssuedMessageCompanion.self, from: data.dropFirst(2)) else {
            return "authentication"
        }
        return msg.reason
    }

    private func postChallengeNotification(reason: String) {
        let macName = UserDefaults.standard.string(forKey: "pairedMacName") ?? "Your Mac"
        let content = UNMutableNotificationContent()
        content.title = "Authentication Request"
        content.body = "\(macName) is asking you to approve: \(reason)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dev.touchbridge.challenge",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        logger.info("Posted background challenge notification")
    }

    public func bleClient(_ client: BLEClient, didReceiveSessionKey data: Data, from peripheralID: UUID) {
        logger.info("Received Mac's ECDH public key")
        completeECDH(macPublicKeyData: data)
    }

    public func bleClient(_ client: BLEClient, didReceivePairingData data: Data, from peripheralID: UUID) {
        logger.info("Received pairing response from Mac")

        // Response is wire format: [version=1][type=2(pairResponse)] + JSON payload
        let payload: Data
        if data.count > 2, data[data.startIndex] == 1 {
            payload = data.dropFirst(2)
        } else {
            payload = data
        }

        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let accepted = json["accepted"] as? Bool, accepted {
            // Persist pairing only once the Mac has accepted.
            // "pairedMacID" holds the Mac's BLE service UUID (set during beginPairing) —
            // it locks future scans to this Mac instead of any TouchBridge Mac nearby.
            UserDefaults.standard.set(bleClient.serviceUUID, forKey: "pairedMacID")
            if let macName = pendingMacName {
                UserDefaults.standard.set(macName, forKey: "pairedMacName")
            }
            pendingPairingToken = nil

            let macID = bleClient.serviceUUID
            DispatchQueue.main.async {
                self.onPairingComplete?(macID)
            }

            logger.info("Pairing accepted by Mac")
        } else {
            pendingPairingToken = nil
            DispatchQueue.main.async {
                self.onPairingFailed?()
            }
            logger.warning("Pairing rejected by Mac")
        }
    }
}

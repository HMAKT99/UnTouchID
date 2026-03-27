import Foundation
import UIKit
import CryptoKit
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
    public var onChallengeResult: ((String, Bool) -> Void)?
    public var onPairingComplete: ((String) -> Void)?

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

        // Wire challenge handler's send callback to BLE
        challengeHandler.sendResponse = { [weak self] data in
            self?.bleClient.sendResponse(data) ?? false
        }
    }

    // MARK: - Public API

    /// Start scanning for Mac daemon peripherals.
    public func startScanning() {
        bleClient.startScanning()
        logger.info("Started scanning for Mac")
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
        } catch {
            logger.error("ECDH failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pairing

    /// Send pairing request to Mac with our signing public key.
    public func sendPairingRequest(macName: String) {
        do {
            let publicKey = try getOrCreateSigningKey()
            let deviceName = UIDevice.current.name

            // Build pairing request JSON
            let request: [String: Any] = [
                "deviceName": deviceName,
                "publicKey": publicKey.base64EncodedString(),
                "deviceID": deviceID,
            ]

            let data = try JSONSerialization.data(withJSONObject: request)
            _ = bleClient.sendPairingData(data)

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
            // Initiate ECDH key exchange
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.performECDHKeyExchange()
            }
        } else {
            sessionCrypto = nil
            ephemeralPrivateKey = nil
            challengeHandler.sessionCrypto = nil
        }

        DispatchQueue.main.async {
            self.onConnectionChanged?(connected)
        }
    }

    public func bleClient(_ client: BLEClient, didReceiveChallenge data: Data, from peripheralID: UUID) {
        logger.info("Received challenge from Mac")

        DispatchQueue.main.async {
            self.onChallengeReceived?("Challenge received")
        }

        // Handle challenge on main actor (biometric prompt requires it)
        Task { @MainActor in
            let result = await challengeHandler.handleChallenge(
                encryptedData: data,
                deviceID: deviceID
            )

            switch result {
            case .success(let challengeID):
                logger.info("Challenge \(challengeID) approved")
                self.onChallengeResult?(challengeID, true)
            case .failed(let error):
                logger.warning("Challenge failed: \(error)")
                self.onChallengeResult?("", false)
            }
        }
    }

    public func bleClient(_ client: BLEClient, didReceiveSessionKey data: Data, from peripheralID: UUID) {
        logger.info("Received Mac's ECDH public key")
        completeECDH(macPublicKeyData: data)
    }

    public func bleClient(_ client: BLEClient, didReceivePairingData data: Data, from peripheralID: UUID) {
        logger.info("Received pairing response from Mac")

        // Parse pairing response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accepted = json["accepted"] as? Bool, accepted {
            let macID = json["deviceID"] as? String ?? peripheralID.uuidString

            // Store pairing info
            UserDefaults.standard.set(macID, forKey: "pairedMacID")

            DispatchQueue.main.async {
                self.onPairingComplete?(macID)
            }

            logger.info("Pairing accepted by Mac")
        } else {
            logger.warning("Pairing rejected by Mac")
        }
    }
}

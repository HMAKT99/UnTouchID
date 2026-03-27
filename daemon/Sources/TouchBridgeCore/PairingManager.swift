import Foundation
import Security
import OSLog
import TouchBridgeProtocol

/// QR code payload exchanged during the pairing ceremony.
public struct PairingPayload: Codable, Sendable {
    public let version: UInt8
    public let serviceUUID: String
    public let pairingToken: Data
    public let macName: String

    public init(version: UInt8 = 1, serviceUUID: String, pairingToken: Data, macName: String) {
        self.version = version
        self.serviceUUID = serviceUUID
        self.pairingToken = pairingToken
        self.macName = macName
    }
}

/// Manages the one-time pairing ceremony between Mac and companion device.
///
/// Pairing flow:
/// 1. Mac generates a `PairingPayload` with a random token, encodes to JSON for QR display
/// 2. iPhone scans QR, connects via BLE, sends `PairRequestMessage` with its SE public key
/// 3. Mac validates the token, stores the public key via `KeychainStore`
/// 4. Mac responds with `PairResponseMessage(accepted: true)`
/// 5. Pairing token expires after 5 minutes
public actor PairingManager {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "PairingManager")

    private let keychainStore: KeychainStore
    private let macName: String
    private let tokenExpiry: TimeInterval

    /// Active pairing token and its creation time.
    private var activePairing: (token: Data, createdAt: Date)?

    public init(
        keychainStore: KeychainStore,
        macName: String? = nil,
        tokenExpiry: TimeInterval = 300 // 5 minutes
    ) {
        self.keychainStore = keychainStore
        self.macName = macName ?? Host.current().localizedName ?? "Mac"
        self.tokenExpiry = tokenExpiry
    }

    /// Generate a pairing payload for QR code display.
    ///
    /// The pairing token is 16 random bytes, valid for 5 minutes.
    /// Returns the JSON-encoded payload suitable for QR code generation.
    public func generatePairingQRData() throws -> Data {
        var tokenBytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes)
        guard status == errSecSuccess else {
            throw PairingError.tokenGenerationFailed
        }

        let token = Data(tokenBytes)
        activePairing = (token: token, createdAt: Date())

        let payload = PairingPayload(
            serviceUUID: TouchBridgeConstants.serviceUUID,
            pairingToken: token,
            macName: macName
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)

        logger.info("Generated pairing QR data (token valid for \(self.tokenExpiry)s)")
        return data
    }

    /// Validate an incoming pairing request from a companion device.
    ///
    /// Checks that:
    /// 1. A pairing token is active
    /// 2. The provided token matches
    /// 3. The token has not expired
    /// 4. The public key data is valid (65 bytes for uncompressed P-256)
    ///
    /// - Returns: A `PairedDevice` record ready to be stored.
    public func validatePairingRequest(
        token: Data,
        devicePublicKey: Data,
        deviceName: String,
        deviceID: String
    ) throws -> PairedDevice {
        guard let active = activePairing else {
            logger.warning("Pairing request received but no active pairing session")
            throw PairingError.noPairingActive
        }

        // Check token match
        guard active.token == token else {
            logger.warning("Pairing token mismatch")
            throw PairingError.tokenMismatch
        }

        // Check expiry
        let elapsed = Date().timeIntervalSince(active.createdAt)
        guard elapsed < tokenExpiry else {
            logger.warning("Pairing token expired (\(elapsed)s elapsed)")
            activePairing = nil
            throw PairingError.tokenExpired
        }

        // Validate public key format (uncompressed P-256 = 65 bytes starting with 0x04)
        guard devicePublicKey.count == 65, devicePublicKey[0] == 0x04 else {
            logger.warning("Invalid public key format: \(devicePublicKey.count) bytes")
            throw PairingError.invalidPublicKey
        }

        // Verify the key can be reconstructed as a SecKey
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard SecKeyCreateWithData(devicePublicKey as CFData, keyAttrs as CFDictionary, &error) != nil else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            logger.error("Public key reconstruction failed: \(desc)")
            throw PairingError.invalidPublicKey
        }

        let device = PairedDevice(
            deviceID: deviceID,
            publicKey: devicePublicKey,
            displayName: deviceName,
            pairedAt: Date()
        )

        logger.info("Pairing request validated for \(deviceName)")
        return device
    }

    /// Complete the pairing by storing the device in the Keychain.
    public func completePairing(device: PairedDevice) throws {
        try keychainStore.storePairedDevice(device)
        activePairing = nil
        logger.info("Pairing completed for \(device.displayName) (\(device.deviceID))")
    }

    /// Cancel any active pairing session.
    public func cancelPairing() {
        activePairing = nil
        logger.info("Pairing session cancelled")
    }

    /// Whether a pairing session is currently active and not expired.
    public var isPairingActive: Bool {
        guard let active = activePairing else { return false }
        return Date().timeIntervalSince(active.createdAt) < tokenExpiry
    }
}

public enum PairingError: Error, Sendable {
    case tokenGenerationFailed
    case noPairingActive
    case tokenMismatch
    case tokenExpired
    case invalidPublicKey
}

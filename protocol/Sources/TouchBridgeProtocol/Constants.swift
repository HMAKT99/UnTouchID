import Foundation

/// Shared constants for the TouchBridge protocol.
public enum TouchBridgeConstants {
    /// Protocol version — included in every message header.
    public static let protocolVersion: UInt8 = 0x01

    /// Maximum wire message size in bytes.
    public static let maxMessageSize = 256

    // MARK: - BLE UUIDs

    /// Primary BLE service UUID.
    public static let serviceUUID = "B5E6D1A4-8C3F-4E2A-9D7B-1F5A0C6E3B28"

    /// Characteristic for ECDH session key exchange.
    public static let sessionKeyCharUUID = "B5E6D1A4-0001-4E2A-9D7B-1F5A0C6E3B28"

    /// Characteristic for challenge delivery (Mac → iPhone, notify).
    public static let challengeCharUUID = "B5E6D1A4-0002-4E2A-9D7B-1F5A0C6E3B28"

    /// Characteristic for signed response (iPhone → Mac, write).
    public static let responseCharUUID = "B5E6D1A4-0003-4E2A-9D7B-1F5A0C6E3B28"

    /// Characteristic for pairing flow (bidirectional).
    public static let pairingCharUUID = "B5E6D1A4-0004-4E2A-9D7B-1F5A0C6E3B28"

    // MARK: - Timing

    /// Challenge nonce expiry in seconds.
    public static let challengeExpirySeconds: TimeInterval = 10.0

    /// Seen-nonces replay protection TTL in seconds.
    public static let replayWindowSeconds: TimeInterval = 60.0

    /// Default companion response timeout in seconds.
    public static let responseTimeoutSeconds: TimeInterval = 15.0

    /// Default RSSI proximity threshold (dBm).
    public static let defaultRSSIThreshold: Int = -75

    // MARK: - Keychain

    /// Keychain service identifier for paired devices.
    public static let keychainService = "dev.touchbridge.daemon"

    /// Secure Enclave signing key tag on iOS.
    public static let signingKeyTag = "dev.touchbridge.signing"
}

import Foundation

/// Shared constants for the TouchBridge protocol.
/// Mirrors protocol/Sources/TouchBridgeProtocol/Constants.swift for the companion app.
enum TouchBridgeConstants {
    static let protocolVersion: UInt8 = 0x01
    static let maxMessageSize = 256

    // BLE UUIDs
    static let serviceUUID = "B5E6D1A4-8C3F-4E2A-9D7B-1F5A0C6E3B28"
    static let sessionKeyCharUUID = "B5E6D1A4-0001-4E2A-9D7B-1F5A0C6E3B28"
    static let challengeCharUUID = "B5E6D1A4-0002-4E2A-9D7B-1F5A0C6E3B28"
    static let responseCharUUID = "B5E6D1A4-0003-4E2A-9D7B-1F5A0C6E3B28"
    static let pairingCharUUID = "B5E6D1A4-0004-4E2A-9D7B-1F5A0C6E3B28"

    // Timing
    static let challengeExpirySeconds: TimeInterval = 10.0
    static let replayWindowSeconds: TimeInterval = 60.0
    static let responseTimeoutSeconds: TimeInterval = 15.0
    static let defaultRSSIThreshold: Int = -75

    // Keychain
    static let keychainService = "dev.touchbridge.daemon"
    static let signingKeyTag = "dev.touchbridge.signing"
}

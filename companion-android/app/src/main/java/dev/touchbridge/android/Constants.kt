package dev.touchbridge.android

import java.util.UUID

/**
 * Shared constants matching the TouchBridge protocol.
 * Must stay in sync with protocol/Sources/TouchBridgeProtocol/Constants.swift
 */
object Constants {
    const val PROTOCOL_VERSION: Byte = 0x01
    const val MAX_MESSAGE_SIZE = 256

    // BLE UUIDs — must match the Mac daemon's GATT service
    val SERVICE_UUID: UUID = UUID.fromString("B5E6D1A4-8C3F-4E2A-9D7B-1F5A0C6E3B28")
    val SESSION_KEY_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0001-4E2A-9D7B-1F5A0C6E3B28")
    val CHALLENGE_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0002-4E2A-9D7B-1F5A0C6E3B28")
    val RESPONSE_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0003-4E2A-9D7B-1F5A0C6E3B28")
    val PAIRING_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0004-4E2A-9D7B-1F5A0C6E3B28")

    // BLE descriptor for enabling notifications
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    // Timing
    const val CHALLENGE_EXPIRY_SECONDS = 10L
    const val RESPONSE_TIMEOUT_SECONDS = 15L

    // Keystore
    const val SIGNING_KEY_ALIAS = "dev.touchbridge.signing"

    // Preferences
    const val PREFS_NAME = "touchbridge_prefs"
    const val PREF_PAIRED_MAC_ID = "paired_mac_id"
    const val PREF_PAIRED_MAC_NAME = "paired_mac_name"
}

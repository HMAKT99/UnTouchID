# TouchBridge Wire Protocol — v0.01

## Transport

- **Primary:** BLE GATT — Mac is peripheral (server), iPhone is central (client)
- **Fallback:** Local Wi-Fi via Bonjour/mDNS (when BLE RSSI below threshold)

## BLE Service

| Name | UUID |
|------|------|
| Service | `B5E6D1A4-8C3F-4E2A-9D7B-1F5A0C6E3B28` |
| Session Key | `B5E6D1A4-0001-4E2A-9D7B-1F5A0C6E3B28` |
| Challenge | `B5E6D1A4-0002-4E2A-9D7B-1F5A0C6E3B28` |
| Response | `B5E6D1A4-0003-4E2A-9D7B-1F5A0C6E3B28` |
| Pairing | `B5E6D1A4-0004-4E2A-9D7B-1F5A0C6E3B28` |

## Wire Format

Every message: `[version: UInt8][type: UInt8][payload: JSON]`

- **Max size:** 256 bytes
- **Version:** `0x01`
- **Encoding:** JSON (Phase 0) — will migrate to MessagePack

## Message Types

| Type | Value | Direction | Description |
|------|-------|-----------|-------------|
| PairRequest | 1 | iPhone → Mac | Device name + SE public key |
| PairResponse | 2 | Mac → iPhone | Accepted/rejected + device ID |
| ChallengeIssued | 3 | Mac → iPhone | Encrypted nonce + reason + expiry |
| ChallengeResponse | 4 | iPhone → Mac | Signed nonce + device ID |
| Error | 5 | Either | Error code + description |

## Crypto

- **Signing:** ECDSA P-256, `ecdsaSignatureMessageX962SHA256`
- **Key agreement:** ECDH P-256 ephemeral per session
- **Session encryption:** AES-256-GCM (key from HKDF-SHA256 over ECDH shared secret)
- **Nonce:** 32 bytes from `SecRandomCopyBytes`, 10-second expiry
- **Replay protection:** 60-second seen-nonces window

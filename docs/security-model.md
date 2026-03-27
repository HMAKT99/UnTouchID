# TouchBridge Security Model

## Non-Negotiables

1. Private key never leaves Secure Enclave
2. Nonce freshness enforced on Mac side (expiry + replay detection)
3. No proximity-only auth by default (biometric required for all surfaces)
4. Reason string always shown on iPhone
5. Pairing is explicit and one-time (QR code ceremony)
6. Timeout = fail open to password, not to grant
7. Daemon runs as user, not root

## Cryptographic Chain

### Pairing (one-time)
- iPhone generates ECDSA P-256 key in Secure Enclave
- Public key transferred to Mac via BLE during QR pairing ceremony
- Mac stores public key in Keychain tagged with device UUID

### Per-Session (ECDH)
- Each BLE connection establishes ephemeral P-256 key pair on both sides
- Shared secret derived via ECDH → HKDF-SHA256 → AES-256 symmetric key
- All challenge/response data encrypted with AES-GCM

### Per-Request (Challenge-Response)
- Mac generates 32-byte nonce via SecRandomCopyBytes
- Nonce encrypted and sent to iPhone via BLE
- iPhone decrypts, prompts biometric, signs with Secure Enclave key
- Mac verifies ECDSA signature against pinned public key
- Nonce marked as seen (60s replay window)

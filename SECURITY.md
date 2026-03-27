# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability in TouchBridge, please report it responsibly:

1. **Do NOT open a public issue**
2. Email: security@touchbridge.dev (or open a private security advisory on GitHub)
3. Include: description, reproduction steps, impact assessment
4. We will acknowledge within 48 hours and provide a fix timeline

## Threat Model

### What TouchBridge protects against

- **Remote authentication attacks**: Biometric confirmation happens on a physical device you hold
- **Replay attacks**: 32-byte nonces with 10-second expiry and 60-second seen-nonces window
- **Man-in-the-middle**: ECDH ephemeral session keys with AES-256-GCM encryption on BLE channel
- **Key theft**: Private signing key lives inside Secure Enclave — never exported, never leaves the chip

### What TouchBridge does NOT protect against

- **Physical access to unlocked companion device**: If someone has your unlocked iPhone, they can approve auth requests
- **Keychain items with `kSecAccessControlBiometryCurrentSet`**: Cryptographically impossible — hardware ACL wall
- **Sandboxed third-party apps calling `LAContext`**: Blocked by SIP and sandbox
- **Compromised macOS kernel**: If the kernel is compromised, no user-space security holds

### Cryptographic properties

| Property | Implementation |
|----------|---------------|
| Nonce | 32 bytes from `SecRandomCopyBytes` |
| Nonce expiry | 10 seconds (hard minimum) |
| Replay protection | Seen-nonces ring buffer, 60-second TTL |
| Signing algorithm | ECDSA P-256 (`ecdsaSignatureMessageX962SHA256`) |
| Key storage (iOS) | Secure Enclave (`kSecAttrTokenIDSecureEnclave`) |
| Key storage (Mac) | Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) |
| Session encryption | AES-256-GCM over ECDH-derived key (HKDF-SHA256) |
| Transport | BLE GATT (encrypted) or local Wi-Fi (Bonjour) |

### Audit logging

Every authentication event is logged to `~/Library/Logs/TouchBridge/` as NDJSON:
- Session ID, result, device, surface, RSSI, latency
- **Nonce values are NEVER logged**

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

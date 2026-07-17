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

### Availability note: PAM fallback vs. a dangling module reference

TouchBridge installs `pam_touchbridge.so` as `auth sufficient`, so if the daemon
is down or the phone is unreachable, PAM falls through to your password — you are
never locked out by a *failed* authentication.

There is one exception, and it is an **availability** issue, not an
authentication bypass: if the module *file* is deleted while a PAM config still
references it, `sudo` cannot initialize PAM and refuses to run entirely. The
`sufficient` flag only falls through when the module loads and returns failure —
a missing module file is a hard failure.

To avoid this, on macOS Sonoma+ we install the hook into the unprotected
`/etc/pam.d/sudo_local` (Apple's sanctioned include) rather than the SIP-protected
`/etc/pam.d/sudo`, and our uninstaller always removes the hook **before** the
module. If you ever hit `sudo: unable to initialize PAM: No such file or
directory`, recover without needing sudo (GUI admin auth uses a different PAM
stack):

```bash
# Sonoma+ (hook in sudo_local — just delete it):
osascript -e 'do shell script "rm -f /etc/pam.d/sudo_local" with administrator privileges'
```

If `/etc/pam.d/sudo` itself is protected on your system and the hook was written
there by an older version, the most reliable fix is to restore the module so the
reference resolves again — download the latest `.pkg`, then:

```bash
pkgutil --expand-full TouchBridge-*.pkg /tmp/tb-x
osascript -e 'do shell script "cp /tmp/tb-x/Payload/usr/local/lib/pam/pam_touchbridge.so /usr/local/lib/pam/" with administrator privileges'
```

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
| 1.0.x   | Yes       |
| 0.1.x   | No — upgrade to 1.0 |

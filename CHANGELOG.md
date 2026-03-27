# Changelog

## [0.1.0-alpha] — 2026-03-23

### Phase 0 — Core Cryptographic Pipeline
- Challenge-response with 32-byte nonces, 10s expiry, replay protection
- ECDSA P-256 signature verification
- ECDH ephemeral session keys with AES-256-GCM encryption
- BLE GATT server (Mac) and client (iOS)
- Secure Enclave key generation and signing (iOS)
- Audit logging (NDJSON, never logs nonces)
- CLI test harness (`touchbridge-test`)
- Companion app with pairing and auth request UI

### Phase 1 — PAM Module
- `pam_touchbridge.so` universal binary (arm64 + x86_64)
- Unix domain socket server for PAM↔daemon IPC
- `sudo` and screensaver unlock via iPhone biometric
- Install/uninstall scripts with PAM file backup and restore
- LaunchAgent for daemon auto-start
- Fallback to password on timeout (configurable, default 15s)

### Phase 2 — Policy Engine
- Per-action configurable policy (biometric required vs proximity session)
- Default policies: sudo=biometric, screensaver=proximity(30m), app_store=biometric
- Proximity session tokens with configurable TTL
- RSSI proximity gate configuration
- `touchbridge-test config` CLI for policy management

### Phase 3 — Authorization Plugin
- Authorization plugin for system-level auth (App Store, System Settings)
- Same daemon socket protocol as PAM module

### Phase 4 — Browser Extensions
- Safari App Extension (Manifest V3)
- Chrome Extension (Manifest V3)
- Native messaging host (`touchbridge-nmh`)
- Password autofill and WebAuthn interception

### Phase 5 — Polish
- README with quick start guide
- SECURITY.md with threat model
- Architecture, setup, limitations, and policy documentation

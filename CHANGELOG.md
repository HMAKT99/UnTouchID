# Changelog

## [1.0.0] — 2026-03-29

### Menu Bar App & Installer
- macOS menu bar app with connection status, auth history, and settings
- 4-step guided setup wizard (welcome → install → pair → done)
- One-click `.pkg` installer — download, double-click, done
- `.dmg` disk image with app + installer bundled
- Release builder script (`installer/build-release.sh`)

### Android Companion
- Full Android companion app (Kotlin + Jetpack Compose)
- BLE GATT client with service discovery and notifications
- Android Keystore key generation (StrongBox/TEE backed)
- ECDH + HKDF-SHA256 + AES-256-GCM (compatible with Apple CryptoKit)
- Material 3 UI with onboarding, pairing, home screen

### Apple Watch Companion
- watchOS app for approving auth from your wrist
- WatchConnectivity relay through iPhone
- Approve/Deny UI with haptic feedback
- StatusView with auth count and connection status

### Wear OS Companion
- Wear OS app for Android Watch users
- Wearable Data Layer API for phone relay
- Compose for Wear OS UI with approve/deny chips

### Web Companion (`touchbridged serve --web`)
- Local HTTP server for browser-based auth (no app install needed)
- One-time tokens (32 bytes, 60s expiry)
- Dark-theme mobile UI with Approve/Deny buttons
- Works with ANY phone — iPhone, Android, or any browser

### Simulator Mode (`touchbridged serve --simulator`)
- Test the full sudo flow without any phone
- Auto-approve mode for testing and CI
- Interactive mode (`--interactive`) for terminal approve/deny
- Full crypto pipeline (nonce → sign → verify) with software keys

### Proximity Auto-Lock (`--auto-lock`)
- Lock Mac when companion device disconnects from BLE
- Configurable RSSI threshold and disconnect delay
- Inverse of "unlock" — lock when phone walks away

### PAM User Messages
- Terminal now shows feedback during authentication:
  - `TouchBridge: check your phone or watch...`
  - `TouchBridge: ✓ authenticated`
  - `TouchBridge: ✗ denied — falling through to password`
  - `TouchBridge: timed out — no response from phone`
  - `TouchBridge: daemon not running — falling through to password`

### Auth History & Analytics
- `touchbridge-test logs --summary` — dashboard with success rate, latency, breakdown
- `touchbridge-test logs --failures` — show only failed auth attempts
- `touchbridge-test logs --export csv` — export auth history for security review
- `AuthNotifier` — macOS notifications for auth success, failure, timeout, suspicious activity

### OpenClaw Integration
- TouchBridge skill for OpenClaw agents (SKILL.md + references)
- Published on ClawHub (clawhub.ai/hmakt99/touchbridge)
- SHA-256 checksum pinning, simulator guardrails

### Testing
- 75 unit tests (daemon)
- 16 protocol tests
- 38 E2E validation tests (complete user journey)
- **129 total tests**

### Documentation
- README rewritten for virality — problem/solution pitch, comparison tables
- Passkeys vs TouchBridge FAQ section
- MacBook Neo base version positioning
- Comprehensive installation guide (all 6 auth methods)
- GitHub Pages site
- Remotion promo video (30s, 6 scenes)
- CONTRIBUTING.md, issue templates, GitHub Actions CI

---

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

# Changelog

## [1.1.1] — 2026-07-16

### Fixed
- **sudo lockout on uninstall/upgrade** (#23): the Homebrew cask deleted the
  PAM module while leaving the `/etc/pam.d/sudo` reference, which made `sudo`
  unable to initialize PAM. Uninstall now restores the pam.d backup (or strips
  our line) before removing the module. Fixed the `depends_on macos:`
  deprecation warning.
- **BLE re-identify recovery on real devices** (#28, #29): restored
  CoreBluetooth connections are reconnected cleanly instead of reused with
  stale state; ECDH now starts only after service/characteristic readiness
  (replaces a fragile fixed delay); the daemon recovers a session when a
  session key arrives before the connect event. Pairing requests are sent from
  the same readiness gate. Thanks to @Souitou-iop for the fixes and the first
  real-iPhone verification.
- `ProximityMonitor` takes an injectable lock action so tests no longer sleep
  the developer's display.

### Security
- SECURITY.md documents the missing-module PAM availability failure mode and a
  recovery that works without sudo.

## [1.1.0] — 2026-07-04

### Pairing Security
- Pairing token from the QR payload is now **enforced end-to-end**: the daemon
  rejects any pairing request whose single-use token doesn't match the active
  5-minute pairing window (previously the token was generated but never validated)
- iOS app sends wire-format pair requests and reports "Paired" only after the
  Mac accepts; rejections show recovery instructions
- Paired devices are stored under their own device ID, fixing re-identify and
  challenge verification after reconnect

### QR Code Pairing
- `touchbridge-test pair` now renders the pairing payload as a QR code image
  and opens it automatically (deleted when pairing ends)
- iOS app: camera QR scanner as the primary pairing path; manual JSON entry
  remains as fallback

### Background Auth Notifications (iOS)
- Challenges arriving while the app is backgrounded now post a local
  notification; Face ID runs when the app is opened

### Daemon Hardening
- Shared session state is lock-protected (fixes data races under concurrent
  BLE callbacks)
- Pending-auth entries are cleaned up after each auth resolves; expired
  challenges and replay nonces are pruned every 60 seconds
- PAM socket timeout now exceeds the daemon auth window by 2s, so approvals
  landing at the deadline are no longer lost

### Distribution & Docs
- New `scripts/patch-pam.sh` — standalone PAM activation for Homebrew/pkg
  installs (docs previously pointed to a file that didn't exist)
- Release artifacts are versioned from the git tag
- Test suite: 127 Swift tests (111 daemon + 16 protocol) + 38-check e2e
  validation suite

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

# TouchBridge — Developer Guide

## Build

```bash
# Build daemon (macOS)
cd daemon && swift build

# Build protocol package
cd protocol && swift build

# Build PAM module (universal binary)
make -C pam
```

## Test

```bash
# Run all daemon tests
cd daemon && swift test

# Run specific test suite
cd daemon && swift test --filter ChallengeManager
cd daemon && swift test --filter Keychain
cd daemon && swift test --filter SocketServer
cd daemon && swift test --filter PolicyEngine
cd daemon && swift test --filter PAMIntegration
```

## Install / Uninstall

```bash
# Install (builds everything, patches PAM, installs LaunchAgent)
sudo bash scripts/install.sh

# Uninstall (restores PAM files, removes daemon)
sudo bash scripts/uninstall.sh
```

## E2E Test Flow

```bash
# 1. Install
sudo bash scripts/install.sh

# 2. Pair with iPhone
touchbridge-test pair

# 3. Open TouchBridge app on iPhone, enter pairing data

# 4. Test sudo
sudo echo 'TouchBridge works!'
# → Face ID prompt appears on iPhone
# → Approve → sudo succeeds
# → Deny/timeout → falls through to password
```

## Project Structure

- `daemon/` — Swift Package, macOS LaunchAgent daemon
  - `Sources/TouchBridgeCore/` — testable library (ChallengeManager, KeychainStore, BLE, SocketServer, etc.)
  - `Sources/touchbridged/` — daemon executable entry point
  - `Sources/touchbridge-test/` — CLI test harness
- `protocol/` — shared Swift Package (message types, wire format, constants)
- `companion/` — iOS/iPadOS companion app (SwiftUI)
  - `Core/` — CompanionCoordinator, BLEClient, SecureEnclaveManager, ChallengeHandler
  - `Views/` — PairingView, HomeView, AuthRequestView, SettingsView
- `pam/` — PAM module (C, universal binary arm64+x86_64)
- `scripts/` — install/uninstall scripts

## Key Rules

- Private keys NEVER leave Secure Enclave
- Never log nonce values — only session_id and result
- No hardcoded secrets, keys, UUIDs, or passwords in source
- Daemon runs as LaunchAgent (user-level), not root
- Ask before touching `/etc/pam.d/` — install script backs up and prompts

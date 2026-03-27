# TouchBridge — Installation Guide

Complete step-by-step guide for installing TouchBridge on your Mac and setting up a companion device.

---

## Table of Contents

- [Requirements](#requirements)
- [Step 1: Install on Mac](#step-1-install-on-mac)
- [Step 2: Choose Your Auth Method](#step-2-choose-your-auth-method)
  - [Option A: Simulator (no phone needed)](#option-a-simulator-mode-no-phone-needed)
  - [Option B: Web Companion (any phone, no app)](#option-b-web-companion-any-phone-no-app-install)
  - [Option C: iPhone](#option-c-iphone-face-id--touch-id)
  - [Option D: Android](#option-d-android-fingerprint--face)
  - [Option E: Apple Watch](#option-e-apple-watch)
  - [Option F: Wear OS](#option-f-wear-os-android-watch)
- [Step 3: Test](#step-3-test-it)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)

---

## Requirements

### Mac (required)

| Requirement | Details |
|------------|---------|
| **macOS** | 13.0 (Ventura) or later |
| **Chip** | Apple Silicon (M1/M2/M3/M4) or Intel with T2 |
| **Xcode Command Line Tools** | `xcode-select --install` if not already installed |
| **Disk space** | ~50 MB |

### Companion device (one of these)

| Device | Minimum version | What you get |
|--------|----------------|-------------|
| Any phone with a browser | Any | Tap to approve (web companion) |
| iPhone | iOS 16+ | Face ID / Touch ID |
| Android phone | Android 9+ (API 28) | Fingerprint / Face |
| Apple Watch | watchOS 9+ (via iPhone) | Tap to approve |
| Wear OS watch | Wear OS 3+ (via Android) | Tap to approve |
| None | — | Simulator mode for testing |

---

## Step 1: Install on Mac

### 1.1 Clone the repository

```bash
git clone https://github.com/HMAKT99/UnTouchID.git
cd UnTouchID
```

### 1.2 Build the daemon and PAM module

```bash
# Build the daemon (Swift)
cd daemon && swift build -c release && cd ..

# Build the PAM module (C, universal binary)
make -C pam
```

**Expected output:**
```
Build complete!
Built pam_touchbridge.so (universal binary)
```

If the build fails, check that Xcode Command Line Tools are installed:
```bash
xcode-select --install
```

### 1.3 Run the installer

```bash
sudo bash scripts/install.sh
```

The installer will:

1. **Check your macOS version** (must be 13.0+)
2. **Copy binaries:**
   - `touchbridged` → `/usr/local/bin/touchbridged`
   - `pam_touchbridge.so` → `/usr/local/lib/pam/pam_touchbridge.so`
3. **Create directories:**
   - `~/Library/Application Support/TouchBridge/`
   - `~/Library/Logs/TouchBridge/`
4. **Back up your PAM config:**
   - `/etc/pam.d/sudo` → `/etc/pam.d/sudo.touchbridge-backup`
5. **Show you the exact change** and ask for confirmation:
   ```
   --- Proposed change to /etc/pam.d/sudo ---
   Adding as first auth line:
     auth       sufficient     pam_touchbridge.so

   Apply this change? [y/N]
   ```
6. **Install the LaunchAgent** (auto-starts the daemon on login)

> **Important:** Type `y` to confirm the PAM change. If you type `n`, TouchBridge installs but won't activate for `sudo`. You can patch manually later.

### 1.4 Verify installation

```bash
# Check daemon is installed
which touchbridged
# → /usr/local/bin/touchbridged

# Check PAM module
file /usr/local/lib/pam/pam_touchbridge.so
# → Mach-O universal binary with 2 architectures: [x86_64] [arm64]

# Check PAM config was patched
head -3 /etc/pam.d/sudo
# → auth       sufficient     pam_touchbridge.so
# → auth       sufficient     pam_tid.so
# → ...

# Check daemon is running
launchctl print gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null && echo "Running" || echo "Not running"
```

---

## Step 2: Choose Your Auth Method

### Option A: Simulator Mode (no phone needed)

**Best for:** Quick testing, CI pipelines, trying TouchBridge before setting up a phone.

The simulator auto-approves all auth requests using software crypto keys. No phone or BLE required.

```bash
# Stop the normal daemon first
launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null

# Start in simulator mode
touchbridged serve --simulator
```

You should see:
```
touchbridged v0.1.0-dev (SIMULATOR MODE: auto-approve)

  No iPhone required. Auth requests will be handled locally.
  This mode is for testing only — not for production use.

  Socket: /Users/you/Library/Application Support/TouchBridge/daemon.sock
  Ready. Waiting for auth requests...
```

Now open **another terminal** and test:
```bash
sudo echo 'It works!'
# → No password prompt. Authenticated via simulator.
```

For interactive mode (approve/deny each request manually):
```bash
touchbridged serve --interactive
```

> **Note:** Simulator mode is for testing. For real security, use a phone or watch.

To go back to normal mode:
```bash
# Kill the simulator (Ctrl+C in its terminal)
# Restart normal daemon
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.touchbridge.daemon.plist
```

---

### Option B: Web Companion (any phone, no app install)

**Best for:** Quick setup, Android users without the app, guests, any device with a browser.

```bash
# Stop the normal daemon
launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null

# Start in web companion mode
touchbridged serve --web
```

You should see:
```
touchbridged v0.1.0-dev (WEB COMPANION MODE)

  No iPhone app required.
  Auth requests will show a URL — open it on any phone to approve.

  Socket: /Users/you/Library/Application Support/TouchBridge/daemon.sock
  Web:    http://localhost:7070
  Ready. Waiting for auth requests...
```

Now when you run `sudo` in another terminal:
```bash
sudo echo test
```

The daemon terminal shows:
```
  ╔══════════════════════════════════════════════════╗
  ║  TouchBridge — Web Authentication               ║
  ╠══════════════════════════════════════════════════╣
  ║                                                  ║
  ║  Open this URL on any phone:                     ║
  ║                                                  ║
  ║  http://192.168.1.42:7070/auth/a3f9b2c1...      ║
  ║                                                  ║
  ║  Request: sudo                                   ║
  ║  User:    you                                    ║
  ║                                                  ║
  ║  Expires in 60 seconds                           ║
  ╚══════════════════════════════════════════════════╝
```

1. Open that URL on **any phone** (iPhone, Android, anything with a browser)
2. You'll see a dark-themed page with **"Approve"** and **"Deny"** buttons
3. Tap **Approve** → sudo succeeds on Mac
4. The URL is one-time-use and expires in 60 seconds

> **Tip:** Both Mac and phone must be on the **same Wi-Fi network** for the URL to work.

---

### Option C: iPhone (Face ID / Touch ID)

**Best for:** Production use with maximum security (Secure Enclave signing).

#### C.1 Build the iOS app

Requires **Xcode 15+** installed on your Mac.

```bash
# Install XcodeGen (generates the Xcode project)
brew install xcodegen

# Generate and open the project
cd companion
xcodegen generate
open TouchBridge.xcodeproj
```

In Xcode:
1. Select the **TouchBridge** target
2. Go to **Signing & Capabilities**
3. Set your **Team** (your Apple Developer account — free tier works)
4. Connect your iPhone via USB cable
5. Select your iPhone as the run destination
6. Click **Run** (Cmd+R)

The app will install on your iPhone.

#### C.2 Pair with your Mac

On your Mac:
```bash
touchbridge-test pair
```

This shows pairing JSON in the terminal:
```json
{"version":1,"serviceUUID":"B5E6D1A4-...","pairingToken":"...","macName":"Mac Mini"}
```

On your iPhone:
1. Open the **TouchBridge** app
2. Tap **"Get Started"**
3. Tap **"Enter Pairing Data"**
4. Paste the JSON from your Mac's terminal
5. Tap **"Pair"**

Both devices should confirm pairing is complete.

#### C.3 Start the daemon in normal mode

```bash
# Restart the daemon (it auto-starts on login, but restart to pick up pairing)
launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.touchbridge.daemon.plist
```

#### C.4 Test

```bash
sudo echo 'Face ID works!'
```

Your iPhone should show a **Face ID prompt** with the reason ("sudo"). Authenticate → sudo succeeds.

---

### Option D: Android (Fingerprint / Face)

**Best for:** Android users who want biometric-grade security (Keystore/StrongBox signing).

#### D.1 Build the Android app

Requires **Android Studio** installed.

1. Open Android Studio
2. **File → Open** → select `companion-android/`
3. Wait for Gradle sync to complete
4. Connect your Android phone via USB (enable Developer Mode + USB Debugging)
5. Click **Run** (green play button)

#### D.2 Pair with your Mac

Same as iPhone pairing:

On Mac:
```bash
touchbridge-test pair
```

On Android:
1. Open **TouchBridge** app
2. Tap **"Get Started"**
3. Paste the pairing JSON
4. Tap **"Pair"**

#### D.3 Test

```bash
sudo echo 'Fingerprint works!'
```

Your Android phone shows a **fingerprint prompt**. Authenticate → sudo succeeds.

---

### Option E: Apple Watch

**Best for:** Approving auth from your wrist without pulling out your phone.

> **Prerequisite:** iPhone must be set up first (Option C). The Watch relays through the iPhone.

#### E.1 Build the watchOS app

In Xcode (with the TouchBridge project already open):
1. Select the **TouchBridgeWatch** scheme
2. Select your Apple Watch as the run destination (it appears when paired with your iPhone)
3. Click **Run**

#### E.2 Use it

When you run `sudo`, your Apple Watch will:
1. Vibrate (haptic notification)
2. Show: **"Auth Request — sudo — Mac Mini"**
3. Display **Approve** and **Deny** buttons
4. Tap **Approve** → iPhone signs the challenge → sudo succeeds

> **Note:** The Watch doesn't do cryptography. It's an approval UI. Your iPhone's Secure Enclave handles all signing.

---

### Option F: Wear OS (Android Watch)

**Best for:** Android ecosystem users who want wrist approval.

> **Prerequisite:** Android phone must be set up first (Option D).

#### F.1 Build the Wear OS app

In Android Studio:
1. **File → Open** → select `companion-android/`
2. Select the **:wear** module configuration
3. Connect your Wear OS watch or select a Watch emulator
4. Click **Run**

#### F.2 Use it

Same as Apple Watch — vibrate, show request, tap Approve.

---

## Step 3: Test It

### Basic test

```bash
sudo echo 'TouchBridge works!'
```

### Test with a specific device

```bash
# List paired devices
touchbridge-test list-devices

# View recent auth events
touchbridge-test logs

# View filtered logs
touchbridge-test logs --surface pam_sudo --result VERIFIED
```

### Test fallback (phone unreachable)

1. Turn off Bluetooth on your phone (or move out of range)
2. Run `sudo echo test`
3. TouchBridge times out after 15 seconds → **falls through to password prompt**
4. Type your password → sudo succeeds as normal

This confirms the safety fallback works. You're never locked out.

---

## Configuration

### View current settings

```bash
touchbridge-test config show
```

Output:
```
TouchBridge Policy Configuration
  Auth timeout: 15.0s
  RSSI threshold: -75 dBm

Surface Policies:
  app_store: biometric required
  browser_autofill: proximity session (10 min)
  screensaver: proximity session (30 min)
  sudo: biometric required
  system_settings: biometric required
```

### Change settings

```bash
# Change auth timeout (how long to wait for phone response)
touchbridge-test config set --timeout 20

# Make screensaver require biometric every time (instead of proximity session)
touchbridge-test config set --surface screensaver --mode biometric_required

# Make sudo use proximity session (less secure, more convenient)
touchbridge-test config set --surface sudo --mode proximity_session --ttl 5

# Reset everything to defaults
touchbridge-test config reset
```

### Enable auto-lock

Lock your Mac when your phone walks away:

```bash
touchbridged serve --auto-lock
```

When your phone disconnects from BLE (out of range for 30 seconds), the Mac screen locks automatically.

---

## Troubleshooting

### "sudo still asks for password"

1. Check the daemon is running:
   ```bash
   launchctl print gui/$(id -u)/dev.touchbridge.daemon
   ```

2. Check the socket exists:
   ```bash
   ls -la ~/Library/Application\ Support/TouchBridge/daemon.sock
   ```

3. Check PAM config:
   ```bash
   head -3 /etc/pam.d/sudo
   # Should show: auth sufficient pam_touchbridge.so
   ```

4. Check logs:
   ```bash
   touchbridge-test logs --count 5
   ```

### "Daemon socket not found"

The daemon may not be running. Start it manually:
```bash
touchbridged serve --simulator  # for testing
# or
touchbridged serve              # for production (needs paired device)
```

### "PAM module not loading"

Verify the module exists and is the right architecture:
```bash
file /usr/local/lib/pam/pam_touchbridge.so
# Should show: Mach-O universal binary with 2 architectures: [x86_64] [arm64]
```

If missing, rebuild and reinstall:
```bash
make -C pam
sudo cp pam/pam_touchbridge.so /usr/local/lib/pam/
```

### "iPhone not connecting via BLE"

1. Ensure Bluetooth is enabled on both Mac and iPhone
2. Ensure the TouchBridge app is open on your iPhone (or running in background)
3. Check the iPhone is within ~5 meters of the Mac
4. Try re-pairing: `touchbridge-test pair`

### "Web companion URL not accessible from phone"

1. Ensure both Mac and phone are on the **same Wi-Fi network**
2. Check if a firewall is blocking port 7070:
   ```bash
   # Test locally first
   curl http://localhost:7070/
   ```
3. Try a different port:
   ```bash
   touchbridged serve --web --web-port 8080
   ```

### "macOS update broke sudo"

macOS updates sometimes reset `/etc/pam.d/sudo`. Re-run the installer:
```bash
sudo bash scripts/install.sh
```

It's idempotent — safe to run again.

---

## Uninstall

```bash
sudo bash scripts/uninstall.sh
```

This will:
1. Stop the daemon and remove the LaunchAgent
2. Restore `/etc/pam.d/sudo` from the backup
3. Restore `/etc/pam.d/screensaver` from the backup
4. Remove `/usr/local/bin/touchbridged`
5. Remove `/usr/local/lib/pam/pam_touchbridge.so`

Your Mac returns to normal password-only authentication.

> **Note:** User data at `~/Library/Application Support/TouchBridge/` and logs at `~/Library/Logs/TouchBridge/` are preserved. Delete manually if desired.

---

## What's Next

After installation, you might want to:

- **View the audit log:** `touchbridge-test logs`
- **Customize policies:** `touchbridge-test config set --surface sudo --mode proximity_session --ttl 10`
- **Enable auto-lock:** `touchbridged serve --auto-lock`
- **Pair additional devices:** `touchbridge-test pair` (run again for each device)

---

*For security details, see [SECURITY.md](../SECURITY.md). For architecture, see [architecture.md](architecture.md). For limitations, see [limitations.md](limitations.md).*

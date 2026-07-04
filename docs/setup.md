# TouchBridge — Installation Guide

Use your phone's fingerprint or face to authenticate on your Mac. No extra hardware required.

---

## Table of Contents

- [Requirements](#requirements)
- [Install TouchBridge](#install-touchbridge)
  - [Option 1: Homebrew (recommended)](#option-1-homebrew-recommended)
  - [Option 2: Build from source](#option-2-build-from-source)
- [Set Up Your Companion Device](#set-up-your-companion-device)
  - [iPhone (Face ID / Touch ID)](#iphone-face-id--touch-id)
  - [Android (Fingerprint / Face)](#android-fingerprint--face)
  - [Apple Watch](#apple-watch)
  - [Wear OS](#wear-os-android-watch)
  - [Any phone browser (no app)](#any-phone-browser-no-app-install)
  - [No phone — simulator mode](#no-phone--simulator-mode)
- [Test It Works](#test-it-works)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)

---

## Requirements

**Mac:**

| Requirement | Details |
|------------|---------|
| macOS | 13.0 (Ventura) or later |
| Chip | Apple Silicon (M1/M2/M3/M4) or Intel with T2 |
| Homebrew | Install at [brew.sh](https://brew.sh) if not already installed |

**Companion device** — one of these:

| Device | What you get |
|--------|-------------|
| iPhone (iOS 16+) | Face ID / Touch ID via BLE — most secure |
| Android (Android 9+) | Fingerprint / Face via BLE — most secure |
| Apple Watch (watchOS 9+) | Tap to approve on your wrist |
| Wear OS watch (Wear OS 3+) | Tap to approve on your wrist |
| Any phone with a browser | One-tap web approval — no app install |
| No device | Simulator mode for testing |

---

## Install TouchBridge

### Option 1: Homebrew (recommended)

No Xcode or build tools required. One command installs everything.

```bash
brew tap HMAKT99/touchbridge
brew install --cask touchbridge
```

This installs:
- `touchbridged` — the daemon that runs in the background
- `touchbridge-test` — CLI for pairing, logs, and config
- `pam_touchbridge.so` — the PAM module that hooks into `sudo`
- The LaunchAgent that auto-starts the daemon at login

**After installation, patch sudo:**

The installer places the binaries but you need to activate the PAM hook. Run once:

```bash
sudo bash /usr/local/share/touchbridge/patch-pam.sh
```

If that file doesn't exist (installs from v1.0.0 or earlier), fetch it from the repo first:

```bash
curl -fsSLO https://raw.githubusercontent.com/HMAKT99/UnTouchID/main/scripts/patch-pam.sh
sudo bash patch-pam.sh
```

This shows you exactly what will change and asks for confirmation before touching any PAM file.

---

### Option 2: Build from source

Use this if you want to inspect or modify the code.

**Prerequisites:**

```bash
# Install Xcode Command Line Tools (if not already installed)
xcode-select --install
```

**Build and install:**

```bash
git clone https://github.com/HMAKT99/UnTouchID.git
cd UnTouchID

# Build daemon and PAM module
cd daemon && swift build -c release && cd ..
make -C pam

# Install everything (requires sudo for PAM and /usr/local)
sudo bash scripts/install.sh
```

The installer will:
1. Check your macOS version
2. Copy binaries to `/usr/local/bin/` and `/usr/local/lib/pam/`
3. Create `~/Library/Application Support/TouchBridge/` and `~/Library/Logs/TouchBridge/`
4. Show you the proposed PAM change and ask for confirmation before applying it
5. Install the LaunchAgent so the daemon starts automatically at login

**Verify the installation:**

```bash
# Daemon is installed
which touchbridged
# → /usr/local/bin/touchbridged

# PAM module is a universal binary (arm64 + x86_64)
file /usr/local/lib/pam/pam_touchbridge.so
# → Mach-O universal binary with 2 architectures: [x86_64] [arm64]

# PAM is patched
head -3 /etc/pam.d/sudo
# → auth       sufficient     pam_touchbridge.so

# Daemon is running
launchctl print gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null && echo "Running" || echo "Not running"
```

---

## Set Up Your Companion Device

Pick the device you want to use for authentication.

---

### iPhone (Face ID / Touch ID)

**Best for:** Maximum security. Uses encrypted BLE + Secure Enclave. Private key never leaves your iPhone.

#### Step 1 — Build the iOS app

You need **Xcode 15+** on your Mac.

```bash
brew install xcodegen       # if not already installed
cd companion
xcodegen generate
open TouchBridge.xcodeproj
```

In Xcode:
1. Select the **TouchBridge** scheme
2. Go to **Signing & Capabilities** → set your **Team** (free Apple ID works)
3. Connect your iPhone via USB
4. Select your iPhone as the destination
5. Press **Cmd+R** to build and install

#### Step 2 — Pair your iPhone with your Mac

On your Mac:
```bash
touchbridge-test pair
```

This opens a QR code on your Mac and also prints the pairing JSON, for example:
```
{"version":1,"serviceUUID":"B5E6D1A4-...","pairingToken":"...","macName":"Mac Mini"}
```

On your iPhone:
1. Open the **TouchBridge** app
2. Tap **Get Started**
3. Tap **Scan QR Code** and point the camera at the QR on your Mac
   (or tap **Enter Pairing Data** and paste the JSON manually)

The pairing token in the QR is single-use and expires after 5 minutes — the Mac
rejects any pairing attempt without a matching token. Both sides confirm pairing
is complete.

#### Step 3 — Restart the daemon

```bash
launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null; \
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.touchbridge.daemon.plist
```

#### Step 4 — Test

```bash
sudo echo 'Face ID works!'
```

Your iPhone shows a Face ID prompt labeled with the reason ("sudo"). Authenticate → `sudo` succeeds.

---

### Android (Fingerprint / Face)

**Best for:** Android users who want biometric-grade security (Keystore/StrongBox). No cloud involved.

#### Step 1 — Build the Android app

You need **Android Studio** installed.

1. Open Android Studio → **File → Open** → select `companion-android/`
2. Wait for Gradle sync
3. Enable Developer Mode on your phone and connect via USB
4. Click **Run**

#### Step 2 — Pair

On your Mac:
```bash
touchbridge-test pair
```

On your Android phone:
1. Open **TouchBridge**
2. Tap **Get Started** → **Enter Pairing Data**
3. Paste the JSON
4. Tap **Pair**

#### Step 3 — Test

```bash
sudo echo 'Fingerprint works!'
```

Your phone shows a fingerprint prompt. Authenticate → `sudo` succeeds.

---

### Apple Watch

**Best for:** Approving `sudo` from your wrist without touching your phone.

> Requires iPhone to be set up first. The Watch is an approval UI — your iPhone's Secure Enclave handles all cryptography.

#### Step 1 — Build the watchOS app

In Xcode (with `TouchBridge.xcodeproj` open):
1. Select the **TouchBridgeWatch** scheme
2. Select your Apple Watch as the destination (appears when paired with your iPhone)
3. Press **Cmd+R**

#### Step 2 — Use it

When you run `sudo`, your Watch:
1. Vibrates
2. Shows: **Auth Request — sudo — Mac Mini**
3. Displays **Approve** and **Deny** buttons

Tap **Approve** → iPhone signs the challenge → `sudo` succeeds.

---

### Wear OS (Android Watch)

**Best for:** Android users who want wrist-level approval.

> Requires Android phone to be set up first.

#### Step 1 — Build

In Android Studio:
1. Open `companion-android/`
2. Switch to the **:wear** module configuration
3. Connect your Wear OS watch (or use an emulator)
4. Click **Run**

#### Step 2 — Use it

Same as Apple Watch — vibrate, show request, tap Approve.

---

### Any Phone Browser (no app install)

**Best for:** Quick setup, guests, or any phone with a browser. No app required.

> Uses HTTP on your local network. For trusted networks only. Not recommended on public Wi-Fi.

```bash
# Stop the normal daemon first
launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null

# Start in web companion mode
touchbridged serve --web
```

When you run `sudo echo test` in another terminal, the daemon prints:

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

Open the URL on any phone → tap **Approve** → `sudo` succeeds.

Both Mac and phone must be on the **same Wi-Fi network**.

---

### No Phone — Simulator Mode

**Best for:** Testing the full flow without any device, CI pipelines, or demos.

Auto-approves all auth requests using software keys.

```bash
# Stop the normal daemon
launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null

# Start simulator
touchbridged serve --simulator
```

In another terminal:
```bash
sudo echo 'It works!'
# → Authenticated immediately (no phone needed)
```

For interactive mode where you manually approve each request:
```bash
touchbridged serve --interactive
```

To return to normal mode:
```bash
# Press Ctrl+C in the simulator terminal, then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.touchbridge.daemon.plist
```

---

## Test It Works

### Basic test

```bash
sudo echo 'TouchBridge works!'
```

### Check which devices are paired

```bash
touchbridge-test list-devices
```

### View the auth log

```bash
touchbridge-test logs            # recent events
touchbridge-test logs --summary  # analytics dashboard
touchbridge-test logs --failures # failed attempts only
```

### Test the fallback (phone unreachable)

1. Turn off Bluetooth on your phone or move out of range
2. Run `sudo echo test`
3. TouchBridge waits 15 seconds → falls through to the normal password prompt
4. Type your password as usual

You are never locked out. If your phone is unavailable, `sudo` falls back to password authentication automatically.

---

## Configuration

### View current settings

```bash
touchbridge-test config show
```

Example output:
```
TouchBridge Policy Configuration
  Auth timeout:    15.0s
  RSSI threshold:  -75 dBm

Surface Policies:
  sudo:             biometric required
  screensaver:      proximity session (30 min)
  app_store:        biometric required
  system_settings:  biometric required
  browser_autofill: proximity session (10 min)
```

### Change settings

```bash
# Change how long to wait for phone response (default: 15s)
touchbridge-test config set --timeout 20

# Require biometric every time for screensaver (more secure)
touchbridge-test config set --surface screensaver --mode biometric_required

# Use proximity session for sudo — no Face ID prompt if phone is nearby
touchbridge-test config set --surface sudo --mode proximity_session --ttl 10

# Reset all settings to defaults
touchbridge-test config reset
```

### Auto-lock when phone walks away

Lock your Mac automatically when your phone goes out of BLE range:

```bash
touchbridged serve --auto-lock
```

If your phone disconnects for 30 seconds, the screen locks. Walk back in range — everything resumes.

To make this permanent, edit `~/Library/LaunchAgents/dev.touchbridge.daemon.plist` and add `--auto-lock` to the `ProgramArguments` array.

---

## Troubleshooting

### `sudo` still asks for password

**1. Check the daemon is running:**
```bash
launchctl print gui/$(id -u)/dev.touchbridge.daemon
```
If it says "service not found", restart it:
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.touchbridge.daemon.plist
```

**2. Check the daemon socket exists:**
```bash
ls -la ~/Library/Application\ Support/TouchBridge/daemon.sock
```
If missing, the daemon may have crashed. Check the log:
```bash
tail -20 ~/Library/Logs/TouchBridge/daemon.stderr.log
```

**3. Check PAM is patched:**
```bash
head -3 /etc/pam.d/sudo
```
The first line should be:
```
auth       sufficient     pam_touchbridge.so
```
If it isn't, re-run the installer: `sudo bash scripts/install.sh`

**4. Check recent auth events:**
```bash
touchbridge-test logs --count 5
```

---

### "Daemon socket not found"

Start the daemon manually to see any errors:
```bash
touchbridged serve --simulator
```
Then check the output.

---

### "PAM module not loading"

Verify the module exists and is a universal binary:
```bash
file /usr/local/lib/pam/pam_touchbridge.so
# Expected: Mach-O universal binary with 2 architectures: [x86_64] [arm64]
```

If it's missing or wrong architecture, rebuild:
```bash
make -C pam
sudo cp pam/pam_touchbridge.so /usr/local/lib/pam/
sudo chmod 444 /usr/local/lib/pam/pam_touchbridge.so
```

---

### iPhone not connecting via BLE

1. Bluetooth must be enabled on both Mac and iPhone
2. Keep the TouchBridge app open on your iPhone (or ensure Background App Refresh is on)
3. Stay within ~5 metres of your Mac
4. If connection is stale, re-pair: `touchbridge-test pair`

---

### Web companion URL not reachable from phone

1. Mac and phone must be on the **same Wi-Fi network**
2. Test locally first: `curl http://localhost:7070/`
3. If blocked by a firewall, try a different port:
   ```bash
   touchbridged serve --web --web-port 8080
   ```

---

### macOS update broke `sudo`

macOS updates sometimes reset `/etc/pam.d/sudo`. Re-run the installer — it's safe to run again:
```bash
sudo bash scripts/install.sh
```

---

## Uninstall

```bash
sudo bash scripts/uninstall.sh
```

This:
1. Stops the daemon and removes the LaunchAgent
2. Restores `/etc/pam.d/sudo` and `/etc/pam.d/screensaver` from backups
3. Removes `/usr/local/bin/touchbridged` and the PAM module

Your Mac returns to normal password-only authentication immediately.

> User data in `~/Library/Application Support/TouchBridge/` and logs in `~/Library/Logs/TouchBridge/` are kept. Delete them manually if you want a clean removal:
> ```bash
> rm -rf ~/Library/Application\ Support/TouchBridge/
> rm -rf ~/Library/Logs/TouchBridge/
> ```

---

*Security model: [SECURITY.md](../SECURITY.md) · Architecture: [architecture.md](architecture.md) · Limitations: [limitations.md](limitations.md)*

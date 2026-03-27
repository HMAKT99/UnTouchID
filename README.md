<p align="center">
  <h1 align="center">🔐 TouchBridge</h1>
  <p align="center">
    <a href="https://github.com/HMAKT99/UnTouchID/stargazers"><img src="https://img.shields.io/github/stars/HMAKT99/UnTouchID?style=flat-square&color=30d158" alt="Stars"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
    <a href="https://github.com/HMAKT99/UnTouchID/releases"><img src="https://img.shields.io/github/v/release/HMAKT99/UnTouchID?style=flat-square&color=ff9500" alt="Release"></a>
    <img src="https://img.shields.io/badge/tests-91%20passing-30d158?style=flat-square" alt="Tests">
    <img src="https://img.shields.io/badge/macOS-13%2B-000?style=flat-square&logo=apple" alt="macOS 13+">
  </p>
  <p align="center">
    <strong>Use your phone's fingerprint to authenticate on any Mac.</strong><br>
    sudo, screensaver, App Store — no $199 Magic Keyboard required.
  </p>
  <p align="center">
    Works with <strong>iPhone · Android · Apple Watch · Wear OS · Any browser</strong>
  </p>
  <p align="center">
    <a href="#try-it-in-60-seconds">Try it in 60 seconds</a> •
    <a href="#how-it-works">How It Works</a> •
    <a href="#every-device-supported">Devices</a> •
    <a href="SECURITY.md">Security</a>
  </p>
</p>

<p align="center">
  <a href="https://github.com/HMAKT99/UnTouchID/releases/tag/v0.1.0-alpha">
    <img src="assets/touchbridge-preview.gif" alt="TouchBridge Demo" width="700">
  </a>
  <br>
  <sub><a href="https://github.com/HMAKT99/UnTouchID/releases/tag/v0.1.0-alpha">▶ Watch full video (30s)</a></sub>
</p>

---

### The Problem

Apple keeps shipping Macs without Touch ID.

**Mac Mini, Mac Studio, Mac Pro** — no fingerprint sensor. The new **MacBook Neo** (ultra-thin) — rumored to drop Touch ID for thinness. Even some **iMacs** ship without a Touch ID keyboard.

Every time you run `sudo`, install software, or unlock your screen — you type your password. Again. And again.

Apple's solution? Buy a [Magic Keyboard with Touch ID for $199](https://www.apple.com/shop/product/MK293LL/A). It only works wired. And if you're at a coffee shop with your MacBook Neo? Too bad.

### The Solution

**TouchBridge uses your phone's fingerprint or face to authenticate on your Mac.** Free. Open source. Works in 60 seconds. No extra hardware to buy or carry.

```
$ sudo echo hello
  → Phone buzzes
  → Touch fingerprint (or tap Watch, or tap browser)
  → ✓ Authenticated
```

---

## Try It in 60 Seconds

No phone needed. Test the full `sudo` flow right now:

```bash
# Clone and build
git clone https://github.com/HMAKT99/UnTouchID.git
cd UnTouchID
cd daemon && swift build -c release && cd ..
make -C pam
sudo bash scripts/install.sh
```

```bash
# Terminal 1 — start daemon in simulator mode
touchbridged serve --simulator

# Terminal 2 — test sudo
sudo echo 'It works!'
# → No password. Authenticated via TouchBridge.
```

**That's it.** Undo anytime with `sudo bash scripts/uninstall.sh`.

---

## Every Device Supported

| Device | How | Auth Method | App Required? |
|--------|-----|-------------|--------------|
| **iPhone** | BLE → Face ID / Touch ID | Secure Enclave signing | iOS app |
| **Android phone** | BLE → Fingerprint / Face | Keystore (StrongBox/TEE) | Android app |
| **Apple Watch** | iPhone relay → Tap to approve | iPhone Secure Enclave | watchOS app |
| **Wear OS watch** | Phone relay → Tap to approve | Phone Keystore | Wear OS app |
| **Any phone/laptop** | Open URL → Tap Approve | One-time token | **No — just a browser** |
| **No device** | Simulator → Auto-approve | Software keys | **No** |

### Use with your phone

**Option A — Any phone, no app install:**
```bash
touchbridged serve --web
sudo echo test
# → Terminal shows a URL → open on any phone → tap Approve
```

**Option B — iPhone (Face ID):**
```
Open companion/TouchBridge.xcodeproj in Xcode → Build → Run on iPhone → Pair
```

**Option C — Android (Fingerprint):**
```
Open companion-android/ in Android Studio → Build → Install → Pair
```

**Option D — Apple Watch (Tap):**
```
Build the watchOS target from companion/TouchBridge.xcodeproj
Challenges relay from iPhone → Watch → tap Approve
```

**Option E — Wear OS (Tap):**
```
Open companion-android/wear/ in Android Studio → Build → Install on watch
Challenges relay from Android phone → Watch → tap Approve
```

---

## How It Works

```
┌──────────────┐         BLE / Wi-Fi         ┌──────────────┐
│              │  ──── challenge (nonce) ───→ │              │
│   Your Mac   │                              │  Your Phone  │
│              │  ←── signed response ──────  │  or Watch    │
│  (daemon)    │                              │  or Browser  │
│              │     ECDSA P-256 signature    │              │
└──────────────┘     verified on Mac          └──────────────┘
       ↑
       │ Unix socket
┌──────────────┐
│  sudo / PAM  │
└──────────────┘
```

1. You run `sudo` → PAM loads `pam_touchbridge.so`
2. PAM module connects to daemon via Unix socket
3. Daemon sends 32-byte random nonce to your device
4. Device prompts biometric (Face ID / fingerprint / tap)
5. Device's secure hardware signs the nonce (private key never leaves chip)
6. Daemon verifies signature → `sudo` proceeds
7. If device is unreachable → **falls through to normal password prompt**

---

## What Can It Do?

| Action | Status | Notes |
|--------|--------|-------|
| **`sudo` commands** | ✅ Verified | PAM module — tested on real hardware |
| **Screensaver unlock** | ✅ Ready | PAM module |
| **App Store purchases** | 🔧 Planned | Authorization Plugin (code written) |
| **System Settings auth** | 🔧 Planned | Authorization Plugin |
| **WebAuthn / Passkeys** | ✅ Ready | Browser extension |
| **Lock when phone walks away** | ✅ Ready | `--auto-lock` flag |
| **Audit log** | ✅ Ready | `touchbridge-test logs` |
| **Per-action policy** | ✅ Ready | `touchbridge-test config` |

### What it cannot do (honestly)

| Limitation | Why |
|-----------|-----|
| Apple Pay | Dedicated hardware — impossible |
| FileVault unlock | Before macOS boots — no daemon |
| Login screen | Daemon starts after login |
| Keychain biometric items | Hardware crypto wall — impossible |
| 1Password/Bitwarden biometric | SIP sandbox — can't intercept |

---

## Compared to Alternatives

| | TouchBridge | Magic Keyboard | Apple Watch | YubiKey Bio | Duo Security |
|---|---|---|---|---|---|
| **Price** | **Free** | $199-$299 | $249+ | $80+ | $3-9/user/mo |
| **sudo** | ✅ | ✅ | ❌ | ✅ | ✅ |
| **Biometric** | ✅ Face ID/FP | ✅ Fingerprint | ❌ Wrist only | ✅ Fingerprint | ❌ Tap only |
| **Wireless** | ✅ BLE | ❌ Wired only | ✅ | ❌ USB | ✅ Cloud |
| **Works at coffee shop** | ✅ | ❌ | Sleep only | ✅ | ✅ |
| **Android support** | ✅ | ❌ | ❌ | ❌ | ✅ |
| **No extra hardware** | ✅ Use your phone | ❌ $199 keyboard | ❌ $249 watch | ❌ $80 key | ✅ |
| **No cloud/internet** | ✅ Local BLE | ✅ | ✅ | ✅ | ❌ Cloud required |
| **Open source** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Auto-lock on walk away** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Audit log** | ✅ | ❌ | ❌ | ❌ | ✅ |

**For MacBook Neo users**: Magic Keyboard is not portable. YubiKey is another thing to carry. Apple Watch can't do sudo. Duo needs internet. **TouchBridge uses the phone already in your pocket.**

---

## All Daemon Modes

| Mode | Command | Use case |
|------|---------|----------|
| **Production** | `touchbridged serve` | iPhone/Android via BLE |
| **Web** | `touchbridged serve --web` | Any phone via browser |
| **Simulator** | `touchbridged serve --simulator` | Testing, CI, demos |
| **Interactive** | `touchbridged serve --interactive` | Terminal approve/deny |
| **Auto-lock** | `touchbridged serve --auto-lock` | Lock when phone leaves |

Flags can be combined: `touchbridged serve --web --auto-lock`

---

## Configuration

```bash
touchbridge-test config show                          # view policy
touchbridge-test config set --surface sudo --mode biometric_required
touchbridge-test config set --surface screensaver --mode proximity_session --ttl 30
touchbridge-test config reset                         # restore defaults
touchbridge-test logs                                 # recent auth events
touchbridge-test logs --surface pam_sudo --count 50   # filtered
touchbridge-test logs --json                          # raw NDJSON
```

---

## Supported Macs

Any Mac running **macOS 13+** (Ventura or later):

| Mac | Why you need TouchBridge |
|-----|------------------------|
| **MacBook Neo** (ultra-thin) | No Touch ID — too thin for the sensor |
| **Mac Mini** M1/M2/M3/M4 | No Touch ID — desktop, no keyboard sensor |
| **Mac Studio** M1/M2/M4 | No Touch ID — pro desktop |
| **Mac Pro** M2/M4 Ultra | No Touch ID — workstation |
| **iMac** (base keyboard) | No Touch ID unless you buy the $199 keyboard |
| **Any MacBook** with broken sensor | Sensor failure — repair costs $300+ |
| **Intel Macs with T2** (2018-2020) | Works with Secure Enclave on Mac side |

### The MacBook Neo story

Apple's upcoming ultra-thin MacBook is rumored to drop Touch ID to achieve its form factor. When it ships, millions of MacBook users will lose biometric auth for the first time.

They can't carry a Magic Keyboard to a coffee shop. Apple Watch only handles sleep/wake. **TouchBridge is the answer** — your phone is already in your pocket.

---

## Security

Private keys **never leave** Secure Enclave (iPhone) / StrongBox (Android). 32-byte nonces, 10s expiry, replay protection, AES-256-GCM encrypted BLE. Full threat model: [SECURITY.md](SECURITY.md)

## Architecture

| Component | Language |
|-----------|----------|
| `touchbridged` | Swift |
| `pam_touchbridge.so` | C (arm64 + x86_64) |
| iOS + watchOS app | Swift / SwiftUI |
| Android + Wear OS app | Kotlin / Compose |
| Web companion | Built into daemon |
| `touchbridge-test` | Swift CLI |

**91 tests** — crypto, socket server, PAM integration, E2E pipeline.

## Uninstall

```bash
sudo bash scripts/uninstall.sh
```

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) — PRs welcome.

## License

[MIT](LICENSE)

---

---

## Why TouchBridge Exists

Apple ships Macs without Touch ID and charges $199 for the fix. The Apple Watch can only unlock from sleep. Duo requires cloud servers and enterprise pricing. YubiKey Bio costs $80 and is another thing to lose.

**TouchBridge is the missing piece**: use the biometric sensor you already carry — your phone — to authenticate on your Mac. Local, private, free, open source.

When the MacBook Neo ships without Touch ID, this is what people will need.

<p align="center">
  <strong>Stop typing your password. Use your fingerprint.</strong><br>
  <a href="#try-it-in-60-seconds">Get started in 60 seconds →</a>
</p>

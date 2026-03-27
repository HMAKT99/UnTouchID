# TouchBridge — Viral Launch Plan

## Status
- [x] Repo is PUBLIC
- [x] Discussions enabled
- [x] Demo GIF in README
- [x] v0.1.0-alpha release with video
- [x] 13 GitHub topics
- [ ] Post on Hacker News
- [ ] Post on Reddit (5 subreddits)
- [ ] Post on Twitter/X
- [ ] Submit to Product Hunt
- [ ] Submit to awesome-macos lists
- [ ] Post on Dev.to / Hashnode

---

## 1. Hacker News (MOST IMPORTANT)

### Title (pick one)
> **Show HN: TouchBridge – Use your phone's fingerprint instead of Apple's $199 keyboard**

> **Show HN: I built a free alternative to Apple's $199 Touch ID keyboard for Mac Mini**

### URL
```
https://github.com/HMAKT99/UnTouchID
```

### Comment to post immediately after:
```
Hey HN, I built TouchBridge because I was tired of typing my password 50 times a day on my Mac Mini.

Apple's answer is a $199 Magic Keyboard with Touch ID. That felt wrong — my iPhone already has Face ID, why can't I just use that?

So I built it:
- sudo → phone buzzes → touch fingerprint → authenticated
- Works with iPhone, Android, Apple Watch, Wear OS, or any browser
- No cloud, no servers — local BLE only
- ECDSA P-256, ECDH session keys, 32-byte nonces, replay protection
- Free, MIT license, 91 tests

The PAM module (C, universal binary) talks to a Swift daemon via Unix socket.
The daemon sends a challenge nonce over BLE. Your phone's Secure Enclave signs it.
Daemon verifies. sudo proceeds.

If your phone is unreachable, it falls through to password — you're never locked out.

Try it in 60 seconds (no phone needed):
  touchbridged serve --simulator
  sudo echo test

I'm especially interested in feedback on the BLE reliability and the security model.

Code: https://github.com/HMAKT99/UnTouchID
```

### Best posting time
- Tuesday/Wednesday 8-9am ET (best HN engagement)
- Avoid weekends and Monday mornings

---

## 2. Reddit Posts

### r/macmini (~120k members)
**Title:** "I made a free tool to use your phone's fingerprint for sudo on Mac Mini — no $199 keyboard needed"
```
My Mac Mini doesn't have Touch ID. Apple's answer is a $199 Magic Keyboard.

I built TouchBridge instead — it uses your phone's fingerprint/Face ID to authenticate sudo, unlock screensaver, etc. Works with iPhone, Android, or any phone with a browser.

Free, open source: https://github.com/HMAKT99/UnTouchID

You can try it in 60 seconds without even connecting a phone:
touchbridged serve --simulator && sudo echo test
```

### r/MacOS (~400k members)
**Title:** "TouchBridge: Use Face ID on your iPhone to authenticate sudo on any Mac without Touch ID"

### r/mac (~1M members)
**Title:** "Open source alternative to Apple's $199 Touch ID keyboard — use your phone's fingerprint instead"

### r/programming (~5M members)
**Title:** "I built a PAM module that delegates macOS auth to a phone's Secure Enclave over BLE [open source]"

### r/opensource (~250k members)
**Title:** "TouchBridge — authenticate on your Mac using your phone's biometrics (free, MIT, 91 tests)"

### Reddit tips
- Post to r/macmini first (most targeted)
- Wait 2-3 hours, then cross-post to r/MacOS
- r/programming the next day (different audience)
- Engage with every comment
- Never be defensive about limitations — own them

---

## 3. Twitter/X Thread

```
🔐 I built TouchBridge — use your phone's fingerprint to authenticate on any Mac.

sudo, screensaver, App Store — no $199 Magic Keyboard required.

Free. Open source. 60 seconds to try.

🧵 Thread:
```

```
1/ The problem: Mac Mini, Mac Studio, Mac Pro — no Touch ID.

Apple's fix? A $199 keyboard. That only works wired.

I thought: my iPhone already has Face ID. Why can't I just use it?

So I built TouchBridge. 🔐
```

```
2/ How it works:

$ sudo echo hello
→ Phone buzzes
→ Touch fingerprint
→ ✓ Authenticated

No password. No $199 keyboard. Just your phone.
```

```
3/ The security:

• ECDSA P-256 signatures (same as Apple Pay)
• Secure Enclave — private key never leaves the chip
• 32-byte nonces, 10s expiry, replay protection
• AES-256-GCM encrypted BLE channel
• Falls through to password if phone is unreachable
```

```
4/ Works with EVERYTHING:

📱 iPhone (Face ID)
🤖 Android (fingerprint)
⌚ Apple Watch (tap)
⌚ Wear OS (tap)
🌐 Any browser (no app needed)
🖥️ Simulator (testing, no device)
```

```
5/ The best part: try it in 60 seconds, no phone needed.

git clone github.com/HMAKT99/UnTouchID
touchbridged serve --simulator
sudo echo 'It works!'

Undo anytime: sudo bash scripts/uninstall.sh
```

```
6/ Free. MIT license. 91 tests.

No cloud. No accounts. No tracking.

Just your fingerprint and your Mac.

⭐ github.com/HMAKT99/UnTouchID

If this is useful, a star helps others find it 🙏
```

---

## 4. Product Hunt

### Tagline
"Use your phone's fingerprint to authenticate on any Mac"

### Description
```
TouchBridge lets you use your phone's biometrics (Face ID, fingerprint) to authenticate on your Mac — sudo, screensaver unlock, App Store purchases.

No $199 Magic Keyboard required. Works with iPhone, Android, Apple Watch, Wear OS, or any browser.

Free and open source (MIT). 91 tests. Zero cloud dependency.

Built for Mac Mini, Mac Studio, Mac Pro, and the upcoming MacBook Neo — any Mac without Touch ID.
```

### Topics
- Mac, Developer Tools, Open Source, Security, Productivity

---

## 5. Awesome Lists to Submit To

### Submit PRs to these repos:
- [ ] `jaywcjlove/awesome-mac` (68k stars) — add under "Security Tools"
- [ ] `iCHAIT/awesome-macOS` (16k stars) — add under "Security"
- [ ] `serhii-londar/open-source-mac-os-apps` (41k stars) — add as new entry
- [ ] `matteocrippa/awesome-swift` (24k stars) — add under "Security"
- [ ] `herrbischoff/awesome-macos-command-line` (29k stars) — add under "Security"

### PR template for awesome lists:
```markdown
## [TouchBridge](https://github.com/HMAKT99/UnTouchID)
Use your phone's fingerprint to authenticate on any Mac. sudo, screensaver, App Store — no $199 Magic Keyboard required. Works with iPhone, Android, or any browser. ![Open Source][OSS] ![Free][Free]
```

---

## 6. Dev.to / Hashnode Blog Post

### Title
"I Built a Free Alternative to Apple's $199 Touch ID Keyboard"

### Outline
1. The frustration (typing passwords on Mac Mini)
2. Why I didn't just buy the keyboard ($199, wired only)
3. The idea (phone already has biometrics)
4. How it works (with architecture diagram)
5. The security model (for the skeptics)
6. Try it in 60 seconds
7. What's next (MacBook Neo positioning)

---

## 7. Launch Timing Strategy

### Day 1 (Tuesday/Wednesday)
- 8am ET: Post on Hacker News
- 9am ET: Post on r/macmini
- 10am ET: Tweet the thread
- Engage with ALL comments

### Day 2
- Cross-post to r/MacOS and r/mac
- Submit to awesome-macos list
- Publish Dev.to blog post

### Day 3
- Post on r/programming
- Submit to Product Hunt
- Post on r/opensource

### Day 7
- Follow up on awesome list PRs
- Share milestone (stars count) on Twitter

---

## 8. Engagement Rules

1. **Reply to every comment** within 2 hours
2. **Be honest about limitations** — people respect transparency
3. **Never be defensive** — acknowledge valid criticism
4. **Thank people who star** — a simple "thanks!" goes far
5. **Fix reported issues immediately** — nothing builds trust like a quick fix
6. **Credit contributors** — even small PRs deserve recognition

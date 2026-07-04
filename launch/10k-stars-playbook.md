# TouchBridge — Path to 10K Stars

## Current: 99 stars (3 days old)

## The Math
- Need ~9,900 more stars
- Awesome-lists alone: ~500-1,000 (slow, weeks)
- Need 2-3 "explosion events" to reach 10K

---

## PRIORITY 1: Hacker News (2,000-5,000 stars potential)

### Why it failed before
Title or timing was wrong. HN is very specific about what works.

### The perfect Show HN post

**Title (MUST be exactly this format):**
```
Show HN: I built a free alternative to Apple's $199 Touch ID keyboard
```

**URL:** `https://github.com/HMAKT99/UnTouchID`

**First comment (post IMMEDIATELY after submitting):**
```
I was tired of typing my password 50x/day on my Mac Mini. Apple's fix is a $199 keyboard that only works wired.

So I built TouchBridge — it uses your phone's fingerprint for sudo, screensaver, and App Store auth via BLE.

How it works: PAM module → Unix socket → daemon → BLE → phone's Secure Enclave signs a 32-byte nonce → daemon verifies ECDSA P-256 signature → sudo proceeds.

If phone is unreachable, falls through to password. You're never locked out.

Try it in 60 seconds (no phone needed):

  git clone https://github.com/HMAKT99/UnTouchID
  touchbridged serve --simulator
  sudo echo test

Works with iPhone, Android, Apple Watch, any browser. 127 tests. MIT.

I'd love feedback on the security model — especially the BLE transport.
```

### Timing
- **Best:** Tuesday or Wednesday, 8-9am US Eastern
- **Worst:** Friday afternoon, weekends
- **Never:** Monday morning (too much noise)

### HN tips
- The title MUST start with "Show HN:"
- Don't say "open source" in title (implied by GitHub link)
- Lead with the PROBLEM, not the solution
- First comment must be technical and honest
- Engage with EVERY comment within 30 minutes
- Never be defensive

---

## PRIORITY 2: Reddit (1,000-3,000 stars potential)

### Subreddits (post one per day, NOT all at once)

**Day 1: r/macmini** (120K members, most targeted)
```
Title: I made a free tool to use your phone's fingerprint for sudo on Mac Mini — no $199 keyboard needed

Body: [keep short, 3-4 lines max, link to GitHub]
```

**Day 2: r/MacOS** (400K members)
```
Title: TouchBridge: Use Face ID on your iPhone to authenticate sudo on any Mac without Touch ID
```

**Day 3: r/programming** (5M members, hardest but biggest)
```
Title: I built a PAM module that delegates macOS sudo auth to a phone's Secure Enclave over BLE
```

**Day 4: r/opensource** (250K members)
```
Title: TouchBridge — authenticate on your Mac using your phone's biometrics (free, MIT, 127 tests)
```

### Reddit rules
- Do NOT post to multiple subreddits on the same day (shadowban risk)
- Be genuinely helpful in comments
- Don't just link-drop — tell a story

---

## PRIORITY 3: Tech YouTubers

### Who to contact (and why they'd care)

**Fireship** (2.5M subs) — covers "100 seconds of X" and "X in 100 seconds"
- Pitch: "A PAM module that uses BLE + Secure Enclave for sudo auth"
- Why: it's a clever hack, technical, and visual

**NetworkChuck** (4M subs) — covers homelab and Mac Mini setups
- Pitch: "Mac Mini users: stop typing your password for sudo"
- Why: his audience IS Mac Mini users

**ThePrimeagen** (1M subs) — covers dev tools
- Pitch: "I replaced Apple's $199 keyboard with 100 lines of C"
- Why: he loves creative hacks and open source

**Jeff Geerling** (1M subs) — covers Mac Mini, homelab, Raspberry Pi
- Pitch: "Mac Mini security tool that uses your phone as Touch ID"
- Why: he literally reviews Mac Minis

### How to reach them
- Most have email in their YouTube About page
- Or DM on Twitter/X
- Keep pitch to 3 sentences + link

---

## PRIORITY 4: Tech Newsletters

### Submit to these (they feature open source tools):

1. **TLDR Newsletter** (1.2M subscribers)
   - Submit: https://tldr.tech/newsletter
   - Pitch: "Free alternative to Apple's $199 Touch ID keyboard"

2. **Console.dev** (curates open source tools)
   - Submit: https://console.dev/submit/
   - They specifically feature CLI tools and dev tools

3. **Hacker Newsletter** (60K subscribers, curates top HN posts)
   - If you get on HN front page, they'll include you automatically

4. **Morning Brew / TLDR Sec** (security newsletter)
   - Submit as a security tool

---

## PRIORITY 5: GitHub Trending (snowball effect)

### How to trigger it
- Need ~50 stars in a single day to appear on Swift daily trending
- Once trending, you get 200-500 more stars/day from trending page traffic
- Snowball: trending → more stars → stay trending → more stars

### How to get the burst
- Post HN + Reddit on the same day (Tuesday 8am ET)
- Have jaywcjlove share again on X
- Ask the awesome-swift maintainer if they'd share

---

## Execution Timeline

| Day | Action | Expected stars |
|-----|--------|----------------|
| Tue 8am ET | Post on HN (Show HN) | +500-2000 |
| Tue 10am | Post on r/macmini | +100-300 |
| Tue | Engage all comments | sustain momentum |
| Wed | Post on r/MacOS | +100-200 |
| Wed | Submit to TLDR + Console.dev | +100-300 (delayed) |
| Thu | Post on r/programming | +200-500 |
| Fri | Email YouTubers | long-term play |
| Week 2 | Follow up on all pending awesome-list PRs | +200-500 |

### Best case: 5,000-8,000 stars in 2 weeks
### Realistic case: 1,000-3,000 stars in 2 weeks
### Worst case: 300-500 stars in 2 weeks (just from awesome-lists)

The HN front page is the single highest-leverage action. One front page post = 2,000-5,000 stars.

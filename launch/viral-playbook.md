# GitHub Viral Playbook — How TouchBridge Got Traction

## What Worked (Copy This for Any Repo)

---

## Phase 1: Build Something People Actually Need

**The formula:** Find a pain point that affects millions, where the existing solution costs money or doesn't exist.

TouchBridge example:
- Pain: Mac Mini/Studio/Pro have no Touch ID → type password all day
- Existing fix: $199 keyboard (expensive, wired only)
- Our fix: Free, open source, uses phone you already have

**For your next repo, answer these:**
1. What annoys millions of Mac users daily?
2. What does Apple charge money for (or not solve at all)?
3. Can you fix it for free with open source?

---

## Phase 2: Make It Installable in 60 Seconds

Nobody stars a project they can't try. We built 3 instant paths:

1. **Simulator mode** — `touchbridged serve --simulator && sudo echo test` (no phone needed, works immediately)
2. **One-click .pkg installer** — download, double-click, done
3. **Build from source** — `git clone && swift build && make`

**For your repo:**
- Can someone try it in under 60 seconds?
- Is there a "no dependencies" mode for quick testing?
- Can a non-technical user install it? (.pkg, .dmg, or brew)

---

## Phase 3: README That Sells

### Structure that works:
```
1. Badges (stars, license, tests) — social proof
2. One-line pitch — what it does
3. Demo GIF — shows it working
4. "Try it in 60 seconds" — instant gratification
5. The Problem — emotional pain point
6. The Solution — your tool
7. Comparison table — vs paid alternatives
8. How it works — architecture diagram
9. What it can/can't do — honest limitations
10. Install guide — every method
11. Contributing — welcoming
12. Footer CTA — "Stop [pain]. Use [solution]."
```

### Key lines that worked:
- "Apple charges extra for Touch ID on every Mac that has it."
- "No $199 Magic Keyboard required."
- "Free. Open source. 60 seconds to try."

**Template for your repo:**
- "[Company] charges $[X] for [feature]. [Your tool] does it for free."
- "Works in 60 seconds. No [dependency] required."

---

## Phase 4: GitHub Discovery Optimization

### Topics (add 10-15)
```
gh repo edit OWNER/REPO --add-topic macos --add-topic swift --add-topic open-source ...
```
Pick topics people actually browse: `macos`, `swift`, `security`, `developer-tools`, etc.

### GitHub Features to Enable
```bash
gh repo edit OWNER/REPO \
  --enable-discussions \
  --enable-issues \
  --enable-wiki \
  --enable-projects \
  --homepage "https://OWNER.github.io/REPO/"
```

### Social Preview Image
- Create a 1280x640 PNG with your project name, one-line pitch, and key visual
- Upload at: Settings → Social preview
- This shows when anyone shares your GitHub URL on Slack/Discord/Twitter

### FUNDING.yml (Sponsor Button)
```yaml
# .github/FUNDING.yml
github: YOUR_USERNAME
```

### Badges in README
```markdown
![Stars](https://img.shields.io/github/stars/OWNER/REPO?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)
![Tests](https://img.shields.io/badge/tests-passing-green?style=flat-square)
```

---

## Phase 5: Issues That Attract Contributors

Create 6-10 issues with these labels:
- `good first issue` — shows up in GitHub's contributor explorer
- `help wanted` — signals you're welcoming
- `enhancement` — features people want to build

**Types of issues that attract people:**
- "Add Homebrew formula" (everyone wants this)
- "Localization — translate to [language]" (low barrier)
- "Support for [new platform]" (exciting)
- "Improve [X] reliability" (clear scope)

```bash
gh issue create --title "Add Homebrew formula" --label "good first issue,enhancement" \
  --body "Enable: brew install [your-tool]. See existing Homebrew formulas for reference."
```

---

## Phase 6: Discussions for Community

Create these discussions immediately:
1. **Announcements** — "v1 is live, try it"
2. **Ideas** — "What features do you want?"
3. **Polls** — "Which [option] would you use?"
4. **Show and tell** — share your own project launch

```bash
gh api graphql -F repositoryId="REPO_ID" -F categoryId="CATEGORY_ID" \
  -F title="Welcome!" -F body="..." \
  -f query='mutation($repositoryId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
    createDiscussion(input: {repositoryId: $repositoryId, categoryId: $categoryId, title: $title, body: $body}) {
      discussion { url }
    }
  }'
```

---

## Phase 7: Awesome-List PRs (HIGHEST IMPACT)

This is the #1 organic GitHub discovery driver. One merged PR to a 68k-star repo drives more traffic than any social media post.

### Process:
1. Fork the awesome-list repo
2. Find the right section (usually alphabetical)
3. Add your entry matching their format exactly
4. Submit PR with clear title and checklist

### Repos to target (by star count):

**Tier 1 — Massive reach:**
| Repo | Stars | Section |
|------|-------|---------|
| trimstray/the-book-of-secret-knowledge | 150k | Relevant tool category |
| jaywcjlove/awesome-mac | 68k | Category that fits |
| serhii-londar/open-source-mac-os-apps | 41k | By category |
| alebcay/awesome-shell | 33k | System Utilities |

**Tier 2 — Targeted:**
| Repo | Stars | Section |
|------|-------|---------|
| matteocrippa/awesome-swift | 24k | If Swift project |
| nikitavoloboev/my-mac-os | 20k | Open issue suggesting |
| iCHAIT/awesome-macOS | 16k | Matching category |
| pluja/awesome-privacy | 13k | If privacy-related |

**Tier 3 — Niche:**
| Repo | Stars |
|------|-------|
| Language-specific awesome lists | Varies |
| Domain-specific awesome lists | Varies |
| phmullins/awesome-macos | 5k |

### Entry format (adapt to each repo's style):
```markdown
- [YourTool](https://github.com/YOU/REPO) - One line description ending with period. [![OSS][OSS Icon]](https://github.com/YOU/REPO) ![Freeware][Freeware Icon]
```

### Rules:
- Submit 2-3 per day max (more looks spammy)
- Customize description for each repo's audience
- Follow their CONTRIBUTING.md exactly
- Be patient — reviews take days to weeks

---

## Phase 8: Platform Integrations

### OpenClaw / ClawHub
If your tool is useful for AI agents:
1. Create a SKILL.md following their format
2. Publish on ClawHub: clawhub.ai/publish-skill
3. Open issue + PR on openclaw/openclaw
4. Include SHA-256 checksums and security guardrails

### Homebrew (future)
```ruby
# Formula/your-tool.rb
class YourTool < Formula
  desc "One line description"
  homepage "https://github.com/YOU/REPO"
  url "https://github.com/YOU/REPO/archive/v1.0.0.tar.gz"
  sha256 "..."
  # ...
end
```

---

## Phase 9: Release with Real Binaries

Maintainers and users want downloadable binaries, not just source code.

### What to include in GitHub Release:
- `.pkg` installer (macOS)
- `.dmg` disk image
- Binary (if CLI tool)
- Demo video or screenshots

### Build script template:
```bash
#!/bin/bash
# Build all release artifacts
swift build -c release          # daemon/CLI
make -C pam                     # native modules
xcodebuild ...                  # GUI app
pkgbuild ...                    # .pkg installer
hdiutil create ...              # .dmg
```

Upload: `gh release create v1.0.0 *.pkg *.dmg`

---

## Phase 10: Respond to Everything

### Rules:
1. Reply to every issue comment within 2 hours
2. Reply to every PR review within 4 hours
3. Fix reported issues the same day if possible
4. Thank everyone who stars or contributes
5. Be honest about limitations
6. Never be defensive about criticism
7. Act on feedback fast — then tell the person you did

### The jaywcjlove example:
- He merged our PR (68k stars repo)
- He gave feedback: "no GUI, hard for general users"
- We built a menu bar app + .pkg installer within hours
- He offered to promote on social media
- **Fast response to feedback = trust = promotion**

---

## Results Tracking

### Check daily:
```bash
# Traffic
gh api repos/OWNER/REPO/traffic/views --jq '{views: .count, visitors: .uniques}'
gh api repos/OWNER/REPO/traffic/clones --jq '{clones: .count, cloners: .uniques}'

# Referrers (which awesome-list is driving traffic?)
gh api repos/OWNER/REPO/traffic/popular/referrers

# Stars
gh repo view OWNER/REPO --json stargazerCount --jq '.stargazerCount'

# Release downloads
gh api repos/OWNER/REPO/releases --jq '.[0].assets[] | {name, downloads: .download_count}'
```

---

## Timeline

| Day | Action |
|-----|--------|
| 0 | Repo public, README polished, badges, GIF |
| 0 | Create 6-10 issues with good-first-issue labels |
| 0 | Create 4-5 discussions |
| 0 | Enable all GitHub features |
| 1 | Submit PR to biggest awesome-list (68k+) |
| 1 | Submit PR to 2nd awesome-list |
| 2 | Submit to 2 more awesome-lists |
| 2 | Create GitHub Release with binaries |
| 3 | Submit to platform integrations (ClawHub, etc.) |
| 3 | Submit to 2 more awesome-lists |
| 7 | Check which PRs merged, follow up on pending |
| 7 | Respond to all issues/comments |
| 14 | Check traffic, iterate on README based on data |

---

## The One Thing That Matters Most

**Get into ONE awesome-list with 50k+ stars.** Everything else is secondary. One merged PR to awesome-mac (68k stars) drove more discovery than all other efforts combined.

Find the biggest curated list in your domain. Match their format exactly. Submit a clean PR. Be patient.

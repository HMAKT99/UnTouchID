# TouchBridge Policy Configuration

## Overview

TouchBridge supports per-action configurable authentication policy. Each auth surface can be configured to require biometric confirmation every time, or to allow proximity sessions (skip biometric if recently authenticated).

## Default Policy

| Surface | Mode | Session TTL |
|---------|------|-------------|
| `sudo` | biometric required | — |
| `screensaver` | proximity session | 30 min |
| `app_store` | biometric required | — |
| `system_settings` | biometric required | — |
| `browser_autofill` | proximity session | 10 min |

## Configuration

### CLI

```bash
# Show current policy
touchbridge-test config show

# Set a surface policy
touchbridge-test config set --surface screensaver --mode biometric_required

# Set proximity session with TTL
touchbridge-test config set --surface browser_autofill --mode proximity_session --ttl 15

# Set global auth timeout
touchbridge-test config set --timeout 20

# Set RSSI proximity threshold
touchbridge-test config set --rssi -60

# Reset to defaults
touchbridge-test config reset
```

### Plist

Policy is stored at `~/Library/Application Support/TouchBridge/policy.plist`:

```xml
<dict>
    <key>AuthTimeoutSeconds</key>
    <real>15</real>
    <key>RSSIThreshold</key>
    <integer>-75</integer>
    <key>Surfaces</key>
    <dict>
        <key>sudo</key>
        <dict>
            <key>mode</key>
            <string>biometric_required</string>
        </dict>
        <key>screensaver</key>
        <dict>
            <key>mode</key>
            <string>proximity_session</string>
            <key>sessionTTLSeconds</key>
            <real>1800</real>
        </dict>
    </dict>
</dict>
```

## Auth Modes

### `biometric_required`
Every authentication request triggers a biometric prompt on the companion device. This is the most secure mode.

### `proximity_session`
After a successful biometric authentication, subsequent requests within the TTL window are auto-approved without biometric. The session is invalidated when:
- The TTL expires
- The companion device disconnects
- The daemon is restarted

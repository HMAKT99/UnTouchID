# v2 on-device acceptance checklist

Run this on a real Mac and iPhone before relying on TouchBridge, and report the
results in #38. Simulator, web and mocked BLE runs don't count: they can't
exercise the Secure Enclave, Face ID or real PAM.

Record: macOS version, iPhone model and iOS version, TouchBridge version
(`brew info --cask touchbridge`), and pass/fail with notes for each row.

**Before you start:** open a second Terminal and run `sudo -s` there. Keep that
root shell open for the whole run so you can recover if `sudo` breaks.

## 1. Install, pair and enroll

| # | Do | Expect |
|---|----|--------|
| 1.1 | `brew tap HMAKT99/touchbridge && brew trust HMAKT99/touchbridge && brew install --cask touchbridge` | Installs; caveats mention enrollment |
| 1.2 | Build and run `companion/` on the iPhone with your signing team | App opens on the phone |
| 1.3 | Stop the daemon, run `touchbridge-test pair`, scan the QR with the app | Pairing completes; phone shows Mac and phone fingerprints |
| 1.4 | `touchbridge-test export-pam-trust` | Same fingerprints as the phone shows |
| 1.5 | `sudo /Library/Security/TouchBridge/touchbridge-trust enroll "$(id -u)" DEVICE_ID MAC_KEY PHONE_KEY` | Asks you to type both fingerprints; saves |
| 1.6 | Type one fingerprint wrong in a second enroll attempt | Refuses; trust unchanged (`touchbridge-trust list "$(id -u)"`) |
| 1.7 | `sudo bash /Library/Security/TouchBridge/patch-pam.sh`, then `touchbridged serve` | Shows a diff, asks, enables the sudo hook |

## 2. sudo

Run `sudo -k; sudo echo ok` in a new Terminal for each row.

| # | Do | Expect |
|---|----|--------|
| 2.1 | Approve with Face ID | Prints `ok` with no password; phone showed your user, `sudo` and a PID |
| 2.2 | Deny on the phone | Falls back to the password prompt |
| 2.3 | Ignore the phone for 20 seconds | Times out, then password prompt |
| 2.4 | Turn off Bluetooth on the phone | Password prompt within the timeout |
| 2.5 | Stop `touchbridged` | Password prompt immediately |
| 2.6 | Approve, then immediately run 2.1 again | Second run asks the phone again (no reuse) |

## 3. Revocation and unpair

| # | Do | Expect |
|---|----|--------|
| 3.1 | `sudo /Library/Security/TouchBridge/touchbridge-trust revoke "$(id -u)" DEVICE_ID`, then 2.1 | Approving on the phone no longer works; password prompt |
| 3.2 | Re-enroll (1.5). Start `sudo echo ok`, then Unpair in the app before approving | Prompt disappears from the phone; password prompt on the Mac |
| 3.3 | Restart the app after 3.2 | It stays unpaired and won't approve anything |

## 4. Lock screen and auto-lock

| # | Do | Expect |
|---|----|--------|
| 4.1 | Lock the Mac (Control-Command-Q) and try to unlock | macOS 27: password only (#42). Earlier macOS: record whether the phone is asked |
| 4.2 | Run `touchbridged serve --auto-lock`, then walk away or turn off phone Bluetooth | Mac locks after the configured delay |
| 4.3 | Come back before the delay ends | Lock is cancelled |

## 5. Removal

| # | Do | Expect |
|---|----|--------|
| 5.1 | `sudo bash /Library/Security/TouchBridge/uninstall.sh` | No `pam_touchbridge` line left in `/etc/pam.d/sudo_local` or `/etc/pam.d/screensaver` |
| 5.2 | `sudo -k; sudo echo ok` | Normal password prompt; works |

Replay, forgery and malformed-message handling are covered by the native and
daemon test suites (`make -C pam test`, `cd daemon && swift test`) and don't
need manual testing.

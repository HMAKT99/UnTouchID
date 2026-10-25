---
name: touchbridge
description: Set up the unreleased TouchBridge protocol v2 source with explicit public-key enrollment and independent native acceptance.
---

# TouchBridge v2 setup

Use the single [setup and migration guide](../../docs/setup.md). This skill does
not grant permission to modify PAM, enroll trust or install unsigned software;
follow the user's actual authorized scope and show the concrete change first.

Homebrew 1.1.2 is legacy and does not contain this patch. The iPhone App requires
its own signed installation. V1 pairings and bare daemon success strings cannot
authorize v2 PAM. Re-pair using a QR-pinned Mac identity and explicitly enroll
verified Mac/phone fingerprints through the root-owned trust tool.

Do not import user Keychain public keys into root trust automatically. Do not
use vulnerable legacy phone approval to authorize migration. Preserve independent
password/admin recovery, retire hooks before replacing modules, and never change
SIP or shared Homebrew directory owners to pass a failed security check.

Simulator, interactive and web modes are diagnostic only and cannot approve
privileged PAM. The v2 isolated regression driver is tests/e2e-validation.sh;
older release versions manipulate real state and must not be used.

Report source tests, unsigned builds, native installation, physical BLE/Face ID,
password fallback, root revocation, actual screen locking and user acceptance as
separate gates. Do not call a simulator log a physical receipt. Unpair must keep
approval disabled on cleanup failure; Mac root trust revocation is separate.

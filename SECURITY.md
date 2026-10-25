# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability in TouchBridge, please report it responsibly:

1. **Do NOT open a public issue**
2. Email: security@touchbridge.dev (or open a private security advisory on GitHub)
3. Include: description, reproduction steps, impact assessment
4. We will acknowledge within 48 hours and provide a fix timeline

## Protocol v2 security boundary

PAM generates and retains a fresh canonical payload (nonce, Mac identity hash,
UID/user, PID/service, short expiry) and verifies the phone signature itself.
The user daemon is untrusted transport. Boolean success, simulator keys and web
tokens cannot authorize PAM. Unknown versions, bad proofs and timeouts fall
through to password.

Module and trust paths are `/Library/Security/TouchBridge/pam_touchbridge.so`
and `/Library/Security/TouchBridge/Trust/<uid>.plist`. All ancestors require
no-follow descriptors, root ownership, safe write permissions and ACL checks.
Extended ACLs are conservatively rejected. Enrollment requires explicit full
fingerprint confirmation; user Keychain data is never auto-imported. Root trust
is re-read after the phone prompt so administrator revocation can take effect.

QR pins a persistent Mac identity. Signed ECDH binds both ephemeral keys and
service context before encrypted token release. Encrypted pairing and fresh
possession proofs bind the phone key to the session; token consumption is atomic.
The complete authorization is authenticated and signed. Approval text is derived
from validated canonical fields, never an unsigned outer reason.

Unpair first disables reconnect and pending signing, then deletes signing
capability and identity. Failed cleanup stays disabled across restart and is
retryable. Root trust revocation is separate. Auto-lock follows verified companion
counts and reports success only after positive macOS lock-state readback.

## Verification limits

This is an unreleased source migration, not an attestation of Homebrew 1.1.2.
V1 peers require re-pairing. Android/Watch/web/simulator/browser diagnostics and
the Authorization Plugin are not privileged v2 paths; the plugin fails closed.
Root/kernel compromise and hardware-bound Apple authentication are outside scope.
Radio denial of service, clocks or missing permissions may cause failure but must
not cause an authentication bypass.

Unit/core fixture and build success are separate from real phone BLE/Face ID,
root enrollment/revocation, privileged installation, password fallback, migration
recovery and actual screen locking. These remain native acceptance gates.

## Availability and recovery

A missing PAM module can prevent PAM initialization, even with auth sufficient.
Remove hooks before deleting modules. Preserve unrelated entries and backups;
never blindly restore a backup containing vulnerable v1 hooks. Do not disable
SIP or change shared Homebrew ownership. Keep independent admin/password recovery.
See [setup](docs/setup.md) and [evidence format](docs/pam-evidence-v2.md).

## Audit logs

User-controlled NDJSON under `~/Library/Logs/TouchBridge` is not a tamper-proof
privileged receipt. Do not log nonces/private keys or treat simulated records as
phone acceptance. Tests use isolated logs/sockets/Keychain namespaces. The v2
`tests/e2e-validation.sh` runs isolated suites only; older versions change real
state and are unsafe on a working machine.

Verified presence has an 8-second monotonic lease, refreshed by one-use encrypted heartbeat challenges (normally every 2 seconds). Missing or replayed replies cannot preserve a ghost session; expiry removes it and publishes absence in state-change order. This establishes authenticated liveness, not cryptographic distance bounding: a live bidirectional relay to an online phone can still extend apparent physical range. Native background/BLE behavior must be verified before relying on auto-lock.

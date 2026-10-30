# Limits and acceptance boundaries

V2 integrates macOS and the iPhone companion. V1 Android, Watch, Wear OS, web,
simulator and browser diagnostics cannot authorize v2 PAM. The Authorization
Plugin fails closed. Old pairing must be replaced with QR-pinned v2 pairing and
explicit administrator enrollment.

FileVault preboot, Apple Pay and hardware-bound Mac Keychain remain outside
scope. Bonjour fallback is not implemented. The phone pairs with one Mac at a
time. Secure Enclave/Face ID, physical BLE, background behavior and permissions
require a signed App and real-device acceptance.

Module/trust ancestors must be root-owned, not group/other writable or symlinks.
Extended ACL entries are conservatively rejected. Do not disable SIP or weaken
shared directories to bypass refusal.

Unpair cancels signing/reconnect/late callbacks; cleanup failure stays disabled
across restart and Settings permits retry. Mac root-pin removal is a separate
administrator step.

Lock-screen unlock is not supported on macOS 27. There, `authorizationhost`
runs the `screensaver` PAM service and never loads third-party modules, so the
phone is never asked and the password is required (#42). `sudo` is unaffected.
A fix likely needs the Authorization Plugin, which is disabled until it has a
v2 verifier.

Auto-lock arms only after a verified companion has been present and the last
verified device leaves. Actual Lock Screen requests require positive lock-state
readback. Missing mechanisms, permission denials or unconfirmed state are errors,
not locking evidence.

Generic compilation and software-key/socket fixtures do not establish physical
BLE, biometric, privileged installation, migration/recovery, password fallback,
actual screen lock or user acceptance. Logs remain user controlled; simulated
records are not physical-device receipts.

Verified presence has an 8-second monotonic lease, refreshed by one-use encrypted heartbeat challenges (normally every 2 seconds). Missing or replayed replies cannot preserve a ghost session; expiry removes it and publishes absence in state-change order. This establishes authenticated liveness, not cryptographic distance bounding: a live bidirectional relay to an online phone can still extend apparent physical range. Native background/BLE behavior must be verified before relying on auto-lock.

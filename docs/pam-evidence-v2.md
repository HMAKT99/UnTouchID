# Authentication evidence v2

The user daemon transports evidence; it is not the authority for privileged
PAM. Protocol v1 peers fail closed and require re-pairing, without fallback to
legacy nonce signatures, plaintext pairing, or boolean PAM success.

## Signed bytes

ECDSA P-256 SHA-256 signs exactly this binary sequence:

| Field | Encoding |
| --- | --- |
| Domain | Eight bytes `54 42 2d 41 55 54 48 00` (`TB-AUTH` and NUL) |
| Version | u8, 2 |
| Purpose | u8, 1=PAM or 2=diagnostics |
| Nonce | 32 random bytes |
| Mac identity | SHA-256 of Mac identity public key (65-byte X9.63) |
| UID | u32 big endian |
| PID | u32 big endian, nonzero |
| Issued | Unix seconds, u64 big endian |
| Expiry | Unix seconds, u64 big endian |
| User length | u16 big endian |
| User | UTF-8, 1–255 bytes, no NUL/control characters |
| Service length | u16 big endian |
| Service | 1–64 ASCII bytes from `[A-Za-z0-9_.:-]` |

Reject unknown version/purpose, invalid encoding/bounds, trailing bytes and
lifetimes outside 1–30 seconds. Phone allows at most 5 seconds future issue
clock skew, requires live expiry, and checks the QR-pinned Mac identity hash.
Approval text comes only from this parsed payload, never outer `reason`.

Privileged PAM generates and retains the complete payload using a root-enrolled
Mac hash; it verifies against its own bytes and local monotonic deadline.
Signatures are X9.62 DER; P-256 public keys are 65-byte uncompressed X9.63.

## Local transport and root trust

Newline-delimited JSON request adds `evidenceVersion: 2` and `challenge` (base64
signed bytes). Existing `user`, `service`, `pid` are routing hints only.
Response carries `proof: { deviceID, signature }`, signature base64 DER.
PAM independently looks up deviceID and verifies proof; result=success alone
fails. Simulator/web cannot produce privileged proof. Bound frames and support
short I/O; do not accept truncated or timed-out frames.

Module: `/Library/Security/TouchBridge/pam_touchbridge.so`.
Trust: `/Library/Security/TouchBridge/Trust/<uid>.plist`, with:

```text
Version: integer 2
UID: integer target UID
MacIdentityHash: Data (32 bytes)
Devices: array of { DeviceID: string, PublicKey: Data (65 bytes) }
```

Device IDs are 1–128 ASCII bytes from `[A-Za-z0-9._-]`. Validate every P-256
point. Verify root ownership, write permissions, ACLs, and absence of symlinks
for files and all ancestors. Never change shared Homebrew directory owners.

Enrollment is explicit administration, outside authentication: export public
metadata as the user, verify Mac/device fingerprints against the paired phone,
then use trusted password/root authorization to enroll. No automatic Keychain
pin import or silent pin replacement. Remove legacy hooks before migrating or
deleting modules; preserve unrelated PAM entries and password fallback.

## BLE and lifecycle

QR pins persistent Mac identity. Authenticate both ephemeral ECDH keys and
protocol/service context with its signature before releasing encrypted token.
Protect complete pairing request/acceptance, bind phone key to transcript,
consume token atomically, and require reconnect proof of key possession.
Encrypt/authenticate complete authorization payload and require signatures over
the complete canonical bytes. Use bounded MTU-aware framing; reject downgrade.

Unpair stops scanning/reconnect before disconnect, cancels current/deferred
challenges, invalidates signing capability and clears identity/session state.
Late callbacks cannot restore authorization or send signatures after revocation.
Document Mac-side trust removal.

Auto-lock tracks verified companions; absence of all of them starts a bounded
delay, reconnection cancels it. Invoke actual session lock and expose errors;
display sleep or an enabled flag is not locking evidence.

Verified presence has an 8-second monotonic lease, refreshed by one-use encrypted heartbeat challenges (normally every 2 seconds). Missing or replayed replies cannot preserve a ghost session; expiry removes it and publishes absence in state-change order. This establishes authenticated liveness, not cryptographic distance bounding: a live bidirectional relay to an online phone can still extend apparent physical range. Native background/BLE behavior must be verified before relying on auto-lock.

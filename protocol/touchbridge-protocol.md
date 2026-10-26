# TouchBridge protocol v2

Version 1 is rejected. Existing installations must re-pair and explicitly enroll
public keys for privileged PAM; no legacy nonce, unsigned identify, plaintext
pairing, or boolean success fallback is accepted.

The authoritative canonical evidence layout and root trust rules are in
[Authentication evidence v2](../docs/pam-evidence-v2.md). The Swift implementation
is `Sources/TouchBridgeProtocol/SecurityV2.swift`, included unchanged in the iOS
app through `companion/project.yml`.

## Session and pairing

1. The QR includes `version:2`, `serviceUUID`, a single-use 16-byte token,
   `macName`, and `publicKey`: the persistent Mac identity's 65-byte X9.63 P-256
   public key, encoded as JSON base64. Private identity keys remain in Keychain.
2. The phone sends `ClientHello(version:2, ephemeralKey)`. Mac returns
   `ServerHello(version:2, ephemeralKey, identityKey, signature)`.
3. Mac signs `TB-SESSION\0`, byte `02`, lowercase canonical service UUID
   (36 ASCII bytes), phone ephemeral key (65 bytes), Mac ephemeral key (65 bytes).
   The phone checks the QR/stored identity pin and signature before deriving the
   session or releasing the token. ECDH P-256 uses HKDF-SHA256 with empty salt,
   info `TouchBridge-v2`, and a 32-byte output key.
4. All subsequent messages use AES-256-GCM. Each plaintext is an entire wire
   message `[version=2][type][JSON]`; the encrypted envelope also includes
   `[version=2][type]`. Decoding requires inner and outer type to match. This
   authenticates all fields, including IDs, metadata, acceptance, and errors.
5. Pair request includes device ID/name/public key/token and phone's DER
   possession signature. Signature bytes start `TB-PAIR\0`, byte `02`, then five
   u16 big-endian length-prefixed fields: session transcript, UTF-8 device ID,
   UTF-8 device name, X9.63 signing public key, token. Reconnect uses domain
   `TB-IDENTIFY\0` plus byte `02`, the same fields, and an empty token. The stored
   phone key must verify reconnect possession on the fresh transcript.
6. Mac validates and consumes the token in one actor-isolated operation before
   storing the phone key. Acceptance contains the exact device ID/public key
   and is encrypted. Phone persists the Mac pin only after this authenticated
   response matches its own pending identity. Invalid messages fail closed.

Device IDs are 1–128 ASCII `[A-Za-z0-9._-]`. Device names are 1–128 UTF-8 bytes
without control characters. Public keys must reconstruct as valid P-256 points.

## Authorization

Mac retains exact canonical authorization bytes, and sends an encrypted
`AuthorizationChallengeMessage {challengeID, authorization}`. Phone validates
version, purpose, identity hash, fields, issue/expiry bounds, and replay state
before showing user/service/PID or prompting biometrics. It signs the complete
`authorization` bytes, then encrypts `ChallengeResponseMessage` containing
challenge ID, device ID, and DER signature. Mac requires the expected verified
BLE session and device before verification. PAM receives the raw device
signature and independently verifies against its own retained bytes and root
pins. Simulator/web flows cannot supply privileged proof.

## Bounded BLE framing

Every characteristic carries application fragments:

`54 42 | 02 | messageID:u32BE | totalLength:u16BE | offset:u16BE | chunk`

Senders use the actual peer's `maximumUpdateValueLength` (Mac notify) or
the smaller of `maximumWriteValueLength(for:.withResponse)` and
`maximumWriteValueLength(for:.withoutResponse)` (phone writes, with a 20-byte
fallback). The acknowledged-write maximum alone may permit ATT long writes;
the second bound keeps every custom frame in a single ATT write with offset 0.
No 256-byte MTU is assumed. Receivers require sequential offsets, one message per characteristic,
matching ID/length, nonempty chunks, at most 8192 total bytes, and completion
within 5 seconds. Malformed, missing, overlapping, timed-out, downgraded, and
oversized fragments reset the partial message and fail. CoreBluetooth send
queues are bounded by 2048 frames and 64 KiB and resume only after backpressure
clears. Mac allows at most 32 tracked peers.

## Revocation

Phone unpair persists revocation before stopping scan/reconnect, disconnecting,
cancelling deferred/in-flight challenges, clearing pins/session/identity, and
deleting the signing key. Deletion errors preserve an incomplete marker and
revocation across restart; late biometric/BLE callbacks cannot sign or restore
authorization. Root PAM enrollment removal is separate administration and is
required when revoking a previously enrolled phone.


## Verified-presence lease

A signed identify/pairing grants an initial 8-second monotonic presence lease.
Mac checks leases every second and sends an encrypted `presencePing` (type 7)
with a fresh 32-byte nonce. Phone replies with an encrypted `presencePong`
(type 8) echo on the response characteristic, including while backgrounded,
without biometrics or signing. Unpair/session revocation disables this echo.

Mac accepts only the outstanding nonce in the same verified, unexpired session,
consumes it once, and renews the lease for 8 seconds. The next fresh ping is due
2 seconds later. Wrong, consumed, delayed-past-expiry, or unauthenticated pongs
do not extend presence. Expiry removes the complete session transcript and any
pending authorizations even if a BLE central keeps its subscriptions alive;
replayed identify messages cannot revive it. Reconnection needs a fresh ECDH
transcript and phone possession proof.

Verified-count changes are enqueued on a serial publication queue while holding
the state mutation lock, then delivered without holding the lock. A later
disconnect/expiry count cannot be overtaken by an older identify count.

This bounds ghost-session persistence. It is not distance bounding: a live relay
that can still forward a real phone's timely authenticated responses is outside
this guarantee. Actual iOS background execution and radio timing require native
acceptance; suspension safely expires the lease rather than preserving trust.

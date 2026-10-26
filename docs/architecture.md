# Protocol v2 architecture

PAM is the privileged verifier; the user daemon is untrusted BLE transport.
Root pins and module code live under `/Library/Security/TouchBridge`, outside
user-writable Homebrew ancestors. Enrollment is explicit administration.

The QR pins a persistent Mac identity. Signed ECDH binds both ephemeral keys and
service context. Pairing is encrypted/authenticated, the phone proves possession,
and token consumption is atomic. Reconnect requires fresh possession proof.
Bounded MTU-aware frames carry complete protected messages.

PAM chooses and retains canonical context/nonce. The phone validates those bytes,
displays their user/service fields, and signs the complete payload. The daemon
returns device ID and DER signature; root PAM independently verifies its retained
bytes against root pins. It never trusts returned context or a boolean result.
See [format](pam-evidence-v2.md). Diagnostics use a separate action; simulator/web
cannot authorize PAM. The Authorization Plugin fails closed.

Unpair disables signing/reconnect before cleanup, cancels stale callbacks and
persists fail-closed state on cleanup failure. Root revocation is separate.
Auto-lock follows verified peers and confirms actual lock state. Fixture/build
success remains separate from real-device/native acceptance.

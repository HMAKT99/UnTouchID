# Authentication policy after v2

Privileged PAM always requires a fresh phone signature over its exact canonical
transaction and a root-enrolled key. User-writable policy cannot turn this into
proximity-only, simulator, browser or boolean approval. Root trust is per UID;
enrollment/revocation requires administrator fingerprint confirmation.

Existing CLI per-surface values remain diagnostic configuration. They do not
override the verifier, the signed 1–30-second lifetime, Mac identity or valid
signature requirement. A configured proximity TTL cannot bypass biometric v2
authorization. AuthTimeoutSeconds controls relay waiting, not evidence expiry.

Bad, expired or unavailable evidence falls through to password. Auto-lock uses
verified companion lifecycle, not RSSI as identity. See [setup](setup.md) and
[canonical format](pam-evidence-v2.md).

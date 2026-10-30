# Protocol v2 migration

TouchBridge 2.0.0 requires new Mac and iPhone builds and re-pairing. Keep
independent password/admin recovery; do not authorize enrollment via vulnerable
legacy PAM.

Install the Mac tools with Homebrew (`brew tap HMAKT99/touchbridge`, then
`brew trust HMAKT99/touchbridge` on Homebrew 7+, then
`brew install --cask touchbridge`), or build as a normal user and review
before administrator installation:

```bash
cd daemon && swift build -c release --jobs 2
cd .. && make -C pam
make -C pam test
sudo bash scripts/install.sh
```

Installation retires old hooks before replacing modules, preserves unrelated PAM
entries/backups, and uses `/Library/Security/TouchBridge`. Root-controlled
ancestors, safe modes and no symlinks are mandatory; extended ACLs are currently
rejected conservatively. Never disable SIP or change shared Homebrew owners.
PAM remains disabled until explicit key enrollment.

Build `companion/TouchBridge.xcodeproj` for your USB-connected iPhone using your
signing team. Trust the Mac and enable Developer Mode if requested. Generic
unsigned compilation does not install a signed physical-device App.

Stop the normal daemon while `touchbridge-test pair` owns BLE, then scan its QR.
The QR pins the Mac identity before encrypted token release. V1 QR data fails
closed. Compare both public-key fingerprints shown on the trusted phone with
`touchbridge-test export-pam-trust`; never blindly import mutable Mac metadata.

## Explicit enrollment

Substitute the intended ID and independently verified base64 public keys:

```bash
sudo /Library/Security/TouchBridge/touchbridge-trust enroll \
  "$(id -u)" DEVICE_ID MAC_PUBLIC_KEY_BASE64 PHONE_PUBLIC_KEY_BASE64
sudo /Library/Security/TouchBridge/touchbridge-trust list "$(id -u)"
sudo bash /Library/Security/TouchBridge/patch-pam.sh
touchbridged serve
```

The tool confirms both full SHA-256 fingerprints through the terminal and refuses
silent identity replacement. Trust is root-managed per UID under
`/Library/Security/TouchBridge/Trust`. PAM never imports user Keychain entries
while authenticating. Activation checks root trust and the absolute module path.

## Acceptance and revocation

Follow the [on-device acceptance checklist](acceptance-v2.md). Verify real iPhone approve/deny/expiry/unavailability, replay rejection, root
revocation and password fallback. Native fixture or mocked BLE tests are not
physical Secure Enclave/PAM acceptance. Simulator/web/browser diagnostic results
cannot authorize PAM. The v2 `tests/e2e-validation.sh` runs isolated suites only; older versions
change real daemon/socket/policy/sudo state and must not be used.

Unpair stops scans/reconnect and pending approvals before deleting the signing
capability. Failure keeps approvals disabled across restart and Settings can
retry. Separately revoke the Mac's enrolled key (fingerprint confirmation required):

```bash
sudo /Library/Security/TouchBridge/touchbridge-trust revoke "$(id -u)" DEVICE_ID
```

`--auto-lock` tracks verified peers. Only the last verified device leaving arms
the delay; verified reconnect cancels it. Success requires actual macOS lock-state
readback. Missing probes and Automation/Accessibility denials report failure.
Test real lock/unlock before relying on it.

## Removal and recovery

```bash
sudo bash /Library/Security/TouchBridge/uninstall.sh
```

Hooks must be removed before module deletion. Preserve unrelated PAM entries;
do not blindly restore backups containing v1 hooks. Use independent administrator
recovery if sudo cannot initialize. No SIP change is required.

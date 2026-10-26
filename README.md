# TouchBridge

Use an iPhone's Face ID or Touch ID to approve Mac authentication. The privileged
PAM module verifies the phone's signature; the user daemon transports evidence.

**v2.0.0 is a breaking protocol v2 security release.** Upgrading from 1.x means
rebuilding the iPhone app, re-pairing, and explicitly enrolling verified
public-key fingerprints.

## Install with Homebrew

```bash
brew install --cask touchbridge
```

## Build and install from source

Requires macOS 13+, Xcode with iOS SDK, and a physical iPhone for biometric use.
Homebrew installs Mac tools, not the iPhone companion App.

```bash
cd daemon && swift build -c release --jobs 2
cd .. && make -C pam
sudo bash scripts/install.sh
```

The installer retires legacy hooks before replacing privileged code, uses
`/Library/Security/TouchBridge`, and leaves PAM disabled until explicit enrollment.
Do not disable SIP or change shared Homebrew directory ownership. Keep an
independent password/admin recovery route during migration; do not authorize
root enrollment using the vulnerable legacy phone-approval path.

## Pair and activate

Build `companion/TouchBridge.xcodeproj` for a USB-connected iPhone with your own
signing team. Stop the normal daemon while `touchbridge-test pair` owns BLE,
then scan its QR with the App. Verify the Mac and phone fingerprints on the
phone before administrator enrollment. See [setup](docs/setup.md) for commands.

```bash
sudo bash /Library/Security/TouchBridge/patch-pam.sh
touchbridged serve
```

PAM independently verifies the complete [canonical evidence](docs/pam-evidence-v2.md)
against root-managed, per-UID trust. There is no automatic user Keychain import.
V1 peers, bare success strings, and unsigned metadata fail closed.

## Diagnostics and lifecycle

`--simulator`, `--interactive`, and `--web` are diagnostic only; none can approve
real PAM. There is no no-phone sudo demo. Web uses HTTP bearer tokens and must
not be exposed to untrusted networks. Browser diagnostics do not replace OS or
website authentication.

`--auto-lock` tracks verified companions; the last one leaving starts the delay.
Verified reconnect cancels it. The controller checks actual lock state and reports
permission errors or unconfirmed results. Without CGSession, the documented Lock
Screen shortcut may require Automation/Accessibility permissions.

Unpair stops scans/reconnects and pending approvals, clears session state, and
invalidates the signing capability. Failed cleanup leaves approval disabled and
can be retried. Revoke the Mac's root-enrolled key separately as well.

## Validation and limits

```bash
make -C pam test
cd protocol && swift test --jobs 2
cd ../daemon && swift test --jobs 2
```

Tests use isolated sockets/software keys. Physical BLE, Secure Enclave, privileged
migration/password fallback and actual screen locking require native acceptance.
`tests/e2e-validation.sh` now runs only isolated suites. Older release versions
change real daemon/socket/policy/sudo state and must not be used.

V2 targets iPhone/macOS. Android, Watch, browser autofill and Authorization Plugin
are not accepted privileged v2 paths; the plugin fails closed. FileVault preboot,
Apple Pay and hardware-bound Mac Keychain items remain outside scope. Read
[security](SECURITY.md), [architecture](docs/architecture.md) and
[limitations](docs/limitations.md).

## Uninstall

```bash
sudo bash /Library/Security/TouchBridge/uninstall.sh
```

Hooks are removed before modules; unrelated PAM entries and backups are preserved.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Follow [SECURITY.md](SECURITY.md) for private
vulnerability reporting.

## License

[MIT](LICENSE)

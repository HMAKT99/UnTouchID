# TouchBridge Limitations

## Cannot Do

### Keychain items with `kSecAccessControlBiometryCurrentSet`
macOS Keychain items sealed with biometric ACLs require the local Secure Enclave to unwrap them. This is a hardware-level restriction — no software can bypass it. TouchBridge cannot unlock these items.

### Sandboxed App Store apps calling LAContext
Third-party apps distributed via the App Store that call `LAContext.evaluatePolicy` internally are sandboxed. TouchBridge cannot intercept these calls due to SIP and sandbox restrictions.

### Apple Pay
Apple Pay uses a dedicated Secure Element on the Mac (or Watch) and cannot be delegated.

### FileVault unlock
FileVault decryption happens before the OS boots. No user-level daemon is running at that point.

## Design Tradeoffs

### BLE range
BLE range is typically 10-30 meters. The RSSI proximity gate (default -75 dBm) limits effective range to ~5 meters. This means your iPhone must be nearby.

### Background BLE on iOS
iOS aggressively kills background BLE connections. TouchBridge uses `CBCentralManagerOptionRestoreIdentifierKey` for state restoration, but there may be delays when the app is in the background.

### Single companion device (Phase 0-1)
Currently supports one paired device. Multi-device support (any paired device can approve) is planned for Phase 5.

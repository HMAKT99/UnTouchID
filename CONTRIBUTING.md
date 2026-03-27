# Contributing to TouchBridge

Thanks for your interest in TouchBridge! Here's how to get involved.

## Quick Setup

```bash
git clone https://github.com/HMAKT99/UnTouchID.git
cd UnTouchID
cd daemon && swift build && swift test
make -C pam
```

## What to Work On

### Good First Issues
- Improve error messages in PAM module
- Add more PolicyEngine test cases
- Improve the web companion UI

### Wanted
- Homebrew formula (`brew install touchbridge`)
- Multi-device pairing (pair multiple phones)
- Login screen unlock (LaunchDaemon instead of LaunchAgent)
- Apple Watch companion
- Better BLE reconnection logic

## Pull Request Process

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-thing`)
3. Write tests for new functionality
4. Ensure `swift test` passes (in `daemon/`)
5. Open a PR with a clear description

## Code Style

- Swift: follow existing patterns in the codebase
- C (PAM module): C11, `goto cleanup` pattern, no dynamic allocation
- Tests: use Swift Testing framework (`@Test`, `#expect`)

## Architecture Rules

1. **Private keys never leave Secure Enclave / Android Keystore**
2. **Never log nonce values** — only session_id and result
3. **Daemon runs as user-level LaunchAgent, not root**
4. **PAM module must never crash** — always return PAM_AUTH_ERR on failure
5. **`auth sufficient`** — password fallback must always work

## Testing

```bash
# Daemon tests
cd daemon && swift test

# PAM module build
make -C pam

# Quick E2E test
touchbridged serve --simulator &
sudo echo test
```

## Questions?

Open a [GitHub issue](https://github.com/HMAKT99/UnTouchID/issues).

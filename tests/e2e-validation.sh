#!/bin/bash
set -euo pipefail

# Isolated regression driver: no sudo, production daemon/socket, PAM, policy,
# root enrollment, or real screen lock operations.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TB_MENU_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/touchbridge-menu-tests.XXXXXX")
trap 'rm -rf "$TB_MENU_TEST_DIR"' EXIT
swiftc "$PROJECT_DIR/menubar/TouchBridgeMenu/Core/ProtectedInstallation.swift" "$PROJECT_DIR/menubar/tests/main.swift" -o "$TB_MENU_TEST_DIR/check"
"$TB_MENU_TEST_DIR/check"
bash "$PROJECT_DIR/authplugin/tests/check-disabled.sh"
make -C "$PROJECT_DIR/pam" test
swift test --package-path "$PROJECT_DIR/protocol" --jobs 2
swift test --package-path "$PROJECT_DIR/daemon" --jobs 2
printf '%s\n' 'Isolated fixture checks passed; physical BLE/Face ID, privileged migration/password fallback, and actual screen lock still require native acceptance.'

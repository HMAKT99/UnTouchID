#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
export TB_PAM_DIR="$FIXTURE"
source "$ROOT/scripts/pam-common.sh"
# Override only in this sourced fixture process; production uses the fixed tool.
_tb_verify_install() { return 0; }
cat > "$FIXTURE/sudo" <<'PAM'
# unrelated comment mentioning pam_touchbridge
auth include sudo_local
auth sufficient pam_touchbridge.so
auth required pam_opendirectory.so
PAM
printf 'auth sufficient pam_tid.so\n' > "$FIXTURE/sudo_local"
printf 'auth sufficient /usr/local/lib/pam/pam_touchbridge.so\nauth required pam_opendirectory.so\n' > "$FIXTURE/screensaver"
cp "$FIXTURE/sudo" "$FIXTURE/original"
tb_disable_sudo;tb_disable_screensaver
cmp "$FIXTURE/sudo.touchbridge-backup" "$FIXTURE/original"
grep -q '^# unrelated comment' "$FIXTURE/sudo"
grep -q 'pam_opendirectory' "$FIXTURE/sudo"
! _tb_has_hook "$FIXTURE/sudo"
tb_enable_sudo
tb_enable_sudo
test "$(grep -c '^auth.*pam_touchbridge.so' "$FIXTURE/sudo_local")" -eq 1
grep -q '/Library/Security/TouchBridge/pam_touchbridge.so' "$FIXTURE/sudo_local"
grep -q 'pam_tid.so' "$FIXTURE/sudo_local"
printf 'auth optional pam_new.so\n' >> "$FIXTURE/sudo"
tb_disable_sudo
grep -q 'pam_new.so' "$FIXTURE/sudo"
cmp "$FIXTURE/sudo.touchbridge-backup" "$FIXTURE/original"
tb_enable_screensaver
grep -q '/Library/Security/TouchBridge/pam_touchbridge.so' "$FIXTURE/screensaver"
rm "$FIXTURE/screensaver";ln -s "$FIXTURE/original" "$FIXTURE/screensaver"
if tb_disable_screensaver; then echo 'FAIL: accepted symlink' >&2;exit 1;fi
echo 'PASS: PAM migration/idempotence/backup/unrelated-entry/symlink fixtures'

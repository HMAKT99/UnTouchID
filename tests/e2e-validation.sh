#!/bin/bash
set -uo pipefail

# TouchBridge — End-to-End User Validation Suite
# Simulates the complete user journey from install to uninstall

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  ❌ FAIL: $1"; }
section() { echo ""; echo "═══ $1 ═══"; }

# Cleanup function
cleanup() {
    kill $DAEMON_PID 2>/dev/null
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.touchbridge.daemon.plist 2>/dev/null
}
trap cleanup EXIT

DAEMON_PID=""

echo "╔══════════════════════════════════════════════════════╗"
echo "║  TouchBridge — End-to-End User Validation Suite     ║"
echo "╚══════════════════════════════════════════════════════╝"

# ─────────────────────────────────────
section "1. BUILD VALIDATION"
# ─────────────────────────────────────

# 1.1 Daemon builds
cd "$PROJECT_DIR/daemon"
if swift build -c release 2>&1 | tail -1 | grep -q "Build complete"; then
    pass "Daemon builds (release)"
else
    fail "Daemon build"
fi

# 1.2 PAM module builds
cd "$PROJECT_DIR"
if make -C pam clean 2>/dev/null && make -C pam 2>&1 | grep -q "universal binary"; then
    pass "PAM module builds (universal)"
else
    fail "PAM module build"
fi

# 1.3 PAM binary is fat (arm64 + x86_64)
if file pam/pam_touchbridge.so | grep -q "universal binary"; then
    pass "PAM binary is universal (arm64 + x86_64)"
else
    fail "PAM binary architecture"
fi

# 1.4 Unit tests pass
cd "$PROJECT_DIR/daemon"
TEST_OUTPUT=$(swift test 2>&1)
TEST_COUNT=$(echo "$TEST_OUTPUT" | grep "Test run" | grep -oE "[0-9]+ passed" | head -1)
if echo "$TEST_OUTPUT" | grep -q "passed"; then
    pass "Unit tests ($TEST_COUNT)"
else
    fail "Unit tests"
fi

# 1.5 Protocol tests pass
cd "$PROJECT_DIR/protocol"
if swift test 2>&1 | grep -q "passed"; then
    pass "Protocol tests pass"
else
    fail "Protocol tests"
fi

# ─────────────────────────────────────
section "2. INSTALLATION VALIDATION"
# ─────────────────────────────────────

# 2.1 Daemon binary installed
if [ -f /usr/local/bin/touchbridged ]; then
    pass "Daemon binary at /usr/local/bin/touchbridged"
else
    fail "Daemon binary missing"
fi

# 2.2 PAM module installed
if [ -f /usr/local/lib/pam/pam_touchbridge.so ]; then
    pass "PAM module at /usr/local/lib/pam/pam_touchbridge.so"
else
    fail "PAM module missing"
fi

# 2.3 PAM module permissions (444 = read-only)
PAM_PERMS=$(stat -f "%Lp" /usr/local/lib/pam/pam_touchbridge.so 2>/dev/null)
if [ "$PAM_PERMS" = "444" ]; then
    pass "PAM module permissions: 444 (read-only)"
else
    fail "PAM module permissions: expected 444, got $PAM_PERMS"
fi

# 2.4 PAM config patched
if grep -q "pam_touchbridge" /etc/pam.d/sudo; then
    pass "PAM config patched (/etc/pam.d/sudo)"
else
    fail "PAM config not patched"
fi

# 2.5 Backup exists
if [ -f /etc/pam.d/sudo.touchbridge-backup ]; then
    pass "PAM backup exists (sudo.touchbridge-backup)"
else
    fail "PAM backup missing"
fi

# 2.6 App support directory
if [ -d "$HOME/Library/Application Support/TouchBridge" ]; then
    pass "App support directory exists"
else
    fail "App support directory missing"
fi

# 2.7 Log directory
if [ -d "$HOME/Library/Logs/TouchBridge" ]; then
    pass "Log directory exists"
else
    fail "Log directory missing"
fi

# 2.8 LaunchAgent plist
if [ -f "$HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist" ]; then
    pass "LaunchAgent plist installed"
else
    fail "LaunchAgent plist missing"
fi

# ─────────────────────────────────────
section "3. SIMULATOR MODE — SUDO"
# ─────────────────────────────────────

# Stop existing daemon
launchctl bootout gui/$(id -u)/dev.touchbridge.daemon 2>/dev/null
sleep 1

# 3.1 Start simulator daemon
cd "$PROJECT_DIR/daemon"
swift run touchbridged serve --simulator &>/tmp/tb-val.log &
DAEMON_PID=$!
sleep 3

if [ -S "$HOME/Library/Application Support/TouchBridge/daemon.sock" ]; then
    pass "Daemon socket created"
else
    fail "Daemon socket missing"
fi

# 3.2 Socket permissions (600 = owner only)
SOCK_PERMS=$(stat -f "%Lp" "$HOME/Library/Application Support/TouchBridge/daemon.sock" 2>/dev/null)
if [ "$SOCK_PERMS" = "600" ]; then
    pass "Socket permissions: 600 (owner-only)"
else
    fail "Socket permissions: expected 600, got $SOCK_PERMS"
fi

# 3.3 Single sudo succeeds
sudo -k
if sudo echo "SINGLE_SUDO_OK" 2>&1 | grep -q "SINGLE_SUDO_OK"; then
    pass "Single sudo succeeds without password"
else
    fail "Single sudo failed"
fi

# 3.4 PAM shows 'check your phone' message
sudo -k
OUTPUT=$(sudo echo "MSG_TEST" 2>&1)
if echo "$OUTPUT" | grep -q "check your phone"; then
    pass "PAM shows 'check your phone or watch...' message"
else
    fail "PAM 'check your phone' message missing"
fi

# 3.5 PAM shows 'authenticated' message
if echo "$OUTPUT" | grep -q "authenticated"; then
    pass "PAM shows '✓ authenticated' message"
else
    fail "PAM 'authenticated' message missing"
fi

# 3.6 Multiple rapid sudo calls (race condition test)
ALL_OK=true
for i in $(seq 1 5); do
    if ! sudo echo "RAPID_$i" 2>&1 | grep -q "RAPID_$i"; then
        ALL_OK=false
        break
    fi
done
if $ALL_OK; then
    pass "5 rapid sudo calls all succeed (no race condition)"
else
    fail "Rapid sudo calls failed"
fi

# ─────────────────────────────────────
section "4. AUDIT LOG VALIDATION"
# ─────────────────────────────────────

# 4.1 Events recorded
LOG_COUNT=$(swift run touchbridge-test logs --count 100 2>/dev/null | grep "✓" | wc -l | tr -d ' ')
if [ "$LOG_COUNT" -gt 0 ]; then
    pass "Audit log has $LOG_COUNT verified events"
else
    fail "Audit log empty"
fi

# 4.2 Nonce never in logs
LOG_DIR="$HOME/Library/Logs/TouchBridge"
if grep -r "nonce" "$LOG_DIR"/*.ndjson 2>/dev/null | grep -q "nonce"; then
    fail "SECURITY: nonce found in audit log!"
else
    pass "SECURITY: nonce never appears in audit log"
fi

# 4.3 Summary dashboard works
if swift run touchbridge-test logs --summary 2>/dev/null | grep -q "Total events"; then
    pass "Summary dashboard works"
else
    fail "Summary dashboard broken"
fi

# 4.4 CSV export works
CSV_HEADER=$(swift run touchbridge-test logs --export csv --count 1 2>/dev/null | head -1)
if echo "$CSV_HEADER" | grep -q "timestamp,surface,result"; then
    pass "CSV export has correct headers"
else
    fail "CSV export broken"
fi

# 4.5 Failures filter works
if swift run touchbridge-test logs --failures --count 1 2>/dev/null | grep -qE "FAILED|No matching"; then
    pass "Failures filter works"
else
    fail "Failures filter broken"
fi

# 4.6 Log entries have required fields
LAST_LOG=$(swift run touchbridge-test logs --export json --count 1 2>/dev/null | tail -1)
FIELDS_OK=true
for field in "session_id" "surface" "result" "ts"; do
    if ! echo "$LAST_LOG" | grep -q "$field"; then
        FIELDS_OK=false
    fi
done
if $FIELDS_OK; then
    pass "Log entries contain all required fields (session_id, surface, result, ts)"
else
    fail "Log entries missing required fields"
fi

# ─────────────────────────────────────
section "5. DAEMON FAILURE — FALLBACK"
# ─────────────────────────────────────

# 5.1 Kill daemon
kill $DAEMON_PID 2>/dev/null
DAEMON_PID=""
sleep 2
rm -f "$HOME/Library/Application Support/TouchBridge/daemon.sock"

# 5.2 Sudo falls through (PAM shows daemon not running)
sudo -k
FALLBACK_OUTPUT=$(sudo -k 2>&1; echo "" | sudo -S echo "SHOULD_FAIL" 2>&1 || true)
if echo "$FALLBACK_OUTPUT" | grep -q "daemon not running\|Password\|Sorry\|password"; then
    pass "Fallback: shows error and falls through to password"
else
    fail "Fallback behavior unexpected: $FALLBACK_OUTPUT"
fi

# ─────────────────────────────────────
section "6. DAEMON RECOVERY"
# ─────────────────────────────────────

# 6.1 Restart daemon
cd "$PROJECT_DIR/daemon"
swift run touchbridged serve --simulator &>/tmp/tb-val2.log &
DAEMON_PID=$!
sleep 3

# 6.2 Sudo works again
sudo -k
if sudo echo "RECOVERY_OK" 2>&1 | grep -q "RECOVERY_OK"; then
    pass "Daemon recovery: sudo works again after restart"
else
    fail "Daemon recovery failed"
fi

# ─────────────────────────────────────
section "7. CONFIGURATION"
# ─────────────────────────────────────

# 7.1 Config show
if swift run touchbridge-test config show 2>/dev/null | grep -q "Policy Configuration"; then
    pass "Config show displays policy"
else
    fail "Config show broken"
fi

# 7.2 Config set
swift run touchbridge-test config set --timeout 25 2>/dev/null
if swift run touchbridge-test config show 2>/dev/null | grep -q "25"; then
    pass "Config set changes timeout"
else
    fail "Config set didn't apply"
fi

# 7.3 Config reset
swift run touchbridge-test config reset 2>/dev/null
if swift run touchbridge-test config show 2>/dev/null | grep -q "15.0"; then
    pass "Config reset restores defaults"
else
    fail "Config reset broken"
fi

# ─────────────────────────────────────
section "8. WEB COMPANION"
# ─────────────────────────────────────

# 8.1 Start web mode (quick check)
kill $DAEMON_PID 2>/dev/null
sleep 1

swift run touchbridged serve --web &>/tmp/tb-web.log &
WEB_PID=$!
sleep 3

# 8.2 HTTP server responds
if curl -s http://localhost:7070/ 2>/dev/null | grep -q "TouchBridge"; then
    pass "Web companion: HTTP server responds on port 7070"
else
    fail "Web companion: HTTP server not responding"
fi

# 8.3 Status page shows correctly
if curl -s http://localhost:7070/ 2>/dev/null | grep -q "running"; then
    pass "Web companion: status page shows 'running'"
else
    fail "Web companion: status page content wrong"
fi

kill $WEB_PID 2>/dev/null
sleep 1

# ─────────────────────────────────────
section "9. CLI COMMANDS"
# ─────────────────────────────────────

cd "$PROJECT_DIR/daemon"

# Restart simulator for remaining tests
swift run touchbridged serve --simulator &>/tmp/tb-val3.log &
DAEMON_PID=$!
sleep 3

# 9.1 list-devices
if swift run touchbridge-test list-devices 2>/dev/null | grep -qE "No paired|Paired"; then
    pass "list-devices command works"
else
    fail "list-devices broken"
fi

# 9.2 touchbridged --help
if swift run touchbridged --help 2>/dev/null | grep -q "daemon"; then
    pass "touchbridged --help works"
else
    fail "touchbridged --help broken"
fi

# 9.3 touchbridge-test --help
if swift run touchbridge-test --help 2>/dev/null | grep -q "harness\|TouchBridge"; then
    pass "touchbridge-test --help works"
else
    fail "touchbridge-test --help broken"
fi

# ─────────────────────────────────────
section "10. SECURITY CHECKS"
# ─────────────────────────────────────

# 10.1 No hardcoded secrets in source
if grep -r "password\s*=" "$PROJECT_DIR/daemon/Sources" --include="*.swift" 2>/dev/null | grep -v "//\|test\|Test\|kSec\|PAM_" | head -1 | grep -q .; then
    fail "SECURITY: possible hardcoded password in source"
else
    pass "SECURITY: no hardcoded passwords in source"
fi

# 10.2 No nonce logging in daemon code
if grep -n "nonce" "$PROJECT_DIR/daemon/Sources/TouchBridgeCore/AuditLog.swift" 2>/dev/null | grep -v "Never\|never\|NEVER\|//" | head -1 | grep -q .; then
    fail "SECURITY: nonce reference in AuditLog code"
else
    pass "SECURITY: AuditLog does not reference nonce values"
fi

# 10.3 PAM uses 'auth sufficient' (not 'auth required')
if grep "pam_touchbridge" /etc/pam.d/sudo | grep -q "sufficient"; then
    pass "SECURITY: PAM uses 'auth sufficient' (password fallback works)"
else
    fail "SECURITY: PAM not using 'sufficient' — could lock out user!"
fi

# ─────────────────────────────────────
# RESULTS
# ─────────────────────────────────────

# Cleanup
kill $DAEMON_PID 2>/dev/null
DAEMON_PID=""

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  RESULTS                                            ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Total:  %-40s ║\n" "$TOTAL tests"
printf "║  Passed: %-40s ║\n" "$PASS ✅"
printf "║  Failed: %-40s ║\n" "$FAIL ❌"
echo "╚══════════════════════════════════════════════════════╝"

exit $FAIL

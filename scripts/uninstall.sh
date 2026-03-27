#!/bin/bash
set -euo pipefail

# TouchBridge Uninstaller
# Removes the daemon, PAM module, and restores PAM config files from backups.

DAEMON_BIN="/usr/local/bin/touchbridged"
PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"
LAUNCH_AGENT_LABEL="dev.touchbridge.daemon"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== TouchBridge Uninstaller ==="
echo ""

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with sudo."
    echo "  Usage: sudo bash scripts/uninstall.sh"
    exit 1
fi

ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
ACTUAL_UID=$(id -u "$ACTUAL_USER")
LAUNCH_AGENT_PLIST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"

# --- Unload LaunchAgent ---

info "Stopping daemon..."
launchctl bootout "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true

if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    rm -f "$LAUNCH_AGENT_PLIST"
    info "Removed LaunchAgent plist."
else
    info "LaunchAgent plist not found — skipping."
fi

# --- Restore PAM Files ---

restore_pam_file() {
    local PAM_FILE="$1"
    local PAM_NAME="$2"
    local BACKUP="${PAM_FILE}.touchbridge-backup"

    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$PAM_FILE"
        rm -f "$BACKUP"
        info "Restored $PAM_FILE from backup."
    elif grep -q "pam_touchbridge" "$PAM_FILE" 2>/dev/null; then
        # No backup but file is patched — remove the touchbridge line
        local TEMP_FILE
        TEMP_FILE=$(mktemp)
        grep -v "pam_touchbridge" "$PAM_FILE" > "$TEMP_FILE"
        cp "$TEMP_FILE" "$PAM_FILE"
        rm -f "$TEMP_FILE"
        info "Removed pam_touchbridge line from $PAM_FILE."
    else
        info "$PAM_NAME not patched — skipping."
    fi
}

restore_pam_file "/etc/pam.d/sudo" "sudo"
restore_pam_file "/etc/pam.d/screensaver" "screensaver"

# --- Remove Binaries ---

if [ -f "$DAEMON_BIN" ]; then
    rm -f "$DAEMON_BIN"
    info "Removed $DAEMON_BIN"
else
    info "Daemon binary not found — skipping."
fi

if [ -f "$PAM_LIB" ]; then
    rm -f "$PAM_LIB"
    info "Removed $PAM_LIB"
else
    info "PAM module not found — skipping."
fi

# --- Remove Socket ---

SOCK_PATH="$ACTUAL_HOME/Library/Application Support/TouchBridge/daemon.sock"
if [ -S "$SOCK_PATH" ]; then
    rm -f "$SOCK_PATH"
    info "Removed daemon socket."
fi

# --- Done ---

echo ""
info "=== Uninstallation Complete ==="
echo ""
echo "Note: User data at ~/Library/Application Support/TouchBridge/ was preserved."
echo "      To remove it: rm -rf ~/Library/Application\\ Support/TouchBridge/"
echo ""
echo "Note: Log files at ~/Library/Logs/TouchBridge/ were preserved."
echo "      To remove them: rm -rf ~/Library/Logs/TouchBridge/"
echo ""

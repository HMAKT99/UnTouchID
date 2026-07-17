#!/bin/bash
set -euo pipefail

# TouchBridge Uninstaller
# Removes the daemon, PAM module, and the TouchBridge PAM hook.
#
# IMPORTANT: the PAM hook is always removed BEFORE the module file, so sudo can
# never be left referencing a deleted module (the lockout class of bugs).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pam-common.sh
source "$SCRIPT_DIR/pam-common.sh"

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

# --- Remove PAM hook (BEFORE the module, to avoid a dangling reference) ---

tb_disable_sudo
tb_disable_screensaver

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

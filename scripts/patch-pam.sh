#!/bin/bash
set -euo pipefail

# TouchBridge PAM Activator
# Patches /etc/pam.d/sudo and /etc/pam.d/screensaver to enable TouchBridge.
# For users who installed via Homebrew or the .pkg — binaries are already in
# place, this only activates the PAM hook. Fully idempotent, backs up each
# file, and asks for confirmation before touching anything.
#
# Usage: sudo bash patch-pam.sh

PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== TouchBridge PAM Activator ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with sudo."
    echo "  Usage: sudo bash patch-pam.sh"
    exit 1
fi

if [ ! -f "$PAM_LIB" ]; then
    error "PAM module not found at $PAM_LIB."
    error "Install TouchBridge first (brew install --cask touchbridge, or the .pkg)."
    exit 1
fi
info "Found PAM module: $PAM_LIB"

patch_pam_file() {
    local PAM_FILE="$1"
    local PAM_NAME="$2"
    local BACKUP="${PAM_FILE}.touchbridge-backup"

    if [ ! -f "$PAM_FILE" ]; then
        warn "$PAM_FILE does not exist — skipping."
        return
    fi

    # Check if already patched (idempotent)
    if grep -q "pam_touchbridge" "$PAM_FILE"; then
        info "$PAM_NAME already patched — skipping."
        return
    fi

    # Create backup
    if [ ! -f "$BACKUP" ]; then
        cp "$PAM_FILE" "$BACKUP"
        info "Backed up $PAM_FILE to $BACKUP"
    fi

    # Show the user what will change
    echo ""
    echo "--- Proposed change to $PAM_FILE ---"
    echo "Adding as first auth line:"
    echo "  auth       sufficient     pam_touchbridge.so"
    echo ""
    echo "Current contents:"
    cat "$PAM_FILE"
    echo "---"
    echo ""

    read -p "Apply this change to $PAM_FILE? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Skipped patching $PAM_FILE."
        return
    fi

    # Insert pam_touchbridge as the first auth line
    # Strategy: find the first line starting with "auth" and insert before it
    local TEMP_FILE
    TEMP_FILE=$(mktemp)
    local INSERTED=0

    while IFS= read -r line; do
        if [ $INSERTED -eq 0 ] && echo "$line" | grep -q "^auth"; then
            echo "auth       sufficient     pam_touchbridge.so" >> "$TEMP_FILE"
            INSERTED=1
        fi
        echo "$line" >> "$TEMP_FILE"
    done < "$PAM_FILE"

    if [ $INSERTED -eq 0 ]; then
        # No auth line found — append at the end
        echo "auth       sufficient     pam_touchbridge.so" >> "$TEMP_FILE"
    fi

    cp "$TEMP_FILE" "$PAM_FILE"
    rm -f "$TEMP_FILE"
    info "Patched $PAM_FILE"
}

patch_pam_file "/etc/pam.d/sudo" "sudo"
patch_pam_file "/etc/pam.d/screensaver" "screensaver"

echo ""
info "Done. Test with: sudo echo 'TouchBridge works!'"
echo "To undo, restore the .touchbridge-backup files or run uninstall.sh."

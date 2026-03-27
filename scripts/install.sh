#!/bin/bash
set -euo pipefail

# TouchBridge Installer
# Builds and installs the daemon, PAM module, and LaunchAgent.
# Patches /etc/pam.d/sudo and /etc/pam.d/screensaver with user confirmation.
# Fully idempotent — safe to run multiple times.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DAEMON_BIN="/usr/local/bin/touchbridged"
PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"
APP_SUPPORT_DIR="$HOME/Library/Application Support/TouchBridge"
LOG_DIR="$HOME/Library/Logs/TouchBridge"
LAUNCH_AGENT_LABEL="dev.touchbridge.daemon"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Preflight Checks ---

echo "=== TouchBridge Installer ==="
echo ""

# Check macOS version >= 13.0
MACOS_VERSION=$(sw_vers -productVersion)
MAJOR_VERSION=$(echo "$MACOS_VERSION" | cut -d. -f1)
if [ "$MAJOR_VERSION" -lt 13 ]; then
    error "macOS 13.0 (Ventura) or later is required. You have $MACOS_VERSION."
    exit 1
fi
info "macOS version: $MACOS_VERSION"

# Check SIP status
SIP_STATUS=$(csrutil status 2>/dev/null || echo "unknown")
if echo "$SIP_STATUS" | grep -q "disabled"; then
    warn "System Integrity Protection is disabled. This is unusual."
    warn "TouchBridge works with SIP enabled — consider re-enabling it."
fi

# Check for root (needed for PAM file modification)
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with sudo."
    echo "  Usage: sudo bash scripts/install.sh"
    exit 1
fi

# Get the actual user (not root)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
APP_SUPPORT_DIR="$ACTUAL_HOME/Library/Application Support/TouchBridge"
LOG_DIR="$ACTUAL_HOME/Library/Logs/TouchBridge"
LAUNCH_AGENT_PLIST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"

info "Installing for user: $ACTUAL_USER"

# --- Build ---

info "Building daemon..."
cd "$PROJECT_DIR/daemon"
sudo -u "$ACTUAL_USER" swift build -c release 2>&1 | tail -1
DAEMON_BUILD="$PROJECT_DIR/daemon/.build/release/touchbridged"
if [ ! -f "$DAEMON_BUILD" ]; then
    error "Daemon build failed — binary not found."
    exit 1
fi
info "Daemon built successfully."

info "Building PAM module..."
cd "$PROJECT_DIR"
make -C pam 2>&1 | tail -1
PAM_BUILD="$PROJECT_DIR/pam/pam_touchbridge.so"
if [ ! -f "$PAM_BUILD" ]; then
    error "PAM module build failed."
    exit 1
fi
info "PAM module built successfully."

# --- Install Binaries ---

info "Installing daemon binary..."
mkdir -p "$(dirname "$DAEMON_BIN")"
cp "$DAEMON_BUILD" "$DAEMON_BIN"
chmod 755 "$DAEMON_BIN"
info "Installed $DAEMON_BIN"

info "Installing PAM module..."
mkdir -p "$(dirname "$PAM_LIB")"
cp "$PAM_BUILD" "$PAM_LIB"
chmod 444 "$PAM_LIB"
info "Installed $PAM_LIB"

# --- Create Directories ---

sudo -u "$ACTUAL_USER" mkdir -p "$APP_SUPPORT_DIR"
chmod 700 "$APP_SUPPORT_DIR"
sudo -u "$ACTUAL_USER" mkdir -p "$LOG_DIR"
info "Created application support and log directories."

# --- Patch PAM Files ---

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

# --- Install LaunchAgent ---

info "Installing LaunchAgent..."

# Unload existing agent if running
ACTUAL_UID=$(id -u "$ACTUAL_USER")
launchctl bootout "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" 2>/dev/null || true

# Write the plist (with correct paths for the actual user)
cat > "$LAUNCH_AGENT_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCH_AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_BIN</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/daemon.stderr.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

chown "$ACTUAL_USER" "$LAUNCH_AGENT_PLIST"
chmod 644 "$LAUNCH_AGENT_PLIST"

# Load the agent
launchctl bootstrap "gui/$ACTUAL_UID" "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
info "LaunchAgent installed and loaded."

# --- Verification ---

echo ""
info "=== Installation Complete ==="
echo ""

# Check daemon is running
if launchctl print "gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL" &>/dev/null; then
    info "Daemon is running."
else
    warn "Daemon may not be running yet. Check: launchctl print gui/$ACTUAL_UID/$LAUNCH_AGENT_LABEL"
fi

# Check socket
SOCK_PATH="$APP_SUPPORT_DIR/daemon.sock"
if [ -S "$SOCK_PATH" ]; then
    info "Socket available at: $SOCK_PATH"
else
    info "Socket will be created when daemon starts: $SOCK_PATH"
fi

echo ""
echo "Next steps:"
echo "  1. Open TouchBridge on your iPhone to pair"
echo "  2. Run: touchbridge-test pair"
echo "  3. Test: sudo echo 'TouchBridge works!'"
echo ""

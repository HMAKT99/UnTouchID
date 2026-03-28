#!/bin/bash
set -euo pipefail

# Builds all release artifacts:
# 1. Daemon binary (release mode)
# 2. PAM module (universal binary)
# 3. Menu bar app
# 4. Installer .pkg
# 5. .dmg with menu bar app

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/installer/build"
RELEASE_DIR="$PROJECT_DIR/installer/release"

echo "=== TouchBridge Release Builder ==="
echo ""

rm -rf "$BUILD_DIR" "$RELEASE_DIR"
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

# 1. Build daemon
echo "[1/5] Building daemon..."
cd "$PROJECT_DIR/daemon"
swift build -c release 2>&1 | tail -1
cp .build/release/touchbridged "$BUILD_DIR/"
cp .build/release/touchbridge-test "$BUILD_DIR/"
cp .build/release/touchbridge-nmh "$BUILD_DIR/"
echo "  ✓ Daemon binaries built"

# 2. Build PAM module
echo "[2/5] Building PAM module..."
cd "$PROJECT_DIR"
make -C pam clean 2>/dev/null || true
make -C pam 2>&1 | tail -1
cp pam/pam_touchbridge.so "$BUILD_DIR/"
echo "  ✓ PAM module built (universal binary)"

# 3. Build menu bar app
echo "[3/5] Building menu bar app..."
cd "$PROJECT_DIR/menubar"
xcodegen generate 2>&1 | tail -1
xcodebuild -project TouchBridgeMenu.xcodeproj -scheme TouchBridgeMenu \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    build 2>&1 | tail -1
APP_PATH=$(find "$BUILD_DIR/derived" -name "TouchBridgeMenu.app" -type d | head -1)
if [ -n "$APP_PATH" ]; then
    cp -R "$APP_PATH" "$BUILD_DIR/TouchBridge.app"
    echo "  ✓ Menu bar app built"
else
    echo "  ⚠ Menu bar app not found — skipping"
fi

# 4. Create .pkg installer
echo "[4/5] Creating installer package..."
PKG_ROOT="$BUILD_DIR/pkg-root"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_ROOT/usr/local/lib/pam"
mkdir -p "$PKG_ROOT/usr/local/share/touchbridge"

cp "$BUILD_DIR/touchbridged" "$PKG_ROOT/usr/local/bin/"
cp "$BUILD_DIR/touchbridge-test" "$PKG_ROOT/usr/local/bin/"
cp "$BUILD_DIR/touchbridge-nmh" "$PKG_ROOT/usr/local/bin/"
cp "$BUILD_DIR/pam_touchbridge.so" "$PKG_ROOT/usr/local/lib/pam/"
cp "$PROJECT_DIR/scripts/install.sh" "$PKG_ROOT/usr/local/share/touchbridge/"
cp "$PROJECT_DIR/scripts/uninstall.sh" "$PKG_ROOT/usr/local/share/touchbridge/"
cp "$PROJECT_DIR/daemon/dev.touchbridge.daemon.plist" "$PKG_ROOT/usr/local/share/touchbridge/"

# Post-install script
cat > "$BUILD_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
# Create directories
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
mkdir -p "$ACTUAL_HOME/Library/Application Support/TouchBridge"
mkdir -p "$ACTUAL_HOME/Library/Logs/TouchBridge"
chmod 700 "$ACTUAL_HOME/Library/Application Support/TouchBridge"

# Install LaunchAgent
PLIST_SRC="/usr/local/share/touchbridge/dev.touchbridge.daemon.plist"
PLIST_DST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"
cp "$PLIST_SRC" "$PLIST_DST"
chown "$ACTUAL_USER" "$PLIST_DST"

# Set permissions
chmod 755 /usr/local/bin/touchbridged
chmod 755 /usr/local/bin/touchbridge-test
chmod 755 /usr/local/bin/touchbridge-nmh
chmod 444 /usr/local/lib/pam/pam_touchbridge.so

echo "TouchBridge installed. Run the menu bar app to complete setup."
exit 0
POSTINSTALL
chmod +x "$BUILD_DIR/postinstall"

pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$BUILD_DIR" \
    --identifier "dev.touchbridge.pkg" \
    --version "0.1.0" \
    --install-location "/" \
    "$RELEASE_DIR/TouchBridge-0.1.0.pkg" 2>&1 | tail -1

echo "  ✓ Installer package created"

# 5. Create .dmg
echo "[5/5] Creating disk image..."
DMG_DIR="$BUILD_DIR/dmg"
mkdir -p "$DMG_DIR"

if [ -d "$BUILD_DIR/TouchBridge.app" ]; then
    cp -R "$BUILD_DIR/TouchBridge.app" "$DMG_DIR/"
fi
cp "$RELEASE_DIR/TouchBridge-0.1.0.pkg" "$DMG_DIR/"

# Create a simple README in the DMG
cat > "$DMG_DIR/README.txt" << 'README'
TouchBridge — Use your phone's fingerprint on any Mac

INSTALL:
  Option A: Double-click TouchBridge-0.1.0.pkg (recommended)
  Option B: Drag TouchBridge.app to Applications

After installing, open TouchBridge from your menu bar.

More info: https://github.com/HMAKT99/UnTouchID
README

hdiutil create \
    -volname "TouchBridge" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$RELEASE_DIR/TouchBridge-0.1.0.dmg" 2>&1 | tail -1

echo "  ✓ Disk image created"

# Summary
echo ""
echo "=== Release Artifacts ==="
ls -lh "$RELEASE_DIR/"
echo ""
echo "Ready to upload to GitHub Releases."

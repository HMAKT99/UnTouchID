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

# Version: override with VERSION=x.y.z, else derive from latest git tag
VERSION="${VERSION:-$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
if [ -z "$VERSION" ]; then
    echo "ERROR: could not determine version (no git tag found). Set VERSION=x.y.z" >&2
    exit 1
fi

echo "=== TouchBridge Release Builder (v$VERSION) ==="
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
# Replace the linker's ad-hoc signature with a regular one; the linker-signed
# variant can be rejected as "Code Signature Invalid" once the binaries embed
# an Info.plist (#41).
for bin in touchbridged touchbridge-test touchbridge-nmh; do
    codesign --force -s - "$BUILD_DIR/$bin"
done
echo "  ✓ Daemon binaries built"

# 2. Build PAM module
echo "[2/5] Building PAM module..."
cd "$PROJECT_DIR"
make -C pam clean 2>/dev/null || true
make -C pam 2>&1 | tail -1
cp pam/pam_touchbridge.so "$BUILD_DIR/"
cp pam/touchbridge-trust "$BUILD_DIR/"
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
mkdir -p "$PKG_ROOT/Library/Security/TouchBridge"
PKG_SCRIPTS="$BUILD_DIR/pkg-scripts"
mkdir -p "$PKG_SCRIPTS"

cp "$BUILD_DIR/touchbridged" "$PKG_ROOT/usr/local/bin/"
cp "$BUILD_DIR/touchbridge-test" "$PKG_ROOT/usr/local/bin/"
cp "$BUILD_DIR/touchbridge-nmh" "$PKG_ROOT/usr/local/bin/"
cp "$BUILD_DIR/pam_touchbridge.so" "$PKG_ROOT/Library/Security/TouchBridge/"
cp "$BUILD_DIR/touchbridge-trust" "$PKG_ROOT/Library/Security/TouchBridge/"
for helper in uninstall.sh patch-pam.sh pam-common.sh; do
    cp "$PROJECT_DIR/scripts/$helper" "$PKG_ROOT/Library/Security/TouchBridge/"
done
cp "$PROJECT_DIR/daemon/dev.touchbridge.daemon.plist" "$PKG_ROOT/Library/Security/TouchBridge/"
cp "$PROJECT_DIR/scripts/pam-common.sh" "$PKG_SCRIPTS/"
cp "$BUILD_DIR/touchbridge-trust" "$PKG_SCRIPTS/"

# Retire legacy hooks BEFORE pkg payload writes or replacement. Use only the
# helper bundled in the installer transaction, never /usr/local/share code.
cat > "$PKG_SCRIPTS/preinstall" << 'PREINSTALL'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/pam-common.sh"
tb_disable_sudo
tb_disable_screensaver
"$SCRIPT_DIR/touchbridge-trust" prepare
for name in pam_touchbridge.so touchbridge-trust pam-common.sh patch-pam.sh uninstall.sh dev.touchbridge.daemon.plist; do
    path="/Library/Security/TouchBridge/$name"
    if [ -e "$path" ] || [ -L "$path" ]; then "$SCRIPT_DIR/touchbridge-trust" check "$path" file; fi
done
PREINSTALL
chmod 755 "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/touchbridge-trust"

# Post-install script
cat > "$PKG_SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
set -euo pipefail
TRUST_TOOL="/Library/Security/TouchBridge/touchbridge-trust"
"$TRUST_TOOL" check "$TRUST_TOOL" file
"$TRUST_TOOL" check /Library/Security/TouchBridge/pam_touchbridge.so file
chmod 444 /Library/Security/TouchBridge/pam_touchbridge.so
# Create directories
ACTUAL_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
if [ "$ACTUAL_USER" = root ] || [ "$ACTUAL_USER" = loginwindow ]; then
    echo "Secure binaries installed; complete user setup and fingerprint enrollment from a logged-in account."
    exit 0
fi
ACTUAL_HOME=$(dscl . -read "/Users/$ACTUAL_USER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
sudo -u "$ACTUAL_USER" mkdir -p "$ACTUAL_HOME/Library/Application Support/TouchBridge" "$ACTUAL_HOME/Library/Logs/TouchBridge" "$ACTUAL_HOME/Library/LaunchAgents"
sudo -u "$ACTUAL_USER" chmod 700 "$ACTUAL_HOME/Library/Application Support/TouchBridge"

# Install LaunchAgent
PLIST_SRC="/Library/Security/TouchBridge/dev.touchbridge.daemon.plist"
PLIST_DST="$ACTUAL_HOME/Library/LaunchAgents/dev.touchbridge.daemon.plist"
sudo -u "$ACTUAL_USER" cp "$PLIST_SRC" "$PLIST_DST"

# Set permissions
chmod 755 /usr/local/bin/touchbridged
chmod 755 /usr/local/bin/touchbridge-test
chmod 755 /usr/local/bin/touchbridge-nmh

echo "TouchBridge installed. PAM remains disabled until explicit root fingerprint enrollment and activation."
exit 0
POSTINSTALL
chmod +x "$PKG_SCRIPTS/postinstall"

# Strip extended attributes (e.g. com.apple.provenance) so pkgbuild doesn't
# emit AppleDouble ._* files into /Library/Security/TouchBridge.
xattr -cr "$PKG_ROOT" "$PKG_SCRIPTS"

pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS" \
    --ownership recommended \
    --identifier "dev.touchbridge.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    "$RELEASE_DIR/TouchBridge-$VERSION.pkg" 2>&1 | tail -1

echo "  ✓ Installer package created"

# 5. Create .dmg
echo "[5/5] Creating disk image..."
DMG_DIR="$BUILD_DIR/dmg"
mkdir -p "$DMG_DIR"

if [ -d "$BUILD_DIR/TouchBridge.app" ]; then
    cp -R "$BUILD_DIR/TouchBridge.app" "$DMG_DIR/"
fi
cp "$RELEASE_DIR/TouchBridge-$VERSION.pkg" "$DMG_DIR/"

# Create a simple README in the DMG
cat > "$DMG_DIR/README.txt" << README
TouchBridge — Use your phone's fingerprint on any Mac

INSTALL:
  Option A: Double-click TouchBridge-$VERSION.pkg (recommended)
  Option B: Drag TouchBridge.app to Applications

After installing, open TouchBridge from your menu bar.

More info: https://github.com/HMAKT99/UnTouchID
README

hdiutil create \
    -volname "TouchBridge" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$RELEASE_DIR/TouchBridge-$VERSION.dmg" 2>&1 | tail -1

echo "  ✓ Disk image created"

# Summary
echo ""
echo "=== Release Artifacts ==="
ls -lh "$RELEASE_DIR/"
echo ""
echo "Ready to upload to GitHub Releases."

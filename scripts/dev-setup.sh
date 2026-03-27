#!/bin/bash
set -euo pipefail

echo "=== TouchBridge Development Setup ==="
echo ""

# Build the protocol package
echo "Building TouchBridgeProtocol..."
cd "$(dirname "$0")/../protocol"
swift build
echo "  ✓ Protocol package built"

# Build the daemon
echo "Building daemon..."
cd "$(dirname "$0")/../daemon"
swift build
echo "  ✓ Daemon built"

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Open companion/TouchBridge.xcodeproj in Xcode for the iOS app"
echo "  2. Run 'cd daemon && swift test' to run daemon tests"
echo "  3. Run 'cd daemon && swift run touchbridge-test' for CLI harness"

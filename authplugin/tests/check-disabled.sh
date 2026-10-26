#!/bin/bash
set -euo pipefail
TB_PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
TB_PLUGIN_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/touchbridge-plugin-test.XXXXXX")
trap 'rm -rf "$TB_PLUGIN_TEST_DIR"' EXIT
swiftc -emit-library "$TB_PLUGIN_DIR/Sources/Plugin.swift" "$TB_PLUGIN_DIR/Sources/AuthUI.swift" -o "$TB_PLUGIN_TEST_DIR/disabled.dylib"
clang -Wall -Wextra -Werror "$TB_PLUGIN_DIR/tests/disabled_plugin.c" -framework Security -o "$TB_PLUGIN_TEST_DIR/check"
"$TB_PLUGIN_TEST_DIR/check" "$TB_PLUGIN_TEST_DIR/disabled.dylib"

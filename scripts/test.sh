#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/paths.sh
TEST_DIR=$(mktemp -d /private/tmp/ixus-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/CameraModel.swift Tests/LiveViewRegression.swift -o "$TEST_DIR/regression"
swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/CameraModel.swift Tests/PreferencesRegression.swift -o "$TEST_DIR/preferences"
swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/CameraModel.swift Tests/ReconnectRegression.swift -o "$TEST_DIR/reconnect"
swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/CameraModel.swift Tests/CaptureSavingRegression.swift -o "$TEST_DIR/saving"
"$TEST_DIR/saving"
env LUA_PATH="Resources/?.lua;;" "$LUA_BIN" Tests/CaptureTransactionRegression.lua
"$TEST_DIR/reconnect"
"$TEST_DIR/preferences"
"$TEST_DIR/regression"
swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Tests/ConnectionRegression.swift -o "$TEST_DIR/connection"
"$TEST_DIR/connection"
swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Tests/AutomaticConnectionRegression.swift -o "$TEST_DIR/automatic-connection"
"$TEST_DIR/automatic-connection"
env LUA_PATH="Resources/?.lua;;" "$LUA_BIN" Tests/MenuSessionRegression.lua
"$LUA_BIN" Tests/BridgeRegression.lua Resources/ixus_bridge.lua "$TEST_DIR/camera-state.json"
swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/CameraModel.swift Tests/SettingsRegression.swift -o "$TEST_DIR/settings"
"$TEST_DIR/settings" "$TEST_DIR/camera-state.json"
if [[ "${1:-}" == "--camera" ]]; then
    swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/CameraModel.swift Tests/PersistentSessionIntegration.swift -o "$TEST_DIR/persistent"
    "$TEST_DIR/persistent" "$APP_PATH/Contents/Resources"
fi

if [[ "${1:-}" == "--display" ]]; then
    swiftc -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/CameraModel.swift Tests/DisplayIntegration.swift -o "$TEST_DIR/display"
    "$TEST_DIR/display" "$APP_PATH/Contents/Resources"
fi

if [[ "${1:-}" == "--backlight-policy" ]]; then
    env LUA_PATH="$APP_PATH/Contents/Resources/?.lua;$APP_PATH/Contents/Resources/chdkptp/lua/?.lua" IXUS_POLICY_TEST="$PROJECT_ROOT/Tests/BacklightPolicyIntegration.lua" "$APP_PATH/Contents/Resources/chdkptp/chdkptp" -r "-e!dofile(os.getenv('IXUS_POLICY_TEST'))"
fi

if [[ "${1:-}" == "--focus-controls" ]]; then
    mkdir -p "$TEST_DIR/camera-controls"
    env LUA_PATH="$APP_PATH/Contents/Resources/?.lua;$APP_PATH/Contents/Resources/chdkptp/lua/?.lua" IXUS_TEST_OUTPUT_DIR="$TEST_DIR/camera-controls" IXUS_FOCUS_TEST="$PROJECT_ROOT/Tests/FocusControlsIntegration.lua" "$APP_PATH/Contents/Resources/chdkptp/chdkptp" -r "-e!dofile(os.getenv('IXUS_FOCUS_TEST'))"
fi

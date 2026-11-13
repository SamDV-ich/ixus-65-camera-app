#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/paths.sh
# Fail before changing any build output if a developer dependency is missing.
for path in "$CHDK_ORIGINAL/chdkptp.c" "$LUA_PREFIX/lib/liblua.a" "$LUA_SOURCE/src/lua.h" "$LIBUSB_COMPAT_PREFIX/lib/libusb-0.1.4.dylib" "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"; do
    [[ -f "$path" ]] || { echo "Missing developer dependency: $path" >&2; exit 1; }
done
BUILD_WORK=$(mktemp -d /private/tmp/ixus-build.XXXXXX)
trap 'rm -rf "$BUILD_WORK"' EXIT
HELPER_BUILD="$BUILD_WORK/helper"
mkdir -p "$HELPER_BUILD"
rsync -a --exclude=.git --exclude=.svn --exclude='*.o' --exclude='*.d' --exclude=chdkptp "$CHDK_ORIGINAL/" "$HELPER_BUILD/"
patch -d "$HELPER_BUILD" -p1 < Resources/chdkptp-safe-usb.patch
make -C "$HELPER_BUILD" -j2 LUA_INCLUDE_DIR="$LUA_PREFIX/include" LUA_LIB_DIR="$LUA_PREFIX/lib" LIBUSB_INCLUDE_DIR="$LIBUSB_COMPAT_PREFIX/include" LIBUSB_LIB_DIR="$LIBUSB_COMPAT_PREFIX/lib"
CHDK_SOURCE="$HELPER_BUILD"
APP="$BUILD_WORK/IXUS Camera.app"
RES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$RES/chdkptp" "$RES/Licenses" "$RES/Sources"
# Include exact local upstream sources and licenses alongside the bundled helper.
rsync -a --exclude='.git' --exclude='.svn' --exclude='*.o' --exclude='chdkptp' "$CHDK_SOURCE/" "$RES/Sources/chdkptp/"
cp "$CHDK_SOURCE/chdkptp" "$RES/chdkptp/chdkptp"
cp -R "$CHDK_SOURCE/lua" "$RES/chdkptp/"
cp Resources/ixus_bridge.lua Resources/ixus_profile.lua Resources/ixus_menu.lua Resources/ixus_capture.lua "$RES/"
cp Resources/*COPYING.txt Resources/*LICENSE.txt "$RES/Licenses/"
cp "$CHDK_SOURCE/COPYING" "$RES/Licenses/CHDKPTP-GPL-2.txt"
cp -R "$LUA_SOURCE" "$RES/Sources/"
cp "$LIBUSB_COMPAT_PREFIX/lib/libusb-0.1.4.dylib" "$APP/Contents/Frameworks/"
cp "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/"
chmod u+w "$RES/chdkptp/chdkptp" "$APP/Contents/Frameworks/"*.dylib
install_name_tool -change /usr/local/opt/libusb-compat/lib/libusb-0.1.4.dylib @executable_path/../../Frameworks/libusb-0.1.4.dylib "$RES/chdkptp/chdkptp"
install_name_tool -id @loader_path/libusb-0.1.4.dylib -change /usr/local/opt/libusb/lib/libusb-1.0.0.dylib @loader_path/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libusb-0.1.4.dylib"
install_name_tool -id @loader_path/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IXUSCamera</string>
<key>CFBundleIdentifier</key><string>local.ixus.camera</string>
<key>CFBundleName</key><string>IXUS Camera</string>
<key>CFBundleDisplayName</key><string>IXUS Camera</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Local camera utility. See Resources/Licenses for third-party software.</string>
</dict></plist>
PLIST
swiftc -O -parse-as-library -target x86_64-apple-macosx13.0 -module-cache-path /private/tmp/ixus65-swift-cache Sources/CameraCore/*.swift Sources/CameraApp/*.swift -o "$APP/Contents/MacOS/IXUSCamera"
for file in "$APP/Contents/Frameworks/"*.dylib "$RES/chdkptp/chdkptp"; do codesign --force --sign - "$file"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Replace only a generated application after the new bundle passes verification.
mkdir -p "$(dirname "$APP_PATH")"
if [[ -e "$APP_PATH" ]]; then
    identity=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
    [[ "$identity" == "local.ixus.camera" ]] || { echo "Output is not an IXUS build: $APP_PATH" >&2; exit 1; }
    mv "$APP_PATH" "$BUILD_WORK/previous.app"
fi
if ! mv "$APP" "$APP_PATH"; then
    [[ ! -e "$BUILD_WORK/previous.app" ]] || mv "$BUILD_WORK/previous.app" "$APP_PATH"
    exit 1
fi
# Refresh the existing workspace shortcut after publishing a complete new bundle.
python3 - "$WORK_ROOT/IXUS Camera.app" "$APP_PATH" <<'PYALIAS'
import os, sys, uuid
from pathlib import Path
alias, app = map(Path, sys.argv[1:])
if alias.is_symlink() and alias.resolve() == app.resolve():
    replacement = alias.with_name('.ixus-shortcut-' + uuid.uuid4().hex)
    replacement.symlink_to(os.readlink(alias), target_is_directory=True)
    os.replace(replacement, alias)
PYALIAS
echo "$APP_PATH"

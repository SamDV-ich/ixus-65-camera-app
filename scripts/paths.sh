#!/bin/bash
# Developer paths. External CHDKPTP/Lua installations are never moved or installed.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="${IXUS_WORK_ROOT:-$(dirname "$PROJECT_ROOT")}"
CHDK_ORIGINAL="${CHDK_ORIGINAL:-$WORK_ROOT/tools/chdkptp}"
LUA_SOURCE="${LUA_SOURCE:-$WORK_ROOT/tools/lua-5.2.4}"
LUA_PREFIX="${LUA_PREFIX:-$WORK_ROOT/tools/lua52}"
LUA_BIN="${LUA_BIN:-$LUA_SOURCE/src/lua}"
LIBUSB_COMPAT_PREFIX="${LIBUSB_COMPAT_PREFIX:-/usr/local/opt/libusb-compat}"
LIBUSB_PREFIX="${LIBUSB_PREFIX:-/usr/local/opt/libusb}"
BUILD_DIR="${BUILD_DIR:-$WORK_ROOT/builds/ixus-capture}"
APP_PATH="${APP_PATH:-$BUILD_DIR/IXUS Camera.app}"

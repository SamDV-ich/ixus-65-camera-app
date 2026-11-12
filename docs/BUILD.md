# Build, packaging and verification

Validated toolchain: Intel macOS Ventura 13.7.8, Swift 5.8.1 and Apple Command Line Tools. The dependencies below are for developers; end users only need the application bundle. These scripts do not install dependencies automatically.

## Paths

The local checkout is `/Users/dmitrysamoilovich/chdk-work/ixus-capture`.

`scripts/paths.sh` treats the project's parent directory as the workspace. Existing dependencies on this Mac are configured as follows:

| Variable | Default |
| --- | --- |
| IXUS_WORK_ROOT | Parent of the project directory |
| CHDK_ORIGINAL | `$IXUS_WORK_ROOT/tools/chdkptp` |
| LUA_SOURCE | `$IXUS_WORK_ROOT/tools/lua-5.2.4` |
| LUA_PREFIX | `$IXUS_WORK_ROOT/tools/lua52` (include and lib/liblua.a) |
| LUA_BIN | `$LUA_SOURCE/src/lua`, used by simulated Lua tests |
| LIBUSB_COMPAT_PREFIX | `/usr/local/opt/libusb-compat` |
| LIBUSB_PREFIX | `/usr/local/opt/libusb` |
| BUILD_DIR | `$IXUS_WORK_ROOT/builds/ixus-capture` |
| APP_PATH | `$BUILD_DIR/IXUS Camera.app` |

Override these variables in the environment for other dependency locations. The commands below were validated with the local defaults. Set IXUS_WORK_ROOT if necessary when relocating the checkout. The existing upstream chdkptp/config.mk contains absolute Lua/libusb paths and is not rewritten; make receives explicit overrides in the temporary build copy.

## Commands

```bash
cd /Users/dmitrysamoilovich/chdk-work/ixus-capture
./scripts/test.sh
./scripts/build.sh
./scripts/verify.sh
```

The default test suite uses simulated services and does not access the camera. Scripts find the project root themselves, regardless of the caller's current directory. Output is `../builds/ixus-capture/IXUS Camera.app`, outside the repository. A rebuild replaces only this generated bundle after verifying the new signature and removes temporary compilation files. The installed upstream sources and original CHDKPTP installation are unchanged. Quit a running application before opening the updated bundle.

The build:

1. Checks that the local developer dependencies exist.
2. Copies CHDKPTP to a temporary directory, applies `Resources/chdkptp-safe-usb.patch` and compiles the helper.
3. Compiles the SwiftUI application for `x86_64-apple-macosx13.0`.
4. Bundles the helper, Lua modules, adapter, two USB dynamic libraries, notices and CHDKPTP/Lua sources.
5. Rewrites loader paths to bundle-relative `@executable_path` / `@loader_path` paths and signs ad-hoc.
6. Verifies the signature before placing the bundle in the external build directory.

verify.sh checks Intel architectures, signatures, Info.plist, resources and notices, and the absence of Homebrew loader paths. A public release with Developer ID/notarization and complete corresponding sources for all bundled third-party components has not been prepared. Notices are in Contents/Resources/Licenses; bundled CHDKPTP/Lua sources are in Contents/Resources/Sources.

## Hardware tests

Run hardware tests only after preparing the camera and agreeing on the physical test. The application and other camera clients must be closed. These scenarios have been used previously, but their wrapper commands were not rerun on hardware after the directory restructuring; that migration was checked using simulated tests and the build.

```bash
./scripts/test.sh --camera
./scripts/test.sh --display
./scripts/test.sh --backlight-policy
```

- `--camera` temporarily changes and restores flash and zoom, checking Live View and the persistent connection without taking photographs.
- `--display` temporarily enters playback, starts Live View, disables the backlight for 15 seconds, checks polling and restores playback/zoom. Shutdown checks backlight restoration. It leaves the camera in playback. An observer must confirm darkness and the restored display; recovery is not guaranteed after power loss.
- `--backlight-policy` checks Auto/P, playback/record and a direct backlight wake outside the policy, followed by reapplication during polling. It restores mode, flash, zoom and AF Lock, turns the backlight on and disconnects without taking photographs. An observer must confirm darkness and restoration. This does not test the physical mode switch. The test body ran on real hardware; its new shell flag was not rerun simply to repeat that test. See [STATUS.md](STATUS.md).

Tests/CameraIntegration.swift is an additional historical scenario requiring initial AUTO mode. Its explicit `--capture` option takes one real photograph; the default test script does not run it. Output goes to IXUS_TEST_OUTPUT_DIR or the temporary ixus-capture-checks directory, not inside the bundle. Do not use it as a universal camera recovery procedure. The external historical artifacts/checks/check_camera.py likewise targets a specific earlier test.

## External dependencies

CHDKPTP and Lua installations are outside the application repository, under the workspace's tools directory or paths supplied in the environment. Compatibility symlinks preserve old workspace paths. The generated bundle contains the components needed by end users.

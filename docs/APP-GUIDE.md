# IXUS Camera user guide

A native macOS controller for Canon Digital IXUS 65 / PowerShot SD630, CHDK 1.6.1, Canon firmware 100A. Intel macOS 13 or later is targeted; hardware checks use Ventura 13.7.8.

## Getting started

Open IXUS Camera.app. Move the complete bundle to Applications or another folder if desired. CHDKPTP, Lua and USB libraries are bundled; no separate runtime dependency installation is required.

1. Start the camera with CHDK and connect USB. Close other camera clients, including an open CHDKPTP console. Leave CHDK's Enable Remote option disabled.
2. The application searches immediately. Without a connection, it retries three seconds after each failure, including absent, occupied and unavailable states. A manual connection button also remains available. Discovery does not take photographs.
3. Live View and keeping the backlight off are enabled by default. After checking support, connection starts Live View and then turns the backlight off. These preferences can be changed in the application menu's Settings window (Command-comma), including before connection, and persist between launches.
4. Select a download folder if needed. The default is ~/Pictures/IXUS65, created on the first capture.
5. The capture button takes one photograph and downloads its JPEG. Filenames contain a timestamp and a random suffix. The original stays on the SD card. Playback changes to record mode when needed.
6. A green preview indicator means frames are updating, orange means a frame has been awaited for more than three seconds, and gray means preview is stopped. There is no frame counter. After connection loss the last image is marked as stale; connection and the chosen preview/backlight preferences recover automatically once access returns.

Controls currently use localized labels. This guide describes their function in English. Click a visible info button beside a section or control to open its explanation; hover is not required.

## Shooting controls

- **Mode:** the list contains photo modes reported as available by CHDK on the connected camera. Selection applies immediately and is read back. Its info button describes the selected mode. Camera-side changes update the selection. Video recording is not supported. Some color effects need further configuration on the camera.
- **Flash:** automatic, on or off. Read/write behavior was checked; a flash-off photograph was verified using EXIF. Actual forced flash firing was not separately tested.
- **Zoom:** seven numbered positions, not magnification factors. Hardware checks included movement between the first positions and later between positions 0 and 4 internally.
- **Focus range:** normal, macro or infinity, mirroring the camera control. Selection applies immediately, releases AF Lock and uses the native Canon button with state readback, rather than a synthetic distance override. Close camera menus first. Some shooting modes restrict available ranges; refusal is reported. Camera-side changes appear during polling. Macro and infinity are distinct from the Digital Macro shooting mode.
- **Focus distance:** 100–10000 mm using AF Lock and CHDK set_focus. A 1000 mm request returned 1008 mm on the camera; this does not establish optical accuracy. Press Enter or leave the edited field to apply. The autofocus action releases AF Lock; focusing occurs on the next photograph.

Commands enter record mode when needed. Camera settings remain on the camera after application exit. JPEG capture temporarily disables CHDK RAW through the standard CHDKPTP command, which restores its original value after a successful capture. Failed downloads may still leave a new photograph on the SD card: inspect it before repeating capture. The application does not delete camera photographs and never automatically repeats capture.

## Connection and battery

The header distinguishes searching, absent, connected, an occupied USB interface and unavailable access with an unknown cause. Session failure alone does not prove another client owns the camera. The owner generally cannot be identified; a running ptpcamerad process is not proof of ownership.

All operations reuse the application's persistent connection. Another application's session cannot be adopted. For occupied or unavailable access, the release-connection action offers to force-stop only macOS's ptpcamerad import service, with confirmation because imports may be interrupted. Close other clients yourself. Success is not guaranteed: the service may restart or another program may hold the camera. Reconnect USB or restart the camera with CHDK if necessary. Automatic discovery never force-stops services.

The bundled CHDKPTP build checks USB interface claiming, avoids changing the USB configuration and avoids device resets on open/close or retrying a failed session open. Resources/chdkptp-safe-usb.patch is applied only to a temporary source copy; the original installation is unchanged. The patched connection and Live View were validated on hardware. Permission denied was kept distinct from confirmed interface occupancy. The import service ignored ordinary termination during testing; SIGKILL released access. Two competing independent CHDKPTP clients were not separately tested.

Battery voltage comes from the camera. Percentage is estimated from CHDK configuration thresholds 2101 and 2100; invalid or missing thresholds leave voltage only. Readings normally update approximately once per second and after commands. Long operations postpone background reads. This is a voltage estimate, not remaining runtime. Threshold identifiers originate in CHDK core/conf.c.

## State synchronization

The application polls mode, flash, zoom, focus distance, AF Lock and battery through the same connection approximately once per second. Changes on the camera appear without a manual refresh, including while preview is running. Polling does not stop preview; if keeping the backlight off is enabled, the same request reapplies that command. USB operations remain sequential, so capture and settings can delay polling.

A poll started before a newer user command cannot overwrite that command's result. Focus distance updates only when the field is not being edited and has no unapplied draft. Entering and leaving an unchanged field does not lock focus. Camera-reported infinity or sentinel distances are displayed as reported rather than treated as optical measurements.

## Backlight policy

The Settings checkbox represents desired behavior, not measured lamp state. Enabling it sends set_backlight(0), then reapplies the command during polling and after settings/capture. Disabling it sends set_backlight(1) and stops enforcement. The preference persists through disconnection and is reapplied after reconnection.

Canon may briefly wake the lamp after a mode change or button press. Reapplication waits for polling and can be delayed during long commands. The LCD image continues to operate without illumination; battery savings have not been measured.

Full display shutdown using set_lcd_display was tested and excluded: after returning to playback, the observer saw a black, backlit screen. Entering record restored the image. The application therefore controls the backlight only.

If the helper turned the backlight off, it attempts to turn it on before normal disconnection, on EOF and after command errors while the connection remains available. Recovery is not guaranteed after USB disconnection, power loss or forced helper termination. Simulation covers restoration before disconnect, including a failure after the off command took effect.

## Architecture

- Sources/CameraCore contains CameraService, response types, photo mode descriptions and the CHDKCameraService actor. Requests execute sequentially without a shell and have time limits.
- Resources/ixus_bridge.lua validates camera model/firmware, accepts a bounded set of actions and parameter values, and returns structured JSON.
- Sources/CameraApp contains SwiftUI views, preferences, state, folder selection and preview decoding.

One CHDKPTP process owns one USB connection. Swift uses numbered requests over stdin/stdout; paths are UTF-8 hex. Frames, settings and captures run sequentially. Preview does not reopen the session for each frame. Disabling preview preserves the connection for other operations. Commands temporarily pause an active preview and resume it only after success; an explicit stop prevents resumption. Background connection recovery never repeats a capture. Shutdown stops monitoring and releases the helper.

Porting to another OS requires a platform-specific process launcher and interface; the operations, protocol and Lua adapter can be retained.

## Build and third-party components

See [BUILD.md](BUILD.md) for build, packaging and simulated tests. Hardware tests require a separately prepared camera and an agreed physical check with the application closed. See [STATUS.md](STATUS.md) for evidence and limitations.

CHDKPTP uses GPL-2.0-or-later, Lua uses MIT, and libusb/libusb-compat retain their bundled licenses. Notices are in Contents/Resources/Licenses and CHDKPTP/Lua sources in Contents/Resources/Sources. Public binary distribution also requires the corresponding sources for the bundled USB library versions and compliance with their license terms.

The original legacy application and original CHDKPTP installation have not been changed.

## Project location

Application repository: /Users/dmitrysamoilovich/chdk-work/ixus-capture. Generated bundle: ../builds/ixus-capture/IXUS Camera.app, outside Git. Workspace-level docs cover film/darktable workflows, tools contains third-party installations, artifacts contains photographs/logs and archive contains old builds and the legacy application.

Version 0.4.1 saves JPEG; DNG + JPEG is not implemented. See [REQUIREMENTS.md](REQUIREMENTS.md) for application scope.

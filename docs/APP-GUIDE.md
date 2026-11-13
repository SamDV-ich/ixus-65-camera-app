# IXUS Camera user guide

A native macOS controller for Canon Digital IXUS 65 / PowerShot SD630, CHDK 1.6.1, Canon firmware 100A. Intel macOS 13 or later is targeted; hardware checks use Ventura 13.7.8.

## Getting started

Open IXUS Camera.app. Move the complete bundle to Applications or another folder if desired. CHDKPTP, Lua and USB libraries are bundled; no separate runtime dependency installation is required.

1. Start the camera with CHDK and connect USB. Close other camera clients, including an open CHDKPTP console. Leave CHDK's Enable Remote option disabled.
2. The application searches immediately. Without a connection, it retries three seconds after each failure, including absent, occupied and unavailable states. A manual connection button also remains available. Discovery does not take photographs.
3. Live View and keeping the backlight off are enabled by default. After checking support, connection starts Live View and then turns the backlight off. These preferences can be changed in the application menu's Settings window (Command-comma), including before connection, and persist between launches.
4. Open Settings (Command-comma), Saving photographs, to choose destination, format and local folder. The default is the operating system Pictures directory, without an IXUS65 subfolder. A previously chosen custom folder is preserved.
5. The capture button takes one photograph using the saved destination and format. The default is original JPEG on both the camera and Mac, named by date and time. Playback changes to record mode when needed. See [Saving photographs](SAVING.md) for all settings and error recovery.
6. A green preview indicator means frames are updating, orange means a frame has been awaited for more than three seconds, and gray means preview is stopped. There is no frame counter. After connection loss the last image is marked as stale; connection and the chosen preview/backlight preferences recover automatically once access returns.

Controls currently use localized labels. This guide describes their function in English. Click a visible info button beside a section or control to open its explanation; hover is not required.

## Shooting controls

- **Mode:** the list contains photo modes reported as available by CHDK on the connected camera. Selection applies immediately and is read back. Its info button describes the selected mode. Camera-side changes update the selection. Video recording is not supported. Some color effects need further configuration on the camera.
- **Flash:** automatic, on or off. Read/write behavior was checked; a flash-off photograph was verified using EXIF. Actual forced flash firing was not separately tested.
- **Zoom:** seven numbered positions, not magnification factors. Hardware checks included movement between the first positions and later between positions 0 and 4 internally.
- **Focus range:** normal, macro or infinity, mirroring the camera control. Selection applies immediately, releases AF Lock and uses the native Canon button with state readback, rather than a synthetic distance override. Close camera menus first. Some shooting modes restrict available ranges; refusal is reported. Camera-side changes appear during polling. Macro and infinity are distinct from the Digital Macro shooting mode.
- **Focus distance (advanced):** 100–10000 mm using AF Lock and CHDK set_focus. A 1000 mm request returned 1008 mm on the camera; this does not establish optical accuracy. Press Enter or use the explicit Set button to apply. Leaving an advanced distance draft does not silently change focus. Focus now actively autofocuses without a photograph. Unlocking releases AF Lock so the next photograph can autofocus again.

Commands enter record mode when needed. Camera settings remain on the camera after application exit. Capture temporarily selects CHDK RAW/DNG behavior through the standard CHDKPTP shooting library, which restores its original configuration after a successful shot. Failed downloads may still leave a new photograph on the SD card: inspect it before repeating capture. The application deletes only the files of the current shot when Only Mac was explicitly selected and all requested local products were successfully saved and checked. It never automatically repeats capture.

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

Version 0.5.0 (build 7) includes configurable saving and preview preferences. See [SAVING.md](SAVING.md) for supported paths and hardware verification limits.

## Simple focus controls and mode restrictions

Focus now performs a bounded half-press autofocus operation without taking a photograph and always releases the half-press, including on failure. Focus lock is an explicit control, available only in Canon modes that support it. Manual distance is under an advanced disclosure. The ordinary/macro/infinity choices and flash/zoom controls are filtered using the IXUS 65 mode profile; unavailable operations are also rejected by the bridge. Profiles follow Canon's mode/function table and must still be checked on physical hardware. Simulated tests cover focusing, locking, timeout cleanup and mode restrictions.

## All shooting settings

Use the mode-dependent ISO, white balance, exposure compensation and metering selectors for quick changes. Values are read back after writing and refreshed during polling. Custom white balance selects an existing calibration; use Canon controls to measure a new reference.

The all-camera-settings button opens the actual camera screen, including Canon's bitmap/menu overlay, with MENU, FUNC, SET, arrows, display and zoom controls. Canon determines which items are available in the current mode. This provides access to the remaining native shooting settings rather than simulating unsupported direct commands. It requires a working CHDK bitmap/palette stream in addition to the existing viewport stream.

Use FUNC for shooting parameters and SET to confirm. MENU opens the main menu from the shooting screen; inside FUNC it performs the selected parameter's context action, such as advanced white-balance or long-shutter controls. Optional half-press combinations hold only the half-shutter while sending a selected button and release it afterward, including on failure. Full shutter is never sent by the menu controls. Closing the window finishes the FUNC session with SET and backs out of main MENU panels using MENU, without starting autofocus, then restores the selected Live View preference.

Image size/compression, drive and timer options, color effects and custom color parameters, autofocus-area/assist options, red-eye and slow-sync settings, long-shutter selection, digital zoom, rotation and grid settings are accessed through Canon's own menus where available. AE/FE operations use Canon's native button combinations. These are controls of the camera, not automatic implementation of burst download or video recording in the application. The dedicated saving preferences now expose JPEG quality and resolution as pre-shot property overrides with readback; the other controls remain in the native menus. Saving can also request CHDK RAW or DNG with a JPEG companion.

Direct property readback verifies reported Canon state, not the optical or photographic effect. Additional control values and native menu behavior still require hardware validation on this camera.

An explicit autofocus action discards an unapplied manual-distance draft, so clicking it cannot silently apply an old distance. If the current mode does not support AF Lock, autofocus runs without attempting to retain a lock inherited from another mode.

## Focus behavior after hardware validation

For a close target, choose Macro, press Focus now, then enable focus lock. If Canon already confirmed focus, locking retains the current distance instead of running autofocus again. Without a confirmed focus, enabling the lock first attempts autofocus. Normal focus refusal shows a local warning and leaves the USB session and preview available for another attempt. Manual distance remains an explicit advanced operation.

On this camera, normal/macro/infinity use the dedicated Canon Macro logical event, not an emulated left-arrow press. FUNC navigation runs inside one continuous camera script because restarting scripts for each key/state query can close the Canon function menu. Main MENU uses the working native menu button path. Final MENU-to-FUNC exit handling uses bounded MENU presses and bitmap-alpha readback; it has simulator coverage but was not rerun on hardware after the battery depleted and further hardware testing was declined. See [hardware validation](HARDWARE-CONTROLS.md).

## Preview preferences

Open Settings (Command-comma) and use the Preview section. Changes apply immediately and persist between launches. They affect the Mac preview only, never downloaded JPEG quality.

- Quality: Faster uses the existing horizontal sample skipping. More detail (experimental) decodes all horizontal samples. Its optical benefit on IXUS 65 has not yet been checked on hardware; it may increase host processing cost. Both retain the camera display's 4:3 proportions.
- Refresh rate: Maximum, or an upper limit of 5, 10 or 15 frames per second. The default is 10. The frame interval includes transfer and decoding time, replacing the previous unconditional 150 ms pause. Slow transfers do not receive an extra frame interval. Maximum has no intentional frame delay. Actual performance still depends on camera, USB and other commands.
- Display: Fit to window, or Original size. Original size avoids enlarging the preview and accounts for the camera's pixel aspect ratio; this is a logical display size in macOS points. It also applies to a stopped preview, but not to a downloaded JPEG. Larger images can be scrolled.

The native Canon menu window keeps its fitted preview and continues receiving frames even if the main Live View preference is disabled while the menu is open. Quality and refresh rate apply to both windows. The new preferences and frame routing were checked with simulations and a build only; no new camera connection or performance benchmark was performed.

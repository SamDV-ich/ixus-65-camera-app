# Camera controls: hardware validation, 2026-11-12

Device: Canon Digital IXUS 65 / PowerShot SD630, firmware 100A, CHDK 1.6.1 rev6355. Host: Intel macOS Ventura 13.7.8. The application was closed. One authorized termination of ptpcamerad released USB access; the service was not repeatedly killed during testing.

## Confirmed on the camera

- Main Canon MENU was received as a 360 x 240 RGBA bitmap with the viewport.
- FUNC opened through the Canon Func logical event. Down/up changed its highlighted row; SET confirmed. Captured images were visually inspected.
- A continuous camera-side script preserved FUNC across state polling. Restarting a PTP script for every key/query did not reliably preserve it.
- Native normal (0), macro (1) and infinity (3) were selected and read back through PROPCASE_REAL_FOCUS_MODE. The dedicated Macro event worked; treating the control as an ordinary left-arrow press did not.
- With a lit close target and Macro selected, autofocus succeeded and reported 188 mm. A separate lock command retained the found focus and returned AF Lock = 1.
- The successful focus workflow restored initial playback state, remembered Auto mode, flash, zoom, range, AF Lock and ISO/WB/EV/metering properties. The exposure counter was 6201 before and after. No full-shutter command or JPEG capture was used.
- Backlight ON was requested before disconnection. Its original physical state was not measured; restoration of exact optical distance was not claimed when the initial autofocus was unlocked.

## Problems discovered and corrected

Camera Lua cannot yield through pcall; protected calls around press/sleep/release caused runtime errors. Camera waits now run outside protected calls, with release before timeout reporting and host-side cleanup for unexpected failures.

The IXUS 65 directional/FUNC keyboard-emulation limitation is also described in the [CHDK developer discussion](https://chdk.setepontos.com/d/12245-making-kbdc-code-generic/50). The application uses checked Canon event names and a continuous FUNC session with a bounded idle timeout and backlight cleanup.

Locking an already confirmed focus no longer performs another autofocus cycle. Ordinary autofocus refusal is now a nonfatal result, so the application can retain preview and USB access while showing a useful warning.

High Auto ISO uses native property value 1, not the CHDK ISO-table ID -1. The test read the native value; additional ISO settings were not photographically validated.

## Final changes not rerun on hardware

The last MENU-to-FUNC transition correction closes main-menu panels with bounded MENU presses and checks bitmap opacity. It avoids the earlier half-press exit, which could initiate autofocus and block subsequent navigation. Recorded hardware bitmaps distinguish opaque MENU panels from FUNC/shooting overlays; simulator tests cover the control sequence. Unusual full-screen camera dialogs still need hardware coverage.

The last ordinary-focus-refusal handling, its SwiftUI warning, and the final menu-exit/readback revision were validated with simulators. The battery reached 0% in the last record-mode image; the user declined further physical tests. The final generated bundle was therefore checked by compilation, protocol tests and signature/resource verification rather than another camera run.

Screen captures and raw logs remain outside this application repository. They are not committed or included in release sources.

## Repeating the focus test

Use a charged battery, close camera clients, select Auto/P/Portrait, and place a well-lit detailed target about 15-25 cm away for the Macro autofocus step. After agreeing on the physical test, run:

```bash
./scripts/test.sh --focus-controls
```

The test temporarily enters P, uses wide-angle zoom, checks normal/macro/infinity, focuses in Macro, locks without refocusing and restores its recorded baseline. It never takes a photograph. It requests backlight ON before disconnecting. A low initial battery voltage stops the test before changing shooting settings. Readback does not establish optical accuracy; confirm sharpness separately before a film digitization session.

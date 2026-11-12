# Application status: 0.4.1

Hardware checks used Canon IXUS 65, CHDK 1.6.1 rev6355 / 100A and Intel macOS Ventura 13.7.8.

## Hardware validation

- JPEG capture, download and image loading succeeded; the original remains on the SD card.
- Live View decoding and commands share one USB connection. This is not a measurement of the unique-frame rate.
- Auto, P and Portrait transitions, flash settings and zoom were checked by reading state back. A flash-off photograph was also checked using EXIF; forced flash firing was not tested separately.
- AF Lock and a focus-distance request were checked against camera responses, not optical accuracy or film sharpness.
- Camera-side zoom changes were reflected in the application. Simulated tests cover focus drafts, errors and stale responses.
- The backlight-off policy was checked across Auto/P and playback/record transitions. A direct camera command simulated firmware waking the lamp; the next poll turned it off again. The observer confirmed darkness and a restored image afterward.
- Full LCD shutdown was excluded because returning to playback could leave a black, backlit screen. Only backlight control is used. Its physical state is not measured; the interface represents the requested policy.
- Battery voltage is read from the camera; its percentage is approximate. The presence of ptpcamerad alone does not prove that it owns the interface.
- Bundle contents and ad-hoc signatures were verified. A clean second Mac has not been tested; Developer ID signing and notarization are not configured.

DNG + JPEG, stand optics, exposure/ISO/ND overrides, full-roll endurance and battery savings have not been separately validated. Automated visual inspection was unavailable; physical backlight outcomes were confirmed by the user.

## Dynamic photo modes

The mode list comes from the connected camera's capmode table, without the former three-mode restriction or ID cutoff at 50. Selection checks the name and capmode.valid before switching, then reads the resulting mode back. Video is excluded and the JPEG command rejects video modes too. Localized names and the selected mode's explanation are available through the info button. Polling updates the selection when the camera mode changes.

Simulated tests cover additional modes and rejection paths. Physical switching of the additional modes has not been validated; the earlier hardware checks cover Auto/P/Portrait only.

Descriptions use Canon's [basic guide](https://gdlp01.c-wss.com/gds/0/0900001440/02/PSSD630IXUS65CUGba-EN.pdf) and [advanced guide](https://files.canon-europe.com/files/soft26285/Manual/IXUS-65_ADVCUG_EN.pdf). Some effects require color selection or other parameters on the camera itself.

## Preview and backlight preferences

Live View and keeping the backlight off are enabled by default and controlled in Settings (Command-comma). Preferences persist independently of connection state. After connecting and checking support, the application starts Live View, then turns the backlight off. Simulated tests cover defaults, immediate application, persistence and unsupported capabilities. The new automatic startup sequence has not been tested separately on hardware.

## Continuous discovery

Every connection failure schedules another background attempt after three seconds, including unavailable and occupied states and a broken preview connection. Discovery never invokes reclaim and stops on shutdown. Simulation covers absent, unavailable and occupied states, connection, disconnection and recovery with preview/backlight preferences. This change has not had a separate physical USB reconnection test.

[Requirements](REQUIREMENTS.md) · [Build and tests](BUILD.md)

Historical reports, photographs and test logs are outside this application repository.

## Native focus range

The focus-range picker reads PROPCASE_REAL_FOCUS_MODE (11 in propset1), separately from PROPCASE_FOCUS_MODE (12, manual focus). It selects normal/macro/infinity using the IXUS 65 native left button, releases AF Lock and verifies the resulting property. Selection uses at most three button presses; failure attempts to restore the initial range and AF Lock. Camera menus must be closed. Readback confirms Canon state, not optical accuracy.

Simulated tests cover all three values, AF Lock release, unsupported and invalid selections, and camera-side macro synchronization. Physical behavior on this IXUS 65 still requires validation. Sources: [CHDK propset1](https://github.com/pelrun/CHDK/blob/master/include/propset1.h), [CHDK focus state conversion](https://github.com/pelrun/CHDK/blob/master/core/shooting.c), [IXUS 65 keyboard mapping](https://github.com/pelrun/CHDK/blob/master/platform/ixus65_sd630/kbd.c), and the Canon guides linked above.

## Simple focus controls and mode restrictions

Focus now performs a bounded half-press autofocus operation without taking a photograph and always releases the half-press, including on failure. Focus lock is an explicit control, available only in Canon modes that support it. Manual distance is under an advanced disclosure. The ordinary/macro/infinity choices and flash/zoom controls are filtered using the IXUS 65 mode profile; unavailable operations are also rejected by the bridge. Profiles follow Canon's mode/function table and must still be checked on physical hardware. Simulated tests cover focusing, locking, timeout cleanup and mode restrictions.

## Complete Canon control surface

Mode-dependent direct controls now include ISO, stored white balance, exposure compensation and metering. The profile is application-side; it is based on the IXUS 65 function table, not a firmware API claiming to enumerate every writable setting. Unknown modes expose no speculative direct controls. Direct writes are checked against the profile and read back; physical photographic effects are not established by readback alone.

A native control window adds the camera bitmap/palette overlay to the viewport and exposes bounded navigation keys plus half-press combinations. Canon menus provide the remaining shooting settings and enforce their native mode restrictions. It is a remote control surface, not a separate implementation of every menu field or of movie/burst download. Palette/bitmap decoding and menu interactions require hardware validation.

Simulation covers exposure readback, unavailable-mode rejection, menu keys, half-press cleanup and RGBA frame serialization. A cross-language test decodes the actual Lua response in Swift, including numeric capability arrays, and checks overlay payload validation. The profile resource is bundled and verified.

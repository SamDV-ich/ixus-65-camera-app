# IXUS Camera requirements

A native macOS application for Canon Digital IXUS 65 / PowerShot SD630, firmware 100A, CHDK 1.6.1 rev6355. The validated environment is Intel macOS Ventura 13.7.8. Film digitization is one use case; stand design and image processing materials live outside this repository.

## Features

- Automatically find and connect to the camera, with clear access status and recovery after disconnection.
- Capture one image and download its JPEG to a selected Mac folder, retaining the original on the SD card.
- Use one persistent USB connection for commands and Live View when supported.
- Obtain photo modes from the connected camera's CHDK capabilities, with localized names and descriptions opened using an info button.
- Apply flash, zoom, native normal/macro/infinity focus range, AF Lock and focus distance controls within the implemented limits.
- Poll state approximately once per second without overwriting an active focus edit.
- Display battery voltage and an approximate percentage derived from CHDK thresholds.
- Keep the camera backlight off by periodically reapplying the command; restore it during normal shutdown.
- Enable Live View and the backlight-off preference by default, with persistent controls in the standard Settings window.
- Deliver one application bundle containing CHDKPTP, Lua and USB libraries.

The SwiftUI interface is separate from CameraService and the Lua adapter. Camera operations execute sequentially. Capture is never automatically retried after failure. Another application's USB session cannot be adopted; stopping the system import service requires an explicit action and confirmation.

DNG + JPEG recording, paired downloads and validation of the resulting DNG in an editor remain future work. Automatic image processing and a positive preview of negatives are outside the current version.

[Validation and limitations](STATUS.md) · [Build](BUILD.md) · [User guide](APP-GUIDE.md)

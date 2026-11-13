# Saving photographs

## Checked capabilities

The existing local CHDKPTP `shoot` command and its `rlib_shoot` library support JPEG, CHDK RAW and camera-generated DNG. They return the shot directory, exposure number and RAW naming configuration. The implementation uses that same shot library directly to retain an exact list of files and propagate download errors instead of using the CLI command's status-printing path. It does not guess the newest photo by scanning the card.

The [IXUS 65 platform definition](https://github.com/pelrun/CHDK/blob/master/platform/ixus65_sd630/platform_camera.h) supplies RAW dimensions and DNG calibration. The [propset1 definition](https://github.com/pelrun/CHDK/blob/master/include/propset1.h) identifies QUALITY 23 and RESOLUTION 24. The [CHDK scripting reference](https://chdk.fandom.com/wiki/CHDK_scripting) documents quality 0/1/2 and resolution 0/1/2/4/8 for L/M1/M2/S/W. Values remain subject to this camera's current mode and are read back before capture. They have not been confirmed by a new physical capture.

The [Canon advanced guide](https://files.canon-europe.com/files/soft26285/Manual/IXUS-65_ADVCUG_EN.pdf) lists Superfine, Fine and Normal compression; JPEG dimensions are L 2816 x 2112, M1 2272 x 1704, M2 1600 x 1200, S 640 x 480 and W 2816 x 1584. Postcard date imprint is a separate native Canon option, not a distinct file format. It remains available in the native FUNC menu; this saving pane does not control the date-imprint function.

## Settings and defaults

Settings has Saving photographs and Preview tabs. Saving controls apply to subsequent captures and persist between launches.

- Destination defaults to Camera and Mac. Camera only makes no local directory or download. Mac only uses a card-backed shot, then deletes its exact originals only after verified local saving. It does not claim direct-to-computer capture without an intermediate card write.
- The default local folder is the OS Pictures directory. A custom folder selected earlier is retained. Folder selection and Open folder are in Settings; the main window shows the destination and offers Show saved file.
- JPEG preserves the camera's original bytes and metadata without recompression. PNG and TIFF are local conversions of that JPEG and do not add detail; retaining the JPEG companion is enabled by default and can be disabled. PNG/TIFF are unavailable in Camera only mode; selecting that destination resets a conversion format to JPEG.
- CHDK RAW and DNG each include the associated JPEG. CHDK RAW is stored locally with a `.raw` extension; DNG uses `.dng`, regardless of the extension configured on the card. RAW is not Canon's proprietary native RAW. Camera-only saves use the camera's configured names and extensions. A RAW naming collision with JPEG is rejected without deleting either file.
- JPEG quality and size default to As on camera. Explicit choices are applied and read back immediately before shooting, so a refused override prevents the shot. Current camera property values are shown separately and updated by normal polling. RAW sensor data is independent of JPEG compression.
- Names can use date/time, original camera basename (per companion, with the selected local format extension), or a custom template. Tokens are `{date}`, `{time}`, `{counter}` and `{original}`. Literal text supplies a prefix, for example `Product_{counter}`. Separators, control characters, unknown tokens and empty names are rejected before shooting. The next counter is editable and persists; it advances when the camera has reported a shot, including camera-only shots.
- Date folders can be off (default), per day `yyyy-MM-dd`, or per month `yyyy-MM`. Local time at capture initiation determines names and folders. A preview shows the resulting path.
- Existing files are never overwritten. Collisions add a suffix to all companions as a group.

## Transaction and recovery

1. Validate settings and create a private staging directory inside the selected destination before requesting a shot. Camera-only skips local preparation.
2. Request one shot through `rlib_shoot`, temporarily selecting RAW/DNG behavior. The upstream library restores those configuration values after a successful shot; if a camera script itself fails, inspect its settings before retrying.
3. Derive only that shot's JPEG/RAW paths from returned metadata. Check remote file sizes and download into staging. Verify that local sizes match remote sizes. No file is deleted by this step.
4. Decode JPEG completely; validate DNG's TIFF signature and exact downloaded size, or RAW's exact size. RAW/DNG checks establish complete transfer, not photographic quality or correctness of every sensor value. Convert PNG/TIFF with ImageIO, preserving available metadata and orientation. Check each final image, flush the local files and publish without overwriting existing files. Source metadata support varies by target format.
5. Only for Mac only, issue a separate finish request. The helper permits deletion only of its pending shot's paths, and checks their sizes and modification times again. A changed file is retained. Deletion errors are reported while keeping the local results.
6. Remove staging after success. On a saving failure, retain staging and camera originals; show the staging path for recovery. Partial final products from a failed publication are rolled back. There is no automatic capture retry and no automatic deletion retry after an uncertain connection failure.

A process crash before the finish request leaves camera originals. An uncertain delete response can mean that some originals were already removed, but the complete selected local outputs have already passed validation. Other existing files on the card are outside the transaction. Local conversion failures preserve the camera connection and do not hide the last good preview.

## Verification boundary

New simulated checks cover destination routing, camera shot metadata, RAW/DNG naming, quality/size readback before shooting, download failure, deferred deletion, changed-file protection, local JPEG identity, PNG/TIFF dimensions and orientation, optional JPEG companions, persistent preferences, OS Pictures default, date folders, template rejection and collisions. The existing host bridge regression was rerun because its status payload and command routing changed. Previously passed unrelated preview and focus hardware checks were not repeated.

The bundle was rebuilt and its signature, Intel binaries and bundled dependencies checked. No camera connection, new photograph, physical RAW/DNG validation or physical deletion test was performed: the user's instruction to stop hardware testing remains in force. RAW/DNG controls disclose this boundary in the application.

## Capture error handling

Capture errors include the failing stage (property preparation, shooting, remote file readiness, download or local verification). Native CHDKPTP `download` returns no values on success and throws on failure; it must not be treated as a Boolean result. Regression doubles follow this native contract. After an error, a single script-status query checks the existing session without starting another script. A responsive, idle camera keeps its connection and preview can resume; a transport failure or still-running script takes the normal disconnected recovery path. The photograph is never repeated automatically. A confirmed pre-shot refusal is reported as no shot requested. These changes are checked offline; they do not establish the origin of an earlier unannotated PTP I/O error.

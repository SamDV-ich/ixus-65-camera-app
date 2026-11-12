# IXUS Camera

A native macOS application for Canon Digital IXUS 65 / PowerShot SD630 with CHDK. Version 0.4.1 saves JPEG files to the Mac and provides Live View, shooting controls, battery information and camera backlight management.

## Repository layout

This directory is the standalone application repository:

```text
ixus-capture/
  Sources/        # SwiftUI application and camera service
  Resources/      # Lua adapter, USB patch and third-party licenses
  Tests/          # simulated and hardware integration tests
  scripts/        # build and verification scripts
  docs/           # application documentation
  LICENSE
  README.md
  .gitignore
```

Generated applications, installed dependencies, film workflow research, photographs and archives live outside this repository.

## Build

Run from this directory:

```bash
./scripts/test.sh
./scripts/build.sh
./scripts/verify.sh
```

Default output: `../builds/ixus-capture/IXUS Camera.app`. The application bundles CHDKPTP, Lua and USB libraries; end users do not install these separately. Developer dependencies live in the workspace's external `tools` directory or can be specified through environment variables. See [Build instructions](docs/BUILD.md).

[Requirements](docs/REQUIREMENTS.md) · [User guide](docs/APP-GUIDE.md) · [Validation and limitations](docs/STATUS.md)

DNG + JPEG capture is planned; the current application captures JPEG only.

## License

Original IXUS Camera code is licensed under the GNU General Public License, version 2 or, at your option, any later version (`GPL-2.0-or-later`). See [LICENSE](LICENSE). The software is provided without warranty.

CHDKPTP and its modifications retain GPL-2.0-or-later. Lua and the USB libraries retain their respective licenses and notices. USB license files are in Resources; the build copies CHDKPTP and Lua notices from their dependency sources.

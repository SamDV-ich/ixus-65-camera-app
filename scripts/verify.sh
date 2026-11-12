#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/paths.sh
APP="$APP_PATH"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
python3 - "$APP" <<'PY'
from pathlib import Path
import subprocess,sys
app=Path(sys.argv[1])
files=[app/'Contents/MacOS/IXUSCamera',app/'Contents/Resources/chdkptp/chdkptp',*list((app/'Contents/Frameworks').glob('*.dylib'))]
for f in files:
    arch=subprocess.check_output(['file',str(f)],text=True)
    assert 'x86_64' in arch,arch
    deps=subprocess.check_output(['otool','-L',str(f)],text=True)
    assert '/usr/local/' not in deps and '/opt/homebrew/' not in deps,deps
assert (app/'Contents/Resources/chdkptp/lua/main.lua').is_file()
assert (app/'Contents/Resources/ixus_bridge.lua').is_file()
assert (app/'Contents/Resources/ixus_profile.lua').is_file()
assert (app/'Contents/Resources/ixus_menu.lua').is_file()
assert (app/'Contents/Resources/ixus_capture.lua').is_file()
assert len(list((app/'Contents/Resources/Licenses').glob('*')))>=4
print('PASS: Intel executables, bundled Lua, USB libraries, licenses, no Homebrew loader paths')
PY

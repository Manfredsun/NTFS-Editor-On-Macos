#!/usr/bin/env python3
"""Package the release app (0.2.5), matching helper installer, and setup guide into DMG."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / '.build/Kernel025/Build/Products/Release/NTFS Editor.app'
HELPER = ROOT / 'Dependencies/Install NTFS Editor Mount Helper 0.2.5.pkg'
OUTPUT = ROOT / 'Build/NTFS Editor-0.2.5.dmg'

if OUTPUT.exists():
    OUTPUT.unlink()

assert APP.is_dir(), f"Missing app at {APP}"
assert HELPER.is_file(), f"Missing helper at {HELPER}"
app_version = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
assert app_version == '0.2.5', f"Expected version 0.2.5, got {app_version}"

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
subprocess.run(['ditto', str(APP), str(ROOT / 'Build/NTFS Editor.app')], check=True)

with tempfile.TemporaryDirectory(prefix='ntfs-025-dmg-') as folder:
    stage = Path(folder) / 'NTFS Editor'
    stage.mkdir()
    subprocess.run(['ditto', str(APP), str(stage / APP.name)], check=True)
    subprocess.run(['ditto', str(HELPER), str(stage / HELPER.name)], check=True)
    (stage / 'Applications').symlink_to('/Applications')
    (stage / 'INSTALL-KERNEL.md').write_bytes((ROOT / 'INSTALL-KERNEL.md').read_bytes())
    subprocess.run(['hdiutil', 'create', '-volname', 'NTFS Editor 0.2.5', '-srcfolder', str(stage),
                    '-format', 'UDZO', '-fs', 'HFS+', str(OUTPUT)], check=True)

subprocess.run(['hdiutil', 'verify', str(OUTPUT)], check=True)
print(f"Successfully generated: {OUTPUT}")

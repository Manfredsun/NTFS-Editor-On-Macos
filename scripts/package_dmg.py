#!/usr/bin/env python3
"""Build the 0.2.5 packaging revision without replacing the original DMG."""
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / '.build/Packaging025/Build/Products/Release/NTFS Editor.app'
HELPER = ROOT / 'Dependencies/Install NTFS Editor Mount Helper 0.2.5.pkg'
MACFUSE = ROOT / 'Dependencies/Install macFUSE 5.5.0.pkg'
OUTPUT = ROOT / 'Build/NTFS Editor-0.2.5-install-revision.dmg'
MACFUSE_SHA256 = '5acf9e30bab227707de8d15eb28472a0cc9ed45709846b3e067d283294dc7f9e'

if OUTPUT.exists():
    raise SystemExit(f'Refusing to overwrite {OUTPUT}')
for path in (APP, HELPER, MACFUSE):
    if not path.exists():
        raise SystemExit(f'Missing required input: {path}')
if hashlib.sha256(MACFUSE.read_bytes()).hexdigest() != MACFUSE_SHA256:
    raise SystemExit('macFUSE installer checksum does not match the verified official package')
info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleShortVersionString') != '0.2.5' or info.get('CFBundleIconFile') != 'AppIcon':
    raise SystemExit('App version or icon configuration is incorrect')
if not (APP / 'Contents/Resources/AppIcon.icns').is_file():
    raise SystemExit('App icon resource is missing')

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
subprocess.run(['pkgutil', '--check-signature', str(MACFUSE)], check=True)
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='ntfs-025-package-') as folder:
    root = Path(folder)
    expanded = root / 'macfuse-expanded'
    subprocess.run(['pkgutil', '--expand', str(MACFUSE), str(expanded)], check=True)
    license_file = expanded / 'Resources/License.rtf'
    if not license_file.is_file():
        raise SystemExit('Official macFUSE license is missing')
    stage = root / 'NTFS Editor'
    stage.mkdir()
    for source in (APP, HELPER, MACFUSE):
        subprocess.run(['ditto', str(source), str(stage / source.name)], check=True)
    (stage / 'Applications').symlink_to('/Applications')
    (stage / 'INSTALL-KERNEL.md').write_bytes((ROOT / 'INSTALL-KERNEL.md').read_bytes())
    (stage / 'macFUSE License.rtf').write_bytes(license_file.read_bytes())
    subprocess.run(['hdiutil', 'create', '-volname', 'NTFS Editor 0.2.5', '-srcfolder', str(stage),
                    '-format', 'UDZO', '-fs', 'HFS+', str(OUTPUT)], check=True)
subprocess.run(['hdiutil', 'verify', str(OUTPUT)], check=True)
print(f'Successfully generated: {OUTPUT}')

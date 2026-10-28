#!/usr/bin/env python3
"""Build a local, unsigned administrator-installed helper package; never installs it."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / '.build/HelperPackage/Payload'
DEST = STAGE / 'Library/PrivilegedHelperTools/local.NTFSEditor.mount'
ENGINE = ROOT / '.build/Engine'
if STAGE.exists():
    shutil.rmtree(STAGE)  # This directory is solely owned by this packaging script.
for directory in [DEST, DEST / 'engine/bin', DEST / 'engine/lib', DEST / 'licenses', DEST / 'logs', DEST / 'records']:
    directory.mkdir(parents=True, exist_ok=True)
    directory.chmod(0o700 if directory.name == 'logs' else 0o755)
shutil.copy2(ROOT / '.build/Kernel025/Build/Products/Release/NTFSEditorMountHelper', DEST / 'NTFSEditorMountHelper')
(DEST / 'NTFSEditorMountHelper').chmod(0o755)
for name in ['ntfs-3g', 'ntfs-3g.probe']:
    shutil.copy2(ENGINE / 'bin' / name, DEST / 'engine/bin' / name)
for name in ['libntfs-3g.91.dylib', 'libintl.8.dylib']:
    shutil.copy2(ENGINE / 'lib' / name, DEST / 'engine/lib' / name)
# Copy the verified official library into the protected helper tree. Never execute
# root code linked to Homebrew's user-writable /usr/local/lib directory.
shutil.copy2(ROOT / '.build/Dependencies/macfuse-550-expanded.noindex/Core.pkg/Payload/usr/local/lib/libfuse.2.dylib',
             DEST / 'engine/lib/libfuse.2.dylib')
for binary in (DEST / 'engine/bin').iterdir():
    subprocess.run(['install_name_tool', '-change', '/usr/local/lib/libfuse.2.dylib',
                    '@loader_path/../lib/libfuse.2.dylib', str(binary)], check=True)
for library in (DEST / 'engine/lib').iterdir():
    library.chmod(0o644)
    subprocess.run(['install_name_tool', '-id', '@loader_path/' + library.name, str(library)], check=True)
for binary in list((DEST / 'engine/bin').iterdir()) + list((DEST / 'engine/lib').iterdir()):
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
for license_file in (ENGINE / 'licenses').iterdir():
    if license_file.is_file():
        shutil.copy2(license_file, DEST / 'licenses' / license_file.name)
shutil.copy2(ROOT / '.build/Dependencies/macfuse-550-expanded.noindex/Core.pkg/Payload/Library/Filesystems/macfuse.fs/Contents/Resources/License.rtf',
             DEST / 'licenses/macfuse-License.rtf')
manifest = {str(path.relative_to(DEST / 'engine')): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (DEST / 'engine').glob('*/*') if path.is_file()}
(DEST / 'engine-sha256.json').write_text(json.dumps(manifest, indent=2) + '\n')
(DEST / 'engine-version.txt').write_text('2026.9.28\n')
(DEST / 'helper-version.txt').write_text('0.2.5\n')
for file in DEST.glob('*.*'):
    file.chmod(0o644)
(DEST / 'NTFSEditorMountHelper').chmod(0o755)
SCRIPTS = ROOT / '.build/HelperPackage/Scripts'
SCRIPTS.mkdir(parents=True, exist_ok=True)
preinstall = SCRIPTS / 'preinstall'
preinstall.write_text('''#!/bin/sh
# Refuse helper updates while an NTFS Editor managed filesystem is mounted.
if /sbin/mount | /usr/bin/awk 'index($0, " on /Volumes/NTFSEditor-") { found=1 } END { exit !found }'; then
    echo "Unmount NTFS Editor managed volumes before installing this update." >&2
    exit 1
fi
exit 0
''')
preinstall.chmod(0o755)
output = ROOT / 'Dependencies/Install NTFS Editor Mount Helper 0.2.5.pkg'
subprocess.run(['pkgbuild', '--root', str(STAGE), '--scripts', str(SCRIPTS), '--ownership', 'recommended',
                '--identifier', 'local.NTFSEditor.mount', '--version', '0.2.5', '--install-location', '/', str(output)], check=True)
print(output)

#!/usr/bin/env python3
"""Write/read only a newly-created disposable image, never a /dev device."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / '.build/Engine/bin'
TEST_ROOT = ROOT / '.build/ReadWriteTests'
TEST_ROOT.mkdir(parents=True, exist_ok=True)
if TEST_ROOT.is_symlink() or TEST_ROOT.resolve() != TEST_ROOT:
    raise RuntimeError('Test directory must be local and must not be a symlink')
run = TEST_ROOT / str(uuid.uuid4())
run.mkdir()
image = run / 'disposable.ntfs'
fd = os.open(image, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
try:
    os.ftruncate(fd, 128 * 1024 * 1024)
finally:
    os.close(fd)

def invoke(tool, arguments, expected=0):
    result = subprocess.run([str(TOOLS / tool), *map(str, arguments)], capture_output=True,
                            env={'PATH': '/usr/bin:/bin', 'LANG': 'C'}, timeout=60)
    if result.returncode != expected:
        raise RuntimeError(f'{tool}: {result.returncode}: {result.stderr.decode(errors="replace")}')
    return result

# --force here only tells mkntfs that this NEW REGULAR FILE is an image, not a block device.
# This script never accepts an image path or device argument from the caller.
invoke('mkntfs', ['--force', '--fast', '--label', 'NTFSEditorTest', image])
invoke('ntfs-3g.probe', ['--readwrite', image])
first = b'NTFS Editor disposable image test\n' + bytes(range(256)) * 4096
second = b'Updated by NTFS Editor engine test\n' + bytes(range(255, -1, -1)) * 8192
source = run / 'payload.bin'
checks = []
for name, data in [('create', first), ('overwrite', second)]:
    source.write_bytes(data)
    invoke('ntfscp', [image, source, '/ntfs-editor-test.bin'])
    readback = invoke('ntfscat', [image, '/ntfs-editor-test.bin']).stdout
    assert readback == data, 'Byte-for-byte readback mismatch'
    checks.append({'operation': name, 'bytes': len(data), 'sha256': hashlib.sha256(readback).hexdigest()})
invoke('ntfs-3g.probe', ['--readwrite', image])
invoke('ntfsfix', ['--no-action', image])
report = {'image': str(image), 'engine': 'NTFS-3G 2026.9.28', 'checks': checks,
          'probe_before_after': 'exit 0', 'ntfsfix': 'no-action only',
          'not_verified': ['FSKit mount', 'Finder writes', 'rename/delete', 'physical disk', 'Windows readback']}
(ROOT / 'Evidence/Phase2/image-engine-test.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))

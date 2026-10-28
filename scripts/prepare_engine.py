#!/usr/bin/env python3
"""Prepare verified, private arm64 test tools. Does not install system components."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.build/Dependencies'
ENGINE = ROOT / '.build/Engine'
CACHE.mkdir(parents=True, exist_ok=True)
(ENGINE / 'bin').mkdir(parents=True, exist_ok=True)
(ENGINE / 'lib').mkdir(exist_ok=True)
(ENGINE / 'licenses').mkdir(exist_ok=True)
manifest = []

def fetch(url, headers=()):
    args = ['/usr/bin/curl', '-fsSL', '--proto', '=https', '--tlsv1.2']
    for h in headers:
        args.extend(['-H', h])
    return subprocess.check_output(args + [url])

def bottle(name, repo, digest):
    archive = CACHE / (name + '.tar.gz')
    if not archive.exists():
        token_url = 'https://ghcr.io/token?' + urllib.parse.urlencode({'service': 'ghcr.io', 'scope': f'repository:{repo}:pull'})
        token = json.loads(fetch(token_url))['token']
        archive.write_bytes(fetch(f'https://ghcr.io/v2/{repo}/blobs/sha256:{digest}', ['Authorization: Bearer ' + token]))
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != digest:
        raise RuntimeError('Checksum mismatch: ' + name)
    destination = CACHE / (name + '-extracted')
    destination.mkdir(exist_ok=True)
    with tarfile.open(archive) as tar:
        tar.extractall(destination, filter='data')
    manifest.append({'name': name, 'sha256': digest, 'source': f'https://ghcr.io/v2/{repo}/blobs/sha256:{digest}'})
    return destination

ntfs = bottle('ntfs-3g-mac-2026.9.28', 'gromgit/fuse/ntfs-3g-mac', 'e619abaf184a287e2e2e76ed81450fc1c10b4ca782243b60bdd11c874d8ba640')
for package in ['gettext']:
    metadata = json.loads(fetch(f'https://formulae.brew.sh/api/formula/{package}.json'))
    digest = metadata['bottle']['stable']['files']['arm64_sequoia']['sha256']
    root = bottle(package, 'homebrew/core/' + package, digest)
    for library in root.glob('**/lib/*.dylib'):
        if library.name == 'libintl.8.dylib':
            shutil.copy2(library, ENGINE / 'lib' / library.name)
    for license_file in root.glob('**/LICENSE*'):
        if license_file.is_file():
            shutil.copy2(license_file, ENGINE / 'licenses' / (package + '-' + license_file.name))

prefix = ntfs / 'ntfs-3g-mac/2026.9.28'
for tool in ['ntfs-3g', 'ntfs-3g.probe', 'ntfscat', 'ntfsfix', 'ntfsinfo']:
    shutil.copy2(prefix / 'bin' / tool, ENGINE / 'bin' / tool)
for tool in ['mkntfs', 'ntfscp']:
    shutil.copy2(prefix / 'sbin' / tool, ENGINE / 'bin' / tool)
for library in (prefix / 'lib').glob('*.dylib'):
    shutil.copy2(library, ENGINE / 'lib' / library.name)
for name in ['COPYING', 'COPYING.LIB']:
    shutil.copy2(prefix / name, ENGINE / 'licenses' / ('ntfs-3g-' + name))

libraries = {p.name: p for p in (ENGINE / 'lib').glob('*.dylib')}
for executable in list((ENGINE / 'bin').iterdir()) + list(libraries.values()):
    dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(executable)], text=True).splitlines()[1:]
    if executable.parent.name == 'lib':
        subprocess.run(['/usr/bin/install_name_tool', '-id', '@loader_path/' + executable.name, str(executable)], check=True)
    for line in dependencies:
        original = line.strip().split(' (')[0]
        leaf = Path(original).name
        if leaf in libraries:
            relative = '@loader_path/' + ('../lib/' if executable.parent.name == 'bin' else '') + leaf
            subprocess.run(['/usr/bin/install_name_tool', '-change', original, relative, str(executable)], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(executable)], check=True)
(ROOT / 'Evidence/Phase2/engine-dependencies.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Prepared private arm64 tools:', ENGINE)

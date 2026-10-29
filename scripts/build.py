#!/usr/bin/env python3
"""Validate and reproducibly package the public mod; never package server data."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MOD_FILES = ('info.json', 'settings.lua', 'pause.lua', 'context_export.lua',
             'control.lua', 'map_detail.lua', 'changelog.txt')
VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')


def version_tuple(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError('Version must have three numeric components')
    parts = tuple(map(int, value.split('.')))
    if any(part > 65535 for part in parts):
        raise ValueError('Version component exceeds 65535')
    return parts


def release_files(root=ROOT, tag=None):
    mod = root / 'mod'
    metadata = json.loads((mod / 'info.json').read_text())
    if not re.fullmatch(r'[A-Za-z0-9_-]{4,49}', metadata.get('name', '')):
        raise ValueError('Invalid Portal mod name')
    version_tuple(metadata.get('version'))
    if metadata.get('factorio_version') != '2.1':
        raise ValueError('This release targets Factorio 2.1')
    for field in ('title', 'author', 'description'):
        if not isinstance(metadata.get(field), str) or not metadata[field].strip():
            raise ValueError('Missing metadata: ' + field)
    if metadata.get('dependencies') != ['base >= 2.1.23']:
        raise ValueError('Expected explicit supported base dependency')
    if tag is not None and tag != 'v' + metadata['version']:
        raise ValueError('Tag must match info.json version')
    files = {name: mod / name for name in MOD_FILES}
    files.update({'LICENSE': root / 'LICENSE', 'README.md': root / 'README.md'})
    for path in (mod / 'locale').rglob('*.cfg') if (mod / 'locale').is_dir() else ():
        files[path.relative_to(mod).as_posix()] = path
    if (mod / 'thumbnail.png').exists():
        files['thumbnail.png'] = mod / 'thumbnail.png'
    payload = {}
    for name, path in sorted(files.items()):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing regular release file: ' + name)
        # Reject parent-directory symlinks as well as direct symlinks.
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Release file escapes project')
        data = path.read_bytes()
        if not data:
            raise ValueError('Empty release file: ' + name)
        if name != 'thumbnail.png':
            text = data.decode('utf-8')
            if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{20,}', text):
                raise ValueError('Possible credential in release file: ' + name)
        payload[name] = data
    versions = re.findall(r'^Version:\s*(\S+)\s*$', payload['changelog.txt'].decode(), re.M)
    if not versions or versions[0] != metadata['version']:
        raise ValueError('Latest changelog entry must match release')
    return metadata, payload


def archive_bytes(root=ROOT, tag=None):
    metadata, files = release_files(root, tag)
    prefix = metadata['name'] + '_' + metadata['version']
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(prefix + '/' + name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data, compresslevel=9)
    return prefix + '.zip', output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--tag')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not args.check and args.output is None:
        parser.error('Use --check or --output DIRECTORY')
    try:
        name, data = archive_bytes(tag=args.tag)
        if args.output:
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / name).write_bytes(data)
            (args.output / (name + '.sha256')).write_text(hashlib.sha256(data).hexdigest() + '  ' + name + '\n')
        print('Validated ' + name + '; SHA256 ' + hashlib.sha256(data).hexdigest())
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, 'Build failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()

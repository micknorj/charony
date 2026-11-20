#!/usr/bin/env python3
"""Record CI build context and inspect its IPA; does not infer an arbitrary IPA's source."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import zipfile

from verify_ipa import verify

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_MARKERS = [b'CHFixture', b'CHObservedTabs', b'ui-phase.log', b'Fixture blocking alert']


def inspect_executable(data):
    if len(data) < 32 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x100000c):
        raise ValueError('Expected one arm64 Mach-O executable')
    _, _, _, kind, count, command_bytes, _, _ = struct.unpack_from('<IiiIIIII', data)
    if kind != 2 or 32 + command_bytes > len(data):
        raise ValueError('Invalid executable load commands')
    offset = 32
    build = entitlements = flags = None
    for _ in range(count):
        if offset + 8 > 32 + command_bytes:
            raise ValueError('Truncated load command')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > 32 + command_bytes:
            raise ValueError('Invalid load-command size')
        if command == 0x32:
            if size < 24:
                raise ValueError('Truncated build-version command')
            platform, minimum, sdk = struct.unpack_from('<III', data, offset + 8)
            if platform != 2:
                raise ValueError('Expected a device iOS executable')
            version = lambda value: f'{value >> 16}.{(value >> 8) & 255}.{value & 255}'
            build = {'minimum_os': version(minimum), 'sdk': version(sdk)}
        if command == 0x1d:
            if size < 16:
                raise ValueError('Truncated signature command')
            start, length = struct.unpack_from('<II', data, offset + 8)
            blob = data[start:start + length]
            if len(blob) != length or len(blob) < 12:
                raise ValueError('Truncated signature')
            magic, blob_length, slots = struct.unpack_from('>III', blob)
            if magic != 0xfade0cc0 or blob_length > length or blob_length < 12 or 12 + slots * 8 > blob_length or any(blob[blob_length:]):
                raise ValueError('Invalid signature container')
            for index in range(slots):
                _, relative = struct.unpack_from('>II', blob, 12 + index * 8)
                if relative + 8 > blob_length:
                    raise ValueError('Invalid signature slot')
                item_magic, item_size = struct.unpack_from('>II', blob, relative)
                if item_size < 8 or relative + item_size > blob_length:
                    raise ValueError('Invalid signature item')
                if item_magic == 0xfade7171:
                    entitlements = plistlib.loads(blob[relative + 8:relative + item_size])
                if item_magic == 0xfade0c02:
                    if item_size < 16:
                        raise ValueError('Truncated code directory')
                    flags = struct.unpack_from('>I', blob, relative + 12)[0]
        offset += size
    if offset != 32 + command_bytes:
        raise ValueError('Load-command table is inconsistent')
    expected = plistlib.loads((ROOT / 'entitlements.plist').read_bytes())
    if not build or build['minimum_os'] != '26.0.0' or entitlements != expected or flags is None or not flags & 2:
        raise ValueError('Development architecture, deployment, entitlement or ad-hoc policy mismatch')
    if any(marker in data for marker in FIXTURE_MARKERS):
        raise ValueError('Development fixture present in shipping executable')
    return {'architecture': 'arm64', **build, 'entitlements': entitlements, 'signing': 'ad-hoc'}


def create_manifest(ipa):
    verify(ipa)
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=ROOT).strip():
        raise ValueError('Source checkout is not clean; do not attribute this IPA to a commit')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=ROOT, text=True).strip()
    with zipfile.ZipFile(ipa) as archive:
        prefix = 'Payload/charony.app/'
        if any(name.endswith('embedded.mobileprovision') for name in archive.namelist()):
            raise ValueError('Unexpected provisioning material in development artifact')
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        binary = archive.read(prefix + 'charony')
        catalog_hash = hashlib.sha256(archive.read(prefix + 'Assets.car')).hexdigest()
    return {'format_version': 1, 'source_commit': commit, 'source_tree': tree,
            'bundle_id': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'ipa_sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
            'executable_sha256': hashlib.sha256(binary).hexdigest(), 'assets_sha256': catalog_hash,
            'embedded_provisioning_profile': False, **inspect_executable(binary)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    args = parser.parse_args()
    manifest = create_manifest(args.ipa)
    (args.ipa.parent / 'charony-build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (args.ipa.parent / 'charony.ipa.sha256').write_text(manifest['ipa_sha256'] + '  ' + args.ipa.name + '\n')
    print(json.dumps(manifest, indent=2))

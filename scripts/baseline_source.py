#!/usr/bin/env python3
"""Verify and unpack the stable upstream test source without importing Git history."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
MAX_ARCHIVE = 64 * 1024 * 1024


def manifest():
    return json.loads((ROOT / 'tests/upstream-baseline.json').read_text())


def unpack(archive, destination, policy):
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError('Baseline destination must not exist')
    if hashlib.sha256(Path(archive).read_bytes()).hexdigest() != policy['archive_sha256']:
        raise ValueError('Stable baseline archive checksum mismatch')
    records = {}
    prefix = None
    with tarfile.open(archive, 'r:gz') as source:
        for entry in source:
            parts = entry.name.rstrip('/').split('/')
            if any(part in ('', '.', '..') or '\\' in part for part in parts):
                raise ValueError('Unsafe baseline archive path')
            if prefix is None:
                prefix = parts[0]
            if parts[0] != prefix or not (entry.isdir() or entry.isfile()):
                raise ValueError('Unexpected baseline archive root or entry type')
            if entry.isdir():
                continue
            relative = '/'.join(parts[1:])
            expected = policy['files'].get(relative)
            if expected is None or relative in records:
                raise ValueError('Unexpected or duplicate baseline file')
            if entry.size != expected['size'] or entry.mode & 0o111 != expected['mode'] & 0o111:
                raise ValueError('Baseline size or executable mode mismatch')
            contents = source.extractfile(entry).read()
            if hashlib.sha256(contents).hexdigest() != expected['sha256']:
                raise ValueError('Baseline file checksum mismatch')
            records[relative] = contents
    if set(records) != set(policy['files']):
        raise ValueError('Missing stable baseline files')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.baseline-', dir=destination.parent) as temporary:
        staged = Path(temporary) / 'source'
        staged.mkdir()
        for relative, contents in records.items():
            output = staged / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(contents)
            output.chmod(policy['files'][relative]['mode'])
        if destination.exists() or destination.is_symlink():
            raise ValueError('Baseline destination appeared during verification')
        os.rename(staged, destination)


def prepare(destination, archive=None):
    policy = manifest()
    if archive is None:
        archive = ROOT / '.work/baseline' / (policy['commit'] + '.tar.gz')
        if not archive.exists():
            archive.parent.mkdir(parents=True, exist_ok=True)
            with urlopen(policy['archive_url'], timeout=60) as response:
                contents = response.read(MAX_ARCHIVE + 1)
            if len(contents) > MAX_ARCHIVE or hashlib.sha256(contents).hexdigest() != policy['archive_sha256']:
                raise ValueError('Downloaded stable baseline size/checksum mismatch')
            archive.write_bytes(contents)
    unpack(archive, destination, policy)
    print(f'Verified {len(policy["files"])} stable source files from {policy["commit"]}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--archive', type=Path)
    arguments = parser.parse_args()
    prepare(arguments.destination, arguments.archive)

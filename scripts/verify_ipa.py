#!/usr/bin/env python3
"""Validate the produced package and metadata without extracting archive paths."""
import plistlib
from pathlib import Path
import stat
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def verify(path):
    expected = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate archive entries')
        prefix = 'Payload/charony.app/'
        for entry in archive.infolist():
            name = entry.filename
            if not (name == 'Payload/' or name.startswith(prefix)):
                raise ValueError(f'Unexpected package entry {name}')
            components = name.rstrip('/').split('/')
            if any(part in ('', '.', '..') for part in components) or '\\' in name:
                raise ValueError('Unsafe archive path')
            mode = entry.external_attr >> 16
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('Archive contains a link or special file')
            if any(part.endswith('.lproj') for part in components) or name.endswith(('.wqtheme', '.js')):
                raise ValueError('Obsolete resource')
        required = {prefix + name for name in ['charony', 'Info.plist', 'Assets.car', 'LICENSE', 'NOTICE.md']}
        if not required.issubset(names):
            raise ValueError('Package misses executable, assets or legal notices')
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        for key, value in expected.items():
            if info.get(key) != value:
                raise ValueError(f'Metadata mismatch for {key}')
        for key in ['NSLocalNetworkUsageDescription', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations',
                    'UIFileSharingEnabled', 'LSSupportsOpeningDocumentsInPlace']:
            if key in info:
                raise ValueError(f'Obsolete permission or registration {key}')
        if info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'] != 'AppIcon':
            raise ValueError('Compiled icon metadata missing')
        if not (archive.getinfo(prefix + 'charony').external_attr >> 16) & 0o111:
            raise ValueError('App executable has no execute permission')
        if archive.testzip():
            raise ValueError('Archive CRC failed')

if __name__ == '__main__':
    verify(Path(sys.argv[1]))
    print('IPA package and metadata checks passed')

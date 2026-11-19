"""Command doubles for packaging tests. These never validate Apple binaries."""
from pathlib import Path

TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
failure = os.environ.get('CH_FIXTURE_FAIL', '')
log = os.environ.get('CH_FIXTURE_LOG')
if log:
    with open(log, 'a') as stream:
        stream.write(json.dumps([name, *args]) + '\n')

def fail(phase):
    if failure == phase:
        raise SystemExit('injected ' + phase + ' failure')

def value_text(value):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    return str(value)

if name == 'plutil':
    path = Path(args[-1])
    value = plistlib.loads(path.read_bytes())
    if args[0] == '-extract':
        for key in args[1].split('.'):
            value = value[int(key)] if isinstance(value, list) else value[key]
        print(value_text(value))
    elif args[0] == '-convert':
        data = plistlib.dumps(value, fmt=plistlib.FMT_BINARY if args[1] == 'binary1' else plistlib.FMT_XML)
        if '-o' in args:
            destination = args[args.index('-o') + 1]
            if destination == '-':
                sys.stdout.buffer.write(data)
            else:
                Path(destination).write_bytes(data)
        else:
            path.write_bytes(data)
    elif args[0] != '-lint':
        raise SystemExit('unexpected plutil arguments')
elif name == 'PlistBuddy':
    command = args[1]
    path = Path(args[2])
    value = plistlib.loads(path.read_bytes())
    verb, _, operand = command.partition(' ')
    if verb == 'Print':
        for key in operand.lstrip(':').split(':'):
            value = value[int(key)] if isinstance(value, list) else value[key]
        print(value_text(value))
    elif verb == 'Merge':
        value.update(plistlib.loads(Path(operand.strip("'\"")).read_bytes()))
        path.write_bytes(plistlib.dumps(value))
    elif verb == 'Delete':
        del value[operand.lstrip(':')]
        path.write_bytes(plistlib.dumps(value))
    else:
        raise SystemExit('unexpected PlistBuddy command')
elif name == 'xcrun':
    if '--show-sdk-path' in args:
        print('/fixture-sdk')
    elif 'clang' in args:
        fail('compile')
        output = Path(args[args.index('-o') + 1])
        output.write_text('#!/bin/sh\nexit 0\n')
        output.chmod(0o755)
    elif 'lipo' in args:
        print('x86_64' if failure == 'architecture' else 'arm64')
    elif args[0] == 'actool':
        fail('assets')
        destination = Path(args[args.index('--compile') + 1])
        assert (Path(args[1]) / 'AppIcon.appiconset' / 'Charon.png').exists()
        if failure != 'missing-assets':
            (destination / 'Assets.car').write_bytes(b'fixture asset catalog')
        partial = Path(args[args.index('--output-partial-info-plist') + 1])
        partial.write_bytes(plistlib.dumps({'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}}))
    else:
        raise SystemExit('unexpected xcrun arguments')
elif name == 'sips':
    shutil.copyfile(args[3], args[args.index('--out') + 1])
elif name == 'codesign':
    app = Path(args[-1])
    if args[0] == '--force':
        fail('sign')
        entitlements = plistlib.loads(Path(args[args.index('--entitlements') + 1]).read_bytes())
        if failure == 'entitlements':
            entitlements = {}
        if failure == 'lookalike-group':
            entitlements['com.apple.security.application-groups'][0] += '.wrong'
        (app / '.fixture-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
        (app / '_CodeSignature').mkdir()
        (app / '_CodeSignature' / 'CodeResources').write_text('fixture signature')
    elif args[0] == '--verify':
        fail('verify_unpacked' if 'unpacked' in app.parts else 'verify')
        assert (app / 'charony').stat().st_mode & 0o111
        assert (app / '_CodeSignature' / 'CodeResources').exists()
    elif args[0] == '-d':
        sys.stdout.buffer.write((app / '.fixture-entitlements.plist').read_bytes())
    else:
        raise SystemExit('unexpected codesign arguments')
elif name == 'nm':
    print('_NSLog' if failure == 'privacy' else '_fixture_import')
elif name == 'strings':
    print('fixture binary')
elif name == 'zip':
    fail('zip')
    if failure == 'package':
        path = Path('Payload/charony.app/Info.plist')
        value = plistlib.loads(path.read_bytes())
        value['CFBundleIdentifier'] = 'wrong.fixture'
        path.write_bytes(plistlib.dumps(value))
    os.execv('/usr/bin/zip', ['zip', *args])
else:
    raise SystemExit('unexpected tool ' + name)
'''


def install_tools(directory):
    directory.mkdir()
    for name in ['plutil', 'PlistBuddy', 'xcrun', 'sips', 'codesign', 'nm', 'strings', 'zip']:
        path = directory / name
        path.write_text(TOOL)
        path.chmod(0o755)

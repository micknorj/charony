#!/usr/bin/env python3
"""Verify the pinned CI toolchain before running any native validation."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
XCODE_VERSION = '26.2'
DEVELOPER_DIR = '/Applications/Xcode_26.2.app/Contents/Developer'
IOS_VERSION = (26, 0)
SDK_VERSION = (26, 2)
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
IPAD_DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB'


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', value):
        raise ValueError(f'Invalid toolchain version {value!r}')
    return tuple(int(part) for part in value.split('.'))


def inspect_toolchain(run, minimum_os, simulator=False):
    if version(minimum_os)[:2] != IOS_VERSION:
        raise ValueError('The reviewed deployment target must remain iOS 26.0')
    xcode = run(['xcodebuild', '-version'])
    if not re.fullmatch(r'Xcode ' + re.escape(XCODE_VERSION) + r'\nBuild version [A-Za-z0-9]+', xcode):
        raise ValueError(f'Expected pinned Xcode {XCODE_VERSION}, found {xcode!r}')
    report = {'xcode': xcode, 'deployment_target': minimum_os, 'sdks': {}}
    processors = int(run(['sysctl', '-n', 'hw.activecpu']))
    # Upstream's unchanged fixture uses utility mode (cores / 2). Charony's
    # fixture explicitly requests parallel mode, which provides two workers.
    minimum_processors = 2 if simulator else 4
    if processors < minimum_processors:
        raise ValueError(f'Native interruption fixtures require at least {minimum_processors} active CPUs')
    report['active_processors'] = processors
    report['minimum_processors'] = minimum_processors
    for sdk in ['macosx', 'iphoneos', 'iphonesimulator']:
        sdk_version = run(['xcrun', '--sdk', sdk, '--show-sdk-version'])
        if sdk != 'macosx' and version(sdk_version)[:2] != SDK_VERSION:
            raise ValueError(f'{sdk} SDK must match the reviewed iOS 26.2 toolchain, found {sdk_version}')
        version(sdk_version)
        path = run(['xcrun', '--sdk', sdk, '--show-sdk-path'])
        if not path:
            raise ValueError(f'{sdk} SDK path is empty')
        report['sdks'][sdk] = {'version': sdk_version, 'path': path}
    if simulator:
        runtimes = json.loads(run(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
        devices = json.loads(run(['xcrun', 'simctl', 'list', 'devicetypes', '--json']))['devicetypes']
        candidates = [runtime for runtime in runtimes
                      if runtime.get('isAvailable') is True
                      and re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-26-2(?:-\d+)?',
                                       runtime.get('identifier', ''))
                      and version(runtime.get('version'))[:2] == SDK_VERSION]
        if not candidates:
            raise ValueError('No available iOS 26.2 simulator runtime. Installed inventory was printed above')
        for required in [DEVICE_TYPE, IPAD_DEVICE_TYPE]:
            if not any(device.get('identifier') == required for device in devices):
                raise ValueError(f'Required simulator device type is unavailable: {required}')
        selected = max(candidates, key=lambda item: version(item['version']))
        report['simulator_runtime'] = selected['identifier']
        report['simulator_runtime_version'] = selected['version']
        report['simulator_device_type'] = DEVICE_TYPE
        report['simulator_ipad_device_type'] = IPAD_DEVICE_TYPE
    return report


def command(arguments):
    # CoreSimulator's first inventory query can spend its timeout starting the
    # hosted service. Retry only this read-only setup query, once. A second
    # timeout, command error or invalid inventory remains a hard failure.
    attempts = 2 if arguments[:3] == ['xcrun', 'simctl', 'list'] else 1
    for attempt in range(attempts):
        print('$ ' + ' '.join(arguments), flush=True)
        try:
            result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=60, check=False)
        except subprocess.TimeoutExpired:
            if attempt + 1 == attempts:
                raise
            print('CoreSimulator inventory timed out; retrying once without skipping validation.', flush=True)
            continue
        print(result.stdout, end='' if result.stdout.endswith('\n') else '\n', flush=True)
        result.check_returncode()
        return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--simulator', action='store_true')
    args = parser.parse_args()
    if os.environ.get('DEVELOPER_DIR') != DEVELOPER_DIR or not Path(DEVELOPER_DIR).is_dir():
        installed = sorted(str(path) for path in Path('/Applications').glob('Xcode*.app'))
        raise ValueError(f'Pinned {DEVELOPER_DIR} is required. Installed Xcodes: {installed}')
    if os.environ.get('WQ_SKIP_IOS_CHECK', '0') != '0':
        raise ValueError('CI must run the strict iOS checks')
    for tool in ['bash', 'git', 'python3', 'zip', 'unzip', 'codesign', 'plutil', 'sips', 'xcrun', 'xcodebuild', 'sysctl']:
        if not shutil.which(tool):
            raise ValueError(f'Required CI command is unavailable: {tool}')
    minimum = plistlib.loads((ROOT / 'Info.plist').read_bytes())['MinimumOSVersion']
    report = inspect_toolchain(command, minimum, args.simulator)
    for sdk, details in report['sdks'].items():
        if not Path(details['path']).is_dir():
            raise ValueError(f'{sdk} SDK directory does not exist: {details["path"]}')
    report['runner_image'] = {key: os.environ.get(key, '') for key in ['ImageOS', 'ImageVersion', 'RUNNER_ARCH']}
    output = ROOT / '.ci-results'
    output.mkdir(exist_ok=True)
    (output / 'toolchain.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.simulator and os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as stream:
            for key in ['simulator_runtime', 'simulator_device_type', 'simulator_ipad_device_type']:
                stream.write(f'{key}={report[key]}\n')
    print('Pinned Xcode, SDK and requested simulator availability checks passed')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f'CI toolchain preflight failed: {error}')

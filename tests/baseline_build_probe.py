#!/usr/bin/env python3
"""Diagnose stable build fixtures using explicit plist-tool adapters on Linux.

Compiler, asset and signature doubles come from upstream's fixture tests.
This probe provides no native build or Apple signature validation evidence.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import importlib.util

from fixture_tools import install_tools

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('baseline_source', ROOT / 'scripts/baseline_source.py')
BASELINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASELINE)


def main():
    with tempfile.TemporaryDirectory(prefix='charony-baseline-probe-') as directory:
        workspace = Path(directory)
        source = workspace / 'stable'
        BASELINE.prepare(source)
        tools = workspace / 'tools'
        install_tools(tools)
        build = source / 'build.sh'
        build.write_text(build.read_text().replace('/usr/libexec/PlistBuddy', 'PlistBuddy'))
        tests = source / 'tests/test_build.py'
        tests.write_text(tests.read_text().replace('/usr/bin/plutil', 'plutil'))
        environment = os.environ.copy()
        environment['PATH'] = str(tools) + os.pathsep + environment['PATH']
        environment['PYTHONDONTWRITEBYTECODE'] = '1'
        environment.pop('CH_FIXTURE_FAIL', None)
        environment.pop('CH_FIXTURE_LOG', None)
        print('Stable build fixtures with plist command adapters. Native compilation/signing remain unverified.', flush=True)
        return subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_build.py', '-v'],
                              cwd=source, env=environment).returncode


if __name__ == '__main__':
    raise SystemExit(main())

"""Exercise the real build orchestration with command doubles and real ZIP/plist I/O."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

from fixture_tools import install_tools

ROOT = Path(__file__).resolve().parents[1]


class BuildPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.project = self.base / 'project with spaces'
        self.project.mkdir()
        for source in [ROOT / 'build.sh', ROOT / 'Info.plist', ROOT / 'entitlements.plist', ROOT / 'LICENSE', ROOT / 'NOTICE.md', *ROOT.glob('*.[mh]')]:
            shutil.copy2(source, self.project / source.name)
        for directory in ['scripts', 'icons']:
            shutil.copytree(ROOT / directory, self.project / directory, ignore=shutil.ignore_patterns('__pycache__'))
        (self.project / 'tests').mkdir()
        self.runner = self.project / 'tests/run_all_tests.sh'
        self.runner.write_text('touch "$CH_PREFLIGHT_MARKER"\n')
        tools = self.base / 'tools'
        install_tools(tools)
        self.events_path = self.base / 'events.jsonl'
        self.marker = self.base / 'preflight-marker'
        self.environment = os.environ.copy()
        self.environment.update(PATH=str(tools) + os.pathsep + self.environment['PATH'],
                                CH_FIXTURE_LOG=str(self.events_path), CH_PREFLIGHT_MARKER=str(self.marker),
                                PYTHONDONTWRITEBYTECODE='1')
        self.environment.pop('CHARONY_FINAL_IPA', None)
        self.environment.pop('CH_FIXTURE_FAIL', None)

    def run_build(self):
        return subprocess.run(['bash', 'build.sh'], cwd=self.project, env=self.environment,
                              text=True, capture_output=True, timeout=60)

    def events(self):
        if not self.events_path.exists():
            return []
        return [json.loads(line) for line in self.events_path.read_text().splitlines()]

    def test_successful_pipeline_and_actual_compile_arguments(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertTrue((self.project / 'charony.ipa').is_file())
        clang = next(event for event in self.events() if event[:4] == ['xcrun', '--sdk', 'iphoneos', 'clang'])
        self.assertIn('-miphoneos-version-min=26.0', clang)
        self.assertIn('-Werror', clang)
        self.assertIn('CHAppData.m', clang)
        extraction = next(event for event in self.events() if event[:2] == ['codesign', '-d'])
        self.assertEqual(extraction[2:5], ['--entitlements', '-', '--xml'])
        self.assertFalse(list(self.project.glob('.charony-build.*')))
        self.assertTrue(any('unpacked' in event[-1] for event in self.events() if event[0] == 'codesign' and '--verify' in event))

    def test_preflight_failure_preserves_existing_artifact_and_stops_toolchain(self):
        final = self.project / 'charony.ipa'
        final.write_bytes(b'existing artifact')
        self.runner.write_text('exit 7\n')
        result = self.run_build()
        self.assertEqual(result.returncode, 7)
        self.assertEqual(final.read_bytes(), b'existing artifact')
        self.assertEqual(self.events(), [])

    def test_missing_preflight_fails_closed(self):
        self.runner.unlink()
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertFalse((self.project / 'charony.ipa').exists())

    def test_pipeline_failures_preserve_existing_artifact_and_clean_staging(self):
        for phase in ['compile', 'architecture', 'assets', 'missing-assets', 'privacy', 'sign', 'verify',
                      'entitlements', 'lookalike-group', 'zip', 'package', 'verify_unpacked']:
            with self.subTest(phase=phase):
                self.events_path.unlink(missing_ok=True)
                final = self.project / 'charony.ipa'
                final.write_bytes(b'existing artifact')
                self.environment['CH_FIXTURE_FAIL'] = phase
                result = self.run_build()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(final.read_bytes(), b'existing artifact')
                self.assertTrue(self.marker.exists())
                self.assertFalse(list(self.project.glob('.charony-build.*')))
                events = self.events()
                self.assertTrue(any('clang' in event for event in events))
                if phase in ['compile', 'assets', 'sign', 'verify']:
                    self.assertIn('injected ' + phase + ' failure', result.stderr)
                if phase == 'architecture':
                    self.assertIn('Expected exactly arm64', result.stderr)
                if phase == 'missing-assets':
                    self.assertIn('Asset catalog was not compiled', result.stderr)
                if phase in ['entitlements', 'lookalike-group']:
                    self.assertTrue(any(event[:2] == ['codesign', '-d'] for event in events), result.stderr)
                    self.assertIn('Signed entitlements differ', result.stderr)
                if phase == 'zip':
                    self.assertIn('injected zip failure', result.stderr)
                if phase == 'package':
                    self.assertIn('Metadata mismatch', result.stderr)
                if phase == 'privacy':
                    self.assertIn('binary contains forbidden', result.stderr)
                if phase == 'verify_unpacked':
                    self.assertIn('injected verify_unpacked failure', result.stderr)

    def test_entitlement_gate_survives_python_optimization(self):
        self.environment['CH_FIXTURE_FAIL'] = 'entitlements'
        for optimization in ['1', '2']:
            with self.subTest(optimization=optimization):
                self.environment['PYTHONOPTIMIZE'] = optimization
                final = self.project / 'charony.ipa'
                final.write_bytes(b'existing artifact')
                result = self.run_build()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('Signed entitlements differ', result.stderr)
                self.assertEqual(final.read_bytes(), b'existing artifact')

    def test_final_directory_is_preserved(self):
        destination = self.project / 'charony.ipa'
        destination.mkdir()
        sentinel = destination / 'charony.ipa'
        sentinel.write_bytes(b'unrelated existing file')
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(destination.is_dir())
        self.assertEqual(sentinel.read_bytes(), b'unrelated existing file')
        self.assertFalse(list(self.project.glob('.charony-build.*')))

    def test_separate_output_and_metadata_policy(self):
        destination = self.base / 'output directory'
        destination.mkdir()
        final = destination / 'candidate.ipa'
        self.environment['CHARONY_FINAL_IPA'] = str(final)
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(final.is_file())
        self.assertFalse((self.project / 'charony.ipa').exists())
        info = plistlib.loads((self.project / 'Info.plist').read_bytes())
        info['MinimumOSVersion'] = '27.0'
        (self.project / 'Info.plist').write_bytes(plistlib.dumps(info))
        self.events_path.unlink()
        before = final.read_bytes()
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MinimumOSVersion must remain 26.0', result.stderr)
        self.assertEqual(final.read_bytes(), before)
        self.assertFalse(any('clang' in event for event in self.events()))

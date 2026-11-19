"""Fail-closed CI toolchain selection using explicit command-response fixtures."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('ci_preflight', ROOT / 'scripts/ci_preflight.py')
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)


class CIPreflightTests(unittest.TestCase):
    def setUp(self):
        self.responses = {('xcodebuild', '-version'): 'Xcode 26.2\nBuild version 17C52'}
        self.responses[('sysctl', '-n', 'hw.activecpu')] = '4'
        for sdk in ['macosx', 'iphoneos', 'iphonesimulator']:
            self.responses[('xcrun', '--sdk', sdk, '--show-sdk-version')] = '26.2'
            self.responses[('xcrun', '--sdk', sdk, '--show-sdk-path')] = f'/SDKs/{sdk}.sdk'
        self.runtimes = [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2',
                          'version': '26.2', 'isAvailable': True}]
        self.devices = [{'identifier': CI.DEVICE_TYPE}]

    def run_command(self, command):
        if command == ['xcrun', 'simctl', 'list', 'runtimes', '--json']:
            return json.dumps({'runtimes': self.runtimes})
        if command == ['xcrun', 'simctl', 'list', 'devicetypes', '--json']:
            return json.dumps({'devicetypes': self.devices})
        return self.responses[tuple(command)]

    def test_exact_toolchain_and_available_runtime(self):
        report = CI.inspect_toolchain(self.run_command, '26.0', simulator=True)
        self.assertEqual(report['simulator_runtime'], self.runtimes[0]['identifier'])
        self.assertEqual(report['simulator_device_type'], CI.DEVICE_TYPE)
        self.assertEqual(set(report['sdks']), {'macosx', 'iphoneos', 'iphonesimulator'})

    def test_wrong_xcode_is_refused(self):
        for value in ['Xcode 16.4\nBuild version 16F6', 'Xcode 26.1\nBuild version 17B55',
                      'Xcode 26.2\nBuild version unknown\nextra']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.responses[('xcodebuild', '-version')] = value
                CI.inspect_toolchain(self.run_command, '26.0')

    def test_wrong_sdk_is_refused_for_device_and_simulator(self):
        for sdk in ['iphoneos', 'iphonesimulator']:
            key = ('xcrun', '--sdk', sdk, '--show-sdk-version')
            for value in ['18.5', '26.0', '26.1', '26.5', '', 'unknown']:
                with self.subTest(sdk=sdk, value=value), self.assertRaises(ValueError):
                    self.responses[key] = value
                    CI.inspect_toolchain(self.run_command, '26.0')
            self.responses[key] = '26.2'

    def test_missing_unavailable_or_unrelated_runtime_is_refused(self):
        fixtures = [[], [dict(self.runtimes[0], isAvailable=False)],
                    [dict(self.runtimes[0], identifier='com.apple.CoreSimulator.SimRuntime.tvOS-26-0')],
                    [dict(self.runtimes[0], version='26.1')]]
        for runtimes in fixtures:
            with self.subTest(runtimes=runtimes), self.assertRaises(ValueError):
                self.runtimes = runtimes
                CI.inspect_toolchain(self.run_command, '26.0', simulator=True)

    def test_missing_device_type_is_refused(self):
        self.devices = []
        with self.assertRaises(ValueError):
            CI.inspect_toolchain(self.run_command, '26.0', simulator=True)

    def test_empty_sdk_path_and_changed_deployment_target_are_refused(self):
        with self.assertRaises(ValueError):
            CI.inspect_toolchain(self.run_command, '27.0')
        self.responses[('xcrun', '--sdk', 'iphoneos', '--show-sdk-path')] = ''
        with self.assertRaises(ValueError):
            CI.inspect_toolchain(self.run_command, '26.0')

    def test_baseline_preflight_does_not_require_a_simulator(self):
        self.runtimes = []
        self.devices = []
        report = CI.inspect_toolchain(self.run_command, '26.0')
        self.assertNotIn('simulator_runtime', report)

    def test_insufficient_active_cpus_are_refused(self):
        for processors in ['0', '1', '2', '3', 'unknown']:
            with self.subTest(processors=processors), self.assertRaises(ValueError):
                self.responses[('sysctl', '-n', 'hw.activecpu')] = processors
                CI.inspect_toolchain(self.run_command, '26.0')

    def test_parallel_fixture_allows_three_cpu_simulator_host(self):
        self.responses[('sysctl', '-n', 'hw.activecpu')] = '3'
        report = CI.inspect_toolchain(self.run_command, '26.0', simulator=True)
        self.assertEqual(report['minimum_processors'], 2)
        self.responses[('sysctl', '-n', 'hw.activecpu')] = '1'
        with self.assertRaises(ValueError):
            CI.inspect_toolchain(self.run_command, '26.0', simulator=True)


if __name__ == '__main__':
    unittest.main()

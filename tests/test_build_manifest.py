"""Exercise structural IPA evidence checks; these fixtures are not signed IPAs."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('build_manifest', ROOT / 'scripts/write_build_manifest.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


def executable(architecture=0x100000c, platform=2, minimum=26 << 16, flags=2, entitlements=None, padding=b'\0' * 16):
    values = plistlib.loads((ROOT / 'entitlements.plist').read_bytes()) if entitlements is None else entitlements
    xml = plistlib.dumps(values)
    entitlement = struct.pack('>II', 0xfade7171, len(xml) + 8) + xml
    directory = struct.pack('>IIII', 0xfade0c02, 16, 0x20400, flags)
    blob_size = 28 + len(entitlement) + len(directory)
    signature = (struct.pack('>III', 0xfade0cc0, blob_size, 2) + struct.pack('>II', 5, 28) +
                 struct.pack('>II', 0, 28 + len(entitlement)) + entitlement + directory + padding)
    commands = struct.pack('<IIIIII', 0x32, 24, platform, minimum, (26 << 16) + (2 << 8), 0)
    commands += struct.pack('<IIII', 0x1d, 16, 72, len(signature))
    header = struct.pack('<IIIIIIII', 0xfeedfacf, architecture, 0, 2, 2, len(commands), 0, 0)
    return header + commands + signature


class BuildManifestTests(unittest.TestCase):
    def test_structural_claims_accept_reserved_zero_padding(self):
        result = manifest.inspect_executable(executable())
        self.assertEqual(result['architecture'], 'arm64')
        self.assertEqual(result['minimum_os'], '26.0.0')
        self.assertEqual(result['sdk'], '26.2.0')
        self.assertEqual(result['signing'], 'ad-hoc')
        self.assertNotIn('signature_verified', result)

    def test_wrong_platform_architecture_deployment_groups_and_flags_fail(self):
        cases = [{'architecture': 0x1000007}, {'platform': 7}, {'minimum': 27 << 16},
                 {'entitlements': {}}, {'flags': 0},
                 {'entitlements': {'com.apple.security.application-groups': ['group.io.github.micknorj.charony.wrong']}}]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                manifest.inspect_executable(executable(**case))

    def test_truncated_tables_and_signature_garbage_fail(self):
        data = executable()
        for invalid in [data[:8], data[:35], data[:-32], executable(padding=b'not padding')]:
            with self.subTest(length=len(invalid)), self.assertRaises(ValueError):
                manifest.inspect_executable(invalid)

    def test_fixture_markers_are_refused(self):
        for marker in manifest.FIXTURE_MARKERS:
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                manifest.inspect_executable(executable() + marker)

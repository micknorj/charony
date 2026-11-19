"""Portable source, privacy, metadata and packaging gates. Native logic runs on macOS."""
import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import stat
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

class CharonyTests(unittest.TestCase):
    def test_privacy_source(self):
        self.assertEqual(module('privacy_audit').source_failures(), [])

    def test_privacy_audit_preserves_runtime_urls_and_symbols(self):
        audit = module('privacy_audit')
        text = audit.without_comments('// legal https://example.com\nconst char *url = "https://runtime.invalid"; /* hidden */ _NSLog;')
        self.assertNotIn('example.com', text)
        self.assertIn('https://runtime.invalid', text)
        self.assertRegex(text, audit.FORBIDDEN)

    def test_access_cache_safety_primitives_preserved(self):
        policy = json.loads((ROOT / 'tests/upstream-baseline.json').read_text())
        fixture = (ROOT / 'tests/fixtures/upstream-access-safety.json').read_bytes()
        self.assertEqual(hashlib.sha256(fixture).hexdigest(), policy['safety_fixture_sha256'])
        original = json.loads(fixture)
        self.assertEqual(original['upstream_commit'], policy['commit'])
        self.assertEqual(original['upstream_file_sha256'], policy['files']['WQAccessSafety.h']['sha256'])
        current = (ROOT / 'WQAccessSafety.h').read_text()
        for name in ['WQOpenDirectoryNoLinksFlags', 'WQOpenRegularAt', 'WQCacheSwapRecover',
                     'WQRecoverCacheSwapAtPath', 'WQCacheSwapReset', 'WQCacheLockOpenForRepair', 'WQCacheSwapBegin',
                     'WQCreateDirectoriesNoLinksMode', 'WQCreateDirectoriesNoLinks']:
            # These upstream helpers end at the next top-level closing brace.
            expression = r'^static inline [^\n]*\b' + name + r'\(.*?^\}'
            after = re.search(expression, current, re.M | re.S)
            self.assertIsNotNone(after, name)
            self.assertEqual(original['functions'][name], after.group(), name)

    def test_removed_modules_and_routes(self):
        for name in ['WQWebServer', 'WQArchive', 'WQSharing', 'WQTheme', 'WQInspector',
                     'WQPlistEditor', 'WQSQLiteViewer', 'WQHexViewer', 'WQTrash', 'WQMediaStream']:
            self.assertFalse((ROOT / f'{name}.m').exists(), name)
            self.assertFalse((ROOT / f'{name}.h').exists(), name)
        self.assertEqual(list(ROOT.glob('*.lproj')), [])
        production = '\n'.join(p.read_text() for p in ROOT.glob('*.m'))
        for symbol in ['WQDirViewController', 'wq_backup_root', 'wq_make_backup',
                       'wq_cache_custom_target', 'WQSettingsViewController', 'wq_check_update']:
            self.assertNotIn(symbol, production)

    def test_local_imports_resolve(self):
        for path in [*ROOT.glob('*.[mh]'), *ROOT.glob('tests/*.m')]:
            for include in re.findall(r'#(?:import|include) "([^"]+)"', path.read_text()):
                self.assertTrue((path.parent / include).exists() or (ROOT / include).exists(), f'{path.name} -> {include}')

    def test_compile_inventory(self):
        manifest = (ROOT / 'scripts/sources.sh').read_text()
        declared = re.search(r'SOURCES=\(([^)]+)\)', manifest).group(1).split()
        self.assertEqual(set(declared), {p.name for p in ROOT.glob('*.m')})
        self.assertNotRegex(manifest, r'sqlite|JavaScriptCore|UniformTypeIdentifiers|\-lz')

    def test_metadata(self):
        info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleDisplayName'], 'charony')
        self.assertEqual(info['CFBundleIdentifier'], 'io.github.micknorj.charony')
        self.assertEqual(info['CFBundleExecutable'], 'charony')
        self.assertEqual(info['MinimumOSVersion'], '26.0')
        self.assertEqual(info['CFBundleLocalizations'], ['en'])
        for key in ['NSLocalNetworkUsageDescription', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations',
                    'UIFileSharingEnabled', 'LSSupportsOpeningDocumentsInPlace']:
            self.assertNotIn(key, info)

    def test_entitlement(self):
        entitlements = plistlib.loads((ROOT / 'entitlements.plist').read_bytes())
        self.assertEqual(entitlements, {'com.apple.security.application-groups': ['group.io.github.micknorj.charony']})

    def test_cache_selection_starts_empty(self):
        source = (ROOT / 'WQCache.m').read_text()
        assignments = re.findall(r'\b(?:item|logs)\.selected\s*=\s*([^;]+);', source)
        self.assertTrue(assignments)
        self.assertEqual(set(assignments), {'NO', '!item.selected'})
        for removed in ['selectWhere:', 'clearSelection', 'customRelative', 'Select All', 'Invert Selection']:
            self.assertNotIn(removed, source)

    def test_scope_and_identity_validation_stay_on_mutation_path(self):
        source = (ROOT / 'CHAppData.m').read_text()
        self.assertIn('[@"Documents", @"Library", @"tmp"]', source)
        self.assertIn('current.st_dev == device && current.st_ino == inode', source)
        self.assertIn('[wq_container_label(container) isEqualToString:bundleID]', source)
        self.assertIn('wq_purge_contents_validated(', source)
        self.assertIn('WQCacheSafetyTargetMatchesContainer', source)
        self.assertNotIn('wq_copy', source)
        cache = (ROOT / 'WQCache.m').read_text()
        self.assertIn('return WQCacheValidateItem(item, NULL)', cache)
        self.assertIn('wq_begin_mutation(self)', cache)
        self.assertIn('wq_begin_mutation(self)', (ROOT / 'WQApps.m').read_text())

    def test_confirmations(self):
        for name, action in [('WQApps.m', 'Clear Data'), ('WQCache.m', 'Clean')]:
            source = (ROOT / name).read_text()
            self.assertIn('wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)', source)
            self.assertIn(f'wq_alert_action(@"{action}", UIAlertActionStyleDestructive', source)
            self.assertIn('cannot be undone' if name == 'WQCache.m' else 'Permanently', source)

    def test_task_journal_omits_completed_results(self):
        source = (ROOT / 'WQScanTask.m').read_text()
        self.assertNotRegex(source, r'saved\[@"(?:result|finishedAt)"\]')
        self.assertIn('WQScanJournalRemove([@"task:"', source)
        self.assertIn('WQScanJournalRemoveScope(_name)', source)
        self.assertIn('task->_result = nil;', source)
        for name in ['WQApps.m', 'WQCache.m']:
            self.assertNotIn('timeIntervalSinceNow > 600', (ROOT / name).read_text())

    def test_contextual_native_search(self):
        source = (ROOT / 'main.m').read_text()
        self.assertIn('[[UISearchTab alloc] initWithViewControllerProvider:', source)
        self.assertIn('@[appsTab, cachesTab, self.searchTab]', source)
        self.assertIn('contextSearchController', source)
        self.assertIn('self.contextNavigation.viewControllers = @[root]', source)
        self.assertIn('root.navigationItem.searchController = nil', source)

    def test_build_is_gated_and_staged(self):
        source = (ROOT / 'build.sh').read_text()
        self.assertIn('bash tests/run_all_tests.sh', source)
        self.assertNotIn('SKIP_PREFLIGHT', source)
        self.assertLess(source.index('scripts/verify_ipa.py'), source.index('os.replace('))
        self.assertIn('scripts/privacy_audit.py --binary', source)
        self.assertIn('codesign --verify --deep --strict', source)
        self.assertIn('xcrun actool', source)

    def test_ipa_verifier_positive_and_negative(self):
        verify = module('verify_ipa').verify
        info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.ipa'
            def write(extra=None, missing=None, wrong_id=False):
                data = dict(info)
                if wrong_id:
                    data['CFBundleIdentifier'] = 'wrong.app'
                with zipfile.ZipFile(path, 'w') as archive:
                    for name in ['charony', 'Assets.car', 'LICENSE', 'NOTICE.md']:
                        if name != missing:
                            entry = zipfile.ZipInfo('Payload/charony.app/' + name)
                            entry.external_attr = (stat.S_IFREG | (0o755 if name == 'charony' else 0o644)) << 16
                            archive.writestr(entry, b'fixture')
                    archive.writestr('Payload/charony.app/Info.plist', plistlib.dumps(data))
                    if extra:
                        archive.writestr(extra, b'unexpected')
            write()
            verify(path)
            for extra in ['Payload/charony.app/../../escape', 'Payload/other.app/main', 'Payload/charony.app/bad.js',
                          'Payload/charony.app/./charony', 'Payload/charony.app//charony',
                          'Payload/charony.app/fr.lproj/Localizable.strings', 'Payload/charony.app/back\\slash']:
                write(extra=extra)
                with self.assertRaises(ValueError):
                    verify(path)
            write(missing='Assets.car')
            with self.assertRaises(ValueError):
                verify(path)
            write(wrong_id=True)
            with self.assertRaises(ValueError):
                verify(path)

    def test_ipad_release_policy_preserved(self):
        info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        self.assertEqual(info['UIDeviceFamily'], [1, 2])
        self.assertEqual(set(info['UISupportedInterfaceOrientations~ipad']), {
            'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
            'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'})

    def test_package_rejects_links_special_files_and_metadata_changes(self):
        verify = module('verify_ipa').verify
        info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.ipa'
            for mode, metadata_key in [(stat.S_IFLNK | 0o777, None), (stat.S_IFIFO | 0o600, None),
                                       (stat.S_IFREG | 0o644, None), (stat.S_IFREG | 0o755, 'UIDeviceFamily'),
                                       (stat.S_IFREG | 0o755, 'LSSupportsOpeningDocumentsInPlace')]:
                with self.subTest(mode=mode, key=metadata_key):
                    data = dict(info)
                    if metadata_key:
                        data[metadata_key] = True
                    with zipfile.ZipFile(path, 'w') as archive:
                        for name in ['charony', 'Assets.car', 'LICENSE', 'NOTICE.md']:
                            entry = zipfile.ZipInfo('Payload/charony.app/' + name)
                            entry.external_attr = (mode if name == 'charony' else stat.S_IFREG | 0o644) << 16
                            archive.writestr(entry, b'fixture')
                        archive.writestr('Payload/charony.app/Info.plist', plistlib.dumps(data))
                    with self.assertRaises(ValueError):
                        verify(path)

    def test_missing_malformed_and_empty_archives_fail_closed(self):
        verify = module('verify_ipa').verify
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bad.ipa'
            with self.assertRaises(FileNotFoundError):
                verify(path)
            path.write_bytes(b'not a zip')
            with self.assertRaises(zipfile.BadZipFile):
                verify(path)
            with zipfile.ZipFile(path, 'w'):
                pass
            with self.assertRaises(ValueError):
                verify(path)

    def test_no_unresolved_imported_project_symbols(self):
        # Catch stale module APIs after physical deletion. Native linking remains required.
        paths = [*ROOT.glob('*.[mh]')]
        text = '\n'.join(p.read_text() for p in paths)
        symbols = set(re.findall(r'\b(wq_[a-z_]+)\s*\(', text))
        declarations = set()
        for match in re.finditer(r'^[\w<> *,]+\b(wq_[a-z_]+)\s*\(', text, re.M):
            declarations.add(match.group(1))
        declarations.update(re.findall(r"\(\^(wq_[a-z_]+)\)", text))
        self.assertEqual(symbols - declarations, set())

if __name__ == '__main__':
    unittest.main()

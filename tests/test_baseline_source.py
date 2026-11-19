"""Verify pinned baseline extraction without requiring inherited Git objects."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('baseline_source', ROOT / 'scripts/baseline_source.py')
BASELINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASELINE)


class BaselineSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / 'source.tar.gz'
        self.destination = self.root / 'extracted'
        self.files = {'build.sh': (b'#!/bin/bash\nexit 0\n', 0o755), 'LICENSE': (b'GPL fixture', 0o644)}
        self.policy = {'files': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data), 'mode': mode}
                                 for name, (data, mode) in self.files.items()}}

    def write(self, files=None, extra=None):
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name, (data, mode) in (self.files if files is None else files).items():
                entry = tarfile.TarInfo('upstream/' + name)
                entry.size, entry.mode = len(data), mode
                archive.addfile(entry, io.BytesIO(data))
            if extra is not None:
                archive.addfile(extra, io.BytesIO(b''))
        self.policy['archive_sha256'] = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def test_exact_snapshot_preserves_bytes_and_executable_mode(self):
        self.write()
        BASELINE.unpack(self.archive, self.destination, self.policy)
        for name, (data, mode) in self.files.items():
            self.assertEqual((self.destination / name).read_bytes(), data)
            self.assertEqual((self.destination / name).stat().st_mode & 0o777, mode)

    def test_tampered_archive_fails_before_creating_destination(self):
        self.write()
        with self.archive.open('ab') as stream:
            stream.write(b'tampered')
        with self.assertRaises(ValueError):
            BASELINE.unpack(self.archive, self.destination, self.policy)
        self.assertFalse(self.destination.exists())

    def test_missing_unexpected_and_changed_files_fail_closed(self):
        fixtures = [{'LICENSE': self.files['LICENSE']}, dict(self.files, unexpected=(b'foreign', 0o644)),
                    dict(self.files, LICENSE=(b'GPL changed', 0o644))]
        for files in fixtures:
            with self.subTest(files=list(files)):
                self.write(files)
                with self.assertRaises(ValueError):
                    BASELINE.unpack(self.archive, self.destination, self.policy)
                self.assertFalse(self.destination.exists())

    def test_links_traversal_and_absolute_paths_are_refused(self):
        for name, kind in [('upstream/../../escape', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                           ('upstream/link', tarfile.SYMTYPE), ('upstream/hardlink', tarfile.LNKTYPE)]:
            with self.subTest(name=name):
                entry = tarfile.TarInfo(name)
                entry.type, entry.linkname = kind, '../../escape'
                self.write(extra=entry)
                with self.assertRaises(ValueError):
                    BASELINE.unpack(self.archive, self.destination, self.policy)
                self.assertFalse(self.destination.exists())
                self.assertFalse((self.root / 'escape').exists())

    def test_existing_destination_and_sentinel_are_preserved(self):
        self.write()
        self.destination.mkdir()
        sentinel = self.destination / 'keep'
        sentinel.write_bytes(b'unrelated')
        with self.assertRaises(ValueError):
            BASELINE.unpack(self.archive, self.destination, self.policy)
        self.assertEqual(sentinel.read_bytes(), b'unrelated')

    def test_duplicate_entry_is_refused(self):
        self.write(extra=tarfile.TarInfo('upstream/LICENSE'))
        with self.assertRaises(ValueError):
            BASELINE.unpack(self.archive, self.destination, self.policy)
        self.assertFalse(self.destination.exists())

    def test_executable_mode_or_size_changes_are_refused(self):
        for change in [(self.files['build.sh'][0], 0o644), (b'short', 0o755)]:
            with self.subTest(change=change):
                self.write(dict(self.files, **{'build.sh': change}))
                with self.assertRaises(ValueError):
                    BASELINE.unpack(self.archive, self.destination, self.policy)
                self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()

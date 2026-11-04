"""Prepared demo caches cannot replace edited inputs or existing visitor state."""
import importlib.util
import base64
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('demo_cache', ROOT / 'native/runner/toolchain/demo_cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class DemoCaches(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / 'project'
        self.prepared = self.base / 'prepared'
        (self.root / 'src').mkdir(parents=True)
        (self.root / 'src/Main.hx').write_text('class Main {}\n')
        (self.root / 'build.hxml').write_text('-cp src\n-main Main\n-hl bin/main.hl\n')
        (self.root / '.rayzor/blade/editor').mkdir(parents=True)
        (self.root / '.rayzor/blade/editor/main.bidx').write_bytes(b'operator index')
        (self.root / 'bin').mkdir()
        (self.root / 'bin/main.hl').write_bytes(b'operator bytecode')
        self.manifest = cache.seal(self.root, self.prepared, 'a' * 64, {'restored': {'files': 1, 'reused': 1}})
        self.old = self.base / 'old'
        self.root.rename(self.old)
        (self.root / 'src').mkdir(parents=True)
        for name in self.manifest['inputs']:
            shutil.copyfile(self.old / name, self.root / name)
            os.utime(self.root / name, ns=(1_000_000_000, 1_000_000_000))

    def test_matching_fresh_sources_receive_private_caches_and_configuration_timestamps(self):
        report = cache.restore(self.root, self.prepared, 'a' * 64)
        self.assertEqual(report['status'], 'restored')
        self.assertEqual((self.root / '.rayzor/blade/editor/main.bidx').read_bytes(), b'operator index')
        self.assertEqual((self.root / 'bin/main.hl').read_bytes(), b'operator bytecode')
        for name, item in self.manifest['inputs'].items():
            self.assertEqual((self.root / name).stat().st_mtime_ns, item['modifiedNs'])
        (self.root / '.rayzor/blade/editor/main.bidx').write_bytes(b'visitor index')
        self.assertEqual((self.prepared / 'files/.rayzor/blade/editor/main.bidx').read_bytes(), b'operator index')

    def test_modified_or_additional_inputs_do_not_receive_caches(self):
        for change in ['edited', 'additional']:
            with self.subTest(change=change):
                path = self.root / ('src/Main.hx' if change == 'edited' else 'src/New.hx')
                path.write_text('class Changed {}')
                before = (self.root / 'build.hxml').stat().st_mtime_ns
                self.assertEqual(cache.restore(self.root, self.prepared, 'a' * 64)['reason'], 'changed-inputs')
                self.assertEqual((self.root / 'build.hxml').stat().st_mtime_ns, before)
                self.assertFalse((self.root / '.rayzor').exists())

    def test_existing_visitor_cache_is_never_overwritten(self):
        (self.root / '.rayzor').mkdir()
        marker = self.root / '.rayzor/private'
        marker.write_text('visitor')
        self.assertEqual(cache.restore(self.root, self.prepared, 'a' * 64)['reason'], 'existing-cache')
        self.assertEqual(marker.read_text(), 'visitor')

    def test_personal_settings_and_library_overrides_prevent_seeding(self):
        (self.root / '.rayde').mkdir()
        self.assertEqual(cache.restore(self.root, self.prepared, 'a' * 64)['reason'], 'existing-state')
        self.assertFalse((self.root / '.rayzor').exists())

    def test_release_or_canonical_path_mismatch_stays_cold(self):
        self.assertEqual(cache.restore(self.root, self.prepared, 'b' * 64)['reason'], 'different-demo')
        moved = self.base / 'different-path'
        self.root.rename(moved)
        self.assertEqual(cache.restore(moved, self.prepared, 'a' * 64)['reason'], 'different-demo')

    def test_corrupt_payload_is_rejected_before_any_project_mutation(self):
        (self.prepared / 'files/bin/main.hl').write_bytes(b'changed bytecode')
        before = (self.root / 'build.hxml').stat().st_mtime_ns
        with self.assertRaisesRegex(ValueError, 'artifact changed'):
            cache.restore(self.root, self.prepared, 'a' * 64)
        self.assertEqual((self.root / 'build.hxml').stat().st_mtime_ns, before)
        self.assertFalse((self.root / 'bin').exists())

    def test_traversal_and_symlink_inputs_are_rejected(self):
        for value in ['../outside', '/outside', 'a/../b', 'a//b', 'a\\b']:
            with self.assertRaises(ValueError):
                cache.relative(value)
        if os.name != 'nt':
            (self.root / 'src/link.hx').symlink_to(self.old / 'src/Main.hx')
            with self.assertRaisesRegex(ValueError, 'symlinks'):
                cache.restore(self.root, self.prepared, 'a' * 64)

    def test_dangling_cache_symlink_is_not_replaced(self):
        if os.name == 'nt':
            self.skipTest('Requires symlinks')
        (self.root / 'bin').symlink_to(self.base / 'missing')
        self.assertEqual(cache.restore(self.root, self.prepared, 'a' * 64)['reason'], 'existing-cache')
        self.assertTrue((self.root / 'bin').is_symlink())

    def test_malformed_bundle_is_rejected_before_materializing_sources(self):
        def entry(name, directory=False):
            return {'path': '/work/pocket-studio/' + name, 'directory': directory, 'data': base64.b64encode(b'content').decode()}
        for entries in [[entry('build.hxml', True)], [entry('build.hxml'), entry('a'), entry('a/b')],
                        [entry('build.hxml'), entry('../outside')], [entry('build.hxml'), entry('bin/app.hl')],
                        [entry('build.hxml'), {**entry('src'), 'directory': 'false'}]]:
            with self.subTest(entries=entries):
                bundle = self.base / 'bundle.json'
                bundle.write_text(json.dumps({'version': 1, 'root': '/work/pocket-studio', 'entries': entries}))
                fresh = self.base / 'fresh'
                with self.assertRaises(ValueError):
                    cache.materialize(bundle, fresh)
                self.assertFalse(fresh.exists())


if __name__ == '__main__':
    unittest.main()

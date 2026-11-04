import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('site_release', pathlib.Path(__file__).resolve().parents[1] / 'scripts/site_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class Store:
    def __init__(self):
        self.objects = {}
        self.writes = []
        self.fail = None

    def put(self, key, path):
        if key == self.fail:
            raise OSError('Interrupted upload')
        self.objects[key] = path.read_bytes()
        self.writes.append(key)

    def get(self, key):
        return self.objects[key]


class SiteReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.source = self.root / 'site'
        for name in release.REQUIRED:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('<html><head></head>page</html>' if name.endswith('.html') else 'contents')
        (self.source / 'dist/libraries.json').write_text('["ash_channel"]')
        (self.source / 'dist/ash_channel.wasm').write_bytes(b'\x00asm\x01\x00\x00\x00')
        self.demo = 'a' * 64
        entry = 'demo/' + self.demo + '/index.html'
        target = self.source / 'dist' / entry
        target.parent.mkdir(parents=True)
        target.write_text('<html>app</html>')
        (self.source / 'dist/demo-workspace.json').write_text(json.dumps({'preview': {'release': self.demo, 'entry': entry}}))

    def prepare(self):
        return release.prepare(self.source, self.root / 'releases')

    def test_content_identity_and_only_public_inputs(self):
        (self.source / '.env').write_text('private')
        (self.source / 'demo').mkdir()
        (self.source / 'demo/private').write_text('not a public artifact')
        first = self.prepare()
        self.assertEqual(first, self.prepare())
        self.assertNotIn('.env', release.verify(first)['files'])
        (self.source / 'dist/worker.js').write_text('new loader')
        second = self.prepare()
        self.assertNotEqual(first, second)
        self.assertEqual((first / 'dist/worker.js').read_text(), 'contents')

    def test_missing_dependencies_changed_bytes_and_unlisted_files_are_refused(self):
        target = self.source / 'dist/ash_channel.wasm'
        target.unlink()
        with self.assertRaisesRegex(ValueError, 'Missing WASM side module'):
            self.prepare()
        target.write_bytes(b'wasm')
        prepared = self.prepare()
        (prepared / 'dist/worker.js').write_text('edited after packaging')
        with self.assertRaisesRegex(ValueError, 'Release files changed'):
            release.verify(prepared)
        with self.assertRaises(ValueError):
            release.upload(prepared, Store())

    def test_symlinks_and_hidden_public_assets_are_refused(self):
        target = self.source / 'assets/private'
        target.symlink_to('/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'public regular files'):
            self.prepare()
        target.unlink()
        (self.source / 'dist/.token').write_text('private')
        with self.assertRaisesRegex(ValueError, 'public regular files'):
            self.prepare()

    def test_build_changes_during_packaging_do_not_publish_a_directory(self):
        copy = release.shutil.copyfile
        def changing(source, target):
            result = copy(source, target)
            if pathlib.Path(source).name == 'thread.js':
                (self.source / 'dist/new-module.mjs').write_text('new build input')
            return result
        with patch.object(release.shutil, 'copyfile', changing):
            with self.assertRaisesRegex(ValueError, 'Site files changed'):
                self.prepare()
        self.assertEqual(list((self.root / 'releases').iterdir()), [])

    def test_upload_does_not_promote_and_partial_or_corrupt_releases_cannot_promote(self):
        prepared = self.prepare()
        store = Store()
        store.objects[release.POINTER] = b'previous release'
        store.fail = 'releases/' + prepared.name + '/dist/worker.js'
        with self.assertRaisesRegex(OSError, 'Interrupted'):
            release.upload(prepared, store)
        self.assertEqual(store.objects[release.POINTER], b'previous release')
        with self.assertRaises(KeyError):
            release.promote(prepared, store)
        store.fail = None
        release.upload(prepared, store)
        self.assertEqual(store.objects[release.POINTER], b'previous release')
        key = 'releases/' + prepared.name + '/dist/rayde.wasm'
        original = store.objects[key]
        store.objects[key] = b'truncated'
        with self.assertRaisesRegex(ValueError, 'Published release file'):
            release.promote(prepared, store)
        self.assertEqual(store.objects[release.POINTER], b'previous release')
        store.objects[key] = original
        release.promote(prepared, store)
        self.assertEqual(json.loads(store.objects[release.POINTER])['release'], prepared.name)
        self.assertEqual(store.writes[-1], release.POINTER)

    def test_rollback_only_changes_the_pointer(self):
        first = self.prepare()
        (self.source / 'dist/thread.js').write_text('second release')
        second = self.prepare()
        store = Store()
        release.upload(first, store)
        release.upload(second, store)
        release.promote(first, store)
        release.promote(second, store)
        count = len(store.writes)
        release.promote(first, store)
        self.assertEqual(store.writes[count:], [release.POINTER])
        self.assertEqual(json.loads(store.objects[release.POINTER])['release'], first.name)


if __name__ == '__main__':
    unittest.main()

"""OCI build preparation must contain a clean Git workspace and matching warm caches."""
import base64
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('container_image', ROOT / 'native/session/container/prepare.py')
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)


class ContainerImage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.image = self.base / 'image'
        self.image.mkdir()
        shutil.copyfile(ROOT / 'native/runner/toolchain/demo_cache.py', self.image / 'demo_cache.py')
        sys.path.insert(0, str(self.image))
        self.addCleanup(lambda: sys.path.remove(str(self.image)))
        import demo_cache
        self.cache = demo_cache
        self.root = self.base / 'project'
        self.state = self.base / 'state'
        sources = {'build.hxml': '-main Main\n', 'Main.hx': 'class Main {}\n', '.gitignore': '.rayde/\n.rayzor/\nbin/\n'}
        value = {'version': 1, 'root': '/work/pocket-studio', 'entries': [
            {'path': '/work/pocket-studio/' + name, 'directory': False, 'data': base64.b64encode(text.encode()).decode()}
            for name, text in sources.items()]}
        self.bundle = self.image / 'demo-workspace.json'
        self.bundle.write_text(json.dumps(value))
        self.cache.materialize(self.bundle, self.root)
        (self.root / '.rayzor').mkdir()
        (self.root / '.rayzor/main.bidx').write_bytes(b'prepared index')
        for stage in ['bytecode', 'wasm']:
            path = self.root / '.rayde/preview-cache' / stage
            path.mkdir(parents=True)
            (path / 'manifest.json').write_text('{}')
        self.cache.seal(self.root, self.image / 'demo-cache', self.cache.digest(self.bundle), {
            'restored': {'files': 1, 'reused': 1}, 'preview': {'bytecode': True, 'wasm': True}})
        shutil.rmtree(self.root)

    def test_clean_git_baseline_excludes_warm_cache_and_private_state(self):
        import subprocess
        image.prepare(self.image, self.root, self.state)
        result = subprocess.run(['git', '-C', str(self.root), 'status', '--porcelain'], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, '')
        tracked = subprocess.check_output(['git', '-C', str(self.root), 'ls-files'], text=True).splitlines()
        self.assertEqual(tracked, ['.gitignore', 'Main.hx', 'build.hxml'])
        self.assertEqual((self.root / '.rayzor/main.bidx').read_bytes(), b'prepared index')
        self.assertEqual(list(self.state.iterdir()), [])
        with self.assertRaises(ValueError):
            image.prepare(self.image, self.root, self.state)

    def test_incomplete_warming_or_mismatched_sources_refuse_an_image(self):
        path = self.image / 'demo-cache/manifest.json'
        manifest = json.loads(path.read_text())
        changed = {**manifest, 'report': {'restored': {'files': 1, 'reused': 0}}}
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, 'verified warm'):
            image.prepare(self.image, self.root, self.state)
        self.assertFalse(self.root.exists())
        path.write_text(json.dumps(manifest))
        self.bundle.write_text(self.bundle.read_text() + '\n')
        with self.assertRaisesRegex(ValueError, 'matching prepared caches'):
            image.prepare(self.image, self.root, self.state)
        self.assertFalse(self.state.exists())


if __name__ == '__main__':
    unittest.main()

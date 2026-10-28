"""The compiler and language-server manifests must select the same demo libraries."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DemoVersions(unittest.TestCase):
    def test_hxml_and_manifest_resolve_the_same_published_ashui_packages(self):
        demo = ROOT / 'site/demo'
        dependencies = json.loads((demo / 'haxelib.json').read_text())['dependencies']
        libraries = dict(line.removeprefix('-L ').split(':', 1) for line in (demo / 'build.hxml').read_text().splitlines() if line.startswith('-L '))
        for name in ['ashui', 'ashui-components', 'ashui-icons']:
            self.assertEqual(dependencies[name], libraries[name], name)
        self.assertEqual(len(set(dependencies[name] for name in libraries)), 1)

if __name__ == '__main__':
    unittest.main()

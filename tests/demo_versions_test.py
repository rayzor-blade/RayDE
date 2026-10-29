"""The compiler and language-server manifests must select the same demo libraries."""
import json
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('serve_site', ROOT / 'scripts/serve-site.py')
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)

class DemoVersions(unittest.TestCase):
    def test_hxml_and_manifest_resolve_the_same_published_ashui_packages(self):
        demo = ROOT / 'site/demo'
        dependencies = json.loads((demo / 'haxelib.json').read_text())['dependencies']
        libraries = dict(line.removeprefix('-L ').split(':', 1) for line in (demo / 'build.hxml').read_text().splitlines() if line.startswith('-L '))
        for name in ['ashui', 'ashui-components', 'ashui-icons']:
            self.assertEqual(dependencies[name], libraries[name], name)
        self.assertEqual(len(set(dependencies[name] for name in libraries)), 1)

    def test_managed_demo_upgrades_only_the_previous_shipped_build(self):
        current = (ROOT / 'site/demo/build.hxml').read_text()
        previous = current.replace('-dce full\n', '', 1)
        self.assertNotEqual(current, previous)
        self.assertEqual(site.demo_build(previous), current)
        self.assertEqual(site.demo_build(current), current)
        for custom in [previous + '-cp custom\n', previous + '-dce no\n', previous.replace('-main Main', '-main Custom')]:
            self.assertEqual(site.demo_build(custom), custom)

if __name__ == '__main__':
    unittest.main()

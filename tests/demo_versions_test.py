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

    def test_managed_demo_adds_preview_defaults_without_replacing_custom_choices(self):
        template = json.loads((ROOT / 'site/demo/haxelib.json').read_text())
        previous = {key: value for key, value in template.items() if key != 'rayde'}
        upgraded = site.demo_manifest(previous)
        self.assertEqual(upgraded, template)
        self.assertEqual(json.dumps(upgraded, indent=2) + '\n', (ROOT / 'site/demo/haxelib.json').read_text())
        custom = json.loads(json.dumps(previous))
        custom['rayde'] = {'other': True, 'run': {'previews': {'hl': {'mode': 'process', 'compilerFlags': ['-D', 'custom']}}}}
        upgraded = site.demo_manifest(custom)
        self.assertEqual(upgraded['rayde']['run']['previews']['hl']['mode'], 'process')
        self.assertEqual(upgraded['rayde']['run']['previews']['hl']['compilerFlags'], ['-D', 'custom'])
        self.assertTrue(upgraded['rayde']['other'])

    def test_managed_demo_upgrades_published_versions_and_preserves_custom_sources(self):
        current = (ROOT / 'site/demo/build.hxml').read_text()
        for version in site.PREVIOUS_ASHUI:
            previous = current.replace(':0.2.4', ':' + version)
            self.assertEqual(site.demo_build(previous), current)
            self.assertEqual(site.demo_build(previous + '-cp custom\n'), current + '-cp custom\n')
            manifest = json.loads((ROOT / 'site/demo/haxelib.json').read_text())
            manifest['dependencies'] = {name: version for name in manifest['dependencies']}
            self.assertEqual(set(site.demo_manifest(manifest)['dependencies'].values()), {'0.2.4'})
            guide = (ROOT / 'site/demo/README.md').read_text()
            self.assertEqual(site.demo_readme(guide.replace('0.2.4', version) + '\nMy notes\n'), guide + '\nMy notes\n')

if __name__ == '__main__':
    unittest.main()

"""Preview modules cannot cross runtime identities or mutate the installed Haxelib repository."""
from pathlib import Path
import json
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from native_web import MODULES, WASM, stage, verify, overlay


class NativeWeb(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.runtime=self.root/'ash_runtime.o';self.runtime.write_bytes(WASM+b'runtime-one')
        self.source=self.root/'source';self.source.mkdir()
        for names in MODULES.values():
            for name in names:
                (self.source/name).write_bytes(WASM+name.encode() if name.endswith('.wasm') else name.encode())
        self.bundle=self.root/'bundle';stage(self.source,self.bundle,self.runtime)

    def repository(self):
        root=self.root/'installed'
        for name in [*MODULES,'ashui']:
            library=root/name/'0,2,3';library.mkdir(parents=True)
            (library/'haxelib.json').write_text(json.dumps({'name':name,'version':'0.2.3'}))
            (library.parent/'.current').write_text('0.2.3')
            (library/'Source.hx').write_text('published source')
            (library/'web').mkdir();(library/'web/old.mjs').write_text('previous target')
        return root

    def test_private_overlay_installs_verified_modules_without_changing_sources(self):
        repository=self.repository();target=self.root/'overlay'
        overlay(self.bundle,repository,target,self.runtime)
        for package,names in MODULES.items():
            for name in names:
                self.assertEqual((target/package/'0,2,3/web'/name).read_bytes(),(self.source/name).read_bytes())
                self.assertFalse((repository/package/'0,2,3/web'/name).exists())
            self.assertEqual((target/package/'0,2,3/Source.hx').read_text(),'published source')
        self.assertTrue((target/'ashui').is_symlink())

    def test_runtime_mismatch_and_changed_modules_are_refused_before_overlay_creation(self):
        repository=self.repository();target=self.root/'overlay'
        self.runtime.write_bytes(WASM+b'runtime-two')
        with self.assertRaisesRegex(ValueError,'another preview runtime'):
            overlay(self.bundle,repository,target,self.runtime)
        self.assertFalse(target.exists())
        self.runtime.write_bytes(WASM+b'runtime-one')
        (self.bundle/'xwindow.mjs').write_text('changed')
        with self.assertRaisesRegex(ValueError,'module changed'):
            verify(self.bundle,self.runtime)

    def test_missing_or_linked_payloads_are_not_accepted(self):
        (self.bundle/'xwindow.wasm').unlink()
        (self.bundle/'xwindow.wasm').symlink_to(self.source/'xwindow.wasm')
        with self.assertRaisesRegex(ValueError,'regular files'):
            verify(self.bundle,self.runtime)
        (self.source/'xwindow.wasm').unlink()
        with self.assertRaisesRegex(ValueError,'regular files'):
            stage(self.source,self.root/'incomplete',self.runtime)

    def test_native_installation_refuses_development_and_traversing_package_versions(self):
        repository=self.repository();(repository/'hlwindow/.dev').write_text('/some/checkout')
        with self.assertRaisesRegex(ValueError,'released package'):
            overlay(self.bundle,repository,self.root/'dev',self.runtime)
        (repository/'hlwindow/.dev').unlink();(repository/'hlwindow/.current').write_text('../outside')
        with self.assertRaisesRegex(ValueError,'Invalid installed'):
            overlay(self.bundle,repository,self.root/'unsafe',self.runtime)


if __name__=='__main__':unittest.main()

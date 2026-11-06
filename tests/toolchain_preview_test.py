"""Preview image admission rejects incomplete tooling and incompatible compilers before boot."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
spec=importlib.util.spec_from_file_location('prepare_toolchain',ROOT/'scripts/prepare-toolchain.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
from native_web import MODULES, stage

class PreviewToolchain(unittest.TestCase):
    def test_installed_ash_support_preserves_runtime_and_aot_without_copying_unrelated_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);installed=root/'installed';output=root/'output'
            installed.mkdir();output.mkdir()
            for name in ['ash','libash_std.so','libash_std.a','simd.hdll','unrelated-private-file']:
                (installed/name).write_text(name)
            module.copy_ash_support(installed/'ash',output)
            self.assertEqual(sorted(path.name for path in output.iterdir()),['libash_std.a','libash_std.so','simd.hdll'])
            for path in output.iterdir():self.assertEqual(path.read_text(),path.name)

    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.compiler=self.root/'ash'
        self.compiler.write_text('#!/bin/sh\n[ "$1" = "--help" ] || exit 1\necho --codegen-opt-level\n')
        self.compiler.chmod(0o755)
        for name in ['ash_runtime.o','ash_channel.wasm','channel-agent.mjs','rayde_preview_files.mjs','preview-frames.mjs','haxe/rayde/preview/Files.hx']:
            path=self.root/name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(b'\x00asm\x01\x00\x00\x00' if name.endswith(('.o','.wasm')) else b'fixture')
        for names in MODULES.values():
            for name in names:
                (self.root/name).write_bytes(b'\x00asm\x01\x00\x00\x00' if name.endswith('.wasm') else b'fixture')
        stage(self.root,self.root/'native-web',self.root/'ash_runtime.o')

    def test_current_compiler_and_complete_wasm_tools_are_accepted(self):
        module.validate_previews(self.compiler,self.root)

    def test_old_cli_is_rejected_before_image_creation(self):
        self.compiler.write_text('#!/bin/sh\necho old-ash\n')
        with self.assertRaisesRegex(ValueError,'--codegen-opt-level'):
            module.validate_previews(self.compiler,self.root)

    def test_native_runtime_and_missing_bridge_are_rejected(self):
        (self.root/'ash_runtime.o').write_bytes(b'\x7fELF')
        with self.assertRaisesRegex(ValueError,'WebAssembly'):
            module.validate_previews(self.compiler,self.root)
        (self.root/'preview-frames.mjs').unlink()
        with self.assertRaisesRegex(ValueError,'incomplete'):
            module.validate_previews(self.compiler,self.root)

    def test_failing_compiler_is_not_reported_ready(self):
        self.compiler.write_text('#!/bin/sh\nexit 2\n')
        with self.assertRaises(subprocess.CalledProcessError):
            module.validate_previews(self.compiler,self.root)

    def test_missing_or_mismatched_target_modules_are_rejected_before_image_creation(self):
        (self.root/'ash_runtime.o').write_bytes(b'\x00asm\x01\x00\x00\x00changed')
        with self.assertRaisesRegex(ValueError,'another preview runtime'):
            module.validate_previews(self.compiler,self.root)
        (self.root/'native-web').rename(self.root/'saved-native-web')
        with self.assertRaisesRegex(ValueError,'matching native web modules'):
            module.validate_previews(self.compiler,self.root)

    def test_rayzor_revision_is_bound_to_the_executable_and_standard_library(self):
        stdlib=self.root/'stdlib';stdlib.mkdir()
        (stdlib/'StdTypes.hx').write_text('extern class Int {}')
        build={'version':1,'revision':'a'*40,'target':'x86_64-unknown-linux-gnu','profile':'release',
               'sourceArchiveSha256':'b'*64,'binarySha256':module.digest(self.compiler),'stdlibSha256':module.stdlib_digest(stdlib)}
        module.verify_rayzor_build(build,self.compiler,stdlib)
        self.compiler.write_text('another binary')
        with self.assertRaisesRegex(ValueError,'executable differs'):
            module.verify_rayzor_build(build,self.compiler,stdlib)
        build['binarySha256']=module.digest(self.compiler)
        (stdlib/'StdTypes.hx').write_text('extern class Bool {}')
        with self.assertRaisesRegex(ValueError,'standard library differs'):
            module.verify_rayzor_build(build,self.compiler,stdlib)
        for changed in [{'revision':'0.1.0'},{'target':'aarch64-apple-darwin'},{'profile':'dev'},{'sourceArchiveSha256':'missing'}]:
            with self.assertRaisesRegex(ValueError,'Invalid Rayzor release'):
                module.verify_rayzor_build({**build,**changed},self.compiler,stdlib)

if __name__=='__main__':
    unittest.main()

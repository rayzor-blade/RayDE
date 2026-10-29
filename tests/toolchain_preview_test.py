"""Preview image admission rejects incomplete tooling and incompatible compilers before boot."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('prepare_toolchain',ROOT/'scripts/prepare-toolchain.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PreviewToolchain(unittest.TestCase):
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

if __name__=='__main__':
    unittest.main()

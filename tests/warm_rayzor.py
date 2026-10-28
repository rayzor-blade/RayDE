"""Check persisted LSP reuse and invalidation using a real Rayzor process."""
import asyncio
import importlib.util
import os
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('warm_rayzor', ROOT / 'scripts/warm-rayzor.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PersistentCache(unittest.TestCase):
    def test_new_process_reuses_indexes_and_changed_source_invalidates(self):
        command = os.environ.get('RAYZOR_LSP', str(ROOT.parent / 'rayzor/target/release/rayzor'))
        with tempfile.TemporaryDirectory(prefix='rayde warm cache ') as directory:
            root = pathlib.Path(directory)
            (root / 'src').mkdir()
            source = root / 'src/Main.hx'
            source.write_text('class Main { static function main() trace(1); }\n')
            (root / 'build.hxml').write_text('-cp src\n-main Main\n--interp\n')
            first = asyncio.run(module.warm(root, command, 30))
            self.assertEqual(first, {'files': 1, 'indexed': 1, 'reused': 0})
            indexes = list((root / '.rayzor/blade/editor').glob('*.bidx'))
            self.assertEqual(len(indexes), 1)
            before = indexes[0].read_bytes()
            second = asyncio.run(module.warm(root, command, 30))
            self.assertEqual(second, {'files': 1, 'indexed': 0, 'reused': 1})
            self.assertEqual(indexes[0].read_bytes(), before)
            source.write_text('class Main { static function main() trace("Changed"); }\n')
            changed = asyncio.run(module.warm(root, command, 30))
            self.assertEqual(changed['indexed'], 1)
            self.assertNotEqual(indexes[0].read_bytes(), before)

    @unittest.skipIf(os.name == 'nt', 'fixture uses a POSIX executable script')
    def test_timeout_reaps_the_preparation_process(self):
        with tempfile.TemporaryDirectory(prefix='rayde-warm-timeout-') as directory:
            root = pathlib.Path(directory)
            (root / 'src').mkdir()
            (root / 'src/Main.hx').write_text('class Main {}')
            command = root / 'stalled-lsp'
            command.write_text('#!/usr/bin/env python3\nimport os,pathlib,time\npathlib.Path("pid").write_text(str(os.getpid()))\ntime.sleep(60)\n')
            command.chmod(0o700)
            with self.assertRaises(TimeoutError):
                asyncio.run(module.warm(root, str(command), 1))
            pid = int((root / 'pid').read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


if __name__ == '__main__':
    unittest.main()

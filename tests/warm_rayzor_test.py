"""Demo caches are admitted only after settled analysis, including a fresh cached process."""
import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('warm_rayzor', ROOT / 'scripts/warm-rayzor.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WarmRayzor(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'src').mkdir()
        (self.root / 'src/Main.hx').write_text('class Main {}')

    def server(self, *, cached=False, diagnostics=None, transient=False):
        path = self.root / 'lsp'
        path.write_text(f'#!{sys.executable}\n' + '''import json,sys
def send(value):
 data=json.dumps({'jsonrpc':'2.0',**value}).encode()
 sys.stdout.buffer.write(f'Content-Length: {len(data)}\\r\\n\\r\\n'.encode()+data);sys.stdout.buffer.flush()
while True:
 headers={}
 while line:=sys.stdin.buffer.readline().strip():
  key,value=line.split(b':',1);headers[key.lower()]=value.strip()
 if not headers:break
 request=json.loads(sys.stdin.buffer.read(int(headers[b'content-length'])))
 method=request.get('method')
 if method=='initialize':send({'id':request['id'],'result':{'capabilities':{}}})
 elif method=='textDocument/didOpen':
  uri=request['params']['textDocument']['uri']
  def status(state):send({'method':'rayzor/analysisStatus','params':{'uri':uri,'version':1,'state':state}})
  def publish(items):send({'method':'textDocument/publishDiagnostics','params':{'uri':uri,'version':1,'diagnostics':items}})
''' + f'''  if {transient!r}:publish([{{'severity':1,'message':'partial inference'}}])
  if not {cached!r}:status('checking')
  publish(json.loads({json.dumps(json.dumps(diagnostics or []))}))
  status('ready')
''' + ''' elif method=='shutdown':send({'id':request['id'],'result':None})
 elif method=='exit':break
''')
        path.chmod(0o755)
        return str(path)

    def test_partial_errors_are_replaced_by_the_settled_clean_result(self):
        result = asyncio.run(module.warm(self.root, self.server(transient=True), 5))
        self.assertEqual(result, {'files': 1, 'indexed': 1, 'reused': 0, 'errors': 0})

    def test_clean_cached_analysis_and_warnings_are_accepted(self):
        result = asyncio.run(module.warm(self.root, self.server(cached=True, diagnostics=[{'severity':2,'message':'warning'}]), 5))
        self.assertEqual(result['reused'], 1)
        self.assertEqual(result['errors'], 0)

    def test_settled_errors_are_refused_from_live_and_cached_analysis(self):
        for cached in [False, True]:
            with self.subTest(cached=cached), self.assertRaisesRegex(ValueError, r'1 error\(s\) in Main.hx: broken macro'):
                asyncio.run(module.warm(self.root, self.server(cached=cached, diagnostics=[{'severity':1,'message':'broken macro'}]), 5))


if __name__ == '__main__':
    unittest.main()

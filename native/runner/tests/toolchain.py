"""Guest-side integration probe, invoked by the explicit MSB test."""
import json
from pathlib import Path
import select
import subprocess
import time

subprocess.run(['haxe','-cp','src','-main','Main','-hl','probe.hl'],check=True,timeout=30)
assert 'toolchain-ready' in subprocess.check_output(['ash','probe.hl'],text=True,timeout=30)
Path('probe.hl').unlink()

lsp=subprocess.Popen(['rayzor','lsp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0)
def send(value):
    data=json.dumps(value).encode();lsp.stdin.write(f'Content-Length: {len(data)}\r\n\r\n'.encode()+data);lsp.stdin.flush()
def reply(expected):
    deadline=time.monotonic()+45
    while time.monotonic()<deadline:
        assert select.select([lsp.stdout],[],[],max(0,deadline-time.monotonic()))[0], 'LSP response timed out'
        headers={}
        while line:=lsp.stdout.readline().strip():
            key,value=line.decode().split(':',1);headers[key.lower()]=value.strip()
        data=json.loads(lsp.stdout.read(int(headers['content-length'])))
        if data.get('id')==expected:
            assert 'error' not in data,data
            return data.get('result')
    raise AssertionError('LSP response missing')
try:
    send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'processId':None,'rootUri':Path.cwd().as_uri(),'capabilities':{},'initializationOptions':{'hxml':'build.hxml'}}})
    assert reply(1)['capabilities']
    send({'jsonrpc':'2.0','method':'initialized','params':{}})
    uri=(Path.cwd()/'src/Main.hx').as_uri()
    send({'jsonrpc':'2.0','method':'textDocument/didOpen','params':{'textDocument':{'uri':uri,'languageId':'haxe','version':1,'text':Path('src/Main.hx').read_text()}}})
    send({'jsonrpc':'2.0','id':2,'method':'textDocument/documentSymbol','params':{'textDocument':{'uri':uri}}})
    assert reply(2), 'Rayzor returned no symbols'
finally:
    lsp.kill();lsp.wait()

root=Path('/opt/rayde/extensions/git')
manifest=json.loads((root/'git.rayext').read_text())
host=subprocess.Popen(['/opt/rayde/bin/rayde-extension-host','--root',str(root/'ext'),'--extension','git-probe'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
def message(value):
    host.stdin.write((json.dumps(value)+'\n').encode());host.stdin.flush()
def until(kind):
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        assert select.select([host.stdout],[],[],max(0,deadline-time.monotonic()))[0], 'Extension host timed out'
        line=host.stdout.readline();assert line,'Extension host exited'
        value=json.loads(line)
        assert value['t']!='error',value
        if value['t']==kind:return value
    raise AssertionError('Extension response missing')
try:
    until('ready')
    message({'t':'natives','root':str(root),'capabilities':manifest['capabilities'],'libraries':[{'name':name,**spec} for name,spec in manifest['natives'].items()]})
    until('nativesReady')
    message({'t':'run','name':str(root/'ext/probe.rays'),'source':'native "git2" { function git_libgit2_init():Int32; function git_libgit2_shutdown():Int32; } if (git_libgit2_init() < 0) throw "git init failed"; trace("git-native-ready"); git_libgit2_shutdown();'})
    assert until('log')['message']=='git-native-ready'
finally:
    host.kill();host.communicate(timeout=5)
print('toolchain-build-run-lsp-native-extension-ready')

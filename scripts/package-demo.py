#!/usr/bin/env python3
"""Package the tracked demo sources as browser workspace entries, without build artifacts."""
import base64
import json
import pathlib
import hashlib
import shutil
import sys

source = pathlib.Path(__file__).resolve().parent.parent / 'site/demo'
output = pathlib.Path(sys.argv[1])
root = '/work/pocket-studio'
entries = [{'path':'/work','directory':True,'data':None}, {'path':root,'directory':True,'data':None}]
for path in sorted(source.rglob('*')):
    relative = path.relative_to(source)
    if any(part in ('bin', '.haxelib', '.rayzor', '.rayde', '.git') for part in relative.parts):
        continue
    if path.is_symlink():
        raise SystemExit('Sample sources must not contain symlinks')
    entries.append({'path':root+'/'+relative.as_posix(), 'directory':path.is_dir(), 'data':None if path.is_dir() else base64.b64encode(path.read_bytes()).decode()})
output.parent.mkdir(parents=True,exist_ok=True)
bundle={'version':1,'name':'Pocket Studio','root':root,'project':'pocket-studio/build.hxml','entries':entries}
prepared=source.parent.parent / 'bin/demo-preview/manifest.json'
if prepared.is_file():
    preview=json.loads(prepared.read_text())
    inputs={path.relative_to(source).as_posix():hashlib.sha256(path.read_bytes()).hexdigest()
            for path in source.rglob('*') if path.is_file() and path.relative_to(source).as_posix()!='data/tasks.json'
            and path.relative_to(source).parts[0] not in ('bin','build','Export')
            and not any(part in ('.git','.rayde','.rayzor','.haxelib','.rayde-session') for part in path.relative_to(source).parts)}
    if inputs!=preview['inputs']:
        raise SystemExit('Pocket Studio sources changed; prepare its public preview before packaging')
    release=preview['release']
    if len(release)!=64 or any(char not in '0123456789abcdef' for char in release):
        raise SystemExit('Invalid prepared demo release')
    destination=output.parent / 'demo' / release
    destination.mkdir(parents=True,exist_ok=True)
    for name,digest in preview['files'].items():
        relative=pathlib.PurePosixPath(name)
        if relative.is_absolute() or any(part in ('','.','..') for part in relative.parts):
            raise SystemExit('Invalid prepared demo file')
        path=prepared.parent / 'files' / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise SystemExit('The prepared demo artifact changed')
        target=destination / name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)
    bundle['preview']={key:preview[key] for key in ('release','inputs','configuration')}
    bundle['preview']['entry']='demo/'+release+'/index.html'
output.write_text(json.dumps(bundle,separators=(',',':'))+'\n')

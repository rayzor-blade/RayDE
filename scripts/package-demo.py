#!/usr/bin/env python3
"""Package the tracked demo sources as browser workspace entries, without build artifacts."""
import base64
import json
import pathlib
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
output.write_text(json.dumps({'version':1,'name':'Pocket Studio','root':root,'project':'pocket-studio/build.hxml','entries':entries},separators=(',',':'))+'\n')

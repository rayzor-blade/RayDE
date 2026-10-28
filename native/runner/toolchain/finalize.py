"""Write a content-addressed identity and checksums inside a trusted image builder."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess

root=Path('/opt/rayde')
def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()
files=[]
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        if not path.resolve().is_relative_to(root):
            raise SystemExit('Toolchain contains an external symlink')
        if path.is_file():
            files.append({'path':path.relative_to(root).as_posix(),'sha256':digest(path),'bytes':path.stat().st_size})
        continue
    if not path.is_file() or path.name in ('toolchain.json','SHA256SUMS'):
        continue
    relative=path.relative_to(root).as_posix()
    if any(character in relative for character in ['\n','\r','\\']):
        raise SystemExit('Toolchain has an unsupported filename')
    files.append({'path':relative,'sha256':digest(path),'bytes':path.stat().st_size})
system=set()
for name in ['/usr/bin/git','/usr/bin/neko']:
    system.add(Path(name).resolve())
    output=subprocess.check_output(['ldd',name],text=True)
    for word in output.split():
        if word.startswith('/') and Path(word).is_file():
            system.add(Path(word).resolve())
for path in sorted(system):
    files.append({'path':str(path),'sha256':digest(path),'bytes':path.stat().st_size})
manifest={'version':1,'platform':'linux-'+platform.machine(),'haxe':'4.3.6','systemPackages':subprocess.check_output(['dpkg-query','-W','-f=${Package}=${Version}\n'],text=True).splitlines(),'libraries':{'ashui':'0.2.2','ashui-components':'0.2.2','ashui-icons':'0.2.2'},'files':files}
identity=root/'toolchain.json'
identity.write_text(json.dumps(manifest,separators=(',',':'),sort_keys=True)+'\n')
(root/'SHA256SUMS').write_text(''.join(item['sha256']+'  '+item['path']+'\n' for item in files)+digest(identity)+'  toolchain.json\n')
print('RayDE toolchain identity: '+digest(identity),flush=True)

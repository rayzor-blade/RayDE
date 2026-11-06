"""Build-time only: install a verified, warm demo into the OCI image's private filesystem base."""
import json
from pathlib import Path
import subprocess
import sys


def prepare(image, root, state):
    sys.path.insert(0, str(image))
    from demo_cache import digest, materialize, restore
    bundle = image / 'demo-workspace.json'
    manifest = json.loads((image / 'demo-cache/manifest.json').read_text())
    report = manifest.get('report', {})
    reused = report.get('restored', {})
    if reused.get('files', 0) < 1 or reused.get('reused') != reused.get('files') or report.get('preview') != {'bytecode': True, 'wasm': True}:
        raise ValueError('Container images require verified warm Rayzor and managed preview caches')
    if state.exists() or state.is_symlink():
        raise ValueError('Container image preparation needs a new private state directory')
    materialize(bundle, root)
    restored = restore(root, image / 'demo-cache', digest(bundle))
    if restored.get('status') != 'restored':
        raise ValueError('The container image did not receive its matching prepared caches')
    for stage in ['bytecode', 'wasm']:
        if not (root / '.rayde/preview-cache' / stage / 'manifest.json').is_file():
            raise ValueError('A managed preview cache stage is missing')
    subprocess.run(['git', 'init', '--quiet', '--initial-branch=main', str(root)], check=True, timeout=10)
    subprocess.run(['git', '-C', str(root), 'add', '--all'], check=True, timeout=10)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Pocket Studio', '-c', 'user.email=demo@rayde.invalid',
                    '-c', 'commit.gpgSign=false', 'commit', '--quiet', '-m', 'Start Pocket Studio'], check=True, timeout=10)
    state.mkdir(mode=0o700, parents=True)
    print(json.dumps({'release': digest(bundle), 'cacheFiles': restored['files']}), flush=True)


if __name__ == '__main__':
    prepare(Path('/opt/rayde'), Path('/workspace/project'), Path('/state'))

"""Prepare immutable demo caches, then copy them only into a matching fresh guest."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import secrets
import socket
import subprocess
import tempfile
import time

MAX_BYTES = 64 * 1024 * 1024
MAX_FILES = 4096
RESERVED = {'.git', '.haxelib', '.rayde', '.rayzor', '.rayde-session', 'bin'}


def relative(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or path.as_posix() != value or any(part in ('.', '..') for part in path.parts) or '\\' in value or '\0' in value:
        raise ValueError('Invalid demo cache path')
    return path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def files(root, ignored=()):
    if root.is_symlink():
        raise ValueError('Demo cache inputs cannot contain symlinks')
    result = {}
    for directory, directories, names in os.walk(root, followlinks=False):
        parent = Path(directory)
        directories[:] = [name for name in directories if name not in ignored]
        for name in directories + names:
            path = parent / name
            if path.is_symlink():
                raise ValueError('Demo cache inputs cannot contain symlinks')
        for name in names:
            if name in ignored:
                continue
            path = parent / name
            if not path.is_file():
                raise ValueError('Demo cache inputs must be regular files')
            result[path.relative_to(root).as_posix()] = path
    if len(result) > MAX_FILES or sum(path.stat().st_size for path in result.values()) > MAX_BYTES:
        raise ValueError('Demo cache exceeds its preparation budget')
    return result


def materialize(bundle, root):
    if root.exists() or root.is_symlink():
        raise ValueError('Prepare the demo only in a new workspace directory')
    if bundle.stat().st_size > 3 * 1024 * 1024:
        raise ValueError('Public demo bundle exceeds its size limit')
    value = json.loads(bundle.read_bytes())
    if value.get('version') != 1 or value.get('root') != '/work/pocket-studio' or not isinstance(value.get('entries'), list) or not 1 <= len(value['entries']) <= 256:
        raise ValueError('Invalid public demo bundle')
    planned = {}
    for entry in value['entries']:
        name = entry['path']
        if not isinstance(name, str) or not isinstance(entry.get('directory'), bool):
            raise ValueError('Invalid public demo entry')
        if name in ('/work', value['root']):
            continue
        prefix = value['root'] + '/'
        if not name.startswith(prefix):
            raise ValueError('Demo entry is outside the workspace')
        path = relative(name[len(prefix):])
        if any(part in RESERVED for part in path.parts) or str(path) in planned:
            raise ValueError('Demo entry has a reserved or duplicate path')
        planned[str(path)] = None if entry['directory'] else base64.b64decode(entry['data'], validate=True)
    if sum(len(data) for data in planned.values() if data is not None) > 2 * 1024 * 1024 or planned.get('build.hxml') is None:
        raise ValueError('Invalid demo source inventory')
    if any(str(parent) in planned and planned[str(parent)] is not None for name in planned for parent in PurePosixPath(name).parents):
        raise ValueError('Demo entry has a file as its parent')
    root.mkdir(parents=True)
    for name, data in planned.items():
        path = root / name
        if data is None:
            path.mkdir(parents=True, exist_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)


def seal(root, cache, release, report):
    if cache.exists() or cache.is_symlink():
        raise ValueError('Choose a new immutable cache directory')
    sources = files(root, RESERVED)
    artifacts = {}
    for directory in [root / '.rayzor', root / 'bin', root / '.rayde/preview-cache/bytecode', root / '.rayde/preview-cache/wasm']:
        if directory.exists():
            for _, path in files(directory).items():
                if directory.name == 'bin' and path.suffix != '.hl':
                    continue
                artifacts[path.relative_to(root).as_posix()] = path
    if not any(name.endswith('.bidx') for name in artifacts):
        raise ValueError('Rayzor produced no persisted editor indexes')
    if len(artifacts) > MAX_FILES or sum(path.stat().st_size for path in artifacts.values()) > MAX_BYTES:
        raise ValueError('Prepared caches exceed their byte budget')
    cache.mkdir(parents=True)
    for name, path in artifacts.items():
        target = cache / 'files' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    manifest = {'version': 1, 'release': release, 'root': str(root.resolve()), 'report': report,
                'inputs': {name: {'sha256': digest(path), 'modifiedNs': path.stat().st_mtime_ns} for name, path in sources.items()},
                'artifacts': {name: {'sha256': digest(path), 'bytes': path.stat().st_size} for name, path in artifacts.items()}}
    (cache / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
    return manifest


def restore(root, cache, release):
    manifest = json.loads((cache / 'manifest.json').read_text())
    if manifest.get('version') != 1 or manifest.get('release') != release or manifest.get('root') != str(root.resolve()):
        return {'status': 'cold', 'reason': 'different-demo'}
    if root.is_symlink() or any((root / name).exists() or (root / name).is_symlink() for name in ['.rayzor', 'bin']):
        return {'status': 'cold', 'reason': 'existing-cache'}
    if any((root / name).exists() or (root / name).is_symlink() for name in ['.rayde', '.haxelib', '.rayde-session']):
        return {'status': 'cold', 'reason': 'existing-state'}
    sources = files(root, RESERVED)
    if sources.keys() != manifest['inputs'].keys() or any(digest(path) != manifest['inputs'][name]['sha256'] for name, path in sources.items()):
        return {'status': 'cold', 'reason': 'changed-inputs'}
    artifacts = manifest['artifacts']
    if len(artifacts) > MAX_FILES or sum(item['bytes'] for item in artifacts.values()) > MAX_BYTES:
        raise ValueError('Invalid cache inventory')
    if files(cache / 'files').keys() != artifacts.keys():
        raise ValueError('Prepared cache inventory changed')
    for name, item in artifacts.items():
        path = relative(name)
        preview = len(path.parts) >= 4 and path.parts[:2] == ('.rayde', 'preview-cache') and path.parts[2] in ('bytecode', 'wasm') and (path.parts[3:] == ('manifest.json',) or len(path.parts) >= 5 and path.parts[3] == 'files')
        if path.parts[0] != '.rayzor' and not (path.parts[0] == 'bin' and path.suffix == '.hl') and not preview:
            raise ValueError('Invalid cache artifact')
        source = cache / 'files' / name
        if source.is_symlink() or source.stat().st_size != item['bytes'] or digest(source) != item['sha256']:
            raise ValueError('Prepared cache artifact changed')
    # No project program is running yet; publish only after all inputs and artifacts match.
    with tempfile.TemporaryDirectory(prefix='.rayde-demo-cache-', dir=root) as temporary:
        stage = Path(temporary)
        for name in artifacts:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(cache / 'files' / name, target)
        for name, path in sources.items():
            os.utime(path, ns=(path.stat().st_atime_ns, manifest['inputs'][name]['modifiedNs']))
        for name in ['.rayzor', 'bin', '.rayde']:
            if (stage / name).exists():
                (stage / name).rename(root / name)
    return {'status': 'restored', 'files': len(artifacts), 'bytes': sum(item['bytes'] for item in artifacts.values())}


def warm_preview(root, session, operator, timeout):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        raw_port = listener.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix='rayde-demo-operator-') as temporary:
        directory = Path(temporary)
        token = directory / 'token'
        token.write_text(secrets.token_urlsafe(32))
        token.chmod(0o600)
        # Match direct guest launches rather than inheriting the builder shell's state.
        environment = {name: os.environ[name] for name in ['HOME', 'PATH', 'TERM'] if name in os.environ}
        with (directory / 'session.log').open('w') as output:
            process = subprocess.Popen([str(session), '--root', str(root), '--state-root', str(directory / 'state'),
                                        '--host', '127.0.0.1', '--port', str(port), '--raw-port', str(raw_port), '--token-file', str(token),
                                        '--exec', '--env-file', '/opt/rayde/environment.json', '--preview-tools', '/opt/rayde/preview'], env=environment, stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        with socket.create_connection(('127.0.0.1', raw_port), timeout=1):
                            break
                    except OSError:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise ValueError('Private preview preparation session did not start')
                        time.sleep(.05)
                # The native socket reader must not occupy the operator's only worker.
                result = subprocess.run(['ash', str(operator), f'127.0.0.1:{raw_port}', str(token), '-', '--framed'], cwd=root,
                                        env={**os.environ, 'ASH_WORKERS': '4'}, stdout=subprocess.PIPE, text=True, check=True, timeout=timeout)
                print(result.stdout, end='', flush=True)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for stage in ['bytecode', 'wasm']:
            manifest = root / '.rayde/preview-cache' / stage / 'manifest.json'
            if not manifest.is_file():
                raise ValueError('Preview preparation did not publish both compiler stages')
        return {'reused': result.stdout.count('Reusing unchanged preview bundle.') == 2}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'restore'])
    parser.add_argument('--root', type=Path, default=Path('/workspace/project'))
    parser.add_argument('--cache', type=Path, default=Path('/opt/rayde/demo-cache'))
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--release')
    parser.add_argument('--session-binary', type=Path)
    parser.add_argument('--preview-operator', type=Path)
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if args.action == 'prepare':
        if args.bundle is None or not 1 <= args.timeout <= 600:
            parser.error('Preparation requires a public bundle and a bounded timeout')
        if bool(args.session_binary) != bool(args.preview_operator):
            parser.error('Preview preparation requires both the session binary and operator')
        materialize(args.bundle, args.root)
        subprocess.run(['git', 'init', '--quiet', str(args.root)], check=True, timeout=10)
        expected = {name: digest(path) for name, path in files(args.root, RESERVED).items()}
        subprocess.run(['haxe', 'build.hxml'], cwd=args.root, check=True, timeout=args.timeout)
        warmed = subprocess.run(['python3', str(Path(__file__).with_name('warm-rayzor.py')), '--root', str(args.root), '--command', 'rayzor', '--timeout', str(args.timeout)],
                                check=True, text=True, stdout=subprocess.PIPE, timeout=args.timeout * 2 + 10)
        report = json.loads(warmed.stdout)
        if args.preview_operator:
            warm_preview(args.root, args.session_binary, args.preview_operator, args.timeout)
            report['preview'] = {'bytecode': True, 'wasm': True}
        if {name: digest(path) for name, path in files(args.root, RESERVED).items()} != expected:
            raise ValueError('Preparation changed the public demo sources')
        manifest = seal(args.root, args.cache, digest(args.bundle), report)
        shutil.rmtree(args.root)
        print(json.dumps({'release': manifest['release'], 'report': report, 'files': len(manifest['artifacts'])}))
    else:
        if args.release is None:
            parser.error('Restore requires the provisioned demo release')
        print(json.dumps(restore(args.root, args.cache, args.release)))


if __name__ == '__main__':
    main()

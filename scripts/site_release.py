#!/usr/bin/env python3
"""Prepare, verify and publish complete immutable landing/editor releases."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
POINTER = 'editor-release.json'
PARTS = ('index.html', 'landing.css', 'landing.mjs', 'assets', 'docs', 'dist')
REQUIRED = ('index.html', 'landing.css', 'landing.mjs', 'assets/editor-preview.webp',
            'assets/remix.svg', 'assets/rayde-icon.svg', 'docs/index.html',
            'dist/index.html', 'dist/rayde.wasm', 'dist/ash_browser_bg.wasm',
            'dist/ashui-host.mjs', 'dist/worker.js', 'dist/thread.js',
            'dist/rayde_session.mjs', 'dist/rayde_connection.mjs',
            'dist/rayde-platform.js', 'dist/rayde-page.css',
            'dist/demo-workspace.json', 'dist/libraries.json')
DIGEST = re.compile(r'[a-f0-9]{64}\Z')


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode()


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def safe(path):
    return bool(path) and not path.startswith('/') and '\\' not in path and all(
        part and not part.startswith('.') for part in path.split('/'))


def inventory(root, selected=None):
    files = {}
    for path in selected if selected is not None else sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if path.is_symlink() or not safe(name):
            raise ValueError('Release paths must be public regular files: ' + name)
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError('Release file is missing: ' + name)
        size = path.stat().st_size
        if size > 256 * 1024 * 1024 or len(files) >= 4096:
            raise ValueError('Release exceeds its file or size limit')
        files[name] = {'bytes': size, 'sha256': digest(path)}
    if sum(value['bytes'] for value in files.values()) > 1024 * 1024 * 1024:
        raise ValueError('Release exceeds 1 GiB')
    return files


def complete(root, files):
    for name in REQUIRED:
        if name not in files:
            raise ValueError('Release file is missing: ' + name)
    for name in ('index.html', 'dist/index.html'):
        html = (root / name).read_text().lower()
        if '<html' not in html or '<base' in html:
            raise ValueError('Release entry must declare HTML without its own asset base: ' + name)
    libraries = json.loads((root / 'dist/libraries.json').read_text())
    if not isinstance(libraries, list) or any(not isinstance(name, str) or not re.fullmatch(r'[a-zA-Z0-9_]+', name) for name in libraries):
        raise ValueError('Invalid native library inventory')
    for library in libraries:
        if 'dist/' + library + '.wasm' not in files:
            raise ValueError('Missing WASM side module: ' + library)
    preview = json.loads((root / 'dist/demo-workspace.json').read_text()).get('preview', {})
    release = preview.get('release', '')
    entry = 'demo/' + release + '/index.html'
    if not DIGEST.fullmatch(release) or preview.get('entry') != entry or 'dist/' + entry not in files:
        raise ValueError('The release needs a prepared cached demo preview')


def verify(directory):
    directory = pathlib.Path(directory)
    if directory.is_symlink() or not DIGEST.fullmatch(directory.name):
        raise ValueError('Use the immutable release directory named by its manifest hash')
    manifest_path = directory / 'manifest.json'
    if manifest_path.is_symlink() or not manifest_path.is_file() or manifest_path.stat().st_size > 1024 * 1024:
        raise ValueError('Invalid release manifest')
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    if hashlib.sha256(raw).hexdigest() != directory.name or manifest.get('version') != 1 or encoded(manifest) != raw:
        raise ValueError('Release manifest identity changed')
    actual = inventory(directory, (path for path in sorted(directory.rglob('*')) if path != manifest_path))
    if actual != manifest.get('files'):
        raise ValueError('Release files changed, are missing, or contain unlisted files')
    complete(directory, actual)
    return manifest


def public_paths(source):
    selected = []
    for part in PARTS:
        path = source / part
        selected.extend([path, *sorted(path.rglob('*'))] if path.is_dir() and not path.is_symlink() else [path])
    return selected


def prepare(source, output):
    source, output = pathlib.Path(source).resolve(), pathlib.Path(output).resolve()
    if output == source or source in output.parents:
        raise ValueError('Release output must be outside the site source')
    selected = public_paths(source)
    before = inventory(source, selected)
    complete(source, before)
    output.mkdir(parents=True, exist_ok=True)
    raw = encoded({'version': 1, 'files': before})
    release = hashlib.sha256(raw).hexdigest()
    destination = output / release
    with tempfile.TemporaryDirectory(prefix='preparing-', dir=output) as temporary:
        stage = pathlib.Path(temporary) / release
        stage.mkdir()
        for name in before:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, target)
        (stage / 'manifest.json').write_bytes(raw)
        verify(stage)
        if inventory(source, public_paths(source)) != before:
            raise ValueError('Site files changed while preparing the release; finish the build and retry')
        if destination.exists():
            verify(destination)
        else:
            stage.rename(destination)
    return destination


class R2:
    def __init__(self, bucket):
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,62}', bucket):
            raise ValueError('Invalid editor asset bucket name')
        self.bucket = bucket
        self.cloud = ROOT / 'web/cloud'
        self.wrangler = self.cloud / 'node_modules/.bin/wrangler'

    def command(self, *args):
        subprocess.run([str(self.wrangler), 'r2', 'object', *args], cwd=self.cloud, check=True)

    def get(self, key):
        with tempfile.TemporaryDirectory(prefix='rayde-readback-') as temporary:
            target = pathlib.Path(temporary) / 'object'
            self.command('get', self.bucket + '/' + key, '--remote', '--file', str(target))
            return target.read_bytes()

    def put(self, key, path):
        content_type = {'wasm': 'application/wasm', 'html': 'text/html; charset=utf-8',
                        'mjs': 'text/javascript; charset=utf-8', 'js': 'text/javascript; charset=utf-8',
                        'json': 'application/json', 'css': 'text/css; charset=utf-8',
                        'svg': 'image/svg+xml', 'woff2': 'font/woff2'}.get(path.suffix[1:], 'application/octet-stream')
        self.command('put', self.bucket + '/' + key, '--remote', '--file', str(path), '--content-type', content_type)


def check_remote(directory, store, manifest):
    release = directory.name
    prefix = 'releases/' + release + '/'
    if store.get(prefix + 'manifest.json') != (directory / 'manifest.json').read_bytes():
        raise ValueError('Published release manifest does not match')
    for name, value in manifest['files'].items():
        data = store.get(prefix + name)
        if len(data) != value['bytes'] or hashlib.sha256(data).hexdigest() != value['sha256']:
            raise ValueError('Published release file does not match: ' + name)


def upload(directory, store):
    directory = pathlib.Path(directory)
    manifest = verify(directory)
    prefix = 'releases/' + directory.name + '/'
    # Snapshot and check each file again before handing it to the uploader.
    with tempfile.TemporaryDirectory(prefix='rayde-upload-') as temporary:
        for name, value in manifest['files'].items():
            snapshot = pathlib.Path(temporary) / pathlib.PurePosixPath(name).name
            shutil.copyfile(directory / name, snapshot)
            if snapshot.stat().st_size != value['bytes'] or digest(snapshot) != value['sha256']:
                raise ValueError('Release file changed during upload: ' + name)
            store.put(prefix + name, snapshot)
        snapshot = pathlib.Path(temporary) / 'manifest.json'
        snapshot.write_bytes(encoded(manifest))
        store.put(prefix + 'manifest.json', snapshot)
    check_remote(directory, store, manifest)


def promote(directory, store):
    directory = pathlib.Path(directory)
    manifest = verify(directory)
    check_remote(directory, store, manifest)
    # Promotion and rollback change only the entry pointer, after every byte is verified.
    with tempfile.TemporaryDirectory(prefix='rayde-promote-') as temporary:
        pointer = pathlib.Path(temporary) / POINTER
        pointer.write_bytes(encoded({'version': 1, 'release': directory.name}))
        store.put(POINTER, pointer)
        if store.get(POINTER) != pointer.read_bytes():
            raise ValueError('Release promotion readback did not match')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    pack = commands.add_parser('prepare')
    pack.add_argument('--site', type=pathlib.Path, default=ROOT / 'site')
    pack.add_argument('--output', type=pathlib.Path, default=ROOT / 'bin/site-releases')
    for name in ('verify', 'upload', 'promote'):
        command = commands.add_parser(name)
        command.add_argument('directory', type=pathlib.Path)
        if name != 'verify':
            command.add_argument('--bucket', required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        print(prepare(args.site, args.output))
    elif args.command == 'verify':
        verify(args.directory)
        print('Release verified:', args.directory.name)
    else:
        operation = upload if args.command == 'upload' else promote
        operation(args.directory, R2(args.bucket))
        print('Release ' + args.command + ' verified:', args.directory.name)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))

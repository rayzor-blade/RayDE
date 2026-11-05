"""Bind installed browser target modules to the runtime used by preview builds."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

MODULES = {
    'hlwindow': ('xwindow.wasm', 'xwindow.mjs', 'xwindow_wire.mjs'),
    'hlwgpu': ('xgpu.wasm', 'gpu.mjs', 'gpu-agent.mjs', 'gpu-worker.mjs', 'hlwgpu.js'),
}
WASM = b'\0asm\x01\0\0\0'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('Native web modules must be bounded regular files: ' + path.name)
    if path.suffix in ('.wasm', '.o'):
        with path.open('rb') as stream:
            if stream.read(8) != WASM:
                raise ValueError('Native web modules and runtime must be WebAssembly: ' + path.name)


def stage(source, destination, runtime):
    source, destination, runtime = Path(source), Path(destination), Path(runtime)
    regular(runtime)
    names = [name for names in MODULES.values() for name in names]
    for name in names:
        regular(source / name)
    destination.mkdir(parents=True, exist_ok=True)
    files = {name: digest(source / name) for name in names}
    for name in names:
        shutil.copyfile(source / name, destination / name)
    manifest = {'version': 1, 'runtime': digest(runtime), 'files': files}
    (destination / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
    verify(destination, runtime)


def verify(bundle, runtime):
    bundle, runtime = Path(bundle), Path(runtime)
    regular(runtime)
    manifest = bundle / 'manifest.json'
    regular(manifest)
    if manifest.stat().st_size > 16384:
        raise ValueError('Native web manifest exceeds its limit')
    value = json.loads(manifest.read_bytes())
    names = {name for names in MODULES.values() for name in names}
    if value.get('version') != 1 or value.get('runtime') != digest(runtime):
        raise ValueError('Native web modules belong to another preview runtime')
    if not isinstance(value.get('files'), dict) or set(value['files']) != names:
        raise ValueError('Native web module inventory is incomplete')
    for name, expected in value['files'].items():
        regular(bundle / name)
        if digest(bundle / name) != expected:
            raise ValueError('Native web module changed: ' + name)
    return value


def install(bundle, repository, runtime):
    bundle, repository = Path(bundle), Path(repository)
    verify(bundle, runtime)
    targets = {}
    for package in MODULES:
        library = repository / package
        if (library / '.dev').exists():
            raise ValueError('Native web installation requires a released package: ' + package)
        version = (library / '.current').read_text().strip()
        if not re.fullmatch(r'[0-9][A-Za-z0-9.+_-]*', version):
            raise ValueError('Invalid installed native package version')
        target = library / version.replace('.', ',')
        metadata = json.loads((target / 'haxelib.json').read_bytes())
        if metadata.get('name') != package or metadata.get('version') != version or target.is_symlink():
            raise ValueError('Installed native package identity changed')
        targets[package] = target / 'web'
    for package, target in targets.items():
        target.mkdir(exist_ok=True)
        for name in MODULES[package]:
            shutil.copyfile(bundle / name, target / name)


def overlay(bundle, repository, destination, runtime):
    repository, destination = Path(repository).resolve(strict=True), Path(destination)
    verify(bundle, runtime)
    destination.mkdir()
    for package in repository.iterdir():
        if package.name.startswith('.') or not package.is_dir():
            continue
        target = destination / package.name
        if package.name in MODULES:
            shutil.copytree(package, target)
        else:
            target.symlink_to(package, target_is_directory=True)
    install(bundle, destination, runtime)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    args = parser.parse_args()
    install(args.bundle, args.repository, args.runtime)

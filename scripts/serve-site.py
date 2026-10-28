#!/usr/bin/env python3
"""Serve the landing page and an optional local workspace through the Rust session."""
import argparse
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import signal
import subprocess
import tempfile
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent

def process_environment():
    environment = dict(os.environ)
    if (ROOT.parent / 'ash/target/release/ash').is_file():
        environment['PATH'] = str(ROOT.parent / 'ash/target/release') + os.pathsep + environment.get('PATH','')
    if (ROOT.parent / 'rayzor/target/release/rayzor').is_file():
        environment['PATH'] = str(ROOT.parent / 'rayzor/target/release') + os.pathsep + environment.get('PATH','')
        stdlib = ROOT.parent / 'rayzor/compiler/haxe-std'
        if stdlib.is_dir():
            environment.setdefault('RAYZOR_STD_PATH', str(stdlib))
    return environment

def main():
    def stop(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8732, help='loopback HTTP/session port (0 chooses an available port)')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--workspace', type=pathlib.Path, help='explicitly connect a local project and enable its tools/extensions')
    mode.add_argument('--demo', action='store_true', help='connect the default editable Pocket Studio preview')
    mode.add_argument('--offline', action='store_true', help='serve the browser-only sample without workspace tools')
    parser.add_argument('--prepare-only', action='store_true', help='prepare and verify the persistent demo LSP cache, without serving or opening an editor')
    args = parser.parse_args()
    if args.prepare_only and (args.workspace or args.offline):
        parser.error('--prepare-only prepares the managed Pocket Studio demo')
    if not 0 <= args.port <= 65535:
        parser.error('--port must be between 0 and 65535')
    if not (ROOT / 'site/dist/rayde.wasm').is_file():
        parser.error('Build the editor first: bash scripts/build-site.sh')
    binary = ROOT / 'native/session/target/debug/rayde-session'
    if not binary.is_file():
        subprocess.run(['cargo', 'build', '--manifest-path', str(ROOT / 'native/session/Cargo.toml')], check=True)
    if not args.workspace and not args.offline:
        demo = pathlib.Path.home() / '.rayde-session/demos/pocket-studio'
        if not demo.exists():
            shutil.copytree(ROOT / 'site/demo', demo, ignore=shutil.ignore_patterns('bin', '.haxelib', '.rayzor', '.rayde'))
            for command in [['init','-b','main'],['add','.'],['-c','user.name=Pocket Studio','-c','user.email=demo@example.invalid','commit','-m','Start Pocket Studio']]:
                subprocess.run(['git','-C',str(demo),*command], check=True, stdout=subprocess.DEVNULL)
            guide = demo / 'README.md'
            guide.write_text(guide.read_text() + '\nThis editable local preview keeps its own Git history and saved files.\n')
            subprocess.run(['git','-C',str(demo),'add','README.md'],check=True)
            subprocess.run(['git','-C',str(demo),'-c','user.name=Pocket Studio','-c','user.email=demo@example.invalid','commit','-m','Add the local preview guide'],check=True,stdout=subprocess.DEVNULL)
        ignore = demo / '.gitignore'
        contents = ignore.read_text() if ignore.exists() else ''
        if '.rayde/' not in contents.splitlines():
            ignore.write_text(contents.rstrip('\n') + '\n.rayde/\n')
        if not (demo / '.haxelib').exists():
            subprocess.run(['haxelib','newrepo'],cwd=demo,check=True)
        for name in ['ashui-components','ashui-icons']:
            ready = subprocess.run(['haxelib','path',name+':0.1.5'],cwd=demo,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if ready.returncode:
                subprocess.run(['haxelib','install',name,'0.1.5','--always','--quiet'],cwd=demo,check=True)
        args.workspace = demo / 'build.hxml'
    workspace = args.workspace.resolve() if args.workspace else None
    if workspace and not workspace.exists():
        parser.error('The workspace does not exist')
    environment = process_environment()
    if args.prepare_only:
        config = pathlib.Path.home() / '.rayde-session/environment.json'
        if config.is_file():
            values = json.loads(config.read_text())
            if not isinstance(values, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in values.items()):
                parser.error('Session environment must be a JSON string map')
            environment.update(values)
        return subprocess.run(['python3', str(ROOT / 'scripts/warm-rayzor.py'), '--root', str(workspace.parent),
                               '--file', 'src/Main.hx', '--file', 'src/ui/BoardApp.hx'], env=environment).returncode
    with tempfile.TemporaryDirectory(prefix='rayde-site-') as temporary:
        project = workspace.name if workspace and workspace.is_file() else None
        directory = workspace.parent if project else workspace
        command = [str(binary), '--root', str(directory or temporary), '--port', str(args.port), '--web', str(ROOT / 'site')]
        if workspace:
            host = ROOT / 'bin/rayde-extension-host'
            if not host.is_file():
                parser.error('Build the extension host first: bash scripts/build-rayscript.sh')
            command += ['--exec', '--extension-host', str(host), '--extensions', str(ROOT / 'extensions')]
            if (ROOT / 'bin/preview-tools/haxe').is_dir():
                command += ['--preview-tools', str(ROOT / 'bin/preview-tools')]
            profile = pathlib.Path.home() / '.rayde-session/site-preview' / hashlib.sha256(str(directory).encode()).hexdigest()
            profile.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(profile, 0o700)
            token_file = profile / 'token'
            if not token_file.exists():
                try:
                    with os.fdopen(os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as token:
                        token.write(secrets.token_urlsafe(32))
                except FileExistsError:
                    pass
            command += ['--token-file', str(token_file)]
            if not project:
                project = next((name for name in ['build.hxml', 'rayzor.toml', 'haxelib.json'] if (workspace / name).is_file()), None)
            command += ['--preview-project', project or '']
        else:
            command += ['--state-root', str(pathlib.Path(temporary) / 'private-state')]
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
        endpoint = None
        try:
            for line in child.stdout:
                value = line.strip()
                if value.startswith('http://'):
                    address = urllib.parse.urlsplit(value)
                    endpoint = urllib.parse.urlunsplit(('ws', address.netloc, '/session', '', ''))
                elif value.startswith('token ') and endpoint:
                    socket = urllib.parse.urlsplit(endpoint)
                    url = urllib.parse.urlunsplit(('http', socket.netloc, '/', '', ''))
                    print('RayDE landing page: ' + url, flush=True)
                    print('Press Ctrl+C to stop. ' + ('Local workspace tools are enabled.' if workspace else 'Browser demo; no local workspace is exposed.'), flush=True)
                else:
                    print(line, end='', flush=True)
            return child.wait()
        except KeyboardInterrupt:
            return 0
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGINT)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    child.wait(timeout=5)

if __name__ == '__main__':
    raise SystemExit(main())

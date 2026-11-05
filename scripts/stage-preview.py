#!/usr/bin/env python3
"""Stage the host-owned Haxe filesystem adapter and browser app bridge."""
from pathlib import Path
import argparse
import os
import shutil
from native_web import stage as stage_native_web

ROOT = Path(__file__).resolve().parent.parent

def stage(output, bundle, runtime=None, native_web=None, ash='ash'):
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'preview/haxe', output / 'haxe', dirs_exist_ok=True)
    for source, name in [(bundle / 'ash_channel.wasm', 'ash_channel.wasm'),
                         (bundle / 'channel-agent.mjs', 'channel-agent.mjs'),
                         (ROOT / 'preview/app-files.mjs', 'rayde_preview_files.mjs'),
                         (ROOT / 'web/session/src/frames.js', 'preview-frames.mjs')]:
        shutil.copy2(source, output / name)
    if runtime is None:
        executable = shutil.which(str(ash))
        if executable:
            installed = Path(executable).resolve().parent / 'wasm32-wasip1-threads/ash_runtime.o'
            if installed.is_file():
                runtime = installed
    if native_web and runtime is None:
        raise ValueError('Provide the installed WASI preview runtime with --runtime')
    if runtime:
        shutil.copy2(runtime, output / 'ash_runtime.o')
    if native_web:
        stage_native_web(native_web, output / 'native-web', output / 'ash_runtime.o')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'bin/preview-tools')
    parser.add_argument('--bundle', type=Path, default=ROOT / 'site/dist')
    parser.add_argument('--runtime', type=Path, default=os.environ.get('ASH_RUNTIME'))
    parser.add_argument('--native-web', type=Path, help='installed window/GPU target modules from the matching browser bundle')
    parser.add_argument('--ash', default=os.environ.get('ASH', 'ash'))
    args = parser.parse_args()
    stage(args.output, args.bundle, args.runtime, args.native_web, args.ash)

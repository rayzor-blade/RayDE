#!/usr/bin/env python3
"""Stage the host-owned Haxe filesystem adapter and browser app bridge."""
from pathlib import Path
import argparse
import shutil

ROOT = Path(__file__).resolve().parent.parent

def stage(output, bundle, runtime=None):
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'preview/haxe', output / 'haxe', dirs_exist_ok=True)
    for source, name in [(bundle / 'ash_channel.wasm', 'ash_channel.wasm'),
                         (bundle / 'channel-agent.mjs', 'channel-agent.mjs'),
                         (ROOT / 'preview/app-files.mjs', 'rayde_preview_files.mjs'),
                         (ROOT / 'web/session/src/frames.js', 'preview-frames.mjs')]:
        shutil.copy2(source, output / name)
    if runtime:
        shutil.copy2(runtime, output / 'ash_runtime.o')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'bin/preview-tools')
    parser.add_argument('--bundle', type=Path, default=ROOT / 'site/dist')
    parser.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    stage(args.output, args.bundle, args.runtime)

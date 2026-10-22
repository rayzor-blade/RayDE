"""Runs a memory probe program once per mode and samples its physical footprint with vmmap at each record it prints.

  [WELCOME_MEMORY_OUT=<folder under bin>] [WELCOME_MEMORY_MODES=a,b] [ASHUI_WINDOW_SECONDS=<n>] [MEMORY_PROBE_ROOTS=1 with ASH_GC_DEBUG_ROOTS=1 keeps the collector's root report in the log] python3 tests/memory_probe.py bin/<probe>
"""
import json
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path.cwd()
out = root / 'bin' / os.environ.get('WELCOME_MEMORY_OUT', 'welcome-memory-results')
out.mkdir(exist_ok=True)
(out / 'empty-extensions').mkdir(exist_ok=True)
program = root / (sys.argv[1] if len(sys.argv) > 1 else 'bin/welcome-memory')
context = {'buildHxml': (root / 'build.hxml').read_text(), 'buildSha256': hashlib.sha256((root / 'build.hxml').read_bytes()).hexdigest(),
           'program': str(program), 'programSha256': hashlib.sha256(program.read_bytes()).hexdigest(), 'libraries': {}}
for library in sorted([*program.parent.glob('*.dylib'), *program.parent.glob('*.hdll')]):
    context['libraries'][library.name] = hashlib.sha256(library.read_bytes()).hexdigest()
(out / 'context.json').write_text(json.dumps(context, indent=2))
results = []
for mode in os.environ.get('WELCOME_MEMORY_MODES', 'minimal,full,no-ext,no-explorer').split(','):
    ack = out / (mode + '.ack')
    ack.unlink(missing_ok=True)
    env = dict(os.environ, WELCOME_MEMORY_MODE=mode, WELCOME_MEMORY_ACK=str(ack), ASHUI_WINDOW_SECONDS=os.environ.get('ASHUI_WINDOW_SECONDS', '30'), ASH_GC_STATS='1', HOME=str(out / 'home'))
    if os.environ.get('MEMORY_PROBE_KEEP_HOME') == '1':
        env['HOME'] = os.environ['HOME']
    if not os.environ.get('MEMORY_PROBE_ROOTS'):
        env.pop('ASH_GC_DEBUG_ROOTS', None)
    env.pop('ASH_GC_IDLE', None)
    env['RAYDE_EXTENSIONS'] = str(out / 'empty-extensions' if mode == 'no-ext' else Path(os.environ.get('MEMORY_PROBE_EXTENSIONS', root / 'bin/RayDE.app/Contents/Resources/extensions')))
    with (out / (mode + '.log')).open('w') as log:
        process = subprocess.Popen([str(program)], cwd=root, env=env, stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            for line in process.stdout:
                log.write(line); log.flush()
                if not line.startswith('welcome-memory:'):
                    continue
                record = json.loads(line.split(':', 1)[1])
                mapping = subprocess.run(['vmmap', '-summary', str(process.pid)], capture_output=True, text=True)
                phase = re.sub(r'[^A-Za-z0-9_.-]', '_', str(record['mode']))
                (out / (mode + '-' + phase + '-vmmap.txt')).write_text(mapping.stdout + mapping.stderr)
                match = re.search(r'Physical footprint:\s+([\d.]+)([KMGT])', mapping.stdout)
                record['physicalFootprintBytes'] = int(float(match[1]) * 1024 ** ('KMGT'.index(match[2]) + 1)) if match else None
                if os.environ.get('MEMORY_PROBE_CHILDREN') == '1':
                    children = []
                    table = subprocess.run(['ps', '-axo', 'pid=,ppid=,comm='], capture_output=True, text=True).stdout.splitlines()
                    for row in table:
                        parts = row.strip().split(None, 2)
                        if len(parts) != 3 or int(parts[1]) != process.pid:
                            continue
                        child = subprocess.run(['vmmap', '-summary', parts[0]], capture_output=True, text=True)
                        (out / (mode + '-' + phase + '-child-' + parts[0] + '-vmmap.txt')).write_text(child.stdout + child.stderr)
                        size = re.search(r'Physical footprint:\s+([\d.]+)([KMGT])', child.stdout)
                        children.append(dict(pid=int(parts[0]), command=parts[2], footprintBytes=int(float(size[1]) * 1024 ** ('KMGT'.index(size[2]) + 1)) if size else None))
                    record['children'] = children
                results.append(record)
                (out / 'results.json').write_text(json.dumps(results, indent=2))
                print(json.dumps(record), flush=True)
                ack.touch()
            code = process.wait()
            if code:
                raise RuntimeError(f'{mode} exited {code}: {(out / (mode + ".log")).read_text()[-3000:]}')
        finally:
            if process.poll() is None:
                process.terminate()

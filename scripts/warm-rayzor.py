#!/usr/bin/env python3
"""Prepare Rayzor's own persisted editor indexes without starting an editor."""
import argparse
import asyncio
import json
import os
import pathlib
import sys


async def warm(root, command, timeout, progress=None, files=None):
    root = root.resolve(strict=True)
    sources = sorted(path for path in (root / 'src').rglob('*.hx')
                     if not path.is_symlink() and path.resolve().is_relative_to(root))
    if files:
        selected = {(root / name).resolve(strict=True) for name in files}
        sources = [path for path in sources if path.resolve() in selected]
        if len(sources) != len(selected):
            raise ValueError('Prepared files must be Haxe sources inside the demo src directory')
    if not sources or len(sources) > 256:
        raise ValueError('Expected 1 to 256 Haxe sources in the demo src directory')
    documents = [(path.as_uri(), path.read_bytes().decode('utf-8')) for path in sources]
    if sum(len(text.encode('utf-8')) for _, text in documents) > 8 * 1024 * 1024:
        raise ValueError('Demo sources exceed the preparation limit')
    process = await asyncio.create_subprocess_exec(
        command, 'lsp', cwd=root, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    if hasattr(os, 'setpriority'):
        try:
            os.setpriority(os.PRIO_PROCESS, process.pid, 10)
        except PermissionError:
            pass

    async def send(message):
        body = json.dumps({'jsonrpc': '2.0', **message}).encode()
        process.stdin.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
        await process.stdin.drain()

    async def receive():
        header = await process.stdout.readuntil(b'\r\n\r\n')
        fields = dict(line.split(b':', 1) for line in header.strip().split(b'\r\n'))
        length = int(next(value for key, value in fields.items() if key.lower() == b'content-length'))
        if not 0 < length <= 8 * 1024 * 1024:
            raise ValueError('Invalid LSP response length')
        return json.loads(await process.stdout.readexactly(length))

    async def reply(request):
        if request.get('method') and 'id' in request:
            await send({'id': request['id'], 'result': None})

    async def response(identifier):
        while True:
            message = await receive()
            if message.get('id') == identifier and not message.get('method'):
                if 'error' in message:
                    raise ValueError('Rayzor rejected the preparation request')
                return message.get('result')
            await reply(message)

    report = {'files': len(documents), 'indexed': 0, 'reused': 0}
    try:
        async with asyncio.timeout(timeout):
            await send({'id': 1, 'method': 'initialize', 'params': {
                'processId': None, 'rootUri': root.as_uri(), 'rootPath': str(root),
                'workspaceFolders': [{'uri': root.as_uri(), 'name': root.name}],
                'capabilities': {'experimental': {'rayzorIndexProgress': True}},
                # Match the built-in Rayzor extension's default analysis budget.
                'initializationOptions': {'macroBudgetMs': 5000}}})
            await response(1)
            await send({'method': 'initialized', 'params': {}})
            for uri, text in documents:
                if progress:
                    progress(uri)
                await send({'method': 'textDocument/didOpen', 'params': {'textDocument': {
                    'uri': uri, 'languageId': 'haxe', 'version': 1, 'text': text}}})
                indexed = False
                while True:
                    message = await receive()
                    await reply(message)
                    params = message.get('params', {})
                    if message.get('method') == 'rayzor/analysisStatus' and params.get('uri') == uri:
                        indexed |= params.get('state') == 'checking'
                        if params.get('state') == 'ready':
                            report['indexed' if indexed else 'reused'] += 1
                            break
                await send({'method': 'textDocument/didClose', 'params': {'textDocument': {'uri': uri}}})
            await send({'id': 2, 'method': 'shutdown', 'params': None})
            await response(2)
            await send({'method': 'exit', 'params': None})
            process.stdin.close()
            if await process.wait() != 0:
                raise ValueError('Rayzor did not shut down cleanly')
        return report
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--command', default=os.environ.get('RAYZOR_LSP', 'rayzor'))
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--file', action='append', help='prepare a workspace-relative Haxe file (repeatable; default: all src files)')
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600:
        parser.error('--timeout must be between 1 and 600 seconds')
    try:
        def progress(uri):
            print('Rayzor cache: ' + uri.rsplit('/', 1)[-1], file=sys.stderr, flush=True)
        prepared = asyncio.run(warm(args.root, args.command, args.timeout, progress, args.file))
        restored = asyncio.run(warm(args.root, args.command, args.timeout, progress, args.file))
        if restored['reused'] != restored['files']:
            raise ValueError('A fresh Rayzor process could not reuse all prepared editor indexes')
        print(json.dumps({'prepared': prepared, 'restored': restored}))
        return 0
    except (OSError, ValueError, TimeoutError, asyncio.IncompleteReadError) as error:
        reason = f'timed out after {args.timeout} seconds' if isinstance(error, TimeoutError) else str(error)
        print(f'Rayzor cache preparation failed: {reason}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

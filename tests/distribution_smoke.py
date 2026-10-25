#!/usr/bin/env python3
"""Run the extracted AOT package and both extension/LSP subprocess protocols."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile


def windows_loader_report(bindir, env):
    probe = """import ctypes, os, sys
with os.add_dll_directory(sys.argv[1]):
    ctypes.WinDLL(sys.argv[2])
print('loaded')
"""
    report = []
    for path in sorted(bindir.iterdir()):
        if path.suffix.lower() not in (".dll", ".hdll"):
            continue
        try:
            result = subprocess.run([sys.executable, "-c", probe, str(bindir), str(path)], env=env, capture_output=True, text=True, timeout=15)
            report.append(f"{path.name}: exit {result.returncode} (0x{result.returncode & 0xffffffff:08X})\n{result.stdout}{result.stderr}")
        except (OSError, subprocess.TimeoutExpired) as error:
            report.append(f"{path.name}: {error}")
    return "\n".join(report)


def extension_host(binary, extensions, env):
    git = extensions / "git"
    definition = json.loads((git / "git.rayext").read_text())
    native = definition["natives"]["git2"]
    process = subprocess.Popen([binary, "--root", git / "ext"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    messages = queue.Queue()
    errors = []
    def read():
        for line in process.stdout:
            try:
                messages.put(json.loads(line))
            except ValueError as error:
                messages.put(error)
        messages.put(EOFError("Extension host closed its protocol"))
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    error_reader = threading.Thread(target=lambda: errors.append(process.stderr.read()), daemon=True)
    error_reader.start()
    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
    def until(kind):
        end = time.monotonic() + 30
        while True:
            message = messages.get(timeout=max(.001, end - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            if message["t"] == "error":
                raise RuntimeError(message)
            if message["t"] == kind:
                return message
    try:
        until("ready")
        send({"t": "natives", "root": str(git), "capabilities": ["native:git2"], "libraries": [{"name": "git2", **native}]})
        until("nativesReady")
        send({"t": "run", "name": "distribution-check.rays", "source": "import gitNative.version; import haxe.Json.stringify; trace('@version:' + stringify(version()));"})
        while True:
            message = until("log")
            if message["message"].startswith("@version:"):
                version = json.loads(message["message"].removeprefix("@version:"))
                assert [version[k] for k in ["major", "minor", "patch"]] == [1, 9, 7], version
                break
        send({"t": "shutdown"})
        process.stdin.close()
        process.wait(timeout=15)
        assert process.returncode == 0, errors
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        reader.join(timeout=2)
        error_reader.join(timeout=2)
        process.stdout.close()
        process.stderr.close()


def lsp(binary, env, cwd):
    process = subprocess.Popen([binary, "lsp"], cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    replies = queue.Queue()
    def read():
        try:
            while True:
                length = None
                while True:
                    line = process.stdout.readline()
                    if not line:
                        raise EOFError("Rayzor exited before its response")
                    if line in (b"\r\n", b"\n"):
                        break
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":", 1)[1])
                if length is None:
                    raise ValueError("No LSP Content-Length header")
                body = process.stdout.read(length)
                if len(body) != length:
                    raise EOFError("Truncated LSP response")
                replies.put(json.loads(body))
        except Exception as error:
            replies.put(error)
    threading.Thread(target=read, daemon=True).start()
    errors = []
    threading.Thread(target=lambda: errors.append(process.stderr.read()), daemon=True).start()
    def send(message):
        body = json.dumps({"jsonrpc": "2.0", **message}).encode()
        process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        process.stdin.flush()
    def response(id):
        end = time.monotonic() + 45
        while True:
            message = replies.get(timeout=max(.001, end - time.monotonic()))
            if isinstance(message, Exception):
                raise message
            if message.get("id") == id:
                if "error" in message:
                    raise RuntimeError(message)
                return message
    try:
        send({"id": 1, "method": "initialize", "params": {"processId": os.getpid(), "rootUri": Path(cwd).as_uri(), "capabilities": {}, "workspaceFolders": []}})
        assert "capabilities" in response(1)["result"]
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "shutdown", "params": None})
        response(2)
        send({"method": "exit", "params": None})
        process.wait(timeout=15)
        assert process.returncode == 0, errors
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--platform", choices=["macos", "linux", "windows"], required=True)
    args = parser.parse_args()
    module = Path(__file__).resolve().parent.parent / "scripts/distribution.py"
    spec = importlib.util.spec_from_file_location("distribution", module)
    distribution = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(distribution)
    with tempfile.TemporaryDirectory(prefix="rayde relocated package ") as temp:
        temp = Path(temp)
        if args.archive.name.endswith(".zip"):
            if args.platform == "macos":
                subprocess.run(["ditto", "-x", "-k", str(args.archive.resolve()), str(temp)], check=True)
            else:
                with zipfile.ZipFile(args.archive) as archive:
                    archive.extractall(temp)
        else:
            with tarfile.open(args.archive) as archive:
                archive.extractall(temp, filter="data")
        root = next(p for p in temp.iterdir() if p.is_dir() and p.name != "__MACOSX")
        distribution.validate(root, args.platform)
        bindir, data, extensions, program, rayzor = distribution.layout(root, args.platform)
        home = temp / "clean home"
        home.mkdir()
        cwd = temp / "unrelated working directory"
        cwd.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("RAYDE_", "RAYSCRIPT_", "RAYZOR_", "ASH", "HL_", "DYLD_", "LD_LIBRARY_PATH", "HAXE_", "HAXELIB_"))}
        env.update(HOME=str(home), USERPROFILE=str(home))
        # Resolve everything from the package or the OS, without development tools on PATH.
        env["PATH"] = os.pathsep.join([str(bindir), str(Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32")]) if args.platform == "windows" else "/usr/bin:/bin"
        result = subprocess.run([bindir / program, "--check-install"], cwd=cwd, env=env, capture_output=True, text=True, timeout=45)
        if result.returncode or "RayDE installation check passed" not in result.stdout:
            detail = f"{program} --check-install: exit {result.returncode} (0x{result.returncode & 0xffffffff:08X})\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            if args.platform == "windows":
                detail += "\nWindows library loader probes:\n" + windows_loader_report(bindir, env)
            raise RuntimeError(detail)
        host = bindir / ("rayde-extension-host.exe" if args.platform == "windows" else "rayde-extension-host")
        extension_host(host, extensions, env)
        env["RAYZOR_STD_PATH"] = str(data / "haxe-std")
        lsp(str(data / rayzor), env, str(cwd))
        print("Extracted package: AOT startup, built-ins, embedded/isolated extension hosts, libgit2 and Rayzor LSP passed")


if __name__ == "__main__":
    main()

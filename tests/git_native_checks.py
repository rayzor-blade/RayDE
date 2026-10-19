"""Real libgit2 integration through the editor's native-grant protocol."""

import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import statistics
import time
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "bin" / "git-native-checks"
EXTENSION = ROOT / "extensions" / "git"
HOST = os.environ.get("RAYSCRIPT_HOST", str(ROOT.parent / "rayscript/target/release/rayscript-host"))
LIBRARY = EXTENSION / "natives" / ("libgit2.dylib" if os.uname().sysname == "Darwin" else "libgit2.so")


def git(root, *args, ok=True):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, env=GIT_ENV)
    if ok and result.returncode:
        raise AssertionError(result.stderr.decode())
    return result


GIT_ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.test",
               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.test",
               GIT_TERMINAL_PROMPT="0")


class Host:
    def __enter__(self):
        self.errors = open(FIXTURE / "host.stderr", "a")
        self.process = subprocess.Popen([HOST, "--root", str(EXTENSION / "ext")],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.errors, text=True)
        self.messages = queue.Queue()

        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.send({"t": "natives", "root": str(EXTENSION), "capabilities": ["native:git2"],
                   "libraries": [{"name": "git2", "path": "natives/" + LIBRARY.name,
                                  "sha256": hashlib.sha256(LIBRARY.read_bytes()).hexdigest()}]})
        try:
            self.until("nativesReady")
        except BaseException:
            self.__exit__()
            raise
        return self

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def until(self, kind):
        while True:
            message = self.messages.get(timeout=30)
            if message is None:
                raise AssertionError("extension host ended before " + kind)
            if message["t"] == "error":
                raise AssertionError(message)
            if message["t"] == kind:
                return message

    def run(self, source):
        self.send({"t": "run", "name": "git-check.rays", "source": source})
        while True:
            message = self.until("log")
            if message["message"].startswith("@result:"):
                return json.loads(message["message"][8:])

    def __exit__(self, *error):
        try:
            self.send({"t": "shutdown"})
            self.process.stdin.close()
            self.process.wait(timeout=5)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process.stdout.close()
            self.errors.close()


PREAMBLE = """
import haxe.Json.stringify;
import gitNative.inspect;
import gitNative.version;
import gitNative.withRepository;
import gitNative.status;
import gitNative.statusFlags;
import gitNative.eachStatus;
import gitNative.diff;
function emit(value) { trace('@result:' + stringify(value)); }
function text(snapshot) {
  for (part in [snapshot.staged, snapshot.changes])
    for (line in part.lines) { line.text = line.bytes.toString(); line.bytes = null; }
  return snapshot;
}
"""


def write(root, name, content):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())


def init(name):
    root = FIXTURE / name
    root.mkdir()
    git(root, "init", "-b", "main")
    git(root, "config", "core.autocrlf", "false")
    git(root, "config", "core.hooksPath", str(FIXTURE / "no-hooks"))
    return root


def inspect(root):
    with Host() as host:
        return host.run(PREAMBLE + """
var snapshot = inspect(REPO);
snapshot.flags = withRepository(REPO, repository -> statusFlags(repository));
emit(text(snapshot));
""".replace("REPO", json.dumps(str(root))))


def main():
    if FIXTURE.exists():
        shutil.rmtree(FIXTURE)
    FIXTURE.mkdir(parents=True)
    assert LIBRARY.is_file(), "run scripts/check-git.sh first"
    probe = FIXTURE / "layout"
    subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-I", str(ROOT / ".deps/libgit2-1.9.7/include"),
                    str(ROOT / "tests/fixtures/git-native/layout.c"), "-o", str(probe)], check=True)
    subprocess.run([str(probe)], check=True)
    root = init("repository")
    for name in ["clean.txt", "modified.txt", "staged.txt", "renamed.txt", "conflict.txt", "deleted.txt"]:
        write(root, name, "before\nsecond line\n")
    write(root, "binary.dat", b"\x00old binary\xff")
    write(root, ".gitignore", "ignored.txt\n")
    git(root, "add", ".")
    git(root, "commit", "-m", "base")
    git(root, "checkout", "-b", "other")
    write(root, "conflict.txt", "other\n")
    git(root, "commit", "-am", "other")
    git(root, "checkout", "main")
    write(root, "conflict.txt", "main\n")
    git(root, "commit", "-am", "main")
    assert git(root, "merge", "other", ok=False).returncode != 0
    write(root, "modified.txt", "after \u2603\nsecond line\n")
    write(root, "staged.txt", "staged change\nsecond line\n")
    git(root, "add", "staged.txt")
    git(root, "mv", "renamed.txt", "new name.txt")
    (root / "deleted.txt").unlink()
    write(root, "untracked.txt", "untracked\n")
    write(root, "nested/new.txt", "nested\n")
    write(root, "ignored.txt", "ignored\n")
    write(root, "binary.dat", b"\x00new binary\xfe")
    nested = root / "subfolder"
    nested.mkdir()
    with Host() as host:
        version = host.run(PREAMBLE + "emit(version());")
        assert [version[k] for k in ["major", "minor", "patch"]] == [1, 9, 7], version
        assert version["features"] & 4, version
    snapshot = inspect(nested)
    assert Path(snapshot["workdir"]) == root
    entries = {entry["path"]: entry for entry in snapshot["status"]}
    assert "clean.txt" not in entries and "ignored.txt" not in entries, entries
    assert entries["modified.txt"]["workdir"] & 256, entries
    assert entries["staged.txt"]["index"] & 2, entries
    assert entries["untracked.txt"]["workdir"] & 128, entries
    assert entries["nested/new.txt"]["workdir"] & 128, entries
    assert entries["deleted.txt"]["workdir"] & 512, entries
    assert entries["conflict.txt"]["conflicted"], entries
    assert entries["new name.txt"]["renamedFrom"] == "renamed.txt", entries
    flags = {entry["path"]: entry["flags"] for entry in snapshot["flags"]}
    assert flags["modified.txt"] & 256 and flags["conflict.txt"] & 32768, flags
    assert any(item["path"] == "binary.dat" for item in snapshot["changes"]["binaries"]), snapshot
    assert any(item["path"] == "modified.txt" for item in snapshot["changes"]["hunks"]), snapshot
    assert any(line["text"] == "after \u2603\n" and line["origin"] == ord("+") and line["newLine"] == 1
               for line in snapshot["changes"]["lines"]), snapshot
    assert any(line["text"] == "before\n" and line["origin"] == ord("-") and line["oldLine"] == 1
               for line in snapshot["changes"]["lines"]), snapshot
    assert any(line["text"] == "staged change\n" for line in snapshot["staged"]["lines"]), snapshot
    assert any(item["status"] == 4 and item["oldPath"] == "renamed.txt" for item in snapshot["staged"]["files"]), snapshot
    (FIXTURE / "snapshot.json").write_text(json.dumps(snapshot, indent=2))
    print("git native: version, parent discovery, status, rename, conflict, staged/workdir diff, four callbacks", flush=True)

    empty = init("unborn")
    write(empty, "first.txt", "first\n")
    git(empty, "add", "first.txt")
    result = inspect(empty)
    assert result["status"][0]["index"] & 1, result
    assert result["staged"]["lines"][0]["text"] == "first\n", result
    print("git native: unborn HEAD", flush=True)

    with Host() as host:
        result = host.run(PREAMBLE + """
var errors = [];
try { inspect(PATH); } catch (error) { errors.push(error); }
emit({errors: errors, good: text(inspect(GOOD))});
""".replace("PATH", json.dumps(str(FIXTURE / "missing"))).replace("GOOD", json.dumps(str(root))))
        assert "open repository:" in result["errors"][0], result
        assert result["good"]["status"], result
    print("git native: native errors and recovery", flush=True)

    with Host() as host:
        result = host.run(PREAMBLE + """
var errors = [], calls = 0;
try {
  withRepository(REPO, repository -> eachStatus(repository, (path, flags) -> {
    calls++; gc(); throw 'callback failure';
  }));
} catch (error) { errors.push(error); }
var count = withRepository(REPO, repository -> {
  var count = 0;
  eachStatus(repository, (path, flags) -> { gc(); count++; });
  return count;
});
var snapshot = inspect(REPO);
gc();
emit({errors: errors, calls: calls, count: count, snapshot: text(snapshot)});
""".replace("REPO", json.dumps(str(root))))
        assert result["errors"] == ["callback failure"] and result["calls"] == 1, result
        assert result["count"] >= len(entries), result
        assert any(line["text"] == "after \u2603\n" for line in result["snapshot"]["changes"]["lines"]), result
    print("git native: callback failure, GC, retained copies and recovery", flush=True)

    with Host() as host:
        result = host.run(PREAMBLE + """
var first = spawn(() -> inspect(FIRST));
var second = spawn(() -> inspect(SECOND));
emit({first: text(await first), second: text(await second)});
""".replace("FIRST", json.dumps(str(root))).replace("SECOND", json.dumps(str(empty))))
        assert result["first"]["status"] and result["second"]["status"], result
    print("git native: concurrent Krio script fibers", flush=True)

    if "--benchmark" in sys.argv:
        large = init("large")
        for index in range(10000):
            write(large, f"files/{index:05}.txt", "before\n")
        git(large, "add", ".")
        git(large, "commit", "-m", "ten thousand files")
        for index in range(10000):
            write(large, f"files/{index:05}.txt", "after\n")
        with Host() as host:
            source = PREAMBLE + "emit(withRepository(REPO, repository -> status(repository).length));"
            source = source.replace("REPO", json.dumps(str(large)))
            assert host.run(source) == 10000
            elapsed = []
            for _ in range(5):
                start = time.perf_counter()
                assert host.run(source) == 10000
                elapsed.append((time.perf_counter() - start) * 1000)
        print(f"git native: 10k changed files, median warm status {statistics.median(elapsed):.1f} ms", flush=True)


if __name__ == "__main__":
    main()
